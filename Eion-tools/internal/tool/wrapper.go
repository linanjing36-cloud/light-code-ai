// Package tool 提供 Eino tools.Tool 的薄包装与注册表。
//
// 设计原则（无状态执行 SDK）：
//   - 单次执行 → 单次响应。
//   - 工具本身不持有会话状态；幂等性由 dispatcher 的 ReqId 缓存负责，这里不重复实现。
//   - 仅使用 Eino 的 tools.Tool 接口，不引入任何编排概念。
package tool

import (
	"context"
	"fmt"

	// TODO: 引入 eino 依赖后启用下列 import（go.mod 暂未添加 eino）。
	// "github.com/cloudwego/eino/components/tool"
	// "github.com/cloudwego/eino/schema"
)

// HandlerFunc 是最朴素的 Go 工具实现形式：
// 接收 ctx 与 JSON 参数字符串，返回 JSON 结果字符串或 error。
// 这种形式让任意 Go 函数都能被包装成 Eino tools.Tool，无需关心 Eino 内部的 schema 类型。
type HandlerFunc func(ctx context.Context, argumentsJSON string) (resultJSON string, err error)

// Eino_Tool_Wrapper 维护工具注册表。不持有任何会话状态。
type Eino_Tool_Wrapper struct {
	// TODO: 引入 eino 后将 map 值类型改为 tool.Tool。
	registry map[string]registeredTool
}

// New 创建包装器。
func New() *Eino_Tool_Wrapper {
	return &Eino_Tool_Wrapper{
		registry: make(map[string]registeredTool),
	}
}

// Register 注册一个 HandlerFunc，并标记其将包装为 Eino tools.Tool。
// TODO: 引入 eino 后，应同时返回/构造符合 tool.InvokableTool 接口的对象并暴露给 dispatcher。
func (w *Eino_Tool_Wrapper) Register(name, description, parametersJSON string, h HandlerFunc) {
	w.registry[name] = registeredTool{
		name:           name,
		description:    description,
		parametersJSON: parametersJSON,
		handler:        h,
	}
}

// Get 返回注册的工具（供 dispatcher 查找）。
// TODO: 引入 eino 后将返回值类型改为 tool.Tool。
func (w *Eino_Tool_Wrapper) Get(name string) (registeredTool, bool) {
	t, ok := w.registry[name]
	return t, ok
}

// Names 返回所有已注册工具名。
func (w *Eino_Tool_Wrapper) Names() []string {
	names := make([]string, 0, len(w.registry))
	for n := range w.registry {
		names = append(names, n)
	}
	return names
}

// registeredTool 是内部占位实现；接入 eino 后将由实现 tool.BaseTool / InvokableTool
// 接口的结构替代（Info() 返回 *schema.ToolInfo，InvokableRun() 执行调用）。
type registeredTool struct {
	name           string
	description    string
	parametersJSON string
	handler        HandlerFunc
}

// Invoke 执行工具（占位形式；接入 eino 后由 InvokableTool 接管）。
func (t registeredTool) Invoke(ctx context.Context, argumentsJSON string) (string, error) {
	if t.handler == nil {
		return "", fmt.Errorf("tool %s has no handler", t.name)
	}
	return t.handler(ctx, argumentsJSON)
}

// 示例工具：get_weather —— 演示如何用 HandlerFunc 包装一个普通 Go 函数。
// 真实接入 eino 后应改用 schema.ToolDef + InvokableTool 注册；此处保留 HandlerFunc 形式以便迁移。
//
// 返回值：(name, description, parametersJSON, handler)
func GetWeatherHandler() (name, description, parametersJSON string, h HandlerFunc) {
	return "get_weather",
		"获取指定城市的当前天气",
		`{"type":"object","properties":{"city":{"type":"string","description":"城市名"}},"required":["city"]}`,
		func(ctx context.Context, argumentsJSON string) (string, error) {
			// TODO: 真实实现应解析 argumentsJSON 并调用天气 API。
			// 此处仅返回占位结果，证明端到端链路打通。
			_ = ctx
			return fmt.Sprintf(`{"city":"unknown","weather":"sunny","temp_c":25,"args":%s}`, argumentsJSON), nil
		}
}
