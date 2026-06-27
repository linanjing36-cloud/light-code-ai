// 面板 → 大脑 → Eion → LLM → 大脑 → 面板 闭环 e2e（无 Wails UI）
//
// Phase B: LLM 经 panel exec 在 Wails 进程内调用 DeepSeek API（真实推理，非 mock）。
//
// 前置: Agent-brains 已启动且 HERMES_EXEC_VIA_PANEL=1，api-key 可用
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

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
	"hermes/internal/eion"
	"hermes/internal/router"
)

type panelCaller interface {
	Call(method string, args map[string]any) (any, error)
}

type routerPanel struct{ r *router.Router }

func (p *routerPanel) Call(method string, args map[string]any) (any, error) {
	return p.r.CallPanel(method, args)
}

func main() {
	rounds := flag.Int("rounds", 1, "闭环轮数 (每轮: send → LLM stream → history)")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()

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
		if ev.Kind == "chunk" {
			fmt.Printf("  [llm-chunk] stream=%s content=%q\n", ev.StreamID, truncate(str(ev.Payload["content"]), 30))
		}
	})

	fmt.Println("=== Hermes 闭环 e2e: panel → brain → LLM(DeepSeek) → brain → panel ===")
	_ = os.Setenv("HERMES_EXEC_VIA_PANEL", "1")

	fmt.Println("[0] embedded Eion + panel exec handler (进程内调 LLM API)")
	if err := eionEmb.ServiceStartup(ctx, application.ServiceOptions{}); err != nil {
		fail("eion embed", err)
	}
	defer eionEmb.ServiceShutdown()
	if err := b.Start(ctx); err != nil {
		fail("bridge start", err)
	}
	defer b.Stop()
	if err := rt.ServiceStartup(ctx, application.ServiceOptions{}); err != nil {
		fail("router startup", err)
	}
	defer rt.ServiceShutdown()

	fmt.Println("[1] panel → start_session")
	out, err := pc.Call("start_session", map[string]any{
		"system_prompt": "你是 Hermes 闭环测试助手，回答简洁。",
		"model":         "deepseek-v4-pro",
	})
	if err != nil {
		fail("start_session", err)
	}
	result, ok := out.(brain.StartSessionResult)
	if !ok || result.SessionID == "" {
		fail("start_session", fmt.Errorf("empty session_id: %#v", out))
	}
	sid := result.SessionID
	fmt.Printf("    brain ← session_id=%s\n", sid)

	for r := 1; r <= *rounds; r++ {
		fmt.Printf("\n--- round %d/%d ---\n", r, *rounds)
		msg := fmt.Sprintf("第%d轮：只回复两个字「收到」", r)
		if err := runRound(ctx, pc, sid, msg, &streamMu, streams); err != nil {
			fail(fmt.Sprintf("round %d", r), err)
		}
	}

	fmt.Println("\n=== panel_loop_e2e OK (LLM 真实调用已验证) ===")
}

func runRound(ctx context.Context, pc panelCaller, sid, message string, streamMu *sync.Mutex, streams map[string][]brain.StreamEvent) error {
	fmt.Printf("[2] panel → send message=%q\n", message)
	sendOut, err := pc.Call("send", map[string]any{
		"session_id": sid,
		"message":    message,
	})
	if err != nil {
		return fmt.Errorf("send: %w", err)
	}
	sendResult, ok := sendOut.(brain.SendResult)
	if !ok || sendResult.StreamID == "" {
		return fmt.Errorf("send: empty stream_id: %#v", sendOut)
	}
	streamID := sendResult.StreamID
	fmt.Printf("    brain ← stream_id=%s (ReAct 触发, 经 panel exec 调 LLM)\n", streamID)

	fmt.Println("[3] brain → panel exec → DeepSeek LLM (等待 stream chunk/final...)")
	final, chunks, err := waitStreamFinal(ctx, streamMu, streams, streamID, 90*time.Second)
	if err != nil {
		return err
	}
	fmt.Printf("    LLM OK: stream_chunks=%d completion_tokens=%d prompt_tokens=%d reply=%q\n",
		chunks, final.completionTokens, final.promptTokens, truncate(final.content, 60))
	if chunks == 0 {
		return fmt.Errorf("LLM 未产生 stream chunk，可能未真正调用 API")
	}
	if final.completionTokens <= 0 {
		return fmt.Errorf("LLM completion_tokens=0，未产生有效推理结果")
	}

	fmt.Println("[4] panel → brain_status")
	if err := waitBrainIdle(ctx, pc, sid, 15*time.Second); err != nil {
		return err
	}

	fmt.Println("[5] panel → get_history")
	assistant, err := waitAssistantReply(ctx, pc, sid, message, 10*time.Second)
	if err != nil {
		return err
	}
	fmt.Printf("    brain ← assistant reply=%q\n", truncate(assistant, 80))
	return nil
}

type streamFinal struct {
	content           string
	promptTokens      int
	completionTokens  int
}

func waitStreamFinal(ctx context.Context, streamMu *sync.Mutex, streams map[string][]brain.StreamEvent, streamID string, timeout time.Duration) (streamFinal, int, error) {
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
				pt := intNum(ev.Payload["prompt_tokens"])
				ct := intNum(ev.Payload["completion_tokens"])
				return streamFinal{
					content:          str(ev.Payload["content"]),
					promptTokens:     pt,
					completionTokens: ct,
				}, chunks, nil
			case "error":
				return streamFinal{}, chunks, fmt.Errorf("stream error: %v", ev.Payload["message"])
			}
		}
		select {
		case <-ctx.Done():
			return streamFinal{}, chunks, ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
	return streamFinal{}, chunks, fmt.Errorf("timeout waiting LLM stream final (stream_id=%s, chunks=%d)", streamID, chunks)
}

func waitBrainIdle(ctx context.Context, pc panelCaller, sid string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		stOut, err := pc.Call("brain_status", map[string]any{"session_id": sid})
		if err != nil {
			return fmt.Errorf("brain_status: %w", err)
		}
		st, ok := stOut.(brain.BrainStatusResult)
		if !ok {
			return fmt.Errorf("brain_status: unexpected type %T", stOut)
		}
		fmt.Printf("    brain_status state=%s loop=%d\n", st.State, st.LoopCount)
		if st.State == "idle" {
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

func waitAssistantReply(ctx context.Context, pc panelCaller, sid, userMsg string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		histOut, err := pc.Call("get_history", map[string]any{"session_id": sid})
		if err != nil {
			return "", fmt.Errorf("get_history: %w", err)
		}
		msgs, ok := histOut.([]brain.HistoryEntry)
		if !ok {
			return "", fmt.Errorf("get_history: unexpected type %T", histOut)
		}
		foundUser := false
		for _, item := range msgs {
			if item.Role == "user" && strings.Contains(item.Content, userMsg) {
				foundUser = true
			}
			if foundUser && item.Role == "assistant" && strings.TrimSpace(item.Content) != "" {
				return item.Content, nil
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

func intNum(v any) int {
	switch n := v.(type) {
	case int:
		return n
	case int32:
		return int(n)
	case int64:
		return int(n)
	case float64:
		return int(n)
	default:
		return 0
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
