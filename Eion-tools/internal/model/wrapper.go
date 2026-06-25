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
	"encoding/json"
	"fmt"

	"github.com/eino-contrib/jsonschema"
	"github.com/cloudwego/eino-ext/components/model/deepseek"
	"github.com/cloudwego/eino/schema"

	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

// Eino_Model_Wrapper 是 Eino ChatModel 的薄适配器。
// 不持有任何会话/对话状态；每次 Infer 调用都从请求重建上下文。
type Eino_Model_Wrapper struct{}

// New 创建包装器。
func New() *Eino_Model_Wrapper {
	return &Eino_Model_Wrapper{}
}

// Infer 执行一次 LLM 推理：
//  1. Protobuf Message → Eino []*schema.Message
//  2. 按 model/api_base/api_key 构造 deepseek ChatModel 实例
//  3. 若携带 tools 则 BindTools
//  4. 调用 ChatModel.Generate(ctx, ...)
//  5. 翻译响应回 Protobuf LLMInferResponse
//
// 不重试、不循环 —— 编排交给 Erlang。
func (w *Eino_Model_Wrapper) Infer(ctx context.Context, req *hermes.LLMInferRequest) (*hermes.LLMInferResponse, error) {
	einoMsgs, err := toEinoMessages(req.GetMessages())
	if err != nil {
		return nil, fmt.Errorf("translate messages: %w", err)
	}

	// provider 配置完全由请求携带，Go 侧不缓存。
	cfg := &deepseek.ChatModelConfig{
		APIKey:    req.GetApiKey(),
		BaseURL:   req.GetApiBase(),
		Model:     req.GetModel(),
		MaxTokens: 8192, // 给推理模型(v4-pro)留足 reasoning + 正文空间
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = "https://api.deepseek.com"
	}

	cm, err := deepseek.NewChatModel(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("build chat model: %w", err)
	}

	// 绑定工具描述（让模型知道有哪些工具可调）。仅用 BindTools，不引入编排。
	if tools := req.GetTools(); len(tools) > 0 {
		infos, err := toEinoToolInfos(tools)
		if err != nil {
			return nil, fmt.Errorf("translate tools: %w", err)
		}
		if err := cm.BindTools(infos); err != nil {
			return nil, fmt.Errorf("bind tools: %w", err)
		}
	}

	out, err := cm.Generate(ctx, einoMsgs)
	if err != nil {
		return nil, fmt.Errorf("generate: %w", err)
	}

	return fromEinoMessage(out), nil
}

// toEinoMessages 将 Protobuf Message 列表翻译为 Eino schema.Message 列表。
// 覆盖 role / content / tool_calls / tool_call_id 四要素。
func toEinoMessages(msgs []*hermes.Message) ([]*schema.Message, error) {
	out := make([]*schema.Message, 0, len(msgs))
	for _, m := range msgs {
		msg := &schema.Message{
			Role:       schema.RoleType(m.GetRole()),
			Content:    m.GetContent(),
			ToolCallID: m.GetToolCallId(),
		}
		if tcs := m.GetToolCalls(); len(tcs) > 0 {
			msg.ToolCalls = make([]schema.ToolCall, len(tcs))
			for i, tc := range tcs {
				idx := i
				msg.ToolCalls[i] = schema.ToolCall{
					Index: &idx,
					ID:    tc.GetId(),
					Type:  "function",
					Function: schema.FunctionCall{
						Name:      tc.GetName(),
						Arguments: tc.GetArguments(),
					},
				}
			}
		}
		out = append(out, msg)
	}
	return out, nil
}

// toEinoToolInfos 将 Protobuf ToolDesc 列表翻译为 Eino schema.ToolInfo 列表。
// parameters_json 用 JSON Schema 字符串表达，这里解析为 jsonschema.Schema 后构造 ParamsOneOf。
func toEinoToolInfos(tools []*hermes.ToolDesc) ([]*schema.ToolInfo, error) {
	infos := make([]*schema.ToolInfo, 0, len(tools))
	for _, t := range tools {
		info := &schema.ToolInfo{
			Name: t.GetName(),
			Desc: t.GetDescription(),
		}
		if pj := t.GetParametersJson(); pj != "" {
			var s jsonschema.Schema
			if err := json.Unmarshal([]byte(pj), &s); err != nil {
				return nil, fmt.Errorf("parse tool %q params json: %w", t.GetName(), err)
			}
			info.ParamsOneOf = schema.NewParamsOneOfByJSONSchema(&s)
		}
		infos = append(infos, info)
	}
	return infos, nil
}

// fromEinoMessage 将 Eino 单条响应翻译回 LLMInferResponse。
func fromEinoMessage(out *schema.Message) *hermes.LLMInferResponse {
	resp := &hermes.LLMInferResponse{
		Content:          out.Content,
		ReasoningContent: out.ReasoningContent,
	}
	for _, tc := range out.ToolCalls {
		resp.ToolCalls = append(resp.ToolCalls, &hermes.ToolCall{
			Id:        tc.ID,
			Name:      tc.Function.Name,
			Arguments: tc.Function.Arguments,
		})
	}
	if out.ResponseMeta != nil && out.ResponseMeta.Usage != nil {
		resp.PromptTokens = int32(out.ResponseMeta.Usage.PromptTokens)
		resp.CompletionTokens = int32(out.ResponseMeta.Usage.CompletionTokens)
	}
	return resp
}
