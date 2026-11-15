package singleton

import (
	_ "embed"
	"iter"
	"log"
	"maps"
	"slices"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/patrickmn/go-cache"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"sigs.k8s.io/yaml"

	"github.com/nezhahq/nezha/model"
	"github.com/nezhahq/nezha/pkg/utils"
)

var Version = "debug"

var (
	Cache             *cache.Cache
	DB                *gorm.DB
	Loc               *time.Location
	FrontendTemplates []model.FrontendTemplate
	DashboardBootTime = uint64(time.Now().Unix())

	ServerShared          *ServerClass
	ServiceSentinelShared *ServiceSentinel
	DDNSShared            *DDNSClass
	NotificationShared    *NotificationClass
	NATShared             *NATClass
	CronShared            *CronClass
	// ServerTransferShared is initialized in LoadSingleton AFTER ServerShared
	// (so the in-memory pending index can write back into ServerShared.UserID
	// on transitions) and AFTER initUser (so PushIfOnline can read secrets
	// from UserInfoMap).
)

//go:embed frontend-templates.yaml
var frontendTemplatesYAML []byte

func InitTimezoneAndCache() error {
	var err error
	Loc, err = time.LoadLocation(Conf.Location)
	if err != nil {
		return err
	}

	Cache = cache.New(5*time.Minute, 10*time.Minute)
	return nil
}

// LoadSingleton 加载子服务并执行
func LoadSingleton(bus chan<- *model.Service) (err error) {
	initI18n() // 加载本地化服务
	initUser() // 加载用户ID绑定表
	NATShared = NewNATClass()
	DDNSShared = NewDDNSClass()
	NotificationShared = NewNotificationClass()
	ServerShared = NewServerClass()
	CronShared = NewCronClass()
	ServerTransferShared = NewServerTransferClass()
	// 最后初始化 ServiceSentinel
	ServiceSentinelShared, err = NewServiceSentinel(bus)
	return
}

// InitFrontendTemplates 从内置文件中加载FrontendTemplates
func InitFrontendTemplates() error {
	err := yaml.Unmarshal(frontendTemplatesYAML, &FrontendTemplates)
	if err != nil {
		return err
	}
	return nil
}

// InitDBFromPath 从给出的文件路径中加载数据库
func InitDBFromPath(path string) error {
	var err error
	DB, err = gorm.Open(sqlite.Open(path), &gorm.Config{
		CreateBatchSize: 200,
	})
	if err != nil {
		return err
	}
	if Conf.Debug {
		DB = DB.Debug()
	}
	err = DB.AutoMigrate(model.Server{}, model.User{}, model.ServerGroup{}, model.NotificationGroup{},
		model.Notification{}, model.AlertRule{}, model.Service{}, model.NotificationGroupNotification{},
		model.Cron{}, model.Transfer{}, model.ServerGroupServer{},
		model.NAT{}, model.DDNSProfile{}, model.NotificationGroupNotification{},
		model.WAF{}, model.Oauth2Bind{}, model.ServerTransfer{}, model.JWTSession{},
		model.APIToken{}, model.MCPAuditLog{})
	if err != nil {
		return err
	}

	// 旧 mcp:* scope 与 nezha:* 并行了一段时间，HasScope 通过别名让 mcp:fs:write
	// 静默扩到 REST nezha:server:write。统一命名后这里把残留旧 scope 一次性
	// 归一化（或在仅剩危险旧 scope 时整张 PAT 删除），保证运行时不再依赖别名。
	if rewritten, deleted, mErr := model.MigrateLegacyMCPScopes(DB); mErr != nil {
		log.Printf("NEZHA>> MigrateLegacyMCPScopes failed: %v", mErr)
	} else if rewritten > 0 || deleted > 0 {
		log.Printf("NEZHA>> Migrated legacy mcp:* api token scopes: rewritten=%d deleted=%d", rewritten, deleted)
	}

	return nil
}

// HasCycleTransferRules 检查是否存在已启用的周期流量报警规则
func HasCycleTransferRules() bool {
	AlertsLock.RLock()
	if len(Alerts) > 0 {
		defer AlertsLock.RUnlock()
		for _, alert := range Alerts {
			if !alert.Enabled() {
				continue
			}
			for _, rule := range alert.Rules {
				if rule.IsTransferDurationRule() {
					return true
				}
			}
		}
		return false
	}
	AlertsLock.RUnlock()

	// 若 AlertSentinel 尚未初始化或未加载，从数据库检查
	if DB != nil {
		var alerts []model.AlertRule
		if err := DB.Find(&alerts).Error; err == nil {
			for _, alert := range alerts {
				if !alert.Enabled() {
					continue
				}
				for _, rule := range alert.Rules {
					if rule.IsTransferDurationRule() {
						return true
					}
				}
			}
		}
	}
	return false
}

// RecordTransferHourlyUsage 对流量记录进行打点
func RecordTransferHourlyUsage(servers ...*model.Server) {
	now := time.Now()
	nowTrimSeconds := time.Date(now.Year(), now.Month(), now.Day(), now.Hour(), 0, 0, 0, now.Location())

	var txs []model.Transfer
	var slist iter.Seq[*model.Server]
	if len(servers) > 0 {
		slist = slices.Values(servers)
	} else {
		slist = utils.Seq2To1(ServerShared.Range)
	}

	for server := range slist {
		tx := model.Transfer{
			ServerID: server.ID,
			In:       utils.SubUintChecked(server.State.NetInTransfer, server.PrevTransferInSnapshot),
			Out:      utils.SubUintChecked(server.State.NetOutTransfer, server.PrevTransferOutSnapshot),
		}
		// 无论是否写入 DB，都必须更新内存中的 Snapshot 基准值，保证重启或后续规则能正确计算增量
		server.PrevTransferInSnapshot = server.State.NetInTransfer
		server.PrevTransferOutSnapshot = server.State.NetOutTransfer

		if tx.In == 0 && tx.Out == 0 {
			continue
		}
		tx.CreatedAt = nowTrimSeconds
		txs = append(txs, tx)
	}

	if len(txs) == 0 {
		return
	}

	// 当已启用 TSDB 且无任何活跃的周期流量规则时，时序指标已由 TSDB 全量托管，无需向 SQLite transfers 表写入历史记录
	if TSDBEnabled() && !HasCycleTransferRules() {
		return
	}

	if DB == nil {
		return
	}
	if err := DB.Create(txs).Error; err != nil {
		log.Printf("NEZHA>> Failed to save traffic metrics to database: %v", err)
	} else {
		log.Printf("NEZHA>> Saved traffic metrics to database. Affected %d row(s)", len(txs))
	}
}

// CleanMonitorHistory 清理流量记录（TSDB 有自己的保留策略，SQLite transfers 严格按需与 retention_days 保留）
func CleanMonitorHistory() {
	if DB == nil {
		return
	}

	// 1. 清理已被删除的服务器的流量记录
	DB.Unscoped().Delete(&model.Transfer{}, "server_id NOT IN (SELECT `id` FROM servers)")

	// 2. 确定数据保留时长（默认 30 天，可由 tsdb.retention_days 配置）
	retentionDays := 30
	if Conf.TSDB.RetentionDays > 0 {
		retentionDays = Conf.TSDB.RetentionDays
	}
	defaultKeepTime := time.Now().AddDate(0, 0, -retentionDays)

	// 3. 检查是否有需要使用 transfers 的周期流量报警规则
	var alerts []model.AlertRule
	DB.Find(&alerts)

	var hasCycleRule bool
	var allServerKeep time.Time
	specialServerKeep := make(map[uint64]time.Time)
	var specialServerIDs []uint64

	for _, alert := range alerts {
		if !alert.Enabled() {
			continue
		}
		for _, rule := range alert.Rules {
			if !rule.IsTransferDurationRule() {
				continue
			}
			hasCycleRule = true
			dataCouldRemoveBefore := rule.GetTransferDurationStart().UTC()
			// 确保不会无限期保留（最长不超过 retentionDays）
			if dataCouldRemoveBefore.Before(defaultKeepTime) {
				dataCouldRemoveBefore = defaultKeepTime
			}

			if rule.Cover == model.RuleCoverAll {
				if allServerKeep.IsZero() || allServerKeep.After(dataCouldRemoveBefore) {
					allServerKeep = dataCouldRemoveBefore
				}
			} else {
				for id := range rule.Ignore {
					if specialServerKeep[id].IsZero() || specialServerKeep[id].After(dataCouldRemoveBefore) {
						specialServerKeep[id] = dataCouldRemoveBefore
						specialServerIDs = append(specialServerIDs, id)
					}
				}
			}
		}
	}

	var rowsDeleted int64

	// 4. 当已开启 TSDB 且系统无任何周期流量报警规则时，transfers 表无任何下游消费者，直接全量清空
	if TSDBEnabled() && !hasCycleRule {
		res := DB.Unscoped().Session(&gorm.Session{AllowGlobalUpdate: true}).Delete(&model.Transfer{})
		rowsDeleted = res.RowsAffected
		if rowsDeleted > 0 {
			log.Printf("NEZHA>> TSDB enabled with no cycle rules: purged %d obsolete transfer rows from SQLite", rowsDeleted)
		}
	} else {
		// 5. 按规则计算截止时间，对特殊机器和全局机器分别安全清理（严防 specialServerIDs 为空时 NOT IN (NULL) 导致不删除）
		for id, couldRemove := range specialServerKeep {
			res := DB.Unscoped().Delete(&model.Transfer{}, "server_id = ? AND datetime(`created_at`) < datetime(?)", id, couldRemove)
			rowsDeleted += res.RowsAffected
		}

		cutoff := defaultKeepTime
		if !allServerKeep.IsZero() && allServerKeep.Before(cutoff) {
			cutoff = allServerKeep
		}

		var res *gorm.DB
		if len(specialServerIDs) == 0 {
			// 没有特定机器排除，直接按截止时间清理所有机器
			res = DB.Unscoped().Delete(&model.Transfer{}, "datetime(`created_at`) < datetime(?)", cutoff)
		} else {
			// 排除有独立保留时间的机器
			res = DB.Unscoped().Delete(&model.Transfer{}, "server_id NOT IN (?) AND datetime(`created_at`) < datetime(?)", specialServerIDs, cutoff)
		}
		rowsDeleted += res.RowsAffected

		if rowsDeleted > 0 {
			log.Printf("NEZHA>> Cleaned %d expired transfer rows from SQLite (cutoff: %v)", rowsDeleted, cutoff)
		}
	}

	// 6. 如果清理了大量旧记录（如超过 500 行），主动执行 VACUUM 释放物理磁盘空间
	if rowsDeleted > 500 {
		log.Printf("NEZHA>> SQLite: Cleaned %d rows, executing VACUUM to reclaim disk space...", rowsDeleted)
		if err := DB.Exec("VACUUM").Error; err != nil {
			log.Printf("NEZHA>> SQLite: VACUUM failed: %v", err)
		} else {
			log.Println("NEZHA>> SQLite: VACUUM completed successfully")
		}
	}
}

// PerformMaintenance 执行系统维护（SQLite 清理 + VACUUM 和 TSDB 维护）
func PerformMaintenance() {
	log.Println("NEZHA>> Starting system maintenance...")

	// 1. 先执行历史监控与流量数据清理
	CleanMonitorHistory()

	// 2. SQLite 维护 (VACUUM 回收物理磁盘页)
	if DB != nil {
		log.Println("NEZHA>> SQLite: Starting VACUUM...")
		if err := DB.Exec("VACUUM").Error; err != nil {
			log.Printf("NEZHA>> SQLite: VACUUM failed: %v", err)
		} else {
			log.Println("NEZHA>> SQLite: VACUUM completed")
		}
	}

	// 3. TSDB 维护
	if TSDBEnabled() {
		TSDBShared.Maintenance()
	}

	log.Println("NEZHA>> System maintenance completed")
}

// IPDesensitize 根据设置选择是否对IP进行打码处理 返回处理后的IP(关闭打码则返回原IP)
func IPDesensitize(ip string) string {
	if Conf.EnablePlainIPInNotification {
		return ip
	}
	return utils.IPDesensitize(ip)
}

type class[K comparable, V model.CommonInterface] struct {
	list   map[K]V
	listMu sync.RWMutex

	sortedList   []V
	sortedListMu sync.RWMutex
}

func (c *class[K, V]) Get(id K) (s V, ok bool) {
	c.listMu.RLock()
	defer c.listMu.RUnlock()

	s, ok = c.list[id]
	return
}

func (c *class[K, V]) GetList() map[K]V {
	c.listMu.RLock()
	defer c.listMu.RUnlock()

	return maps.Clone(c.list)
}

func (c *class[K, V]) GetSortedList() []V {
	c.sortedListMu.RLock()
	defer c.sortedListMu.RUnlock()

	return slices.Clone(c.sortedList)
}

func (c *class[K, V]) Range(fn func(k K, v V) bool) {
	c.listMu.RLock()
	defer c.listMu.RUnlock()

	for k, v := range c.list {
		if !fn(k, v) {
			break
		}
	}
}

func (c *class[K, V]) CheckPermission(ctx *gin.Context, idList iter.Seq[K]) bool {
	c.listMu.RLock()
	defer c.listMu.RUnlock()

	for id := range idList {
		if s, ok := c.list[id]; ok {
			if !s.HasPermission(ctx) {
				return false
			}
		}
	}
	return true
}
