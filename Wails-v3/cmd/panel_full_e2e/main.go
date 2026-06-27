// 面板端全流程 e2e（不启动 Wails UI）
//
// 走与 HermesService + 前端 main.ts 相同的路径:
//   Bridge.Start → ListTools 探活 → StartSession → Send → panel:stream → BrainStatus → GetHistory → DeleteSession
//
// 前置: Agent-brains 已启动 (Eion-tools 由本进程 embedded 拉起)
//   go run ./cmd/panel_full_e2e
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"hermes/internal/brain"
	"hermes/internal/eion"
)

// panelClient 模拟 Wails HermesService 薄封装（与 app.go 同路径）
type panelClient struct {
	b *brain.Bridge
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	b := brain.NewBridge()
	pc := &panelClient{b: b}

	var streamMu sync.Mutex
	streams := make(map[string][]brain.StreamEvent)
	brain.SetStreamHandler(func(ev brain.StreamEvent) {
		streamMu.Lock()
		streams[ev.StreamID] = append(streams[ev.StreamID], ev)
		streamMu.Unlock()
	})
	defer brain.SetStreamHandler(nil)

	fmt.Println("=== 面板端全流程 e2e（无 Wails UI）===")

	stopEion, err := eion.StartHeadless(ctx, "")
	if err != nil {
		fail("embedded eion", err)
	}
	defer stopEion()
	fmt.Println("[0] embedded Eion-tools started")

	fmt.Println("[0b] Bridge.Start (等同 Wails 启动时连 panel)")
	if err := b.Start(ctx); err != nil {
		fail("Bridge.Start", err)
	}
	defer b.Stop()

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
	fmt.Printf("    brain_status state=%v history_len=%v\n", st["state"], st["history_len"])

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
	out, err := p.b.Call("list_tools", nil)
	if err != nil {
		return nil, err
	}
	m, _ := out.(map[string]any)
	raw, _ := m["tools"].([]any)
	tools := make([]toolDesc, 0, len(raw))
	for _, item := range raw {
		tm, ok := item.(map[string]any)
		if !ok {
			continue
		}
		tools = append(tools, toolDesc{
			Name:           fmt.Sprint(tm["name"]),
			Description:    fmt.Sprint(tm["description"]),
			ParametersJSON: fmt.Sprint(tm["parameters_json"]),
		})
	}
	return tools, nil
}

func (p *panelClient) startSession(prompt, model string) (string, error) {
	out, err := p.b.Call("start_session", map[string]any{
		"system_prompt": prompt,
		"model":         model,
	})
	if err != nil {
		return "", err
	}
	m, _ := out.(map[string]any)
	id, _ := m["session_id"].(string)
	if id == "" {
		return "", fmt.Errorf("empty session_id: %#v", out)
	}
	return id, nil
}

func (p *panelClient) send(sessionID, message string) (string, error) {
	out, err := p.b.Call("send", map[string]any{
		"session_id": sessionID,
		"message":    message,
	})
	if err != nil {
		return "", err
	}
	m, _ := out.(map[string]any)
	id, _ := m["stream_id"].(string)
	if id == "" {
		return "", fmt.Errorf("empty stream_id: %#v", out)
	}
	return id, nil
}

func (p *panelClient) brainStatus(sessionID string) (map[string]any, error) {
	out, err := p.b.Call("brain_status", map[string]any{"session_id": sessionID})
	if err != nil {
		return nil, err
	}
	m, ok := out.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("unexpected type %T", out)
	}
	return m, nil
}

func (p *panelClient) getHistory(sessionID string) ([]historyEntry, error) {
	out, err := p.b.Call("get_history", map[string]any{"session_id": sessionID})
	if err != nil {
		return nil, err
	}
	m, _ := out.(map[string]any)
	raw, _ := m["messages"].([]any)
	entries := make([]historyEntry, 0, len(raw))
	for _, item := range raw {
		em, ok := item.(map[string]any)
		if !ok {
			continue
		}
		entries = append(entries, historyEntry{
			Role:          fmt.Sprint(em["role"]),
			Content:       fmt.Sprint(em["content"]),
			ToolCallsJSON: fmt.Sprint(em["tool_calls_json"]),
			ToolCallID:    fmt.Sprint(em["tool_call_id"]),
		})
	}
	return entries, nil
}

func (p *panelClient) deleteSession(sessionID string) (bool, error) {
	out, err := p.b.Call("delete_session", map[string]any{"session_id": sessionID})
	if err != nil {
		return false, err
	}
	m, _ := out.(map[string]any)
	ok, _ := m["ok"].(bool)
	return ok, nil
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
		state, _ := st["state"].(string)
		fmt.Printf("    state=%s loop=%v\n", state, st["loop_count"])
		if state == "idle" {
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
