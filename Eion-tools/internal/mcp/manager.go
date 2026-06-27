package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"go.uber.org/zap"

	"github.com/light-code-ai/eion-tools/internal/capability"
	"github.com/light-code-ai/eion-tools/internal/logging"
	"github.com/light-code-ai/eion-tools/internal/tool"
)

type Status struct {
	Name      string
	Healthy   bool
	ToolCount int
	LastError string
}

type Manager struct {
	configs []ServerConfig

	mu      sync.RWMutex
	servers map[string]*managedServer
	cancel  context.CancelFunc
	wg      sync.WaitGroup
}

type managedServer struct {
	cfg        ServerConfig
	client     *stdioClient
	tools      []toolDesc
	registered bool
	lastError  error
}

func NewManager(configs []ServerConfig) *Manager {
	return &Manager{
		configs: append([]ServerConfig(nil), configs...),
		servers: make(map[string]*managedServer),
	}
}

func (m *Manager) Start(parent context.Context, w *tool.Eino_Tool_Wrapper) error {
	if m == nil || len(m.configs) == 0 {
		return nil
	}
	ctx, cancel := context.WithCancel(parent)
	m.cancel = cancel
	for _, cfg := range m.configs {
		if !cfg.Enabled {
			continue
		}
		ms := &managedServer{
			cfg:    cfg,
			client: newStdioClient(cfg),
		}
		if err := ms.connectAndRegister(ctx, w); err != nil {
			cancel()
			return err
		}
		m.servers[cfg.Name] = ms
		m.wg.Add(1)
		go func(s *managedServer) {
			defer m.wg.Done()
			m.watch(ctx, s)
		}(ms)
	}
	return nil
}

func (m *Manager) Stop() {
	if m == nil {
		return
	}
	if m.cancel != nil {
		m.cancel()
	}
	m.mu.RLock()
	servers := make([]*managedServer, 0, len(m.servers))
	for _, srv := range m.servers {
		servers = append(servers, srv)
	}
	m.mu.RUnlock()
	for _, srv := range servers {
		srv.client.stop()
	}
	m.wg.Wait()
}

func (m *Manager) Statuses() []Status {
	if m == nil {
		return nil
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]Status, 0, len(m.servers))
	for _, srv := range m.servers {
		healthy, err := srv.client.health()
		last := ""
		if err != nil {
			last = err.Error()
		} else if srv.lastError != nil {
			last = srv.lastError.Error()
		}
		out = append(out, Status{
			Name:      srv.cfg.Name,
			Healthy:   healthy,
			ToolCount: len(srv.tools),
			LastError: last,
		})
	}
	return out
}

func (m *Manager) watch(ctx context.Context, srv *managedServer) {
	ticker := time.NewTicker(srv.cfg.RetryDelay)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			healthy, _ := srv.client.health()
			if healthy {
				if _, err := srv.client.listTools(ctx); err != nil {
					srv.lastError = err
					srv.client.stop()
					logging.Logger.Warn("mcp health check failed",
						zap.String("server", srv.cfg.Name),
						zap.Error(err))
				}
				continue
			}
			if err := srv.client.restart(ctx); err != nil {
				srv.lastError = err
				logging.Logger.Warn("mcp reconnect failed",
					zap.String("server", srv.cfg.Name),
					zap.Error(err))
				continue
			}
			logging.Logger.Info("mcp server reconnected",
				zap.String("server", srv.cfg.Name))
		}
	}
}

func (s *managedServer) connectAndRegister(ctx context.Context, w *tool.Eino_Tool_Wrapper) error {
	if err := s.client.start(ctx); err != nil {
		return fmt.Errorf("connect mcp server %q: %w", s.cfg.Name, err)
	}
	tools, err := s.client.listTools(ctx)
	if err != nil {
		s.client.stop()
		return fmt.Errorf("list tools for mcp server %q: %w", s.cfg.Name, err)
	}
	s.tools = append([]toolDesc(nil), tools...)
	for _, item := range tools {
		desc := capability.Normalize(capability.Desc{
			Name:        item.Name,
			Kind:        capability.KindMCP,
			Source:      s.cfg.Name,
			Version:     "v1",
			Description: item.Description,
			InputSchema: mustJSON(item.InputSchema),
			Streaming:   false,
			RiskLevel:   capability.RiskSafe,
			CostHint:    capability.CostLow,
			Tags:        []string{"mcp", s.cfg.Name},
		})
		toolName := item.Name
		w.RegisterCapability(desc, func(callCtx context.Context, argumentsJSON string) (string, error) {
			var args map[string]any
			if argumentsJSON != "" {
				if err := json.Unmarshal([]byte(argumentsJSON), &args); err != nil {
					return "", fmt.Errorf("parse mcp args: %w", err)
				}
			}
			result, err := s.client.callTool(callCtx, toolName, args)
			if err != nil {
				return "", err
			}
			out, err := json.Marshal(result)
			if err != nil {
				return "", fmt.Errorf("marshal mcp result: %w", err)
			}
			return string(out), nil
		})
	}
	s.registered = true
	logging.Logger.Info("mcp server connected",
		zap.String("server", s.cfg.Name),
		zap.Int("tools", len(tools)))
	return nil
}

func mustJSON(v map[string]any) string {
	if len(v) == 0 {
		return "{}"
	}
	out, err := json.Marshal(v)
	if err != nil {
		return "{}"
	}
	return string(out)
}
