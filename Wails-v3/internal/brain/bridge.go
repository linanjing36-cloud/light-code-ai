// Package brain 是 Wails(Go) 与 Agent-brains(Erlang/OTP) 之间的桥接层。
//
// 架构定位:
//   Hermes 面板 (Wails/Go)  ──spawn──▶  Erlang ERTS (Agent-brains)
//                                            │
//                                  TCP+JSON  │ RPC (panel_server)
//                                            ▼
//                                    agent_fsm (ReAct 编排)
//
// 通信协议:
//   - 长度前缀帧: 4 字节大端长度 + JSON body
//   - 请求: {"id": <uint64>, "method": "<name>", "args": {...}}
//   - 响应: {"id": <uint64>, "result": <any>, "error": <string|null>}
//   - 单连接多路复用: 每个 Call 用唯一 id, goroutine 等待匹配响应
//
// Wails 不直接引入 Eion-tools。所有 LLM 推理与工具执行请求,
// 都由 Erlang 侧的 Agent_FSM 编排后, 经 Bridge_Manager 发往 Eion-tools。
package brain

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"
)

// Bridge 管理 Erlang ERTS 子进程的生命周期与 TCP 通信。
// 实现 Wails v3 Service 接口: ServiceStartup / ServiceShutdown。
type Bridge struct {
	mu      sync.Mutex
	cmd     *exec.Cmd
	ctx     context.Context
	cancel  context.CancelFunc
	started bool

	// TCP 连接 (与 Erlang panel_server 通信)
	conn    net.Conn
	reader  *bufio.Reader
	writeMu sync.Mutex

	// 请求/响应多路复用
	reqSeq  atomic.Uint64
	pending sync.Map // map[uint64]chan rpcResponse

	// Erlang panel 端口 (从 stdout 读 "PANEL_PORT:<port>" 行获取)
	panelPort int
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
	return &Bridge{}
}

// ServiceStartup 实现 application.ServiceStartup (Wails v3 生命周期)。
// 在应用启动时拉起 Erlang ERTS 子进程, 等 panel_server 上线后建立 TCP 连接。
func (b *Bridge) ServiceStartup(ctx context.Context, _ application.ServiceOptions) error {
	return b.Start(ctx)
}

// ServiceShutdown 实现 application.ServiceShutdown (Wails v3 生命周期)。
// 在应用退出时优雅停止 Erlang 子进程。
func (b *Bridge) ServiceShutdown() error {
	b.Stop()
	return nil
}

// Start 拉起 Erlang ERTS 子进程, 并与 panel_server 建立 TCP 连接。
// ctx 来自 Wails 应用上下文, ctx 取消时子进程会被 kill。
func (b *Bridge) Start(parentCtx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.started {
		return nil
	}

	ctx, cancel := context.WithCancel(parentCtx)
	b.ctx, b.cancel = ctx, cancel

	// 工作目录: 与 bin/start.sh prod 模式一致, erl 在 bin/erl_bin/ 启动。
	// 这样 lager log_root="log" 落到 bin/erl_bin/log/, mnesia 落到 bin/erl_bin/data/mnesia/。
	// 优先 HERMES_DATA_DIR env, 默认 <repo>/bin/erl_bin。
	wDir := workDir()
	_ = os.MkdirAll(wDir, 0o755)

	erlLibs := agentBrainsLibDir()
	erlBin := erlBinaryPath()
	// sys.config 路径: 优先用 bin/erl_bin/config/sys.config (由 make agent 产出),
	// 若不存在 (开发期 make agent 未跑) 退化到源码 config/sys.config。
	sysConfig := findSysConfig(erlLibs)

	// hermes_brains 应用 env (与 bin/start.sh prod 模式对齐):
	//   mnesia_dir           —— 绝对路径, 避免 erl cwd 切换后相对路径歧义
	//   snapshot_interval_ms —— 60s 周期快照
	// snapshot_tables 是 list 类型, 命令行不好设, 在 -eval 里 set_env。
	//
	// 注意: -App Key Value 中 Value 必须是合法 Erlang term。
	// 字符串需用双引号包裹 (与 start.sh 的 \"\"$VAR\"\" 等价), 否则路径里的 / 会被当成语法错误。
	mnesiaDir := filepath.Join(wDir, "data", "mnesia")
	eionToolsBin := eionToolsBinPath()
	// 传给 erl 命令行 (-hermes_brains ... "路径") 的路径会被 Erlang 当 string literal 解析,
	// Windows 反斜杠是转义字符会损坏路径。统一转成 Erlang 安全形式 (见 toErlangPath)。
	mnesiaDir = toErlangPath(mnesiaDir)
	eionToolsBin = toErlangPath(eionToolsBin)
	sysConfig = toErlangPath(sysConfig)
	args := []string{
		"-noshell",
		"-sname", "hermes_brains",
		"-setcookie", "hermes_brains",
		// eion_tools_bin: bridge_manager 在 init 时 erlang:open_port({spawn, 该路径})
		// 拉起 Eion-tools 子进程。用绝对路径, 避免 erl cwd (bin/erl_bin) 解析相对路径错误。
		"-hermes_brains", "eion_tools_bin", `"` + eionToolsBin + `"`,
		"-hermes_brains", "mnesia_dir", `"` + mnesiaDir + `"`,
		"-hermes_brains", "snapshot_interval_ms", "60000",
		"-config", sysConfig,
		"-eval", "application:set_env(hermes_brains, snapshot_tables, [hermes_brains_state]), {ok, _} = application:ensure_all_started(hermes_brains), hermes_brains_app:serve().",
	}

	cmd := exec.CommandContext(ctx, erlBin, args...)
	cmd.Dir = wDir // erl cwd = bin/erl_bin, 让 lager log_root="log" 落对地方
	cmd.Env = append(os.Environ(),
		"ERL_LIBS="+erlLibs,        // 让 erl 把 bin/erl_bin 当作 OTP 应用根
		"HERMES_DATA_DIR="+wDir,    // Erlang 侧 mnesia_store 读取 (兜底)
		"MODE=prod",                 // 用 prod 默认路径 (除非外部覆盖)
	)

	// stdout 用于解析 "PANEL_PORT:<port>" 行, stderr 转发到主进程便于调试
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return fmt.Errorf("brain: 创建 stdout pipe 失败: %w", err)
	}
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		cancel()
		return fmt.Errorf("brain: 启动 Erlang 失败: %w", err)
	}
	b.cmd = cmd

	// 读 stdout 直到拿到 PANEL_PORT 行 (或超时)
	port, err := readPanelPort(stdout, 15*time.Second)
	if err != nil {
		_ = cmd.Process.Kill()
		cancel()
		return fmt.Errorf("brain: 等待 panel_server 超时: %w", err)
	}
	b.panelPort = port

	// 后台 goroutine 继续 drain stdout (避免 pipe 满)
	go drainReader(stdout)

	// 建立 TCP 连接
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 5*time.Second)
	if err != nil {
		_ = cmd.Process.Kill()
		cancel()
		return fmt.Errorf("brain: 连接 panel_server 失败 (port=%d): %w", port, err)
	}

	b.conn = conn
	b.reader = bufio.NewReaderSize(conn, 64*1024)

	// 启动响应读取 goroutine
	go b.readLoop()

	b.started = true
	log.Printf("[brain] Erlang panel connected on 127.0.0.1:%d", port)
	return nil
}

// Stop 优雅停止 Erlang 子进程。
// 优先用 rpc stop (走 TCP, 触发 Erlang init:stop), 失败 fallback 到 ctx cancel + Kill。
func (b *Bridge) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.started {
		return
	}

	// 优雅: 发 stop 方法 (Erlang 侧收到后调 init:stop())
	if b.conn != nil {
		stopCtx, stopCancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, _ = b.callRawLocked(stopCtx, "stop", nil)
		stopCancel()
		_ = b.conn.Close()
		b.conn = nil
	}

	if b.cancel != nil {
		b.cancel()
	}
	if b.cmd != nil && b.cmd.Process != nil {
		// 给 Erlang 5s 自行退出, 否则 SIGKILL
		done := make(chan struct{})
		go func() {
			_ = b.cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			_ = b.cmd.Process.Kill()
		}
	}
	b.started = false
}

// Call 发起一次同步 RPC 到 Erlang 大脑, 返回 result。
func (b *Bridge) Call(method string, args map[string]any) (any, error) {
	b.mu.Lock()
	started, conn := b.started, b.conn
	b.mu.Unlock()
	if !started || conn == nil {
		return nil, fmt.Errorf("brain: not started")
	}
	return b.callRaw(context.Background(), method, args)
}

// callRaw 内部: 单连接多路复用。
//   - 分配唯一 req id
//   - 注册 pending chan
//   - 写帧 (length-prefixed JSON)
//   - 阻塞等响应 chan (30s 超时)
//   - 响应 goroutine 在 readLoop 里 dispatch
func (b *Bridge) callRaw(ctx context.Context, method string, args map[string]any) (any, error) {
	return b.callRawLocked(ctx, method, args)
}

// callRawLocked 与 callRaw 相同, 但允许在持锁状态下调用 (用于 Stop 时发 stop 帧)。
func (b *Bridge) callRawLocked(ctx context.Context, method string, args map[string]any) (any, error) {
	if b.conn == nil {
		return nil, fmt.Errorf("brain: connection closed")
	}

	id := b.reqSeq.Add(1)
	req := rpcRequest{ID: id, Method: method, Args: args}

	ch := make(chan rpcResponse, 1)
	b.pending.Store(id, ch)
	defer b.pending.Delete(id)

	// 写入帧: 4 字节大端长度 + JSON body
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("brain: marshal request: %w", err)
	}
	frame := make([]byte, 4+len(body))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(body)))
	copy(frame[4:], body)

	b.writeMu.Lock()
	_, err = b.conn.Write(frame)
	b.writeMu.Unlock()
	if err != nil {
		return nil, fmt.Errorf("brain: write request: %w", err)
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

// readLoop 持续读 TCP 帧, 按 id 分发到 pending chan。
func (b *Bridge) readLoop() {
	for {
		var lenBuf [4]byte
		if _, err := io.ReadFull(b.reader, lenBuf[:]); err != nil {
			log.Printf("[brain] read len failed: %v", err)
			return
		}
		n := binary.BigEndian.Uint32(lenBuf[:])
		body := make([]byte, n)
		if _, err := io.ReadFull(b.reader, body); err != nil {
			log.Printf("[brain] read body failed: %v", err)
			return
		}
		var resp rpcResponse
		if err := json.Unmarshal(body, &resp); err != nil {
			log.Printf("[brain] unmarshal response failed: %v (body=%s)", err, string(body))
			continue
		}
		if chVal, ok := b.pending.LoadAndDelete(resp.ID); ok {
			ch := chVal.(chan rpcResponse)
			select {
			case ch <- resp:
			default:
				log.Printf("[brain] response chan full for id=%d, dropping", resp.ID)
			}
		}
	}
}

// readPanelPort 从 erl stdout 解析 "PANEL_PORT:<port>" 行。
// 超时则返回 error (Erlang 启动失败或 panel_server 未就绪)。
func readPanelPort(r io.Reader, timeout time.Duration) (int, error) {
	deadline := time.Now().Add(timeout)
	type result struct {
		port int
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		sc := bufio.NewScanner(r)
		for {
			if !sc.Scan() {
				if err := sc.Err(); err != nil {
					ch <- result{0, fmt.Errorf("read stdout: %w", err)}
					return
				}
				ch <- result{0, errors.New("erl stdout closed before panel_port line")}
				return
			}
			line := sc.Text()
			// 转发到主进程 stdout (调试可见)
			fmt.Println("[erl]", line)
			var port int
			if _, err := fmt.Sscanf(line, "PANEL_PORT:%d", &port); err == nil {
				ch <- result{port, nil}
				return
			}
		}
	}()
	select {
	case r := <-ch:
		return r.port, r.err
	case <-time.After(time.Until(deadline)):
		return 0, errors.New("timeout waiting for PANEL_PORT line")
	}
}

// drainReader 持续读 stdout 转发到主进程 stdout, 避免 pipe 满。
func drainReader(r io.Reader) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		fmt.Println("[erl]", sc.Text())
	}
}

// workDir 返回 Erlang 子进程的工作目录 (erl 的 cwd)。
// 与 bin/start.sh prod 模式一致: 工作目录在 bin/erl_bin/,
// 这样 lager 的 log_root="log" 落到 bin/erl_bin/log/,
// mnesia_dir 默认 "data/mnesia" 落到 bin/erl_bin/data/mnesia/。
// 优先 HERMES_DATA_DIR env, 默认 <repo>/bin/erl_bin。
func workDir() string {
	if v := os.Getenv("HERMES_DATA_DIR"); v != "" {
		return v
	}
	// 与 agentBrainsLibDir 同目录: <repo>/bin/erl_bin
	wd, _ := os.Getwd()
	return filepath.Join(wd, "..", "bin", "erl_bin")
}

// agentBrainsLibDir 返回 Agent-brains 的 OTP lib 根目录。
//   - 开发期: <repo>/bin/erl_bin  (含 hermes_brains/, lager/ 等子目录, 由 make agent 编译产出)
//   - 生产期: Wails app bundle 内的 Resources/erl_libs (TODO)
// 由 ERL_LIBS env 注入到 erl 子进程, 让 erl 自动发现 hermes_brains 应用。
func agentBrainsLibDir() string {
	if v := os.Getenv("HERMES_ERL_LIBS"); v != "" {
		return v
	}
	// 假设 Wails-v3 与 Agent-brains 同级目录, 编译产物在 bin/erl_bin
	wd, _ := os.Getwd()
	return filepath.Join(wd, "..", "bin", "erl_bin")
}

// erlBinaryPath 返回 erl 可执行路径。
// 开发期: 直接 PATH 中的 erl; 生产期: bundle 内嵌 ERTS (TODO)
func erlBinaryPath() string {
	if v := os.Getenv("HERMES_ERL_BIN"); v != "" {
		return v
	}
	return "erl"
}

// eionToolsBinPath 返回 Eion-tools server 可执行文件的绝对路径。
//   - 开发期: <repo>/bin/eion_bin/eion-tools-server.exe (由 make agent 的 go build 产出)
//   - 生产期: Wails app bundle 内的 Resources/eion_bin (TODO)
//
// 由 -hermes_brains eion_tools_bin 注入到 app env, bridge_manager 在 init 时
// erlang:open_port({spawn, 该路径}) 拉起 Eion-tools 子进程 (protobuf 帧通信)。
// 用绝对路径, 避免 erl cwd (bin/erl_bin) 导致相对路径解析错误。
func eionToolsBinPath() string {
	if v := os.Getenv("HERMES_EION_TOOLS_BIN"); v != "" {
		return v
	}
	// 假设 Wails-v3 与 bin/eion_bin 同级, 编译产物在 bin/eion_bin
	wd, _ := os.Getwd()
	p := filepath.Join(wd, "..", "bin", "eion_bin", "eion-tools-server.exe")
	if abs, err := filepath.Abs(p); err == nil {
		return abs
	}
	return p
}

// findSysConfig 找 sys.config 文件路径:
//   1. erlLibs/config/sys.config (优先: bin/erl_bin/config/sys.config, 由 make agent 产出)
//   2. erlLibs/../Agent-brains/config/sys.config (退化: 源码目录)
// 找不到返回空字符串, erl -config 会失败, 让用户看到明确错误。
func findSysConfig(erlLibs string) string {
	candidates := []string{
		filepath.Join(erlLibs, "config", "sys.config"),
		filepath.Join(erlLibs, "..", "Agent-brains", "config", "sys.config"),
	}
	for _, c := range candidates {
		if abs, err := filepath.Abs(c); err == nil {
			if _, err := os.Stat(abs); err == nil {
				return abs
			}
		}
	}
	return filepath.Join(erlLibs, "config", "sys.config")
}
