// Package brain 是 Wails(Go) 与 Agent-brains(Erlang/OTP) 之间的桥接层。
//
// 架构定位 (新架构: 三进程独立启动 + 连接池):
//   Wails (Go, 本进程)  ──TCP/UDS 连接池──▶  panel_server (Erlang)
//                                              │
//                                              ▼
//                                         agent_fsm (ReAct 编排)
//                                              │
//                                              ▼ (bridge_manager: TCP/UDS 连接池)
//                                         Eion-tools (Go)
//
// 通信协议:
//   - 长度前缀帧: 4 字节大端长度 + JSON body
//   - 请求: {"id": <uint64>, "method": "<name>", "args": {...}}
//   - 响应: {"id": <uint64>, "result": <any>, "error": <string|null>}
//
// 连接池模型:
//   - Start 时建立 N 个连接 (默认 4), 每个 conn 一个 worker goroutine
//   - 全局请求队列 (chan), N 个 worker 从中取请求串行处理 (写帧→读响应→分发)
//   - 多连接天然并发: panel_server 侧每连接独立进程, 与本侧 worker 一一对应
//   - 连接断开: worker 退出, 剩余 worker 继续服务; 后续可加重连
//
// 地址发现 (优先级):
//   1. HERMES_PANEL_ADDR env (直接地址, 如 "127.0.0.1:12345")
//   2. HERMES_PANEL_ADDR_FILE env (端口文件路径, 读文件取地址)
//   3. 默认端口文件: <repo>/bin/run/panel.addr
package brain

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"
)

// 默认连接池大小 (与 Erlang bridge_manager 对齐)
const defaultPoolSize = 4

// Bridge 管理 Wails ↔ Erlang panel_server 的 TCP/UDS 连接池。
// 实现 Wails v3 Service 接口: ServiceStartup / ServiceShutdown。
type Bridge struct {
	mu      sync.Mutex
	ctx     context.Context
	cancel  context.CancelFunc
	started bool

	// 连接池
	poolSize int
	conns    []net.Conn
	queue    chan pendingCall // 全局请求队列, N 个 worker 从此取请求

	// 请求/响应多路复用 (响应按 id 路由到对应 chan)
	reqSeq  atomic.Uint64
	pending sync.Map // map[uint64]chan rpcResponse
}

// pendingCall 是 Call 入队的一个待处理请求。
// worker 取出后写帧, 读响应, 把结果发到 ch。
type pendingCall struct {
	id   uint64
	body []byte
	ch   chan rpcResponse
}

// rpcRequest / rpcResponse: 与 Erlang panel_server 对齐的 JSON-RPC 帧。
type rpcRequest struct {
	ID     uint64         `json:"id"`
	Method string         `json:"method"`
	Args   map[string]any `json:"args,omitempty"`
}

type rpcResponse struct {
	ID     uint64 `json:"id"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

func NewBridge() *Bridge {
	return &Bridge{poolSize: defaultPoolSize}
}

// ServiceStartup 实现 application.ServiceStartup (Wails v3 生命周期)。
// 在应用启动时发现 panel_server 地址, 建立连接池。
func (b *Bridge) ServiceStartup(ctx context.Context, _ application.ServiceOptions) error {
	return b.Start(ctx)
}

// ServiceShutdown 实现 application.ServiceShutdown (Wails v3 生命周期)。
// 在应用退出时优雅停止连接池 (发 stop RPC + 关闭所有连接)。
func (b *Bridge) ServiceShutdown() error {
	b.Stop()
	return nil
}

// Start 发现 panel_server 地址并建立 TCP/UDS 连接池。
// ctx 来自 Wails 应用上下文, ctx 取消时连接池关闭。
func (b *Bridge) Start(parentCtx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.started {
		return nil
	}

	ctx, cancel := context.WithCancel(parentCtx)
	b.ctx, b.cancel = ctx, cancel

	// 1. 发现 panel_server 地址 (轮询读端口文件, 等 Agent 启动)
	addr, err := resolvePanelAddr(ctx, 30*time.Second)
	if err != nil {
		cancel()
		return fmt.Errorf("brain: 发现 panel_server 地址失败: %w", err)
	}
	log.Printf("[brain] panel_server addr resolved: %s", addr)

	// 2. 建立连接池
	b.queue = make(chan pendingCall, 64)
	b.conns = make([]net.Conn, 0, b.poolSize)
	for i := 0; i < b.poolSize; i++ {
		conn, err := dialPanel(addr, 5*time.Second)
		if err != nil {
			log.Printf("[brain] 连接池 slot %d 连接失败: %v (继续尝试剩余)", i, err)
			continue
		}
		b.conns = append(b.conns, conn)
	}
	if len(b.conns) == 0 {
		cancel()
		return fmt.Errorf("brain: 连接 panel_server 失败 (addr=%s): 所有连接均失败", addr)
	}
	log.Printf("[brain] 连接池就绪: %d/%d 连接", len(b.conns), b.poolSize)

	// 3. 启动 worker goroutine (每个 conn 一个)
	for _, conn := range b.conns {
		go b.connWorker(ctx, conn, bufio.NewReaderSize(conn, 64*1024))
	}

	b.started = true
	return nil
}

// Stop 优雅停止连接池。
// 优先发 stop RPC (触发 Erlang init:stop), 然后关闭所有连接。
func (b *Bridge) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.started {
		return
	}

	// 优雅: 发 stop 方法 (Erlang 侧收到后调 init:stop())
	// 用独立 ctx 避免被 b.ctx 取消影响
	stopCtx, stopCancel := context.WithTimeout(context.Background(), 3*time.Second)
	_, _ = b.callInternal(stopCtx, "stop", nil)
	stopCancel()

	if b.cancel != nil {
		b.cancel()
	}
	// 关闭所有连接 (worker 的 Read 会返回 EOF, 自然退出)
	for _, conn := range b.conns {
		_ = conn.Close()
	}
	// 关闭队列 (worker 的 range 退出)
	close(b.queue)
	b.conns = nil
	b.queue = nil
	b.started = false
}

// Call 发起一次同步 RPC 到 Erlang 大脑, 返回 result。
func (b *Bridge) Call(method string, args map[string]any) (any, error) {
	b.mu.Lock()
	started := b.started
	q := b.queue
	b.mu.Unlock()
	if !started || q == nil {
		return nil, fmt.Errorf("brain: not started")
	}
	return b.callInternal(context.Background(), method, args)
}

// callInternal 内部: 分配 req id → 注册 pending chan → 入队 → 等响应。
func (b *Bridge) callInternal(ctx context.Context, method string, args map[string]any) (any, error) {
	b.mu.Lock()
	q := b.queue
	b.mu.Unlock()
	if q == nil {
		return nil, fmt.Errorf("brain: connection pool closed")
	}

	id := b.reqSeq.Add(1)
	req := rpcRequest{ID: id, Method: method, Args: args}
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("brain: marshal request: %w", err)
	}
	frame := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(body)))
	copy(frame[4:], body)

	ch := make(chan rpcResponse, 1)
	b.pending.Store(id, ch)
	defer b.pending.Delete(id)

	// 入队 (非阻塞尝试, 队列满则报错)
	select {
	case q <- pendingCall{id: id, body: frame, ch: ch}:
	default:
		return nil, fmt.Errorf("brain: request queue full")
	}

	// 等响应 / ctx 取消 / 超时
	select {
	case resp := <-ch:
		if resp.Error != "" {
			return nil, fmt.Errorf("brain: %s: %s", method, resp.Error)
		}
		return resp.Result, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("brain: %s: %w", method, ctx.Err())
	case <-time.After(30 * time.Second):
		return nil, fmt.Errorf("brain: %s: timeout (30s)", method)
	}
}

// connWorker 是单个连接的工作 goroutine:
// 从全局 queue 取请求 → 写帧 → 读响应 → 分发到 pending chan, 循环。
// 单连接串行 (与 panel_server connection_loop 匹配), 多连接并发。
func (b *Bridge) connWorker(ctx context.Context, conn net.Conn, reader *bufio.Reader) {
	// ctx 取消时关闭 conn, 让 Read 返回
	go func() {
		<-ctx.Done()
		_ = conn.Close()
	}()

	for req := range b.queue {
		// 写帧 (已含 4 字节长度前缀)
		if _, err := conn.Write(req.body); err != nil {
			log.Printf("[brain] worker write failed: %v", err)
			req.ch <- rpcResponse{ID: req.id, Error: fmt.Sprintf("write: %v", err)}
			b.markConnBroken(conn)
			return
		}
		// 读响应
		resp, err := readFrame(reader)
		if err != nil {
			log.Printf("[brain] worker read failed: %v", err)
			req.ch <- rpcResponse{ID: req.id, Error: fmt.Sprintf("read: %v", err)}
			b.markConnBroken(conn)
			return
		}
		// 分发到 pending chan (由 callInternal 等待)
		req.ch <- resp
	}
}

// markConnBroken 标记连接断开 (当前简化处理: 仅记日志, 后续可加重连)。
func (b *Bridge) markConnBroken(conn net.Conn) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for i, c := range b.conns {
		if c == conn {
			b.conns = append(b.conns[:i], b.conns[i+1:]...)
			break
		}
	}
	_ = conn.Close()
	if len(b.conns) == 0 && b.started {
		log.Printf("[brain] 连接池已空, 所有连接断开")
	}
}

// readFrame 读取一帧: 4 字节大端长度 + JSON body, 解析为 rpcResponse。
func readFrame(r *bufio.Reader) (rpcResponse, error) {
	var resp rpcResponse
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return resp, err
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		return resp, err
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return resp, fmt.Errorf("unmarshal response: %w (body=%s)", err, string(body))
	}
	return resp, nil
}

// resolvePanelAddr 发现 panel_server 地址 (优先级见包注释)。
// 超时则返回 error (Agent 未启动或端口文件不可读)。
func resolvePanelAddr(ctx context.Context, timeout time.Duration) (string, error) {
	// 1. HERMES_PANEL_ADDR env (直接地址)
	if addr := os.Getenv("HERMES_PANEL_ADDR"); addr != "" {
		return addr, nil
	}

	// 2. 端口文件路径: HERMES_PANEL_ADDR_FILE env > 默认 <repo>/bin/run/panel.addr
	addrFile := os.Getenv("HERMES_PANEL_ADDR_FILE")
	if addrFile == "" {
		addrFile = defaultPanelAddrFile()
	}

	// 3. 轮询读端口文件 (Agent 可能还没启动, 等它写)
	deadline := time.Now().Add(timeout)
	for {
		if data, err := os.ReadFile(addrFile); err == nil {
			addr := string(data)
			if addr != "" {
				return addr, nil
			}
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("timeout waiting for panel addr file %s", addrFile)
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}

// defaultPanelAddrFile 返回默认端口文件路径: <repo>/bin/run/panel.addr
// 基于 Wails cwd 推算 repo 根: 开发期 Wails-v3/, 生产期 bin/wails_v3_bin/。
func defaultPanelAddrFile() string {
	wd, _ := os.Getwd()
	candidates := []string{
		filepath.Join(wd, "..", "run", "panel.addr"),       // 生产期: bin/wails_v3_bin/../run/
		filepath.Join(wd, "..", "bin", "run", "panel.addr"), // 开发期: Wails-v3/../bin/run/
	}
	for _, c := range candidates {
		if abs, err := filepath.Abs(c); err == nil {
			return abs
		}
	}
	return filepath.Join(wd, "..", "run", "panel.addr")
}
