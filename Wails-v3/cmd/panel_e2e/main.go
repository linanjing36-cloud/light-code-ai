// 端到端探测: 需先启动 Agent-brains (start-agent.bat), 再运行:
//   go run ./cmd/panel_e2e
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
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	if err := b.Start(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "bridge start: %v\n", err)
		os.Exit(1)
	}
	defer b.Stop()

	out, err := b.Call("start_session", map[string]any{
		"system_prompt": "你是 Hermes 测试助手",
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "start_session: %v\n", err)
		os.Exit(1)
	}
	m, ok := out.(map[string]any)
	if !ok {
		fmt.Fprintf(os.Stderr, "start_session: unexpected type %T\n", out)
		os.Exit(1)
	}
	sid, _ := m["session_id"].(string)
	if sid == "" {
		fmt.Fprintf(os.Stderr, "start_session: empty session_id: %#v\n", m)
		os.Exit(1)
	}
	fmt.Printf("start_session OK session_id=%s\n", sid)

	stOut, err := b.Call("brain_status", map[string]any{"session_id": sid})
	if err != nil {
		fmt.Fprintf(os.Stderr, "brain_status: %v\n", err)
		os.Exit(1)
	}
	st, ok := stOut.(map[string]any)
	if !ok {
		fmt.Fprintf(os.Stderr, "brain_status: unexpected type %T\n", stOut)
		os.Exit(1)
	}
	fmt.Printf("brain_status OK state=%v loop_count=%v\n", st["state"], st["loop_count"])
}
