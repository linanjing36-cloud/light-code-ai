package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
	"hermes/internal/eion"
	"hermes/internal/router"
)

type routerPanel struct{ r *router.Router }

func (p *routerPanel) Call(method string, args map[string]any) (any, error) {
	return p.r.CallPanel(method, args)
}

type panelCaller interface {
	Call(method string, args map[string]any) (any, error)
}

type historyEntry struct {
	Role, Content, ToolCallID string
	ToolCalls                 []brain.ToolCall
}

const maxAttempts = 3

func main() {
	timeout := flag.Duration("timeout", 90*time.Second, "审批链路单次闭环超时")
	flag.Parse()

	totalTimeout := time.Duration(maxAttempts)*(*timeout+30*time.Second) + 30*time.Second
	ctx, cancel := context.WithTimeout(context.Background(), totalTimeout)
	defer cancel()

	if strings.TrimSpace(os.Getenv("HERMES_PANEL_E2E_QUIET_RUNTIME_LOGS")) == "1" {
		log.SetOutput(io.Discard)
	}
	_ = os.Setenv("HERMES_EXEC_VIA_PANEL", "1")
	_ = os.Setenv("HERMES_MEMORY_DISABLE", "0")
	_ = os.Setenv("HERMES_MEMORY_BACKEND", "dev")
	_ = os.Setenv("HERMES_MEMORY_MOCK_EMBED", "1")
	_ = os.Setenv("HERMES_MEMORY_INDEX", "hermes_memory_approval_e2e")

	fmt.Println("=== panel approval e2e ===")

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		fmt.Printf("[attempt] %d/%d\n", attempt, maxAttempts)
		rtEnv, err := startAttemptRuntime(ctx)
		if err != nil {
			lastErr = err
			fmt.Printf("[attempt] %d failed: %v\n", attempt, err)
			continue
		}
		err = runApprovalAttempt(rtEnv.pc, rtEnv.streamMu, rtEnv.streams, *timeout)
		rtEnv.cleanup()
		if err != nil {
			lastErr = err
			fmt.Printf("[attempt] %d failed: %v\n", attempt, err)
			continue
		}
		fmt.Println("=== panel_approval_e2e OK ===")
		return
	}
	fail("approval_required", lastErr)
	fmt.Println("[delete_session] ok=true")
}

type approvalEvent struct {
	reqID      string
	toolCallID string
	toolName   string
	riskLevel  string
}

type attemptRuntime struct {
	pc       panelCaller
	streamMu *sync.Mutex
	streams  map[string][]brain.StreamEvent
	cleanup  func()
}

func startAttemptRuntime(ctx context.Context) (*attemptRuntime, error) {
	b := brain.NewBridge()
	eionEmb := eion.NewEmbedded()
	rt := router.New(b, eionEmb)
	pc := &routerPanel{r: rt}

	var streamMu sync.Mutex
	streams := make(map[string][]brain.StreamEvent)
	rt.SetStreamTap(func(ev brain.StreamEvent) {
		streamMu.Lock()
		streams[ev.StreamID] = append(streams[ev.StreamID], ev)
		streamMu.Unlock()
	})

	cleanup := func() {
		rt.ServiceShutdown()
		b.Stop()
		eionEmb.ServiceShutdown()
	}

	if err := eionEmb.ServiceStartup(ctx, application.ServiceOptions{}); err != nil {
		cleanup()
		return nil, fmt.Errorf("eion embed: %w", err)
	}
	if err := b.Start(ctx); err != nil {
		cleanup()
		return nil, fmt.Errorf("bridge start: %w", err)
	}
	if err := rt.ServiceStartup(ctx, application.ServiceOptions{}); err != nil {
		cleanup()
		return nil, fmt.Errorf("router startup: %w", err)
	}
	if err := verifyCapabilities(pc); err != nil {
		cleanup()
		return nil, err
	}

	return &attemptRuntime{
		pc:       pc,
		streamMu: &streamMu,
		streams:  streams,
		cleanup:  cleanup,
	}, nil
}

func verifyCapabilities(pc panelCaller) error {
	caps, err := listCapabilities(pc)
	if err != nil {
		return fmt.Errorf("list_capabilities: %w", err)
	}
	memStore, ok := findCapability(caps, "memory_store")
	if !ok {
		return fmt.Errorf("list_capabilities: memory_store not found")
	}
	if memStore.RiskLevel != "review" {
		return fmt.Errorf("list_capabilities: memory_store risk_level=%q want review", memStore.RiskLevel)
	}
	memImport, ok := findCapability(caps, "memory_import")
	if !ok {
		return fmt.Errorf("list_capabilities: memory_import not found")
	}
	if memImport.RiskLevel != "review" {
		return fmt.Errorf("list_capabilities: memory_import risk_level=%q want review", memImport.RiskLevel)
	}
	fmt.Printf("[list_capabilities] memory_store risk=%s cost=%s; memory_import risk=%s cost=%s\n",
		memStore.RiskLevel, memStore.CostHint, memImport.RiskLevel, memImport.CostHint)
	return nil
}

func runApprovalAttempt(pc panelCaller, streamMu *sync.Mutex, streams map[string][]brain.StreamEvent, timeout time.Duration) error {
	systemPrompt := "你是 Hermes 审批链路测试助手。收到要求记住一条事实的用户消息时，必须先调用 memory_store。" +
		"参数 session_id 必须严格使用用户消息给出的原值，text 也必须使用用户消息提供的原文。" +
		"如果你不调用 memory_store，这次自动化测试会直接失败。" +
		"禁止调用 memory_search、workspace_briefing、repo_map、code_search、github_*、get_weather 或其他任何工具。" +
		"工具执行完成后只回复“已记住”。"
	sessionID, err := startSession(pc, systemPrompt, "deepseek-v4-pro")
	if err != nil {
		return fmt.Errorf("start_session: %w", err)
	}
	defer func() {
		_, _ = deleteSession(pc, sessionID)
	}()
	fmt.Printf("[start_session] session_id=%s\n", sessionID)

	message := fmt.Sprintf(
		"这是审批链路自动化测试，如果你不调用 memory_store 就算失败。请把下面这条重要事实记入长期记忆。session_id=%s。text=%s。",
		sessionID,
		"审批链路E2E事实：approval_required 之后必须由 approve 才能继续执行。",
	)
	streamID, err := send(pc, sessionID, message)
	if err != nil {
		return fmt.Errorf("send: %w", err)
	}
	fmt.Printf("[send] stream_id=%s\n", streamID)

	approval, err := waitApproval(streamMu, streams, streamID, timeout)
	if err != nil {
		return err
	}
	fmt.Printf("[approval_required] req_id=%s tool=%s risk=%s\n", approval.reqID, approval.toolName, approval.riskLevel)

	if err := approve(pc, approval.reqID, true); err != nil {
		return fmt.Errorf("approve: %w", err)
	}
	fmt.Println("[approve] ok=true")

	final, toolCallID, err := waitApprovalCompletion(streamMu, streams, streamID, approval.toolCallID, approval.toolName, timeout)
	if err != nil {
		return fmt.Errorf("approval completion: %w", err)
	}
	fmt.Printf("[post-approve] tool_call_id=%s final=%q\n", toolCallID, truncate(final, 48))

	if err := waitIdle(pc, sessionID, 20*time.Second); err != nil {
		return fmt.Errorf("brain_status: %w", err)
	}

	history, err := getHistory(pc, sessionID)
	if err != nil {
		return fmt.Errorf("get_history: %w", err)
	}
	if !historyContainsToolCall(history, approval.toolName) {
		return fmt.Errorf("history missing tool call %q", approval.toolName)
	}
	lastAssistant := lastAssistantContent(history)
	if strings.TrimSpace(lastAssistant) == "" {
		return fmt.Errorf("assistant reply is empty")
	}
	fmt.Printf("[get_history] entries=%d last_assistant=%q\n", len(history), truncate(lastAssistant, 48))

	ok, err := deleteSession(pc, sessionID)
	if err != nil {
		return fmt.Errorf("delete_session: %w", err)
	}
	if !ok {
		return fmt.Errorf("delete_session ok=false")
	}
	fmt.Println("[delete_session] ok=true")
	return nil
}

func listCapabilities(pc panelCaller) ([]brain.CapabilityDesc, error) {
	out, err := pc.Call("list_capabilities", nil)
	if err != nil {
		return nil, err
	}
	caps, ok := out.([]brain.CapabilityDesc)
	if !ok {
		return nil, fmt.Errorf("unexpected list_capabilities type %T", out)
	}
	return caps, nil
}

func startSession(pc panelCaller, prompt, model string) (string, error) {
	out, err := pc.Call("start_session", map[string]any{
		"system_prompt": prompt,
		"model":         model,
	})
	if err != nil {
		return "", err
	}
	result, ok := out.(brain.StartSessionResult)
	if !ok || strings.TrimSpace(result.SessionID) == "" {
		return "", fmt.Errorf("unexpected start_session result %T %#v", out, out)
	}
	return result.SessionID, nil
}

func send(pc panelCaller, sessionID, message string) (string, error) {
	out, err := pc.Call("send", map[string]any{
		"session_id": sessionID,
		"message":    message,
	})
	if err != nil {
		return "", err
	}
	result, ok := out.(brain.SendResult)
	if !ok || strings.TrimSpace(result.StreamID) == "" {
		return "", fmt.Errorf("unexpected send result %T %#v", out, out)
	}
	return result.StreamID, nil
}

func approve(pc panelCaller, reqID string, allow bool) error {
	out, err := pc.Call("approve", map[string]any{
		"req_id": reqID,
		"allow":  allow,
	})
	if err != nil {
		return err
	}
	result, ok := out.(brain.ApproveResult)
	if !ok {
		return fmt.Errorf("unexpected approve result %T", out)
	}
	if !result.OK {
		return fmt.Errorf("approve returned ok=false")
	}
	return nil
}

func getHistory(pc panelCaller, sessionID string) ([]historyEntry, error) {
	out, err := pc.Call("get_history", map[string]any{"session_id": sessionID})
	if err != nil {
		return nil, err
	}
	raw, ok := out.([]brain.HistoryEntry)
	if !ok {
		return nil, fmt.Errorf("unexpected get_history type %T", out)
	}
	entries := make([]historyEntry, 0, len(raw))
	for _, item := range raw {
		entries = append(entries, historyEntry{
			Role:       item.Role,
			Content:    item.Content,
			ToolCalls:  item.ToolCalls,
			ToolCallID: item.ToolCallID,
		})
	}
	return entries, nil
}

func deleteSession(pc panelCaller, sessionID string) (bool, error) {
	out, err := pc.Call("delete_session", map[string]any{"session_id": sessionID})
	if err != nil {
		return false, err
	}
	result, ok := out.(brain.DeleteSessionResult)
	if !ok {
		return false, fmt.Errorf("unexpected delete_session type %T", out)
	}
	return result.OK, nil
}

func waitApproval(streamMu *sync.Mutex, streams map[string][]brain.StreamEvent, streamID string, timeout time.Duration) (approvalEvent, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		streamMu.Lock()
		events := append([]brain.StreamEvent(nil), streams[streamID]...)
		streamMu.Unlock()
		var seenTools []string
		var seenFinal string
		for _, ev := range events {
			switch ev.Kind {
			case "approval_required":
				reqID := fmt.Sprint(ev.Payload["req_id"])
				if strings.TrimSpace(reqID) == "" {
					return approvalEvent{}, fmt.Errorf("approval_required missing req_id")
				}
				return approvalEvent{
					reqID:      reqID,
					toolCallID: fmt.Sprint(ev.Payload["tool_call_id"]),
					toolName:   fmt.Sprint(ev.Payload["tool_name"]),
					riskLevel:  fmt.Sprint(ev.Payload["risk_level"]),
				}, nil
			case "tool_event":
				name := strings.TrimSpace(fmt.Sprint(ev.Payload["name"]))
				if name != "" && !contains(seenTools, name) {
					seenTools = append(seenTools, name)
				}
			case "final":
				seenFinal = fmt.Sprint(ev.Payload["content"])
			case "error":
				return approvalEvent{}, fmt.Errorf("%v", ev.Payload["message"])
			}
		}
		if strings.TrimSpace(seenFinal) != "" {
			return approvalEvent{}, fmt.Errorf("stream finished without approval_required, final=%q seen_tools=%v", truncate(seenFinal, 48), seenTools)
		}
		time.Sleep(200 * time.Millisecond)
	}
	streamMu.Lock()
	events := append([]brain.StreamEvent(nil), streams[streamID]...)
	streamMu.Unlock()
	var seenTools []string
	for _, ev := range events {
		if ev.Kind != "tool_event" {
			continue
		}
		name := strings.TrimSpace(fmt.Sprint(ev.Payload["name"]))
		if name != "" && !contains(seenTools, name) {
			seenTools = append(seenTools, name)
		}
	}
	return approvalEvent{}, fmt.Errorf("timeout waiting approval_required, seen_tools=%v", seenTools)
}

func waitApprovalCompletion(streamMu *sync.Mutex, streams map[string][]brain.StreamEvent, streamID, toolCallID, toolName string, timeout time.Duration) (final string, finishedToolCallID string, err error) {
	deadline := time.Now().Add(timeout)
	var seenToolFinished bool
	for time.Now().Before(deadline) {
		streamMu.Lock()
		events := append([]brain.StreamEvent(nil), streams[streamID]...)
		streamMu.Unlock()
		for _, ev := range events {
			switch ev.Kind {
			case "tool_event":
				name := fmt.Sprint(ev.Payload["name"])
				evToolCallID := fmt.Sprint(ev.Payload["tool_call_id"])
				finished := false
				if raw, ok := ev.Payload["finished"].(bool); ok {
					finished = raw
				}
				if evToolCallID == toolCallID && finished {
					seenToolFinished = true
					finishedToolCallID = evToolCallID
				}
				if (evToolCallID == toolCallID || name == toolName) && fmt.Sprint(ev.Payload["error"]) != "" {
					return "", "", fmt.Errorf("tool_event error: %v", ev.Payload["error"])
				}
			case "final":
				if seenToolFinished {
					return fmt.Sprint(ev.Payload["content"]), finishedToolCallID, nil
				}
			case "error":
				return "", "", fmt.Errorf("%v", ev.Payload["message"])
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return "", "", fmt.Errorf("timeout waiting tool_event/final after approval")
}

func waitIdle(pc panelCaller, sessionID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		out, err := pc.Call("brain_status", map[string]any{"session_id": sessionID})
		if err != nil {
			return err
		}
		result, ok := out.(brain.BrainStatusResult)
		if !ok {
			return fmt.Errorf("unexpected brain_status type %T", out)
		}
		fmt.Printf("[brain_status] state=%s loop=%d history_len=%d\n", result.State, result.LoopCount, result.HistoryLen)
		if result.State == "idle" {
			return nil
		}
		time.Sleep(400 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting idle")
}

func historyContainsToolCall(entries []historyEntry, name string) bool {
	for _, entry := range entries {
		for _, tc := range entry.ToolCalls {
			if tc.Function.Name == name {
				return true
			}
		}
	}
	return false
}

func lastAssistantContent(entries []historyEntry) string {
	for i := len(entries) - 1; i >= 0; i-- {
		if strings.EqualFold(entries[i].Role, "assistant") && strings.TrimSpace(entries[i].Content) != "" {
			return entries[i].Content
		}
	}
	return ""
}

func findCapability(caps []brain.CapabilityDesc, name string) (brain.CapabilityDesc, bool) {
	for _, item := range caps {
		if item.Name == name {
			return item, true
		}
	}
	return brain.CapabilityDesc{}, false
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

func contains(items []string, target string) bool {
	for _, item := range items {
		if item == target {
			return true
		}
	}
	return false
}

func fail(step string, err error) {
	fmt.Fprintf(os.Stderr, "FAIL [%s]: %v\n", step, err)
	os.Exit(1)
}
