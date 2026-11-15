package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"runtime"
	"runtime/debug"
	"strings"
	"time"
	_ "time/tzdata"

	"github.com/gin-gonic/gin"
	"github.com/ory/graceful"
	"golang.org/x/crypto/bcrypt"

	"github.com/nezhahq/nezha/cmd/dashboard/controller"
	"github.com/nezhahq/nezha/cmd/dashboard/controller/waf"
	"github.com/nezhahq/nezha/cmd/dashboard/rpc"
	"github.com/nezhahq/nezha/model"
	geoipx "github.com/nezhahq/nezha/pkg/geoip"
	"github.com/nezhahq/nezha/pkg/idcodec"
	"github.com/nezhahq/nezha/pkg/utils"
	"github.com/nezhahq/nezha/proto"
	"github.com/nezhahq/nezha/service/singleton"
)

type DashboardCliParam struct {
	Version          bool
	ConfigFile       string
	DatabaseLocation string
}

var (
	dashboardCliParam DashboardCliParam
	dashboardHTTP2    = &http.HTTP2Config{MaxConcurrentStreams: 4096}
)

func initSystem(bus chan<- *model.Service) error {
	var usersCount int64
	if err := singleton.DB.Model(&model.User{}).Count(&usersCount).Error; err != nil {
		return err
	}
	if usersCount == 0 {
		hash, err := bcrypt.GenerateFromPassword([]byte("admin"), bcrypt.DefaultCost)
		if err != nil {
			return err
		}
		agentSecret := ""
		if singleton.Conf != nil {
			agentSecret = singleton.Conf.AgentSecretKey
		}
		admin := model.User{
			Username:    "admin",
			Password:    string(hash),
			AgentSecret: agentSecret,
		}
		if err := singleton.DB.Create(&admin).Error; err != nil {
			return err
		}
	}

	if err := singleton.LoadSingleton(bus); err != nil {
		return err
	}

	if _, err := singleton.CronShared.AddFunc("0 30 3 * * *", singleton.CleanMonitorHistory); err != nil {
		return err
	}

	if _, err := singleton.CronShared.AddFunc("0 0 * * * *", func() { singleton.RecordTransferHourlyUsage() }); err != nil {
		return err
	}

	// 每 6 小时强制归还 OS 内存，防止 Go runtime 长期持有未释放内存
	if _, err := singleton.CronShared.AddFunc("0 0 */6 * * *", func() {
		runtime.GC()
		debug.FreeOSMemory()
		log.Println("NEZHA>> MemGC: triggered GC + FreeOSMemory")
	}); err != nil {
		return err
	}

	// 每周日凌晨 4:00 执行 SQLite VACUUM + TSDB flush 维护，防止数据库持续膨胀占用内存
	if _, err := singleton.CronShared.AddFunc("0 0 4 * * 0", func() { singleton.PerformMaintenance() }); err != nil {
		return err
	}

	if err := singleton.StartJWTSessionGC(); err != nil {
		return err
	}
	return nil
}

func initIDCodec() error {
	return idcodec.Init([]byte(singleton.Conf.JWTSecretKey))
}

// @title           Nezha Monitoring API
// @version         1.0
// @description     Nezha Monitoring API
// @termsOfService  http://nezhahq.github.io

// @contact.name   API Support
// @contact.url    http://nezhahq.github.io
// @contact.email  hi@nai.ba

// @license.name  Apache 2.0
// @license.url   http://www.apache.org/licenses/LICENSE-2.0.html

// @host      localhost:2052
// @BasePath  /api/v1

// @securityDefinitions.apikey  BearerAuth
// @in header
// @name Authorization
// @description JWT session token. Browser/UI flow. Format: `Bearer <jwt>` or cookie `nz-jwt`.

// @securityDefinitions.apikey  APITokenAuth
// @in header
// @name Authorization
// @description Personal Access Token (PAT). Programmatic/CI/LLM flow. Format: `Bearer nzp_<secret>`.
// @description Each endpoint enforces a specific scope; see the `controller` package godoc for the authoritative scope table.

// @externalDocs.description  OpenAPI
// @externalDocs.url          https://swagger.io/resources/open-api/
func main() {
	flag.BoolVar(&dashboardCliParam.Version, "v", false, "查看当前版本号")
	flag.StringVar(&dashboardCliParam.ConfigFile, "c", "data/config.yaml", "配置文件路径")
	flag.StringVar(&dashboardCliParam.DatabaseLocation, "db", "data/sqlite.db", "Sqlite3数据库文件路径")
	flag.Parse()

	if dashboardCliParam.Version {
		fmt.Println(singleton.Version)
		os.Exit(0)
	}

	serviceSentinelDispatchBus := make(chan *model.Service)
	if err := utils.FirstError(singleton.InitFrontendTemplates,
		func() error { return singleton.InitConfigFromPath(dashboardCliParam.ConfigFile) },
		initIDCodec,
		singleton.InitTimezoneAndCache,
		func() error {
			if singleton.Conf.Memory.GoMemLimitMB > 0 {
				debug.SetMemoryLimit(singleton.Conf.Memory.GoMemLimitMB * 1024 * 1024)
				log.Printf("NEZHA>> Go memory limit set to %d MB", singleton.Conf.Memory.GoMemLimitMB)
			}
			// 调低 GC 触发阈值为 20%（默认 100%），让 GC 更频繁执行，
			// 减少驻留内存峰值，避免长期运行后内存持续增长导致 OOM/502
			debug.SetGCPercent(20)
			log.Println("NEZHA>> Go GC percent set to 20 (aggressive GC to reduce memory growth)")
			return nil
		},
		func() error {
			if err := geoipx.EnsureDatabases(); err != nil {
				log.Printf("NEZHA>> geoip databases not fully prepared: %v", err)
			}
			return nil
		},
		func() error { return singleton.InitDBFromPath(dashboardCliParam.DatabaseLocation) },
		singleton.InitTSDB,
		func() error { return initSystem(serviceSentinelDispatchBus) }); err != nil {
		log.Fatal(err)
	}

	l, err := net.Listen("tcp", fmt.Sprintf("%s:%d", singleton.Conf.ListenHost, singleton.Conf.ListenPort))
	if err != nil {
		log.Fatal(err)
	}

	// 启动时执行历史流量清理（当 TSDB 已启用且无周期流量规则时，自动清空 transfers 表以降低 sqlite.db 体积）
	singleton.CleanMonitorHistory()
	rpc.DispatchKeepalive()
	rpc.SetMCPKillSwitchObserver(func() bool {
		return singleton.Conf == nil || !singleton.Conf.MCPEnabled()
	})
	go rpc.DispatchTask(serviceSentinelDispatchBus)
	go singleton.AlertSentinelStart()

	grpcHandler := rpc.ServeRPC()
	httpHandler := controller.ServeWeb(os.DirFS("."))
	controller.InitUpgrader()

	muxHandler := newHTTPandGRPCMux(httpHandler, grpcHandler)
	muxServerHTTP := &http.Server{
		Handler:           muxHandler,
		HTTP2:             dashboardHTTP2,
		ReadHeaderTimeout: time.Second * 5,
	}
	muxServerHTTP.Protocols = new(http.Protocols)
	muxServerHTTP.Protocols.SetHTTP1(true)
	muxServerHTTP.Protocols.SetUnencryptedHTTP2(true)

	var muxServerHTTPS *http.Server
	if singleton.Conf.HTTPS.ListenPort != 0 {
		muxServerHTTPS = &http.Server{
			Addr:              fmt.Sprintf("%s:%d", singleton.Conf.ListenHost, singleton.Conf.HTTPS.ListenPort),
			Handler:           muxHandler,
			HTTP2:             dashboardHTTP2,
			ReadHeaderTimeout: time.Second * 5,
			TLSConfig: &tls.Config{
				InsecureSkipVerify: singleton.Conf.HTTPS.InsecureTLS,
			},
		}
	}

	errChan := make(chan error, 2)
	errHTTPS := errors.New("error from https server")

	if err := graceful.Graceful(func() error {
		log.Printf("NEZHA>> Dashboard::START ON %s:%d", singleton.Conf.ListenHost, singleton.Conf.ListenPort)
		if singleton.Conf.HTTPS.ListenPort != 0 {
			go func() {
				errChan <- muxServerHTTPS.ListenAndServeTLS(singleton.Conf.HTTPS.TLSCertPath, singleton.Conf.HTTPS.TLSKeyPath)
			}()
			log.Printf("NEZHA>> Dashboard::START ON %s:%d", singleton.Conf.ListenHost, singleton.Conf.HTTPS.ListenPort)
		}
		go func() {
			errChan <- muxServerHTTP.Serve(l)
		}()
		return <-errChan
	}, func(c context.Context) error {
		log.Println("NEZHA>> Graceful::START")
		singleton.RecordTransferHourlyUsage()
		singleton.CloseTSDB()
		log.Println("NEZHA>> Graceful::END")
		var err error
		if muxServerHTTPS != nil {
			err = muxServerHTTPS.Shutdown(c)
		}
		return errors.Join(muxServerHTTP.Shutdown(c), utils.IfOr(err != nil, utils.NewWrapError(errHTTPS, err), nil))
	}); err != nil {
		log.Printf("NEZHA>> ERROR: %v", err)
		var wrapError *utils.WrapError
		if errors.As(err, &wrapError) {
			log.Printf("NEZHA>> ERROR HTTPS: %v", wrapError.Unwrap())
		}
	}

	close(errChan)
}

func newHTTPandGRPCMux(httpHandler http.Handler, grpcHandler http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil && h != "" {
			host = h
		}
		host = strings.ToLower(strings.TrimSpace(host))
		natConfig := singleton.NATShared.GetNATConfigByDomain(host)
		if natConfig == nil && host != r.Host {
			natConfig = singleton.NATShared.GetNATConfigByDomain(r.Host)
		}
		if natConfig != nil {
			if !natConfig.Enabled {
				c, _ := gin.CreateTestContext(w)
				waf.ShowBlockPage(c, fmt.Errorf("nat host %s is disabled", natConfig.Domain))
				return
			}
			rpc.ServeNAT(w, r, natConfig)
			return
		}
		if r.ProtoMajor == 2 && strings.HasPrefix(r.Header.Get("Content-Type"), "application/grpc") &&
			strings.HasPrefix(r.URL.Path, "/"+proto.NezhaService_ServiceDesc.ServiceName) {
			grpcHandler.ServeHTTP(w, r)
			return
		}
		httpHandler.ServeHTTP(w, r)
	})
}
