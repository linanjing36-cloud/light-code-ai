// Command server 是 Eion-tools 的入口。
//
// 它初始化 dispatcher、注册示例工具，并启动一个 stdin/stdout 二进制帧循环，
// 作为 Erlang 端口通信的占位实现：
//
//	读取 4 字节大端长度前缀 + protobuf 负载 → dispatch → 写回同样格式的响应。
//
// 设计原则：Go 侧无状态、无内部循环；每帧对应一次原子请求 → 一次响应。
// TODO: 后续将替换为真实的 Erlang port driver / 异步 IPC。
package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"os"

	"google.golang.org/protobuf/proto"

	"github.com/light-code-ai/eion-tools/internal/dispatcher"
	"github.com/light-code-ai/eion-tools/internal/tool"
	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

func main() {
	// 1. 初始化 dispatcher，注册示例工具 get_weather
	d := dispatcher.New()
	name, desc, params, handler := tool.GetWeatherHandler()
	d.ToolWrapper().Register(name, desc, params, handler)

	// 2. 启动 stdin/stdout 二进制帧循环（Erlang 端口通信占位实现）
	log.Println("eion-tools server: stdin/stdout framing loop started")
	if err := runFramingLoop(os.Stdin, os.Stdout, d); err != nil {
		log.Fatalf("framing loop exited: %v", err)
	}
}

// runFramingLoop 读取 4 字节大端长度前缀 + protobuf 负载，dispatch 后回写同样格式的响应。
// 这是与 Erlang 端口通信的最简占位实现；后续将替换为真实的 Erlang port driver。
func runFramingLoop(r io.Reader, w io.Writer, d *dispatcher.Command_Dispatcher) error {
	for {
		req, err := readFrame(r)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("read frame: %w", err)
		}

		agentReq := &hermes.AgentRequest{}
		if err := proto.Unmarshal(req, agentReq); err != nil {
			// 解码失败：构造一个错误响应回写，避免 Erlang 端阻塞等待
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

		// dispatcher 内部已有 Panic_Guard，理论上不会 panic 出来
		resp := d.Dispatch(context.Background(), agentReq)
		if resp == nil {
			resp = &hermes.AgentResponse{
				Payload: &hermes.AgentResponse_ToolExec{
					ToolExec: &hermes.ToolExecResponse{Error: "nil response from dispatcher"},
				},
			}
		}

		if err := writeFrame(w, resp); err != nil {
			return fmt.Errorf("write frame: %w", err)
		}
	}
}

// readFrame 读取 4 字节大端长度前缀，再读取对应长度的负载。
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
	// 对 os.Stdout 等可 Sync 的目标进行 flush，确保 Erlang 端能及时读到一帧完整数据
	if f, ok := w.(interface{ Sync() error }); ok {
		_ = f.Sync()
	}
	return nil
}
