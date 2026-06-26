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
	"errors"
	"fmt"
	"io"
	"strings"

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

// Stream 执行一次流式 LLM 推理：
//  1. 与 Infer 相同的 provider 配置（model/api_base/api_key 由请求携带）+ BindTools
//  2. 调用 ChatModel.Stream 拿到 *schema.StreamReader[*schema.Message]
//  3. 循环 Recv：每个增量 chunk 调 onChunk 回调（content + reasoning_content）
//  4. 累积完整响应（content / reasoning_content / tool_calls / usage），转成 LLMInferResponse 返回作为终态
//
// 注意：Eino(deepseek) 的 Stream 每条 message 是增量 delta（非累积），
// 故这里自行累积 content/reasoning_content，并按 Index 合并 tool_calls delta。
// usage 通常仅最后一个 chunk 携带；若 Stream 不返回 usage，终态 tokens 为 0（可接受）。
//
// 不重试、不循环编排 —— 编排交给 Erlang。
func (w *Eino_Model_Wrapper) Stream(
	ctx context.Context,
	req *hermes.LLMInferRequest,
	onChunk func(*hermes.LlmChunk) error,
) (*hermes.LLMInferResponse, error) {
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

	reader, err := cm.Stream(ctx, einoMsgs)
	if err != nil {
		return nil, fmt.Errorf("stream: %w", err)
	}

	// 累积终态响应：deepseek Stream 每条 message 是增量 delta，需自行累积。
	var contentBuf strings.Builder
	var reasoningBuf strings.Builder
	var toolCalls []schema.ToolCall
	toolCallPos := map[int]int{} // delta.Index -> toolCalls 下标
	var lastUsage *schema.TokenUsage

	for {
		msg, err := reader.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			reader.Close()
			return nil, fmt.Errorf("recv stream chunk: %w", err)
		}
		if msg == nil {
			continue
		}

		// 增量 chunk 回调（仅在有正文/推理增量时下发，避免空帧）
		if msg.Content != "" || msg.ReasoningContent != "" {
			if err := onChunk(&hermes.LlmChunk{
				Content:          msg.Content,
				ReasoningContent: msg.ReasoningContent,
			}); err != nil {
				reader.Close()
				return nil, fmt.Errorf("onChunk: %w", err)
			}
		}

		// 累积正文 / 推理
		contentBuf.WriteString(msg.Content)
		reasoningBuf.WriteString(msg.ReasoningContent)

		// 按 Index 合并 tool_calls delta（流式 tool_call 分片到达：首片带 id/name，后续片拼 arguments）
		for _, tc := range msg.ToolCalls {
			if tc.Index == nil {
				continue
			}
			idx := *tc.Index
			if pos, ok := toolCallPos[idx]; ok {
				cur := &toolCalls[pos]
				if tc.ID != "" {
					cur.ID = tc.ID
				}
				if tc.Function.Name != "" {
					cur.Function.Name = tc.Function.Name
				}
				cur.Function.Arguments += tc.Function.Arguments
				if tc.Type != "" {
					cur.Type = tc.Type
				}
			} else {
				toolCallPos[idx] = len(toolCalls)
				toolCalls = append(toolCalls, tc)
			}
		}

		// 记录最近一次 usage（通常仅最后一个 chunk 携带）
		if msg.ResponseMeta != nil && msg.ResponseMeta.Usage != nil {
			lastUsage = msg.ResponseMeta.Usage
		}
	}

	// 构造终态响应（复用 fromEinoMessage 翻译 tool_calls / tokens / reasoning_content）
	finalMsg := &schema.Message{
		Content:          contentBuf.String(),
		ReasoningContent: reasoningBuf.String(),
		ToolCalls:        toolCalls,
	}
	if lastUsage != nil {
		finalMsg.ResponseMeta = &schema.ResponseMeta{Usage: lastUsage}
	}
	return fromEinoMessage(finalMsg), nil
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
