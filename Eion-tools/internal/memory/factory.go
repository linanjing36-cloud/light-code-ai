package memory

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"strings"

	"go.uber.org/zap"

	"github.com/light-code-ai/eion-tools/internal/logging"
)

// NewFromConfig 按 HERMES_MEMORY_BACKEND 创建后端：
//   - dev / memory：进程内向量库（Windows 本地开发，无需 Redis Stack）
//   - redis：Redis Stack + Eino Indexer/Retriever（生产推荐）
//   - auto（默认）：先尝试 redis；失败且 FallbackDev 时降级 dev
func NewFromConfig(ctx context.Context, cfg Config) (Backend, string, error) {
	switch strings.ToLower(cfg.Backend) {
	case "dev", "memory", "local":
		svc, err := NewDevBackend(ctx, cfg)
		return svc, "dev", err
	case "redis":
		svc, err := NewService(ctx, cfg)
		return svc, "redis", err
	default:
		svc, err := NewService(ctx, cfg)
		if err == nil {
			return svc, "redis", nil
		}
		if cfg.FallbackDev {
			logging.Logger.Warn("redis memory unavailable, fallback to dev backend",
				zap.Error(err))
			dev, derr := NewDevBackend(ctx, cfg)
			if derr != nil {
				return nil, "", fmt.Errorf("redis: %w; dev fallback: %v", err, derr)
			}
			return dev, "dev", nil
		}
		return nil, "", err
	}
}

// DefaultBackendForPlatform 桌面 Windows 默认 dev（免 Docker/Redis Stack）。
func DefaultBackendForPlatform() string {
	if runtime.GOOS == "windows" {
		if os.Getenv("HERMES_MEMORY_BACKEND") == "" {
			return "dev"
		}
	}
	return "auto"
}
