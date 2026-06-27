package main

import (
	"context"
	"fmt"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
)

// HermesService 是暴露给前端 (TS via Wails bindings) 的 RPC 对象。
// 前端调用这些方法 → 经 brain.Bridge.Call (TCP+Protobuf) → Erlang panel_server。
//
// 设计原则: 本 Service 不持有业务状态, 仅做转发。
// 所有状态在 Erlang 侧的 agent_fsm / state_store 中, Wails 保持"哑终端"属性。
type HermesService struct {
	ctx   context.Context
	brain *brain.Bridge
}

func NewHermesService(b *brain.Bridge) *HermesService {
	return &HermesService{brain: b}
}

// ServiceStartup 实现 application.ServiceStartup (Wails v3 生命周期)。
// Wails 应用启动时调用, 注入 ctx 供后续 Call 使用。
func (s *HermesService) ServiceStartup(ctx context.Context, _ application.ServiceOptions) error {
	s.ctx = ctx
	return nil
}

// ServiceShutdown 实现 application.ServiceShutdown (Wails v3 生命周期)。
func (s *HermesService) ServiceShutdown() error {
	return nil
}

// ---- 会话管理 ----

// SessionInfo: StartSession 返回值
type SessionInfo struct {
	SessionID string `json:"session_id"`
	Started   bool   `json:"started"`
}

// SessionStartRequest 新建会话参数 (模型/凭证可按会话覆盖 app env)
type SessionStartRequest struct {
	SystemPrompt string `json:"system_prompt"`
	Model        string `json:"model"`
	ApiKey       string `json:"api_key"`
	ApiBase      string `json:"api_base"`
}

// StartSession 启动一个新的 Agent 会话, Erlang 侧会派发一个 Agent_FSM 进程。
func (s *HermesService) StartSession(req SessionStartRequest) (*SessionInfo, error) {
	out, err := s.brain.Call("start_session", map[string]any{
		"system_prompt": req.SystemPrompt,
		"model":         req.Model,
		"api_key":       req.ApiKey,
		"api_base":      req.ApiBase,
	})
	if err != nil {
		return nil, err
	}
	m, _ := out.(map[string]any)
	id, _ := m["session_id"].(string)
	if id == "" {
		return nil, fmt.Errorf("brain: invalid start_session response: %v", out)
	}
	return &SessionInfo{SessionID: id, Started: true}, nil
}

// ---- 对话 ----

// SendResult: Send 返回值
type SendResult struct {
	StreamID string `json:"stream_id"`
}

// Send 向指定会话发送用户消息, 触发 ReAct 循环 (异步)。
// 立即返回 stream_id; chunk/final 经 panel:stream 事件推送, 前端监听后刷新 history。
func (s *HermesService) Send(sessionID, message string) (*SendResult, error) {
	out, err := s.brain.Call("send", map[string]any{
		"session_id": sessionID,
		"message":    message,
	})
	if err != nil {
		return nil, err
	}
	m, _ := out.(map[string]any)
	id, _ := m["stream_id"].(string)
	return &SendResult{StreamID: id}, nil
}

// ---- 工具 ----

// ToolDesc 工具描述 (与 panel.proto ListToolsResult 对齐)
type ToolDesc struct {
	Name            string `json:"name"`
	Description     string `json:"description"`
	ParametersJSON  string `json:"parameters_json"`
}

// ListTools 列出 Eion-tools 侧注册的工具描述 (经 Erlang 转发)。
func (s *HermesService) ListTools() ([]ToolDesc, error) {
	out, err := s.brain.Call("list_tools", nil)
	if err != nil {
		return nil, err
	}
	m, _ := out.(map[string]any)
	raw, _ := m["tools"].([]any)
	tools := make([]ToolDesc, 0, len(raw))
	for _, item := range raw {
		tm, ok := item.(map[string]any)
		if !ok {
			continue
		}
		tools = append(tools, ToolDesc{
			Name:           fmt.Sprint(tm["name"]),
			Description:    fmt.Sprint(tm["description"]),
			ParametersJSON: fmt.Sprint(tm["parameters_json"]),
		})
	}
	return tools, nil
}

// ApproveToolCall 对需要人工确认的工具调用进行授权 (inline approval)。
func (s *HermesService) ApproveToolCall(reqID string, allow bool) error {
	_, err := s.brain.Call("approve", map[string]any{
		"req_id": reqID,
		"allow":  allow,
	})
	return err
}

// ---- Brain 状态 ----

// BrainStatus 返回 Erlang 大脑的运行状态。
// 返回字段: state (idle/thinking/acting), loop_count, max_loops, history_len。
func (s *HermesService) BrainStatus(sessionID string) (map[string]any, error) {
	out, err := s.brain.Call("brain_status", map[string]any{
		"session_id": sessionID,
	})
	if err != nil {
		return nil, err
	}
	if m, ok := out.(map[string]any); ok {
		return m, nil
	}
	return nil, fmt.Errorf("brain: invalid brain_status response: %T", out)
}

// HistoryEntry 单条对话历史 (与 panel.proto HistoryEntry 对齐)
type HistoryEntry struct {
	Role          string `json:"role"`
	Content       string `json:"content"`
	ToolCallsJSON string `json:"tool_calls_json"`
	ToolCallID    string `json:"tool_call_id"`
}

// GetHistory 拉取指定会话的短期记忆 (state_store)。
func (s *HermesService) GetHistory(sessionID string) ([]HistoryEntry, error) {
	out, err := s.brain.Call("get_history", map[string]any{
		"session_id": sessionID,
	})
	if err != nil {
		return nil, err
	}
	m, _ := out.(map[string]any)
	raw, _ := m["messages"].([]any)
	entries := make([]HistoryEntry, 0, len(raw))
	for _, item := range raw {
		em, ok := item.(map[string]any)
		if !ok {
			continue
		}
		entries = append(entries, HistoryEntry{
			Role:          fmt.Sprint(em["role"]),
			Content:       fmt.Sprint(em["content"]),
			ToolCallsJSON: fmt.Sprint(em["tool_calls_json"]),
			ToolCallID:    fmt.Sprint(em["tool_call_id"]),
		})
	}
	return entries, nil
}

// ---- Brain 控制 ----

// StopBrain 优雅停止 Erlang 大脑 (触发 init:stop, 退出整个 erl 子进程)。
// 用于面板"退出"按钮, 让 Erlang 侧的 sup 逆序 terminate 子进程后再退。
func (s *HermesService) StopBrain() error {
	_, err := s.brain.Call("stop", nil)
	return err
}
