package main

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"strings"
)

func main() {
	reader := bufio.NewReader(os.Stdin)
	for {
		body, err := readRPC(reader)
		if err != nil {
			return
		}
		var req map[string]any
		if err := json.Unmarshal(body, &req); err != nil {
			return
		}
		method, _ := req["method"].(string)
		id, _ := req["id"].(float64)
		switch method {
		case "initialize":
			writeResult(int64(id), map[string]any{
				"protocolVersion": "2025-03-26",
				"capabilities":    map[string]any{},
				"serverInfo": map[string]any{
					"name":    "mock-mcp",
					"version": "v1",
				},
			})
		case "notifications/initialized":
			continue
		case "tools/list":
			writeResult(int64(id), map[string]any{
				"tools": []map[string]any{
					{
						"name":        "mcp_echo",
						"description": "Echo MCP arguments for acceptance tests.",
						"inputSchema": map[string]any{
							"type": "object",
							"properties": map[string]any{
								"text": map[string]any{
									"type":        "string",
									"description": "text to echo",
								},
							},
							"required": []string{"text"},
						},
					},
				},
			})
		case "tools/call":
			params, _ := req["params"].(map[string]any)
			name, _ := params["name"].(string)
			args, _ := params["arguments"].(map[string]any)
			switch name {
			case "mcp_echo":
				text, _ := args["text"].(string)
				writeResult(int64(id), map[string]any{
					"structuredContent": map[string]any{
						"echo":   text,
						"server": "mock-mcp",
						"kind":   "mcp",
					},
					"content": []map[string]any{
						{"type": "text", "text": text},
					},
				})
			default:
				writeError(int64(id), -32601, "tool not found")
			}
		default:
			writeError(int64(id), -32601, "method not found")
		}
	}
}

func readRPC(r *bufio.Reader) ([]byte, error) {
	// MCP stdio 规范: newline-delimited JSON
	line, err := r.ReadString('\n')
	if err != nil && err != io.EOF {
		return nil, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return nil, io.EOF
	}
	return []byte(line), nil
}

func writeResult(id int64, result map[string]any) {
	writeFrame(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  result,
	})
}

func writeError(id int64, code int, msg string) {
	writeFrame(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"error": map[string]any{
			"code":    code,
			"message": msg,
		},
	})
}

func writeFrame(v map[string]any) {
	// MCP stdio 规范: newline-delimited JSON
	body, _ := json.Marshal(v)
	_, _ = os.Stdout.Write(body)
	_, _ = os.Stdout.Write([]byte("\n"))
}
