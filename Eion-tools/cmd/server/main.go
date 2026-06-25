// Command server 是 Eion-tools 的入口。
//
// 它初始化 dispatcher、注册示例工具, 并启动一个 TCP(Windows)/UDS(Unix) 服务,
// 接受连接, 每个连接独立 goroutine 跑二进制帧循环:
//
//	读取 4 字节大端长度前缀 + protobuf 负载 → dispatch → 写回同样格式的响应。
//
// 设计原则: Go 侧无状态、无内部循环; 每帧对应一次原子请求 → 一次响应。
// 多连接并发: Agent(Erlang) 侧用连接池, 多个请求可并行走不同连接。
//
// 地址发现: listen 后把实际地址写入端口文件 (默认 bin/run/eion-tools.addr,
// 由 EION_TOOLS_ADDR_FILE 覆盖), 供客户端读取连接。
package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"runtime"

	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"

	"github.com/light-code-ai/eion-tools/internal/dispatcher"
	"github.com/light-code-ai/eion-tools/internal/logging"
	"github.com/light-code-ai/eion-tools/internal/tool"
	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

func main() {
	logging.Init()
	defer func() { _ = logging.Logger.Sync() }()

	// 1. 初始化 dispatcher, 注册示例工具 get_weather
	d := dispatcher.New()
	name, desc, params, handler := tool.GetWeatherHandler()
	d.ToolWrapper().Register(name, desc, params, handler)

	// 2. 解析监听地址 (环境变量 EION_TOOLS_ADDR 覆盖默认值)
	addr := os.Getenv("EION_TOOLS_ADDR")
	if addr == "" {
		addr = defaultAddr()
	}

	// 3. Unix UDS: listen 前清理旧 socket 文件 (否则 "address already in use")
	if network() == "unix" {
		_ = os.Remove(addr)
	}

	// 4. listen
	ln, err := net.Listen(network(), addr)
	if err != nil {
		logging.Logger.Fatal("listen failed", zap.String("net", network()), zap.String("addr", addr), zap.Error(err))
	}
	defer ln.Close()

	// 5. 取实际地址 (port 0 -> ephemeral) 写入端口文件, 供客户端发现
	actualAddr := ln.Addr().String()
	if err := writeAddrFile(actualAddr); err != nil {
		logging.Logger.Warn("write addr file failed", zap.Error(err))
	}

	logging.Logger.Info("eion-tools server listening",
		zap.String("net", network()),
		zap.String("addr", actualAddr),
		zap.String("runtime", runtime.GOOS),
	)

	// 6. accept 循环 (每连接一个 goroutine, 支持连接池并发)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				select {
				case <-ctx.Done():
					return
				default:
					logging.Logger.Error("accept failed", zap.Error(err))
					return
				}
			}
			logging.Logger.Info("connection accepted", zap.String("remote", conn.RemoteAddr().String()))
			go handleConn(ctx, conn, d)
		}
	}()

	// 7. 等待信号优雅关闭
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt)
	if sig := sigForTerm(); sig != nil {
		signal.Notify(sigCh, sig)
	}
	sig := <-sigCh
	logging.Logger.Info("shutting down on signal", zap.String("signal", sig.String()))
	cancel()
	ln.Close()
}

// handleConn 处理单个连接: 跑帧循环直到连接关闭。
func handleConn(ctx context.Context, conn net.Conn, d *dispatcher.Command_Dispatcher) {
	defer conn.Close()
	// 用 done chan 让 ctx 取消时关闭 conn
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-done:
		}
	}()
	if err := runFramingLoop(conn, conn, d); err != nil {
		logging.Logger.Info("connection framing loop ended", zap.Error(err))
	}
}

// writeAddrFile 把实际监听地址写入端口文件, 供客户端发现。
// 文件路径: EION_TOOLS_ADDR_FILE 环境变量, 默认 "eion-tools.addr" (相对 cwd)。
func writeAddrFile(addr string) error {
	path := os.Getenv("EION_TOOLS_ADDR_FILE")
	if path == "" {
		path = "eion-tools.addr"
	}
	return os.WriteFile(path, []byte(addr), 0644)
}

// runFramingLoop 读取 4 字节大端长度前缀 + protobuf 负载, dispatch 后回写同样格式的响应。
// r/w 通常是同一个 net.Conn (服务端) 或 os.Stdin/Stdout (兼容旧 stdin 模式)。
func runFramingLoop(r io.Reader, w io.Writer, d *dispatcher.Command_Dispatcher) error {
	for {
		req, err := readFrame(r)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("read frame: %w", err)
		}
		logging.Logger.Info("received frame", zap.Int("bytes", len(req)))

		agentReq := &hermes.AgentRequest{}
		if err := proto.Unmarshal(req, agentReq); err != nil {
			logging.Logger.Error("unmarshal failed", zap.Error(err))
			// 解码失败: 构造一个错误响应回写, 避免客户端阻塞等待
			errResp := &hermes.AgentResponse{
				Payload: &hermes.AgentResponse_ToolExec{
					ToolExec: &hermes.ToolExecResponse{
						Error: fmt.Sprintf("decode request: %v", err),
					},
				},
			}
			if err := writeFrame(w, errResp); err != nil {
				return fmt.Errorf("write error frame: %w", err)
			}
			continue
		}

		// 调试: 打印请求概要
		switch p := agentReq.GetPayload().(type) {
		case *hermes.AgentRequest_LlmInfer:
			logging.Logger.Debug("dispatch: llm_infer",
				zap.String("model", p.LlmInfer.GetModel()),
				zap.Int("msgs", len(p.LlmInfer.GetMessages())),
				zap.Int("tools", len(p.LlmInfer.GetTools())),
			)
		case *hermes.AgentRequest_ToolExec:
			logging.Logger.Debug("dispatch: tool_exec",
				zap.String("name", p.ToolExec.GetToolName()),
				zap.String("req_id", p.ToolExec.GetReqId()),
			)
		}

		// dispatcher 内部已有 Panic_Guard, 理论上不会 panic 出来
		resp := d.Dispatch(context.Background(), agentReq)
		if resp == nil {
			resp = &hermes.AgentResponse{
				Payload: &hermes.AgentResponse_ToolExec{
					ToolExec: &hermes.ToolExecResponse{Error: "nil response from dispatcher"},
				},
			}
		}

		logging.Logger.Info("sending response frame", zap.Int("bytes", proto.Size(resp)))
		if err := writeFrame(w, resp); err != nil {
			return fmt.Errorf("write frame: %w", err)
		}
	}
}

// readFrame 读取 4 字节大端长度前缀, 再读取对应长度的负载。
func readFrame(r io.Reader) ([]byte, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	if n == 0 {
		return []byte{}, nil
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

// writeFrame 写入 4 字节大端长度前缀 + protobuf 负载。
func writeFrame(w io.Writer, msg proto.Message) error {
	buf, err := proto.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal response: %w", err)
	}
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(buf)))
	if _, err := w.Write(lenBuf[:]); err != nil {
		return err
	}
	if _, err := w.Write(buf); err != nil {
		return err
	}
	// 对可 Sync 的目标进行 flush (net.Conn 无 Sync, os.Stdout 有)
	if f, ok := w.(interface{ Sync() error }); ok {
		_ = f.Sync()
	}
	return nil
}
