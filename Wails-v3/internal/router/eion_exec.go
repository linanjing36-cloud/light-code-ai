package router

import (
	"context"
	"fmt"

	"google.golang.org/protobuf/proto"

	eionserver "github.com/light-code-ai/eion-tools/pkg/server"
	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

// ExecEmit 向 Erlang 回写单帧 PanelExecResult (terminal=false 表示流式中间帧)。
type ExecEmit func(agentResp []byte, errMsg string, terminal bool) error

// EionExecutor 绑定进程内 Eion-tools server，经 panel exec 帧执行 LLM/工具。
type EionExecutor struct {
	srv *eionserver.Server
}

func NewEionExecutor(srv *eionserver.Server) *EionExecutor {
	return &EionExecutor{srv: srv}
}

func (e *EionExecutor) Ready() bool {
	return e != nil && e.srv != nil && e.srv.Dispatcher() != nil
}

func (e *EionExecutor) ListenAddr() string {
	if e == nil || e.srv == nil {
		return ""
	}
	return e.srv.ListenAddr()
}

// RunAgent 进程内调用 dispatcher.DispatchStream，经 emit 逐帧回传 AgentResponse。
func (e *EionExecutor) RunAgent(ctx context.Context, reqBin []byte, emit ExecEmit) error {
	if !e.Ready() {
		return emit(nil, "eion executor not ready", true)
	}
	agentReq := &hermes.AgentRequest{}
	if err := proto.Unmarshal(reqBin, agentReq); err != nil {
		return emit(nil, fmt.Sprintf("decode request: %v", err), true)
	}
	d := e.srv.Dispatcher()
	return d.DispatchStream(ctx, agentReq, func(resp *hermes.AgentResponse) error {
		if resp == nil {
			return emit(nil, "nil agent response", true)
		}
		respBin, err := proto.Marshal(resp)
		if err != nil {
			return err
		}
		return emit(respBin, "", isTerminalAgentResp(resp))
	})
}

func isTerminalAgentResp(resp *hermes.AgentResponse) bool {
	_, isChunk := resp.GetPayload().(*hermes.AgentResponse_LlmChunk)
	return !isChunk
}
