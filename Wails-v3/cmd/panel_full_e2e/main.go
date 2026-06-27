// 面板端全流程 e2e（不启动 Wails UI）
//
// 走与 HermesService + 前端 main.ts 相同的路径:
//   Router → ListTools 探活 → StartSession → Send → stream hub → BrainStatus → GetHistory
//
// 前置: Agent-brains 已启动且 HERMES_EXEC_VIA_PANEL=1 (或 UI 模式)
//   go run ./cmd/panel_full_e2e
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
	"hermes/internal/eion"
	"hermes/internal/router"
)

// panelClient 经 Router 转发 (与 HermesService 同路径)。
type panelClient struct {
	r *router.Router
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	b := brain.NewBridge()
	eionEmb := eion.NewEmbedded()
	rt := router.New(b, eionEmb)
	pc := &panelClient{r: rt}

	var streamMu sync.Mutex
	streams := make(map[string][]brain.StreamEvent)
	rt.SetStreamTap(func(ev brain.StreamEvent) {
		streamMu.Lock()
		streams[ev.StreamID] = append(streams[ev.StreamID], ev)
		streamMu.Unlock()
	})

	fmt.Println("=== 面板端全流程 e2e（无 Wails UI）===")

	_ = os.Setenv("HERMES_EXEC_VIA_PANEL", "1")

	fmt.Println("[0] embedded Eion-tools (in-process via panel exec)")
	if err := eionEmb.ServiceStartup(ctx, application.ServiceOptions{}); err != nil {
		fail("eion embed", err)
	}
	defer eionEmb.ServiceShutdown()

	fmt.Println("[0b] Bridge.Start + Router stream hub + exec handler")
	if err := b.Start(ctx); err != nil {
		fail("Bridge.Start", err)
	}
	defer b.Stop()
	if err := rt.ServiceStartup(ctx, application.ServiceOptions{}); err != nil {
		fail("Router.ServiceStartup", err)
	}
	defer rt.ServiceShutdown()

	// [1] 等同 checkBrainReady: ListTools 探活
	fmt.Println("[1] HermesService.ListTools (探活)")
	tools, err := pc.listTools()
	if err != nil {
		fail("ListTools", err)
	}
	fmt.Printf("    tools=%d", len(tools))
	if len(tools) > 0 {
		fmt.Printf(" first=%s", tools[0].Name)
	}
	fmt.Println()

	// [2] 等同 createNewSession
	fmt.Println("[2] HermesService.StartSession")
	sid, err := pc.startSession("你是 Hermes 全流程测试助手，回答极简。", "deepseek-v4-pro")
	if err != nil {
		fail("StartSession", err)
	}
	fmt.Printf("    session_id=%s\n", sid)

	st, err := pc.brainStatus(sid)
	if err != nil {
		fail("BrainStatus(initial)", err)
	}
	fmt.Printf("    brain_status state=%s history_len=%d\n", st.State, st.HistoryLen)

	// [3] 等同 doSend + panel:stream 监听
	msg := "只回复两个字：收到"
	fmt.Printf("[3] HermesService.Send message=%q\n", msg)
	streamID, err := pc.send(sid, msg)
	if err != nil {
		fail("Send", err)
	}
	fmt.Printf("    stream_id=%s\n", streamID)

	fmt.Println("[4] 等待 panel:stream (chunk → final)")
	final, nChunk, err := waitStream(&streamMu, streams, streamID, 75*time.Second)
	if err != nil {
		fail("stream", err)
	}
	fmt.Printf("    stream OK chunks=%d final=%q\n", nChunk, truncate(final, 40))

	fmt.Println("[5] HermesService.BrainStatus (轮询至 idle)")
	if err := waitIdle(pc, sid, 15*time.Second); err != nil {
		fail("BrainStatus(idle)", err)
	}

	fmt.Println("[6] HermesService.GetHistory (等同 refreshHistoryFromBrain)")
	entries, err := pc.getHistory(sid)
	if err != nil {
		fail("GetHistory", err)
	}
	userN, asst := countRoles(entries)
	fmt.Printf("    history entries=%d user=%d last_assistant=%q\n", len(entries), userN, truncate(asst, 60))
	if userN < 1 || strings.TrimSpace(asst) == "" {
		fail("GetHistory", fmt.Errorf("missing user/assistant: %#v", entries))
	}

	fmt.Println("[7] HermesService.DeleteSession (清理)")
	ok, err := pc.deleteSession(sid)
	if err != nil {
		fail("DeleteSession", err)
	}
	fmt.Printf("    deleted ok=%v\n", ok)

	fmt.Println("\n=== panel_full_e2e OK ===")
}

type toolDesc struct {
	Name, Description, ParametersJSON string
}

type historyEntry struct {
	Role, Content, ToolCallsJSON, ToolCallID string
}

func (p *panelClient) listTools() ([]toolDesc, error) {
	out, err := p.r.CallPanel("list_tools", nil)
	if err != nil {
		return nil, err
	}
	raw, ok := out.([]brain.ToolDesc)
	if !ok {
		return nil, fmt.Errorf("unexpected type %T", out)
	}
	tools := make([]toolDesc, 0, len(raw))
	for _, item := range raw {
		tools = append(tools, toolDesc{
			Name:           item.Name,
			Description:    item.Description,
			ParametersJSON: item.ParametersJSON,
		})
	}
	return tools, nil
}

func (p *panelClient) startSession(prompt, model string) (string, error) {
	out, err := p.r.CallPanel("start_session", map[string]any{
		"system_prompt": prompt,
		"model":         model,
	})
	if err != nil {
		return "", err
	}
	result, ok := out.(brain.StartSessionResult)
	if !ok || result.SessionID == "" {
		return "", fmt.Errorf("empty session_id: %#v", out)
	}
	return result.SessionID, nil
}

func (p *panelClient) send(sessionID, message string) (string, error) {
	out, err := p.r.CallPanel("send", map[string]any{
		"session_id": sessionID,
		"message":    message,
	})
	if err != nil {
		return "", err
	}
	result, ok := out.(brain.SendResult)
	if !ok || result.StreamID == "" {
		return "", fmt.Errorf("empty stream_id: %#v", out)
	}
	return result.StreamID, nil
}

func (p *panelClient) brainStatus(sessionID string) (brain.BrainStatusResult, error) {
	out, err := p.r.CallPanel("brain_status", map[string]any{"session_id": sessionID})
	if err != nil {
		return brain.BrainStatusResult{}, err
	}
	result, ok := out.(brain.BrainStatusResult)
	if !ok {
		return brain.BrainStatusResult{}, fmt.Errorf("unexpected type %T", out)
	}
	return result, nil
}

func (p *panelClient) getHistory(sessionID string) ([]historyEntry, error) {
	out, err := p.r.CallPanel("get_history", map[string]any{"session_id": sessionID})
	if err != nil {
		return nil, err
	}
	raw, ok := out.([]brain.HistoryEntry)
	if !ok {
		return nil, fmt.Errorf("unexpected type %T", out)
	}
	entries := make([]historyEntry, 0, len(raw))
	for _, item := range raw {
		entries = append(entries, historyEntry{
			Role:          item.Role,
			Content:       item.Content,
			ToolCallsJSON: item.ToolCallsJSON,
			ToolCallID:    item.ToolCallID,
		})
	}
	return entries, nil
}

func (p *panelClient) deleteSession(sessionID string) (bool, error) {
	out, err := p.r.CallPanel("delete_session", map[string]any{"session_id": sessionID})
	if err != nil {
		return false, err
	}
	result, ok := out.(brain.DeleteSessionResult)
	if !ok {
		return false, fmt.Errorf("unexpected type %T", out)
	}
	return result.OK, nil
}

func waitStream(streamMu *sync.Mutex, streams map[string][]brain.StreamEvent, streamID string, timeout time.Duration) (final string, chunks int, err error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		streamMu.Lock()
		events := append([]brain.StreamEvent(nil), streams[streamID]...)
		streamMu.Unlock()
		for _, ev := range events {
			switch ev.Kind {
			case "chunk":
				chunks++
			case "final":
				return fmt.Sprint(ev.Payload["content"]), chunks, nil
			case "error":
				return "", chunks, fmt.Errorf("%v", ev.Payload["message"])
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return "", chunks, fmt.Errorf("timeout stream_id=%s chunks=%d", streamID, chunks)
}

func waitIdle(p *panelClient, sid string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		st, err := p.brainStatus(sid)
		if err != nil {
			return err
		}
		fmt.Printf("    state=%s loop=%d\n", st.State, st.LoopCount)
		if st.State == "idle" {
			return nil
		}
		time.Sleep(400 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting idle")
}

func countRoles(entries []historyEntry) (userN int, lastAsst string) {
	for _, e := range entries {
		switch strings.ToLower(e.Role) {
		case "user":
			userN++
		case "assistant":
			lastAsst = e.Content
		}
	}
	return userN, lastAsst
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func fail(step string, err error) {
	fmt.Fprintf(os.Stderr, "FAIL [%s]: %v\n", step, err)
	os.Exit(1)
}
