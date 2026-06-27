package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/light-code-ai/eion-tools/internal/logging"
	"github.com/light-code-ai/eion-tools/internal/tool"
)

func TestManagerRegistersAndReconnects(t *testing.T) {
	logging.Init()
	cfg := ServerConfig{
		Name:           "mock-mcp",
		Command:        os.Args[0],
		Args:           []string{"-test.run=TestMCPHelperProcess", "--", "mcp-stdio"},
		Env:            map[string]string{"GO_WANT_MCP_HELPER": "1"},
		Enabled:        true,
		ConnectTimeout: 2 * time.Second,
		RetryDelay:     150 * time.Millisecond,
	}
	mgr := NewManager([]ServerConfig{cfg})
	w := tool.New()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	defer mgr.Stop()

	if err := mgr.Start(ctx, w); err != nil {
		t.Fatalf("start manager: %v", err)
	}
	if _, ok := w.Get("mock_echo"); !ok {
		t.Fatal("expected mock_echo to be registered")
	}

	caps := w.CapabilityDescs()
	if len(caps) == 0 || caps[0].Kind != "mcp" || caps[0].Source != "mock-mcp" {
		t.Fatalf("unexpected capabilities: %#v", caps)
	}

	echoTool, _ := w.Get("mock_echo")
	out, err := echoTool.InvokableRun(context.Background(), `{"text":"hello"}`)
	if err != nil {
		t.Fatalf("invoke mock_echo: %v", err)
	}
	if !strings.Contains(out, `"echo":"hello"`) {
		t.Fatalf("unexpected echo output: %s", out)
	}

	killTool, _ := w.Get("kill_server")
	if _, err := killTool.InvokableRun(context.Background(), `{}`); err != nil {
		t.Fatalf("invoke kill_server: %v", err)
	}

	deadline := time.Now().Add(4 * time.Second)
	for {
		time.Sleep(200 * time.Millisecond)
		out, err = echoTool.InvokableRun(context.Background(), `{"text":"after-restart"}`)
		if err == nil && strings.Contains(out, `"echo":"after-restart"`) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("expected reconnect success, last err=%v out=%s statuses=%#v", err, out, mgr.Statuses())
		}
	}
}

func TestMCPHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_MCP_HELPER") != "1" {
		return
	}
	if len(os.Args) < 3 || os.Args[len(os.Args)-1] != "mcp-stdio" {
		os.Exit(0)
	}
	serveMockMCP()
	os.Exit(0)
}

func serveMockMCP() {
	reader := bufio.NewReader(os.Stdin)
	for {
		payload, err := readHelperRPC(reader)
		if err != nil {
			return
		}
		var req map[string]any
		if err := json.Unmarshal(payload, &req); err != nil {
			return
		}
		method, _ := req["method"].(string)
		id, _ := req["id"].(float64)
		switch method {
		case "initialize":
			writeHelperResp(int64(id), map[string]any{
				"protocolVersion": "2025-03-26",
				"capabilities":    map[string]any{},
				"serverInfo":      map[string]any{"name": "mock-mcp", "version": "v1"},
			})
		case "notifications/initialized":
			continue
		case "tools/list":
			writeHelperResp(int64(id), map[string]any{
				"tools": []map[string]any{
					{
						"name":        "mock_echo",
						"description": "echo text",
						"inputSchema": map[string]any{"type": "object", "properties": map[string]any{"text": map[string]any{"type": "string"}}},
					},
					{
						"name":        "kill_server",
						"description": "terminate helper process",
						"inputSchema": map[string]any{"type": "object"},
					},
				},
			})
		case "tools/call":
			params, _ := req["params"].(map[string]any)
			name, _ := params["name"].(string)
			if name == "kill_server" {
				writeHelperResp(int64(id), map[string]any{
					"content": []map[string]any{{"type": "text", "text": "bye"}},
				})
				return
			}
			args, _ := params["arguments"].(map[string]any)
			text, _ := args["text"].(string)
			writeHelperResp(int64(id), map[string]any{
				"structuredContent": map[string]any{"echo": text},
				"content":           []map[string]any{{"type": "text", "text": text}},
			})
		default:
			writeHelperErr(int64(id), -32601, "method not found")
		}
	}
}

func readHelperRPC(r *bufio.Reader) ([]byte, error) {
	length := 0
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		if strings.HasPrefix(strings.ToLower(line), "content-length:") {
			var n int
			if _, err := fmt.Sscanf(line, "Content-Length: %d", &n); err == nil {
				length = n
			} else if _, err := fmt.Sscanf(strings.ToLower(line), "content-length: %d", &n); err == nil {
				length = n
			}
		}
	}
	if length <= 0 {
		return nil, io.EOF
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	return body, nil
}

func writeHelperResp(id int64, result map[string]any) {
	writeHelperFrame(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  result,
	})
}

func writeHelperErr(id int64, code int, msg string) {
	writeHelperFrame(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"error": map[string]any{
			"code":    code,
			"message": msg,
		},
	})
}

func writeHelperFrame(v map[string]any) {
	body, _ := json.Marshal(v)
	header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(body))
	_, _ = io.Copy(os.Stdout, bytes.NewBufferString(header))
	_, _ = os.Stdout.Write(body)
}
