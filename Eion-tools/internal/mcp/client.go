package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type toolDesc struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

type clientInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

type initializeParams struct {
	ProtocolVersion string         `json:"protocolVersion"`
	Capabilities    map[string]any `json:"capabilities"`
	ClientInfo      clientInfo     `json:"clientInfo"`
}

type jsonrpcRequest struct {
	JSONRPC string         `json:"jsonrpc"`
	ID      int64          `json:"id,omitempty"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params,omitempty"`
}

type jsonrpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int64           `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type stdioClient struct {
	cfg ServerConfig

	mu        sync.Mutex
	cmd       *exec.Cmd
	stdin     io.WriteCloser
	reader    *bufio.Reader
	healthy   bool
	lastError error
	nextID    atomic.Int64
}

func newStdioClient(cfg ServerConfig) *stdioClient {
	c := &stdioClient{cfg: cfg}
	c.nextID.Store(1)
	return c
}

func (c *stdioClient) start(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cmd != nil && c.healthy {
		return nil
	}
	if err := c.startLocked(ctx); err != nil {
		c.lastError = err
		c.healthy = false
		return err
	}
	c.lastError = nil
	c.healthy = true
	return nil
}

func (c *stdioClient) restart(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.stopLocked()
	if err := c.startLocked(ctx); err != nil {
		c.lastError = err
		c.healthy = false
		return err
	}
	c.lastError = nil
	c.healthy = true
	return nil
}

func (c *stdioClient) startLocked(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, c.cfg.Command, c.cfg.Args...)
	if c.cfg.Cwd != "" {
		cmd.Dir = c.cfg.Cwd
	}
	cmd.Env = append(os.Environ(), envPairs(c.cfg.Env)...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return fmt.Errorf("stdout pipe: %w", err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		return fmt.Errorf("start %s: %w", c.cfg.Name, err)
	}
	c.cmd = cmd
	c.stdin = stdin
	c.reader = bufio.NewReader(stdout)
	if err := c.initializeLocked(); err != nil {
		c.stopLocked()
		return err
	}
	return nil
}

func (c *stdioClient) stop() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.stopLocked()
	c.healthy = false
}

func (c *stdioClient) stopLocked() {
	if c.stdin != nil {
		_ = c.stdin.Close()
		c.stdin = nil
	}
	if c.cmd != nil && c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
		_, _ = c.cmd.Process.Wait()
	}
	c.cmd = nil
	c.reader = nil
}

func (c *stdioClient) listTools(ctx context.Context) ([]toolDesc, error) {
	var result struct {
		Tools []toolDesc `json:"tools"`
	}
	if err := c.call(ctx, "tools/list", nil, &result); err != nil {
		return nil, err
	}
	return result.Tools, nil
}

func (c *stdioClient) callTool(ctx context.Context, name string, arguments map[string]any) (map[string]any, error) {
	params := map[string]any{
		"name":      name,
		"arguments": arguments,
	}
	var result map[string]any
	if err := c.call(ctx, "tools/call", params, &result); err != nil {
		return nil, err
	}
	return result, nil
}

func (c *stdioClient) health() (bool, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.healthy, c.lastError
}

func (c *stdioClient) initializeLocked() error {
	req := jsonrpcRequest{
		JSONRPC: "2.0",
		ID:      c.nextID.Add(1),
		Method:  "initialize",
		Params: map[string]any{
			"protocolVersion": "2025-03-26",
			"capabilities":    map[string]any{},
			"clientInfo": map[string]any{
				"name":    "hermes-eion",
				"version": "v1",
			},
		},
	}
	if _, err := c.doRPCLocked(req); err != nil {
		return fmt.Errorf("initialize: %w", err)
	}
	notify := jsonrpcRequest{
		JSONRPC: "2.0",
		Method:  "notifications/initialized",
	}
	return writeRPC(c.stdin, notify)
}

func (c *stdioClient) call(ctx context.Context, method string, params map[string]any, out any) error {
	deadline := c.cfg.ConnectTimeout
	if deadline <= 0 {
		deadline = 5 * time.Second
	}
	callOnce := func() error {
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.cmd == nil || !c.healthy {
			if err := c.startLocked(ctx); err != nil {
				c.lastError = err
				return err
			}
			c.healthy = true
			c.lastError = nil
		}
		req := jsonrpcRequest{
			JSONRPC: "2.0",
			ID:      c.nextID.Add(1),
			Method:  method,
			Params:  params,
		}
		result, err := c.doRPCLocked(req)
		if err != nil {
			c.healthy = false
			c.lastError = err
			c.stopLocked()
			return err
		}
		if out == nil {
			return nil
		}
		if err := json.Unmarshal(result, out); err != nil {
			return fmt.Errorf("decode %s result: %w", method, err)
		}
		c.healthy = true
		c.lastError = nil
		return nil
	}
	errCh := make(chan error, 1)
	go func() {
		errCh <- callOnce()
	}()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case err := <-errCh:
		return err
	case <-time.After(deadline):
		return fmt.Errorf("%s timeout after %s", method, deadline)
	}
}

func (c *stdioClient) doRPCLocked(req jsonrpcRequest) (json.RawMessage, error) {
	if err := writeRPC(c.stdin, req); err != nil {
		return nil, err
	}
	resp, err := readRPC(c.reader)
	if err != nil {
		return nil, err
	}
	if resp.ID != req.ID {
		return nil, fmt.Errorf("unexpected rpc id %d want %d", resp.ID, req.ID)
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("rpc error %d: %s", resp.Error.Code, resp.Error.Message)
	}
	return resp.Result, nil
}

func writeRPC(w io.Writer, payload any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal rpc: %w", err)
	}
	// MCP stdio 规范: newline-delimited JSON (每行一个 JSON-RPC 消息)
	if _, err := w.Write(body); err != nil {
		return fmt.Errorf("write rpc body: %w", err)
	}
	if _, err := w.Write([]byte("\n")); err != nil {
		return fmt.Errorf("write rpc delimiter: %w", err)
	}
	return nil
}

// readRPC 自动检测两种传输格式:
//   - MCP 标准: newline-delimited JSON (每行一个 JSON-RPC 消息)
//   - LSP 风格: Content-Length: N\r\n\r\n + body (向后兼容旧 mock_mcp_stdio)
func readRPC(r *bufio.Reader) (*jsonrpcResponse, error) {
	first, err := r.Peek(1)
	if err != nil {
		return nil, fmt.Errorf("read rpc peek: %w", err)
	}
	// 以 '{' 开头 → newline-delimited JSON
	if first[0] == '{' {
		line, err := r.ReadString('\n')
		if err != nil && err != io.EOF {
			return nil, fmt.Errorf("read rpc line: %w", err)
		}
		line = strings.TrimRight(line, "\r\n")
		var resp jsonrpcResponse
		if err := json.Unmarshal([]byte(line), &resp); err != nil {
			return nil, fmt.Errorf("decode rpc line: %w", err)
		}
		return &resp, nil
	}
	// 否则 → LSP 风格 Content-Length
	length := 0
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, fmt.Errorf("read rpc header: %w", err)
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		if strings.HasPrefix(strings.ToLower(line), "content-length:") {
			v := strings.TrimSpace(strings.TrimPrefix(line, "Content-Length:"))
			if v == line {
				v = strings.TrimSpace(strings.TrimPrefix(strings.ToLower(line), "content-length:"))
			}
			n, err := strconv.Atoi(v)
			if err != nil {
				return nil, fmt.Errorf("invalid content-length %q: %w", v, err)
			}
			length = n
		}
	}
	if length <= 0 {
		return nil, fmt.Errorf("missing content-length")
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, fmt.Errorf("read rpc body: %w", err)
	}
	var resp jsonrpcResponse
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := dec.Decode(&resp); err != nil {
		return nil, fmt.Errorf("decode rpc body: %w", err)
	}
	return &resp, nil
}

func envPairs(env map[string]string) []string {
	if len(env) == 0 {
		return nil
	}
	out := make([]string, 0, len(env))
	for k, v := range env {
		out = append(out, k+"="+v)
	}
	return out
}
