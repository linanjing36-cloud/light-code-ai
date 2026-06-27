// 端到端 send 探测: 需 Eion-tools + Agent-brains 已启动, api-key.json 可用
//   go run ./cmd/panel_send_e2e
//
// send 为异步 RPC (立即返回 stream_id); 本脚本轮询 get_history 等待 assistant 回复。
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"hermes/internal/brain"
)

func main() {
	b := brain.NewBridge()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	if err := b.Start(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "bridge start: %v\n", err)
		os.Exit(1)
	}
	defer b.Stop()

	out, err := b.Call("start_session", map[string]any{
		"system_prompt": "",
		"model":         "deepseek-v4-pro",
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "start_session: %v\n", err)
		os.Exit(1)
	}
	m, _ := out.(map[string]any)
	sid, _ := m["session_id"].(string)
	if sid == "" {
		fmt.Fprintf(os.Stderr, "empty session_id: %#v\n", m)
		os.Exit(1)
	}
	fmt.Printf("start_session OK session_id=%s\n", sid)

	sendOut, err := b.Call("send", map[string]any{
		"session_id": sid,
		"message":    "只回复两个字：你好",
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "send: %v\n", err)
		os.Exit(1)
	}
	sm, _ := sendOut.(map[string]any)
	fmt.Printf("send OK stream_id=%v (async, waiting for assistant in history...)\n", sm["stream_id"])

	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		histOut, err := b.Call("get_history", map[string]any{"session_id": sid})
		if err != nil {
			fmt.Fprintf(os.Stderr, "get_history: %v\n", err)
			os.Exit(1)
		}
		hm, _ := histOut.(map[string]any)
		msgs, _ := hm["messages"].([]any)
		if len(msgs) >= 2 {
			fmt.Printf("get_history OK messages=%d\n", len(msgs))
			for _, item := range msgs {
				em, _ := item.(map[string]any)
				fmt.Printf("  role=%s content=%q\n", em["role"], em["content"])
			}
			fmt.Println("panel_send_e2e OK")
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	fmt.Fprintf(os.Stderr, "timeout waiting for assistant reply in history\n")
	os.Exit(1)
}
