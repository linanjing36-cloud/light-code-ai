// Package server 提供 Eion-tools TCP/UDS 服务，可嵌入 Wails 等 Go 宿主进程。
package server

import (
	"context"
	"fmt"
	"net"
	"os"
	"sync"

	"go.uber.org/zap"

	"github.com/light-code-ai/eion-tools/internal/dispatcher"
	"github.com/light-code-ai/eion-tools/internal/logging"
	"github.com/light-code-ai/eion-tools/internal/memory"
	"github.com/light-code-ai/eion-tools/internal/tool"
	codesearch "github.com/light-code-ai/eion-tools/plugins/code_search"
	githubplugin "github.com/light-code-ai/eion-tools/plugins/github"
	repomap "github.com/light-code-ai/eion-tools/plugins/repo_map"
)

// Options 启动参数。
type Options struct {
	// ListenAddr 监听地址；空则按平台默认 (Windows: 127.0.0.1:0, Unix: /tmp/hermes-eion.sock)。
	ListenAddr string
	// AddrFile 写入实际地址供 Erlang bridge_manager 发现；空则读 EION_TOOLS_ADDR_FILE 或 eion-tools.addr。
	AddrFile string
	// DisableMemory 为 true 时不注册 memory 工具。
	DisableMemory bool
}

// Server Eion-tools 网络服务。
type Server struct {
	opts Options
	d    *dispatcher.Command_Dispatcher

	mu     sync.Mutex
	ln     net.Listener
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// New 创建 Server 并注册工具（尚未 listen）。
func New(opts Options) (*Server, error) {
	logging.Init()
	d := dispatcher.New()
	name, desc, params, handler := tool.GetWeatherHandler()
	d.ToolWrapper().Register(name, desc, params, handler)
	repomap.Register(d.ToolWrapper())
	codesearch.Register(d.ToolWrapper())
	githubplugin.Register(d.ToolWrapper())

	if !opts.DisableMemory && os.Getenv("HERMES_MEMORY_DISABLE") != "1" {
		memCfg := memory.LoadConfig()
		memSvc, backendName, err := memory.NewFromConfig(context.Background(), memCfg)
		if err != nil {
			logging.Logger.Warn("memory tools disabled",
				zap.Error(err),
				zap.String("hint", "set HERMES_MEMORY_BACKEND=dev and HERMES_MEMORY_MOCK_EMBED=1 for local Windows"))
		} else {
			tool.RegisterMemoryTools(d.ToolWrapper(), memSvc)
			logging.Logger.Info("memory tools enabled",
				zap.String("backend", backendName),
				zap.String("redis", memCfg.RedisAddr),
				zap.Bool("mock_embed", memCfg.MockEmbed))
		}
	}

	return &Server{opts: opts, d: d}, nil
}

// Dispatcher 返回进程内命令分发器 (Phase B: Router 经 Bridge exec 帧 in-process 调用)。
func (s *Server) Dispatcher() *dispatcher.Command_Dispatcher {
	if s == nil {
		return nil
	}
	return s.d
}

// Start 监听并接受连接；返回实际地址 (已写入 AddrFile)。
func (s *Server) Start(parent context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ln != nil {
		return s.ln.Addr().String(), nil
	}

	addr := s.opts.ListenAddr
	if addr == "" {
		if env := os.Getenv("EION_TOOLS_ADDR"); env != "" {
			addr = env
		} else {
			addr = defaultListenAddr()
		}
	}
	if err := prepareListenAddr(addr); err != nil {
		return "", err
	}

	ln, err := net.Listen(network(), addr)
	if err != nil {
		return "", fmt.Errorf("listen %s %s: %w", network(), addr, err)
	}

	actual := ln.Addr().String()
	if err := writeAddrFile(actual, s.opts.AddrFile); err != nil {
		_ = ln.Close()
		return "", fmt.Errorf("write addr file: %w", err)
	}

	ctx, cancel := context.WithCancel(parent)
	s.ln = ln
	s.cancel = cancel

	logging.Logger.Info("eion-tools server listening",
		zap.String("net", network()),
		zap.String("addr", actual),
		zap.String("addr_file", resolveAddrFile(s.opts.AddrFile)),
	)

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		for {
			conn, err := ln.Accept()
			if err != nil {
				select {
				case <-ctx.Done():
					return
				default:
					logging.Logger.Error("accept failed", zap.Error(err))
					return
				}
			}
			logging.Logger.Info("connection accepted", zap.String("remote", conn.RemoteAddr().String()))
			go s.handleConn(ctx, conn)
		}
	}()

	return actual, nil
}

// Stop 关闭 listener 与所有连接。
func (s *Server) Stop() error {
	s.mu.Lock()
	if s.cancel != nil {
		s.cancel()
	}
	ln := s.ln
	s.ln = nil
	s.mu.Unlock()

	if ln != nil {
		_ = ln.Close()
	}
	s.wg.Wait()
	return nil
}

// ListenAddr 返回当前监听地址 (未 Start 时为空)。
func (s *Server) ListenAddr() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ln == nil {
		return ""
	}
	return s.ln.Addr().String()
}

func (s *Server) handleConn(ctx context.Context, conn net.Conn) {
	remote := conn.RemoteAddr().String()
	logging.Logger.Info("connection handler started", zap.String("remote", remote))
	defer func() {
		_ = conn.Close()
		logging.Logger.Info("connection handler exited", zap.String("remote", remote))
	}()

	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-done:
		}
	}()

	if err := runFramingLoop(conn, conn, s.d); err != nil {
		logging.Logger.Info("connection framing loop ended", zap.String("remote", remote), zap.Error(err))
	}
}

func resolveAddrFile(explicit string) string {
	if explicit != "" {
		return explicit
	}
	if f := os.Getenv("EION_TOOLS_ADDR_FILE"); f != "" {
		return f
	}
	return "eion-tools.addr"
}

func writeAddrFile(addr, explicitFile string) error {
	path := resolveAddrFile(explicitFile)
	return os.WriteFile(path, []byte(addr), 0o644)
}
