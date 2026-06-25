// Command agent-demo 是 Go 执行层的端到端验证入口。
//
// 它通过 dispatcher 的 Protobuf 契约（即 Erlang 将来会调用的同款接口）手写一个
// ReAct 循环：Generate → 若有 tool_calls 则执行工具 → 把结果喂回 → 再 Generate，
// 直到模型给出最终回答或达到最大循环次数。
//
// 注意：这是验证用测试程序，不是生产编排。生产环境的 ReAct 编排由 Erlang
// Agent_FSM 负责；本 demo 不引入 Eino 的 agent.NewAgent / Chain / Graph。
//
// 用法：
//
//	go run ./cmd/agent-demo
//
// 默认从 ../api-key.json 读取 api_key 与 model。
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/light-code-ai/eion-tools/internal/dispatcher"
	"github.com/light-code-ai/eion-tools/internal/tool"
	hermes "github.com/light-code-ai/eion-tools/proto/gen"
)

const (
	apiBase    = "https://api.deepseek.com"
	maxLoops   = 10
	systemPrompt = `你是一个会调用工具的助手。当需要查询天气时，请调用 get_weather 工具。
拿到工具结果后，用自然语言总结回答用户。不要编造未通过工具获取的信息。`
	defaultQuery = "北京和上海今天的天气怎么样？请用 get_weather 工具查询后总结。"
)

func main() {
	apiKey, model := loadCredentials()

	// 装配 dispatcher 并注册 get_weather 工具
	d := dispatcher.New()
	name, desc, params, handler := tool.GetWeatherHandler()
	d.ToolWrapper().Register(name, desc, params, handler)

	// 工具描述（与 Erlang 将来下发的 ToolDesc 同构）
	tools := []*hermes.ToolDesc{
		{Name: name, Description: desc, ParametersJson: params},
	}

	query := defaultQuery
	if len(os.Args) > 1 {
		query = os.Args[1]
	}

	messages := []*hermes.Message{
		{Role: "system", Content: systemPrompt},
		{Role: "user", Content: query},
	}

	fmt.Printf("用户: %s\n\n", query)

	ctx := context.Background()
	for loop := 1; loop <= maxLoops; loop++ {
		// 1. 推理请求（通过 dispatcher 的 Protobuf 契约 —— Erlang 同款接口）
		rr := &hermes.LLMInferRequest{
			Model:    model,
			ApiBase:  apiBase,
			ApiKey:   apiKey,
			Messages: messages,
			Tools:    tools,
		}
		resp := d.Dispatch(ctx, &hermes.AgentRequest{
			Payload: &hermes.AgentRequest_LlmInfer{LlmInfer: rr},
		})
		llm := resp.GetLlmInfer()
		if llm == nil {
			log.Fatalf("loop %d: 期望 llm_infer 响应，实际拿到别的分支", loop)
		}

		// 展示推理过程（v4-pro 的思考链）
		if llm.GetReasoningContent() != "" {
			fmt.Printf("[思考 %d] %s\n\n", loop, truncate(llm.GetReasoningContent(), 200))
		}

		// 2. 没有工具调用 → 最终回答，结束循环
		if len(llm.GetToolCalls()) == 0 {
			fmt.Printf("助手: %s\n", llm.GetContent())
			fmt.Printf("\n[用量] prompt=%d completion=%d  [循环数] %d\n",
				llm.GetPromptTokens(), llm.GetCompletionTokens(), loop)
			return
		}

		// 3. 有工具调用 → 把 assistant 消息(含 tool_calls)追加进上下文
		asstMsg := &hermes.Message{
			Role:      "assistant",
			Content:   llm.GetContent(),
			ToolCalls: llm.GetToolCalls(),
		}
		messages = append(messages, asstMsg)

		// 4. 逐个执行工具（通过 dispatcher 的 ToolExec 契约）
		for _, tc := range llm.GetToolCalls() {
			fmt.Printf("[工具调用 %d] %s(%s)\n", loop, tc.GetName(), tc.GetArguments())

			tr := &hermes.ToolExecRequest{
				ReqId:        fmt.Sprintf("loop%d-%s", loop, tc.GetId()),
				ToolName:     tc.GetName(),
				ArgumentsJson: tc.GetArguments(),
			}
			tresp := d.Dispatch(ctx, &hermes.AgentRequest{
				Payload: &hermes.AgentRequest_ToolExec{ToolExec: tr},
			})
			te := tresp.GetToolExec()
			result := te.GetResultJson()
			if te.GetError() != "" {
				result = fmt.Sprintf(`{"error":%q}`, te.GetError())
			}
			fmt.Printf("[工具结果 %d] %s\n\n", loop, prettyJSON(result))

			// 把工具结果作为 role=tool 消息喂回上下文
			messages = append(messages, &hermes.Message{
				Role:       "tool",
				Content:    result,
				ToolCallId: tc.GetId(),
			})
		}
	}

	log.Fatalf("达到最大循环数 %d 仍未给出最终回答", maxLoops)
}

// loadCredentials 从 ../api-key.json 读取 api_key 与 model。
func loadCredentials() (apiKey, model string) {
	// cwd 通常为 Eion-tools，api-key.json 在上一级
	candidates := []string{
		"../api-key.json",
		"../../api-key.json",
		filepath.Join(os.Getenv("HOME"), "local", "light-code-ai", "api-key.json"),
	}
	var path string
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			path = c
			break
		}
	}
	if path == "" {
		log.Fatal("找不到 api-key.json")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		log.Fatalf("读取 %s: %v", path, err)
	}
	var cfg struct {
		APIKey string `json:"api_key"`
		Model  string `json:"model"`
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		log.Fatalf("解析 %s: %v", path, err)
	}
	if cfg.APIKey == "" || cfg.Model == "" {
		log.Fatal("api-key.json 缺少 api_key 或 model")
	}
	return cfg.APIKey, cfg.Model
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func prettyJSON(s string) string {
	var v any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		return s
	}
	b, err := json.Marshal(v)
	if err != nil {
		return s
	}
	return string(b)
}
