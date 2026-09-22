package rpc

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/netip"
	"time"

	"github.com/goccy/go-json"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"

	"github.com/hashicorp/go-uuid"
	"github.com/nezhahq/nezha/model"
	"github.com/nezhahq/nezha/pkg/utils"
	"github.com/nezhahq/nezha/proto"
	rpcService "github.com/nezhahq/nezha/service/rpc"
	"github.com/nezhahq/nezha/service/singleton"
)

// SetMCPKillSwitchObserver re-exports the service/rpc hook so cmd/dashboard
// can wire singleton.Conf.EnableMCP without importing the inner rpc package
// (cmd/dashboard already imports cmd/dashboard/rpc for ServeRPC).
func SetMCPKillSwitchObserver(fn func() bool) {
	rpcService.SetMCPKillSwitchObserver(fn)
}

func ServeRPC() *grpc.Server {
	// Streaming RPCs (RequestTask, IOStream) need the same real-IP + WAF
	// gate as unary calls; without the stream interceptors authHandler.check
	// sees an empty real IP, so brute-force BlockIP counters never key on a
	// source and the WAF block table is bypassed at the stream entrypoint.
	server := grpc.NewServer(
		grpc.ChainUnaryInterceptor(getRealIp, waf),
		grpc.ChainStreamInterceptor(getRealIpStream, wafStream),
	)
	rpcService.NezhaHandlerSingleton = rpcService.NewNezhaHandler()
	// Install the IOStream revocation hook so ServerTransferShared can tear
	// down terminal/FM/NAT sessions held by the previous owner on every
	// ownership rotation (Register/revertTransition/OnServersDeleted).
	singleton.ServerTransferStreamRevocationHook = rpcService.NezhaHandlerSingleton.RevokeStreamsForServer
	proto.RegisterNezhaServiceServer(server, rpcService.NezhaHandlerSingleton)
	return server
}

func ctxWithRealIP(ctx context.Context) (context.Context, error) {
	var ip, connectingIp string
	p, ok := peer.FromContext(ctx)
	if ok {
		addrPort, err := netip.ParseAddrPort(p.Addr.String())
		if err == nil {
			connectingIp = addrPort.Addr().String()
		}
	}
	ctx = context.WithValue(ctx, model.CtxKeyConnectingIP{}, connectingIp)

	if singleton.Conf.AgentRealIPHeader == "" {
		return ctx, nil
	}

	if singleton.Conf.AgentRealIPHeader == model.ConfigUsePeerIP {
		if connectingIp == "" {
			return ctx, fmt.Errorf("connecting ip not found")
		}
		// Peer-IP mode: peer IP is the real IP. Leaving ip="" makes
		// CheckIP/BlockIP short-circuit on empty IP, disabling the WAF.
		ip = connectingIp
	} else {
		vals := metadata.ValueFromIncomingContext(ctx, singleton.Conf.AgentRealIPHeader)
		if len(vals) == 0 {
			return ctx, fmt.Errorf("real ip header not found")
		}
		var err error
		ip, err = utils.GetIPFromHeader(vals[0])
		if err != nil {
			return ctx, err
		}
	}

	if singleton.Conf.Debug {
		log.Printf("NEZHA>> gRPC Agent Real IP: %s, connecting IP: %s\n", ip, connectingIp)
	}

	return context.WithValue(ctx, model.CtxKeyRealIP{}, ip), nil
}

func waf(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
	realip, _ := ctx.Value(model.CtxKeyRealIP{}).(string)
	if err := model.CheckIP(singleton.DB, realip); err != nil {
		return nil, err
	}
	return handler(ctx, req)
}

func getRealIp(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
	ctx, err := ctxWithRealIP(ctx)
	if err != nil {
		return nil, err
	}
	return handler(ctx, req)
}

// realIPServerStream overrides Context() so stream handlers and
// authHandler.check observe the resolved real IP, like the unary path.
type realIPServerStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s *realIPServerStream) Context() context.Context { return s.ctx }

func getRealIpStream(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
	ctx, err := ctxWithRealIP(ss.Context())
	if err != nil {
		return err
	}
	return handler(srv, &realIPServerStream{ServerStream: ss, ctx: ctx})
}

func wafStream(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
	realip, _ := ss.Context().Value(model.CtxKeyRealIP{}).(string)
	if err := model.CheckIP(singleton.DB, realip); err != nil {
		return err
	}
	return handler(srv, ss)
}

func DispatchTask(serviceSentinelDispatchBus <-chan *model.Service) {
	for task := range serviceSentinelDispatchBus {
		if task == nil {
			continue
		}

		switch task.Cover {
		case model.ServiceCoverIgnoreAll:
			for id, enabled := range task.SkipServers {
				if !enabled {
					continue
				}

				server, _ := singleton.ServerShared.Get(id)
				if server == nil {
					continue
				}
				if !canSendTaskToServer(task, server) {
					continue
				}
				// SendTask 走 holder-scoped send mutex，避免与 cron /
				// server-transfer / MCP CallAgent / fs.transfer 等并发
				// SendMsg 同一 RequestTask stream。
				if err := server.SendTask(task.PB()); err != nil &&
					!errors.Is(err, model.ErrTaskStreamOffline) {
					log.Printf("NEZHA>> DispatchTask send error (server=%d): %v", id, err)
				}
			}
		case model.ServiceCoverAll:
			// 快照后逐个 SendTask，不在 ServerShared 的 listMu.RLock 内做阻塞
			// gRPC：否则一个卡死 agent 会拖死需要写锁的 server 生命周期操作。
			for id, server := range singleton.ServerShared.GetList() {
				if server == nil || task.SkipServers[id] {
					continue
				}
				if !canSendTaskToServer(task, server) {
					continue
				}
				if err := server.SendTask(task.PB()); err != nil &&
					!errors.Is(err, model.ErrTaskStreamOffline) {
					log.Printf("NEZHA>> DispatchTask send error (server=%d): %v", id, err)
				}
			}
		}
	}
}

func DispatchKeepalive() {
	singleton.CronShared.AddFunc("@every 20s", func() {
		list := singleton.ServerShared.GetSortedList()
		for _, s := range list {
			if s == nil {
				continue
			}
			if err := s.SendTask(&proto.Task{Type: model.TaskTypeKeepalive}); err != nil &&
				!errors.Is(err, model.ErrTaskStreamOffline) {
				log.Printf("NEZHA>> Keepalive send error (server=%d): %v", s.ID, err)
			}
		}
	})
}

// ServeNAT handles a single HTTP request to tunnel through an agent.
//
// Stability improvements (vs upstream):
//   - Per-NAT stream limit separate from terminal/fm (configurable via nat.per_server_stream_limit)
//   - Configurable timeout via nat.stream_timeout_sec
//   - Auto-retry when agent's gRPC task stream drops mid-connect (nat.max_retries)
//   - Better error messages distinguishing agent-offline vs stream-full
//   - Fast cleanup: StartStream goroutine exits immediately on context cancel
func ServeNAT(w http.ResponseWriter, r *http.Request, natConfig *model.NAT) {
	// Get the target server
	server, _ := singleton.ServerShared.Get(natConfig.ServerID)
	if server == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("server not found"))
		return
	}
	if server.GetTaskStream() == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("server offline"))
		return
	}

	// Enforce NAT-specific per-server stream limit before creating the stream.
	// The global per-server cap (40) covers all stream types; this NAT-specific
	// cap reserves slots for terminal / file-manager / MCP.
	natLimit := rpcService.GetNATStreamLimit()
	currentStreams := rpcService.NezhaHandlerSingleton.CountStreamsPerServer(server.ID)
	if currentStreams >= natLimit {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(fmt.Sprintf("too many NAT tunnels on this server (limit=%d, active=%d)", natLimit, currentStreams)))
		return
	}

	// Try to create a NAT stream, with retries for transient agent disconnects.
	maxRetries := singleton.Conf.NAT.MaxRetries
	if maxRetries < 0 {
		maxRetries = 1
	}
	streamTimeout := singleton.Conf.NAT.StreamTimeoutSec
	if streamTimeout <= 0 {
		streamTimeout = 10
	}

	taskData, err := json.Marshal(model.TaskNAT{
		StreamID: "",
		Host:     natConfig.Host,
	})
	if err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(fmt.Sprintf("task data error: %v", err)))
		return
	}

	// CreateStream + SendTask with retries on transient failure.
	var streamId string
	var streamCreated bool
	var taskStreamOk bool

	attempt := 0
	for attempt <= maxRetries {
		// Re-check server is still online each retry
		server, _ = singleton.ServerShared.Get(natConfig.ServerID)
		if server == nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte("server not found"))
			return
		}
		if server.GetTaskStream() == nil {
			if attempt < maxRetries {
				log.Printf("NEZHA>> NAT tunnel %s: agent offline, retrying (%d/%d)\n", natConfig.Domain, attempt+1, maxRetries)
				time.Sleep(time.Second * time.Duration(attempt+1)) // exponential backoff
				attempt++
				continue
			}
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte("server offline"))
			return
		}

		// Check NAT stream limit again (streams may have been freed)
		currentStreams = rpcService.NezhaHandlerSingleton.CountStreamsPerServer(server.ID)
		if currentStreams >= natLimit {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(fmt.Sprintf("too many NAT tunnels on this server (limit=%d, active=%d)", natLimit, currentStreams)))
			return
		}

		streamId, err = uuid.GenerateUUID()
		if err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(fmt.Sprintf("stream id error: %v", err)))
			return
		}

		// Create the stream slot
		if err := rpcService.NezhaHandlerSingleton.CreateStream(streamId, 0, server.ID); err != nil {
			if errors.Is(err, rpcService.ErrTooManyStreamsForServer) {
				w.WriteHeader(http.StatusServiceUnavailable)
				w.Write([]byte(fmt.Sprintf("too many streams on this server (limit=%d)", natLimit)))
				return
			}
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(fmt.Sprintf("stream create error: %v", err)))
			return
		}
		streamCreated = true

		// Update task data with the stream ID
		taskData, err = json.Marshal(model.TaskNAT{
			StreamID: streamId,
			Host:     natConfig.Host,
		})
		if err != nil {
			rpcService.NezhaHandlerSingleton.CloseStream(streamId)
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(fmt.Sprintf("task data error: %v", err)))
			return
		}

		// Send the NAT task to the agent
		if err := server.SendTask(&proto.Task{
			Type: model.TaskTypeNAT,
			Data: string(taskData),
		}); err != nil {
			// Check if it's a transient gRPC stream error (agent reconnecting)
			if errors.Is(err, model.ErrTaskStreamOffline) && attempt < maxRetries {
				log.Printf("NEZHA>> NAT tunnel %s: gRPC stream dropped, retrying (%d/%d)\n", natConfig.Domain, attempt+1, maxRetries)
				// Clean up the failed stream slot
				rpcService.NezhaHandlerSingleton.CloseStream(streamId)
				streamCreated = false
				time.Sleep(time.Second * time.Duration(attempt+1)) // exponential backoff
				attempt++
				continue
			}
			if streamCreated {
				rpcService.NezhaHandlerSingleton.CloseStream(streamId)
			}
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(fmt.Sprintf("send task error: %v", err)))
			return
		}
		taskStreamOk = true
		break
	}
	if !taskStreamOk {
		return
	}

	wWrapped, err := utils.NewRequestWrapper(r, w)
	if err != nil {
		rpcService.NezhaHandlerSingleton.CloseStream(streamId)
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(fmt.Sprintf("request wrapper error: %v", err)))
		return
	}

	if err := rpcService.NezhaHandlerSingleton.UserConnected(streamId, wWrapped); err != nil {
		rpcService.NezhaHandlerSingleton.CloseStream(streamId)
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte(fmt.Sprintf("user connected error: %v", err)))
		return
	}

	defer rpcService.NezhaHandlerSingleton.CloseStream(streamId)

	// Use a cancellable context so the HTTP request can be cancelled
	// (client disconnect, timeout, etc.) to unblock StartStream immediately
	// instead of waiting for the full timeout.
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(streamTimeout)*time.Second)
	defer cancel()

	err = StartStreamWithContext(ctx, streamId, time.Duration(streamTimeout)*time.Second)
	if err != nil {
		log.Printf("NEZHA>> NAT tunnel %s: stream failed: %v", natConfig.Domain, err)
		if ctx.Err() != nil {
			w.WriteHeader(http.StatusGatewayTimeout)
			w.Write([]byte("tunnel timeout (agent did not connect in time)"))
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte(fmt.Sprintf("tunnel error: %v", err)))
		}
		return
	}

	// If StartStream succeeded, the bidirectional copy goroutines are still
	// running and will drain when either side disconnects.
}

// StartStreamWithContext is like rpcService.NezhaHandlerSingleton.StartStream but
// respects a cancellable context. This allows the HTTP request context to
// unblock the stream relay when the client disconnects, preventing the
// HTTP handler goroutine from being stuck for the full timeout.
func StartStreamWithContext(ctx context.Context, streamId string, timeout time.Duration) error {
	// Use the same StartStream logic but with context-aware timeout
	go func() {
		select {
		case <-ctx.Done():
			// Client disconnected or timeout — close the stream to unblock
			// StartStream's goroutine instead of waiting for the full timeout.
			rpcService.NezhaHandlerSingleton.CloseStream(streamId)
		case <-time.After(timeout + time.Second):
			// Safety net: if StartStream doesn't return within timeout+1s,
			// force-close the stream.
			rpcService.NezhaHandlerSingleton.CloseStream(streamId)
		}
	}()

	return rpcService.NezhaHandlerSingleton.StartStream(streamId, timeout)
}

func canSendTaskToServer(task *model.Service, server *model.Server) bool {
	var role model.Role
	singleton.UserLock.RLock()
	if u, ok := singleton.UserInfoMap[task.UserID]; !ok {
		role = model.RoleMember
	} else {
		role = u.Role
	}
	singleton.UserLock.RUnlock()

	return task.UserID == server.GetUserID() || role.IsAdmin()
}
