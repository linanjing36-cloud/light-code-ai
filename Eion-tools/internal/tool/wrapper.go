// Package tool 提供 Eino tools.Tool 的薄包装与注册表。
//
// 设计原则（无状态执行 SDK）：
//   - 单次执行 → 单次响应。
//   - 工具本身不持有会话状态；幂等性由 dispatcher 的 ReqId 缓存负责，这里不重复实现。
//   - 仅使用 Eino 的 tools.Tool 接口，不引入任何编排概念。
package tool

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/eino-contrib/jsonschema"
	"github.com/cloudwego/eino/components/tool"
	"github.com/cloudwego/eino/schema"
)

// HandlerFunc 是最朴素的 Go 工具实现形式：
// 接收 ctx 与 JSON 参数字符串，返回 JSON 结果字符串或 error。
// 这种形式让任意 Go 函数都能被包装成 Eino tools.Tool，无需关心 Eino 内部的 schema 类型。
type HandlerFunc func(ctx context.Context, argumentsJSON string) (resultJSON string, err error)

// Eino_Tool_Wrapper 维护工具注册表。不持有任何会话状态。
type Eino_Tool_Wrapper struct {
	registry map[string]*registeredTool
}

// New 创建包装器。
func New() *Eino_Tool_Wrapper {
	return &Eino_Tool_Wrapper{registry: make(map[string]*registeredTool)}
}

// Register 注册一个 HandlerFunc 为 Eino InvokableTool。
// parametersJSON 为 JSON Schema 字符串（OpenAI tool 参数格式）。
func (w *Eino_Tool_Wrapper) Register(name, description, parametersJSON string, h HandlerFunc) {
	info := &schema.ToolInfo{
		Name: name,
		Desc: description,
	}
	if parametersJSON != "" {
		var s jsonschema.Schema
		if err := json.Unmarshal([]byte(parametersJSON), &s); err == nil {
			info.ParamsOneOf = schema.NewParamsOneOfByJSONSchema(&s)
		}
		// 解析失败则该工具视为无参工具（ParamsOneOf 为 nil）
	}
	w.registry[name] = &registeredTool{info: info, handler: h, paramsJSON: parametersJSON}
}

// Desc 是对外暴露的工具描述（与 hermes.ToolDesc / panel_tools 对齐）。
type Desc struct {
	Name           string
	Description    string
	ParametersJSON string
}

// ListDescs 返回当前注册表中的全部工具描述（按 name 排序）。
func (w *Eino_Tool_Wrapper) ListDescs() []Desc {
	names := w.Names()
	sort.Strings(names)
	out := make([]Desc, 0, len(names))
	for _, n := range names {
		t := w.registry[n]
		out = append(out, Desc{
			Name:           t.info.Name,
			Description:    t.info.Desc,
			ParametersJSON: t.paramsJSON,
		})
	}
	return out
}

// Get 返回注册的工具（实现 tool.InvokableTool 接口）。
func (w *Eino_Tool_Wrapper) Get(name string) (tool.InvokableTool, bool) {
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

// ToolInfos 返回所有工具的 schema.ToolInfo，供 model.BindTools 使用。
func (w *Eino_Tool_Wrapper) ToolInfos() []*schema.ToolInfo {
	infos := make([]*schema.ToolInfo, 0, len(w.registry))
	for _, t := range w.registry {
		infos = append(infos, t.info)
	}
	return infos
}

// registeredTool 实现 tool.InvokableTool 接口（BaseTool + InvokableRun）。
type registeredTool struct {
	info       *schema.ToolInfo
	handler    HandlerFunc
	paramsJSON string
}

func (t *registeredTool) Info(_ context.Context) (*schema.ToolInfo, error) {
	return t.info, nil
}

func (t *registeredTool) InvokableRun(ctx context.Context, argumentsJSON string, _ ...tool.Option) (string, error) {
	if t.handler == nil {
		return "", fmt.Errorf("tool %s has no handler", t.info.Name)
	}
	return t.handler(ctx, argumentsJSON)
}

// GetWeatherHandler 返回示例工具 get_weather 的注册四元组。
// 演示如何用 HandlerFunc 包装一个普通 Go 函数；真实工具替换 handler 即可。
func GetWeatherHandler() (name, description, parametersJSON string, h HandlerFunc) {
	return "get_weather",
		"获取指定城市的当前天气。仅支持中国主要城市。",
		`{"type":"object","properties":{"city":{"type":"string","description":"城市名，例如 北京/上海/深圳"}},"required":["city"]}`,
		func(ctx context.Context, argumentsJSON string) (string, error) {
			_ = ctx
			var args struct {
				City string `json:"city"`
			}
			_ = json.Unmarshal([]byte(argumentsJSON), &args)
			// 占位实现：用一个固定的假数据映射，证明端到端链路打通。
			// 真实实现应调用天气 API。
			weather := map[string]string{
				"北京": "晴, 26°C, 北风3级",
				"上海": "多云, 23°C, 东风2级",
				"深圳": "雷阵雨, 28°C, 南风3级",
			}
			w, ok := weather[args.City]
			if !ok {
				w = "晴, 25°C"
			}
			return fmt.Sprintf(`{"city":"%s","weather":"%s"}`, args.City, w), nil
		}
}
