// Package model 提供 Eino model.ChatModel 的薄包装。
//
// 设计原则（无状态执行 SDK 的核心）：
//   - 每次请求都是独立的，不缓存对话历史、不重试、不内部循环。
//   - 所有 provider 配置（model / api_base / api_key）均由请求携带，由 Erlang 侧编排。
//   - 仅使用 Eino 的 model.ChatModel 接口；
//     严禁使用 agent.NewAgent / Chain / Graph —— 那会把编排控制权泄漏到 Go 侧。
package model

import (
	"context"
	"fmt"

	// TODO: 引入 eino 依赖后启用下列 import（go.mod 暂未添加 eino）。
	// "github.com/cloudwego/eino/components/model"
	// "github.com/cloudwego/eino/schema"

	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

// Eino_Model_Wrapper 是 Eino ChatModel 的薄适配器。
// 不持有任何会话/对话状态；每次 Infer 调用都从请求重建上下文。
type Eino_Model_Wrapper struct {
	// TODO: 如需按 model+api_base 复用底层 http client，可在此持有客户端池；
	//       但对话/历史状态严禁存放于此。
}

// New 创建包装器。
func New() *Eino_Model_Wrapper {
	return &Eino_Model_Wrapper{}
}

// Infer 执行一次 LLM 推理：
//  1. Protobuf Message → Eino []*schema.Message
//  2. 按 model/api_base/api_key 构造 ChatModel 实例
//  3. 调用 ChatModel.Generate(ctx, ...)
//  4. 翻译响应回 Protobuf LLMInferResponse
//
// 不重试、不循环 —— 编排交给 Erlang。
func (w *Eino_Model_Wrapper) Infer(ctx context.Context, req *hermes.LLMInferRequest) (*hermes.LLMInferResponse, error) {
	// 1. 翻译消息
	einoMsgs, err := w.toEinoMessages(req.GetMessages())
	if err != nil {
		return nil, fmt.Errorf("translate messages: %w", err)
	}

	// 2. 翻译工具描述（可选）
	// TODO: einoTools, err := w.toEinoTools(req.GetTools())
	_ = req.GetTools()

	// 3. 构造 ChatModel（按请求中的 model / api_base / api_key）
	// TODO: cm, err := buildChatModel(req.GetModel(), req.GetApiBase(), req.GetApiKey())
	//       说明：仅使用 model.ChatModel 接口；禁止使用 agent.NewAgent / Chain / Graph。
	_ = req.GetModel()
	_ = req.GetApiBase()
	_ = req.GetApiKey()

	// 4. 调用 cm.Generate(ctx, einoMsgs, opts...)
	// TODO: out, err := cm.Generate(ctx, einoMsgs, model.WithTools(einoTools))
	_ = ctx
	_ = einoMsgs

	// 5. 翻译响应
	// TODO: return w.fromEinoMessage(out)
	return &hermes.LLMInferResponse{}, nil
}

// toEinoMessages 将 Protobuf Message 列表翻译为 Eino schema.Message 列表。
// TODO: 实现完整翻译（role / content / tool_calls / tool_call_id）。
func (w *Eino_Model_Wrapper) toEinoMessages(msgs []*hermes.Message) ([]any, error) {
	out := make([]any, 0, len(msgs))
	for _, m := range msgs {
		_ = m
		// TODO: 翻译为 schema.Message{
		//   Role:      m.GetRole(),
		//   Content:   m.GetContent(),
		//   ToolCalls:  w.toEinoToolCalls(m.GetToolCalls()),
		//   ToolCallID: m.GetToolCallId(),
		// }
		out = append(out, nil)
	}
	return out, nil
}

// fromEinoMessage 将 Eino 单条响应翻译回 LLMInferResponse。
// TODO: 实现完整翻译（content / tool_calls / token usage）。
func (w *Eino_Model_Wrapper) fromEinoMessage(out any) (*hermes.LLMInferResponse, error) {
	_ = out
	// TODO: &hermes.LLMInferResponse{
	//   Content:          out.Content,
	//   ToolCalls:        w.fromEinoToolCalls(out.ToolCalls),
	//   PromptTokens:     out.Usage.PromptTokens,
	//   CompletionTokens: out.Usage.CompletionTokens,
	// }
	return &hermes.LLMInferResponse{}, nil
}
