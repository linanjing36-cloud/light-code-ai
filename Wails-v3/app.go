package main

import (
	"context"
	"fmt"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/router"
)

// HermesService 暴露给 Wails 前端的 RPC；所有面板流量经 Router 转发到 Erlang。
type HermesService struct {
	ctx    context.Context
	router *router.Router
}

func NewHermesService(r *router.Router) *HermesService {
	return &HermesService{router: r}
}

func (s *HermesService) ServiceStartup(ctx context.Context, _ application.ServiceOptions) error {
	s.ctx = ctx
	return nil
}

func (s *HermesService) ServiceShutdown() error {
	return nil
}

// ---- 会话管理 ----

type SessionInfo struct {
	SessionID string `json:"session_id"`
	Started   bool   `json:"started"`
}

type SessionStartRequest struct {
	SystemPrompt string `json:"system_prompt"`
	Model        string `json:"model"`
	ApiKey       string `json:"api_key"`
	ApiBase      string `json:"api_base"`
}

func (s *HermesService) StartSession(req SessionStartRequest) (*SessionInfo, error) {
	out, err := s.router.CallPanel("start_session", map[string]any{
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
		return nil, fmt.Errorf("router: invalid start_session response: %v", out)
	}
	return &SessionInfo{SessionID: id, Started: true}, nil
}

// ---- 对话 ----

type SendResult struct {
	StreamID string `json:"stream_id"`
}

func (s *HermesService) Send(sessionID, message string) (*SendResult, error) {
	out, err := s.router.CallPanel("send", map[string]any{
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

func (s *HermesService) DeleteSession(sessionID string) (bool, error) {
	out, err := s.router.CallPanel("delete_session", map[string]any{
		"session_id": sessionID,
	})
	if err != nil {
		return false, err
	}
	m, _ := out.(map[string]any)
	ok, _ := m["ok"].(bool)
	return ok, nil
}

// ---- 工具 ----

type ToolDesc struct {
	Name           string `json:"name"`
	Description    string `json:"description"`
	ParametersJSON string `json:"parameters_json"`
}

func (s *HermesService) ListTools() ([]ToolDesc, error) {
	out, err := s.router.CallPanel("list_tools", nil)
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

func (s *HermesService) ApproveToolCall(reqID string, allow bool) error {
	_, err := s.router.CallPanel("approve", map[string]any{
		"req_id": reqID,
		"allow":  allow,
	})
	return err
}

// ---- Brain 状态 ----

func (s *HermesService) BrainStatus(sessionID string) (map[string]any, error) {
	out, err := s.router.CallPanel("brain_status", map[string]any{
		"session_id": sessionID,
	})
	if err != nil {
		return nil, err
	}
	if m, ok := out.(map[string]any); ok {
		return m, nil
	}
	return nil, fmt.Errorf("router: invalid brain_status response: %T", out)
}

type HistoryEntry struct {
	Role          string `json:"role"`
	Content       string `json:"content"`
	ToolCallsJSON string `json:"tool_calls_json"`
	ToolCallID    string `json:"tool_call_id"`
}

func (s *HermesService) GetHistory(sessionID string) ([]HistoryEntry, error) {
	out, err := s.router.CallPanel("get_history", map[string]any{
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

func (s *HermesService) StopBrain() error {
	_, err := s.router.CallPanel("stop", nil)
	return err
}
