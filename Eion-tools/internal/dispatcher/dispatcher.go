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
	"log"
	"sync"

	// TODO: 引入 eino 依赖后启用下列 import（go.mod 暂未添加 eino）。
	// "github.com/cloudwego/eino/components/tool"

	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

// Command_Dispatcher 接收解码后的 Protobuf 请求并路由到对应包装器。
// 任何 panic 都会被 Panic_Guard 捕获并转换为错误响应，避免 Go 侧崩溃导致 Erlang 端口异常。
type Command_Dispatcher struct {
	mu sync.RWMutex

	// 工具注册表：name -> tools.Tool
	// TODO: 引入 eino 后将 any 替换为 tool.Tool。
	tools map[string]any

	// 幂等缓存：ReqId -> *hermes.ToolExecResponse。命中即直接返回，避免重复执行副作用工具。
	idempotency sync.Map
}

// New 创建一个 Dispatcher。
func New() *Command_Dispatcher {
	return &Command_Dispatcher{
		tools: make(map[string]any),
	}
}

// RegisterTool 注册一个工具实现。
// TODO: 引入 eino 依赖后，将参数类型由 any 改为 tool.Tool。
func (d *Command_Dispatcher) RegisterTool(name string, t any) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.tools[name] = t
}

// Dispatch 是唯一的入口：接收 AgentRequest，返回 AgentResponse。
//
// Panic_Guard：defer/recover 将 panic 转为对应分支的错误响应，
// 保证 Erlang 端口永远不会因为 Go 侧 panic 而卡死。
func (d *Command_Dispatcher) Dispatch(ctx context.Context, req *hermes.AgentRequest) (resp *hermes.AgentResponse) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("dispatcher panic recovered: %v", r)
			if resp == nil {
				resp = &hermes.AgentResponse{}
			}
			// 根据请求分支填充错误（兜底到 tool_exec 分支）
			switch req.GetPayload().(type) {
			case *hermes.AgentRequest_LlmInfer:
				resp.Payload = &hermes.AgentResponse_LlmInfer{
					LlmInfer: &hermes.LLMInferResponse{},
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

// handleLLM 路由到 model 包装器。无缓存、无重试、无循环。
func (d *Command_Dispatcher) handleLLM(ctx context.Context, req *hermes.LLMInferRequest) *hermes.LLMInferResponse {
	// TODO: 调用 internal/model.Eino_Model_Wrapper.Infer(ctx, req)
	_ = ctx
	_ = req
	return &hermes.LLMInferResponse{}
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
	d.mu.RLock()
	t, ok := d.tools[req.GetToolName()]
	d.mu.RUnlock()
	if !ok {
		resp := &hermes.ToolExecResponse{
			Error: fmt.Sprintf("tool not found: %s", req.GetToolName()),
		}
		d.cacheIdempotent(req.GetReqId(), resp)
		return resp
	}

	// 3. TODO: 调用 internal/tool.Eino_Tool_Wrapper 执行 t。
	//    引入 eino 后此处改为：result, err := t.InvokableRun(ctx, req.GetArgumentsJson())
	_ = ctx
	_ = t
	resp := &hermes.ToolExecResponse{
		ResultJson: "", // 占位
	}
	d.cacheIdempotent(req.GetReqId(), resp)
	return resp
}

// cacheIdempotent 将工具执行结果存入幂等缓存（ReqId 为空则跳过）。
func (d *Command_Dispatcher) cacheIdempotent(reqId string, resp *hermes.ToolExecResponse) {
	if reqId == "" {
		return
	}
	d.idempotency.Store(reqId, resp)
}
