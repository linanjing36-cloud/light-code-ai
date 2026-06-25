// Package brain 是 Wails(Go) 与 Agent-brains(Erlang/OTP) 之间的桥接层。
//
// 架构定位:
//   Hermes 面板 (Wails/Go)  ──spawn──▶  Erlang ERTS (Agent-brains)
//                                            │
//                                  Protobuf │ IPC
//                                            ▼
//                                      Eion-tools (Go/Eino)  ← 无状态执行
//
// Wails 不直接引入 Eion-tools。所有 LLM 推理与工具执行请求,
// 都由 Erlang 侧的 Agent_FSM 编排后,经 Bridge_Manager 发往 Eion-tools。
package brain

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
)

// Bridge 管理 Erlang ERTS 子进程的生命周期与通信。
// 通信方式: 经 ErlPort / 标准 IO 端口双向传递 Protobuf 二进制。
type Bridge struct {
	mu      sync.Mutex
	cmd     *exec.Cmd
	ctx     context.Context
	cancel  context.CancelFunc
	started bool
}

func NewBridge() *Bridge {
	return &Bridge{}
}

// Start 拉起内嵌的 Erlang ERTS 子进程 (Agent-brains release)。
// 数据目录重定向到 ~/Library/Application Support/Hermes/ (macOS 惯例)。
func (b *Bridge) Start() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.started {
		return nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	b.ctx, b.cancel = ctx, cancel

	// TODO: 定位打包后的 ERTS 与 Agent-brains release 路径。
	// 开发期直接用本地 rebar3 shell / escript 启动。
	dataDir := dataDir()
	_ = os.MkdirAll(dataDir, 0o755)

	// 占位: 用 erl 直接启动 Agent-brains,生产期替换为内嵌 ERTS。
	// 实际通信通过 ErlPort (见 stream.go / call.go)。
	b.cmd = exec.CommandContext(ctx,
		"erl", "-noshell",
		"-pa", agentBrainsEbin(),
		"-eval", "application:ensure_all_started(hermes_brains), hermes_brains_app:serve().",
		"-config", filepath.Join(dataDir, "sys.config"),
	)
	b.cmd.Stdout = os.Stdout
	b.cmd.Stderr = os.Stderr

	if err := b.cmd.Start(); err != nil {
		cancel()
		return fmt.Errorf("brain: 启动 Erlang 失败: %w", err)
	}

	b.started = true
	return nil
}

// Stop 优雅停止 Erlang 子进程。
func (b *Bridge) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.started {
		return
	}
	if b.cancel != nil {
		b.cancel()
	}
	if b.cmd != nil && b.cmd.Process != nil {
		_ = b.cmd.Process.Kill()
	}
	b.started = false
}

// Call 发起一次同步请求到 Erlang 大脑,返回响应。
// TODO: 接入 ErlPort 二进制协议,当前为 stub。
func (b *Bridge) Call(method string, args map[string]any) (any, error) {
	// TODO: 将 {method, args} 编码为 Protobuf,经端口发给 Erlang,
	// 阻塞等待 Agent_FSM 产生的响应并解码。
	return nil, fmt.Errorf("brain.Call(%s): 协议未接入 (TODO)", method)
}

func dataDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Hermes")
}

// agentBrainsEbin 返回 Agent-brains 的 beam 路径 (开发期)。
func agentBrainsEbin() string {
	// 假设 Agent-brains 与 Wails-v3 同级目录。
	wd, _ := os.Getwd()
	return filepath.Join(wd, "..", "Agent-brains", "_build", "default", "lib", "hermes_brains", "ebin")
}
