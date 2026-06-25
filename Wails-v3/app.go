package main

import (
	"context"

	"hermes/internal/brain"
)

// App 是暴露给前端 (React) 的 Go 侧对象。
// 前端调用这些方法 → 转发到 Erlang 大脑 → Erlang 编排 → 调用 Eion-tools 执行。
// Wails 自身不直接接触 LLM API 或工具,保持"哑终端"属性。
type App struct {
	ctx    context.Context
	brain  *brain.Bridge
}

func NewApp(b *brain.Bridge) *App {
	return &App{brain: b}
}

func (a *App) OnStartup(ctx context.Context) {
	a.ctx = ctx
}

// ---- 会话管理 ----

// StartSession 启动一个新的 Agent 会话,Erlang 侧会派发一个 Agent_FSM 进程。
func (a *App) StartSession(systemPrompt string) (string, error) {
	out, err := a.brain.Call("start_session", map[string]any{
		"system_prompt": systemPrompt,
	})
	if err != nil {
		return "", err
	}
	if s, ok := out.(string); ok {
		return s, nil
	}
	return "", nil
}

// ---- 对话 ----

// Send 向指定会话发送用户消息,触发 ReAct 循环。
// 返回 stream id,前端通过 StreamEvents 订阅实时事件 (thinking/tool/result)。
func (a *App) Send(sessionID, message string) (string, error) {
	out, err := a.brain.Call("send", map[string]any{
		"session_id": sessionID,
		"message":    message,
	})
	if err != nil {
		return "", err
	}
	if s, ok := out.(string); ok {
		return s, nil
	}
	return "", nil
}

// ---- 上下文 / 工具 ----

// ListTools 列出 Eion-tools 侧注册的工具描述 (经 Erlang 转发)。
func (a *App) ListTools() ([]string, error) {
	out, err := a.brain.Call("list_tools", nil)
	_ = out
	return nil, err
}

// ApproveToolCall 对需要人工确认的工具调用进行授权 (inline approval)。
func (a *App) ApproveToolCall(reqID string, allow bool) error {
	_, err := a.brain.Call("approve", map[string]any{
		"req_id": reqID,
		"allow":  allow,
	})
	return err
}

// ---- Brain 状态 ----

// BrainStatus 返回 Erlang 大脑的运行状态 (FSM 状态/Loop 计数/Go 节点连接)。
func (a *App) BrainStatus() (map[string]any, error) {
	out, err := a.brain.Call("brain_status", nil)
	if m, ok := out.(map[string]any); ok {
		return m, err
	}
	return nil, err
}
