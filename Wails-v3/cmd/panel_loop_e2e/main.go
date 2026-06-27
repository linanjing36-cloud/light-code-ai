// 面板 → 大脑 → Eion → LLM → 大脑 → 面板 闭环 e2e（无 Wails UI）
//
// 前置: Eion-tools + Agent-brains 已启动, api-key.json 可用
//   go run ./cmd/panel_loop_e2e
//   go run ./cmd/panel_loop_e2e -rounds 2
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"hermes/internal/brain"
)

func main() {
	rounds := flag.Int("rounds", 1, "闭环轮数 (每轮: send → stream → history)")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	b := brain.NewBridge()
	var streamMu sync.Mutex
	streams := make(map[string][]brain.StreamEvent)
	brain.SetStreamHandler(func(ev brain.StreamEvent) {
		streamMu.Lock()
		streams[ev.StreamID] = append(streams[ev.StreamID], ev)
		streamMu.Unlock()
		fmt.Printf("  [stream] id=%s kind=%s payload=%v\n", ev.StreamID, ev.Kind, briefPayload(ev))
	})
	defer brain.SetStreamHandler(nil)

	if err := b.Start(ctx); err != nil {
		fail("bridge start", err)
	}
	defer b.Stop()

	fmt.Println("=== Hermes 闭环 e2e: panel → brain → eion → brain → panel ===")

	fmt.Println("[1] panel → start_session")
	out, err := b.Call("start_session", map[string]any{
		"system_prompt": "你是 Hermes 闭环测试助手，回答简洁。",
		"model":         "deepseek-v4-pro",
	})
	if err != nil {
		fail("start_session", err)
	}
	sid, _ := out.(map[string]any)["session_id"].(string)
	if sid == "" {
		fail("start_session", fmt.Errorf("empty session_id: %#v", out))
	}
	fmt.Printf("    brain ← session_id=%s\n", sid)

	for r := 1; r <= *rounds; r++ {
		fmt.Printf("\n--- round %d/%d ---\n", r, *rounds)
		msg := fmt.Sprintf("第%d轮：只回复两个字「收到」", r)
		if err := runRound(ctx, b, sid, msg, &streamMu, streams); err != nil {
			fail(fmt.Sprintf("round %d", r), err)
		}
	}

	fmt.Println("\n=== panel_loop_e2e OK ===")
}

func runRound(ctx context.Context, b *brain.Bridge, sid, message string, streamMu *sync.Mutex, streams map[string][]brain.StreamEvent) error {
	fmt.Printf("[2] panel → send message=%q\n", message)
	sendOut, err := b.Call("send", map[string]any{
		"session_id": sid,
		"message":    message,
	})
	if err != nil {
		return fmt.Errorf("send: %w", err)
	}
	streamID, _ := sendOut.(map[string]any)["stream_id"].(string)
	if streamID == "" {
		return fmt.Errorf("send: empty stream_id: %#v", sendOut)
	}
	fmt.Printf("    brain ← stream_id=%s (async)\n", streamID)

	fmt.Println("[3] brain → eion → LLM (等待 stream chunk/final...)")
	if err := waitStreamFinal(ctx, streamMu, streams, streamID, 75*time.Second); err != nil {
		return err
	}

	fmt.Println("[4] panel → brain_status")
	if err := waitBrainIdle(ctx, b, sid, 15*time.Second); err != nil {
		return err
	}

	fmt.Println("[5] panel → get_history")
	assistant, err := waitAssistantReply(ctx, b, sid, message, 10*time.Second)
	if err != nil {
		return err
	}
	fmt.Printf("    brain ← assistant reply=%q\n", truncate(assistant, 80))
	return nil
}

func waitStreamFinal(ctx context.Context, streamMu *sync.Mutex, streams map[string][]brain.StreamEvent, streamID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var chunks int
	for time.Now().Before(deadline) {
		streamMu.Lock()
		events := append([]brain.StreamEvent(nil), streams[streamID]...)
		streamMu.Unlock()
		for _, ev := range events {
			switch ev.Kind {
			case "chunk":
				chunks++
			case "final":
				fmt.Printf("    stream OK: chunks=%d final_content=%q\n", chunks, truncate(str(ev.Payload["content"]), 60))
				return nil
			case "error":
				return fmt.Errorf("stream error: %v", ev.Payload["message"])
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
	return fmt.Errorf("timeout waiting stream final (stream_id=%s, chunks=%d)", streamID, chunks)
}

func waitBrainIdle(ctx context.Context, b *brain.Bridge, sid string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		stOut, err := b.Call("brain_status", map[string]any{"session_id": sid})
		if err != nil {
			return fmt.Errorf("brain_status: %w", err)
		}
		st, _ := stOut.(map[string]any)
		state, _ := st["state"].(string)
		loop, _ := st["loop_count"]
		fmt.Printf("    brain_status state=%s loop=%v\n", state, loop)
		if state == "idle" {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(400 * time.Millisecond):
		}
	}
	return fmt.Errorf("timeout waiting brain idle")
}

func waitAssistantReply(ctx context.Context, b *brain.Bridge, sid, userMsg string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		histOut, err := b.Call("get_history", map[string]any{"session_id": sid})
		if err != nil {
			return "", fmt.Errorf("get_history: %w", err)
		}
		hm, _ := histOut.(map[string]any)
		msgs, _ := hm["messages"].([]any)
		foundUser := false
		for _, item := range msgs {
			em, _ := item.(map[string]any)
			role, _ := em["role"].(string)
			content, _ := em["content"].(string)
			if role == "user" && strings.Contains(content, userMsg) {
				foundUser = true
			}
			if foundUser && role == "assistant" && strings.TrimSpace(content) != "" {
				return content, nil
			}
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(300 * time.Millisecond):
		}
	}
	return "", fmt.Errorf("timeout waiting assistant reply in history")
}

func briefPayload(ev brain.StreamEvent) string {
	switch ev.Kind {
	case "chunk":
		return truncate(str(ev.Payload["content"]), 40)
	case "final":
		return truncate(str(ev.Payload["content"]), 40)
	case "error":
		return str(ev.Payload["message"])
	default:
		return ev.Kind
	}
}

func str(v any) string {
	s, _ := v.(string)
	return s
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
