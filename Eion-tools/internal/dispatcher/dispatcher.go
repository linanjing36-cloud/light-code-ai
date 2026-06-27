// Package dispatcher 负责将 Erlang 解码后的 Protobuf 请求路由到 model 或 tool 包装器。
//
// 设计原则（无状态执行 SDK）：
//   - 不持有任何会话/对话状态。
//   - 不做内部循环、不重试 —— 这些编排交给 Erlang。
//   - "问什么答什么"：一次 Dispatch 调用对应一次原子请求 → 一次响应。
//   - 唯一例外：工具执行的 ReqId 幂等缓存，避免 Erlang 重试导致副作用重复。
package dispatcher

import (
	"context"
	"fmt"
	"sync"

	"go.uber.org/zap"

	"github.com/light-code-ai/eion-tools/internal/logging"
	"github.com/light-code-ai/eion-tools/internal/model"
	"github.com/light-code-ai/eion-tools/internal/tool"
	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

// Command_Dispatcher 接收解码后的 Protobuf 请求并路由到对应包装器。
// 任何 panic 都会被 Panic_Guard 捕获并转换为错误响应，避免 Go 侧崩溃导致 Erlang 端口异常。
type Command_Dispatcher struct {
	modelW *model.Eino_Model_Wrapper
	toolW  *tool.Eino_Tool_Wrapper

	// 幂等缓存：ReqId -> *hermes.ToolExecResponse。命中即直接返回，避免重复执行副作用工具。
	idempotency sync.Map
}

// New 创建一个 Dispatcher，内部装配 model 与 tool 包装器。
func New() *Command_Dispatcher {
	return &Command_Dispatcher{
		modelW: model.New(),
		toolW:  tool.New(),
	}
}

// ToolWrapper 返回内部工具注册表，供外部注册工具。
func (d *Command_Dispatcher) ToolWrapper() *tool.Eino_Tool_Wrapper {
	return d.toolW
}

// Dispatch 是唯一的入口：接收 AgentRequest，返回 AgentResponse。
//
// Panic_Guard：defer/recover 将 panic 转为对应分支的错误响应，
// 保证 Erlang 端口永远不会因为 Go 侧 panic 而卡死。
func (d *Command_Dispatcher) Dispatch(ctx context.Context, req *hermes.AgentRequest) (resp *hermes.AgentResponse) {
	defer func() {
		if r := recover(); r != nil {
			logging.Logger.Error("dispatcher panic recovered", zap.Any("panic", r))
			if resp == nil {
				resp = &hermes.AgentResponse{}
			}
			switch req.GetPayload().(type) {
			case *hermes.AgentRequest_LlmInfer:
				resp.Payload = &hermes.AgentResponse_LlmInfer{
					LlmInfer: &hermes.LLMInferResponse{},
				}
			case *hermes.AgentRequest_ToolList:
				resp.Payload = &hermes.AgentResponse_ToolList{
					ToolList: &hermes.ToolListResponse{Error: fmt.Sprintf("panic: %v", r)},
				}
			default:
				resp.Payload = &hermes.AgentResponse_ToolExec{
					ToolExec: &hermes.ToolExecResponse{
						Error: fmt.Sprintf("panic: %v", r),
					},
				}
			}
		}
	}()

	switch p := req.GetPayload().(type) {
	case *hermes.AgentRequest_LlmInfer:
		out := d.handleLLM(ctx, p.LlmInfer)
		return &hermes.AgentResponse{
			Payload: &hermes.AgentResponse_LlmInfer{LlmInfer: out},
		}

	case *hermes.AgentRequest_ToolExec:
		out := d.handleTool(ctx, p.ToolExec)
		return &hermes.AgentResponse{
			Payload: &hermes.AgentResponse_ToolExec{ToolExec: out},
		}

	case *hermes.AgentRequest_ToolList:
		out := d.handleToolList(p.ToolList)
		return &hermes.AgentResponse{
			Payload: &hermes.AgentResponse_ToolList{ToolList: out},
		}

	default:
		return &hermes.AgentResponse{
			Payload: &hermes.AgentResponse_ToolExec{
				ToolExec: &hermes.ToolExecResponse{
					Error: "unknown request payload",
				},
			},
		}
	}
}

// DispatchStream 是支持流式的分发入口：
//   - llm_infer 且 stream=true：先发若干 AgentResponse{llm_chunk: ...} 增量，最后发 AgentResponse{llm_infer: ...} 终态
//   - 其他（stream=false 或 tool_exec）：等价于 Dispatch，writeFrame 一次
//
// writeFrame 由调用方传入（负责长度前缀编码 + 写连接）；返回 error 表示写失败，
// DispatchStream 会中断并向上返回，调用方据此关闭连接。
//
// Panic_Guard：defer/recover 将 panic 转为错误响应并 writeFrame，保证 Erlang 端口不卡死。
func (d *Command_Dispatcher) DispatchStream(ctx context.Context, req *hermes.AgentRequest, writeFrame func(*hermes.AgentResponse) error) (err error) {
	defer func() {
		if r := recover(); r != nil {
			logging.Logger.Error("dispatcher stream panic recovered", zap.Any("panic", r))
			errResp := &hermes.AgentResponse{}
			switch req.GetPayload().(type) {
			case *hermes.AgentRequest_LlmInfer:
				// 流式分支即使 panic 也必须以 llm_infer 终态收尾，否则 Erlang 端会一直等流结束
				errResp.Payload = &hermes.AgentResponse_LlmInfer{LlmInfer: &hermes.LLMInferResponse{}}
			default:
				errResp.Payload = &hermes.AgentResponse_ToolExec{
					ToolExec: &hermes.ToolExecResponse{Error: fmt.Sprintf("panic: %v", r)},
				}
			}
			_ = writeFrame(errResp)
		}
	}()

	// 仅 llm_infer + stream=true 走流式分支
	if p, ok := req.GetPayload().(*hermes.AgentRequest_LlmInfer); ok && p.LlmInfer.GetStream() {
		return d.handleLLMStream(ctx, p.LlmInfer, writeFrame)
	}

	// 其他情况：复用 Dispatch 单次响应（Dispatch 内部已有 Panic_Guard）
	resp := d.Dispatch(ctx, req)
	if resp == nil {
		resp = &hermes.AgentResponse{
			Payload: &hermes.AgentResponse_ToolExec{
				ToolExec: &hermes.ToolExecResponse{Error: "nil response from dispatcher"},
			},
		}
	}
	return writeFrame(resp)
}

// handleLLMStream 路由到 model.Stream：增量 chunk 走 llm_chunk 分支，终态走 llm_infer 分支。
// 出错时下发一个空 LLMInferResponse 作为终态，标志流结束（避免 Erlang 端无限等待）。
func (d *Command_Dispatcher) handleLLMStream(ctx context.Context, req *hermes.LLMInferRequest, writeFrame func(*hermes.AgentResponse) error) error {
	// onChunk：把增量内容包成 llm_chunk 帧下发（非终态）
	onChunk := func(chunk *hermes.LlmChunk) error {
		return writeFrame(&hermes.AgentResponse{
			Payload: &hermes.AgentResponse_LlmChunk{LlmChunk: chunk},
		})
	}

	out, err := d.modelW.Stream(ctx, req, onChunk)
	if err != nil {
		logging.Logger.Error("llm stream error", zap.Error(err))
		out = &hermes.LLMInferResponse{}
	}

	// 终态：包成 llm_infer 帧下发，标志流结束
	return writeFrame(&hermes.AgentResponse{
		Payload: &hermes.AgentResponse_LlmInfer{LlmInfer: out},
	})
}

// handleLLM 路由到 model 包装器。无缓存、无重试、无循环。
func (d *Command_Dispatcher) handleLLM(ctx context.Context, req *hermes.LLMInferRequest) *hermes.LLMInferResponse {
	out, err := d.modelW.Infer(ctx, req)
	if err != nil {
		logging.Logger.Error("llm infer error", zap.Error(err))
		return &hermes.LLMInferResponse{}
	}
	return out
}

// handleTool 执行工具，并按 ReqId 做幂等缓存。
func (d *Command_Dispatcher) handleTool(ctx context.Context, req *hermes.ToolExecRequest) *hermes.ToolExecResponse {
	// 1. 幂等检查：命中即直接返回上次的响应
	if reqId := req.GetReqId(); reqId != "" {
		if cached, ok := d.idempotency.Load(reqId); ok {
			if cachedResp, ok := cached.(*hermes.ToolExecResponse); ok {
				return cachedResp
			}
		}
	}

	// 2. 查找工具
	t, ok := d.toolW.Get(req.GetToolName())
	if !ok {
		resp := &hermes.ToolExecResponse{
			Error: fmt.Sprintf("tool not found: %s", req.GetToolName()),
		}
		d.cacheIdempotent(req.GetReqId(), resp)
		return resp
	}

	// 3. 执行工具（InvokableRun）
	result, err := t.InvokableRun(ctx, req.GetArgumentsJson())
	if err != nil {
		resp := &hermes.ToolExecResponse{
			Error: err.Error(),
		}
		d.cacheIdempotent(req.GetReqId(), resp)
		return resp
	}

	resp := &hermes.ToolExecResponse{
		ResultJson: result,
	}
	d.cacheIdempotent(req.GetReqId(), resp)
	return resp
}

func (d *Command_Dispatcher) handleToolList(_ *hermes.ToolListRequest) *hermes.ToolListResponse {
	descs := d.toolW.ListDescs()
	tools := make([]*hermes.ToolDesc, 0, len(descs))
	for _, desc := range descs {
		tools = append(tools, &hermes.ToolDesc{
			Name:           desc.Name,
			Description:    desc.Description,
			ParametersJson: desc.ParametersJSON,
		})
	}
	return &hermes.ToolListResponse{Tools: tools}
}

// cacheIdempotent 将工具执行结果存入幂等缓存（ReqId 为空则跳过）。
func (d *Command_Dispatcher) cacheIdempotent(reqId string, resp *hermes.ToolExecResponse) {
	if reqId == "" {
		return
	}
	d.idempotency.Store(reqId, resp)
}
