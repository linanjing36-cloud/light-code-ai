// Package plugin 提供 plugin host，统一管理插件生命周期 (install/enable/disable/uninstall)。
//
// 设计原则 (EXEC-P1-002)：
//   - Host 不持有会话状态，仅维护插件清单与状态映射。
//   - Enable 调用插件的 Register(w) 注册 capability；Disable 按 Manifest.Capabilities 精确注销。
//   - 与现有 plugins/* 的 Register(w) 签名兼容，经 FuncPlugin 适配器零侵入接入。
package plugin

import (
	"fmt"
	"sort"
	"sync"

	"github.com/light-code-ai/eion-tools/internal/tool"
)

// State 插件生命周期状态。
type State string

const (
	StateInstalled State = "installed" // 已注册到 host，未启用
	StateEnabled   State = "enabled"   // 已注册 capability 到 wrapper
	StateDisabled  State = "disabled"  // 已注销 capability
)

// Manifest 插件清单。
type Manifest struct {
	Name         string
	Version      string
	Description  string
	Source       string   // 来源: "builtin" / 路径
	Capabilities []string // 插件注册的 capability 名列表，disable 时按此精确注销
	Builtin      bool
}

// Plugin 插件接口。实现者提供清单与注册逻辑。
type Plugin interface {
	Manifest() Manifest
	Register(w *tool.Eino_Tool_Wrapper)
}

// FuncPlugin 把 (Manifest, RegisterFunc) 适配为 Plugin，兼容现有 plugins/* 的 Register(w) 签名。
type FuncPlugin struct {
	manifest Manifest
	register func(w *tool.Eino_Tool_Wrapper)
}

// NewFuncPlugin 创建函数式插件适配器。
func NewFuncPlugin(m Manifest, register func(w *tool.Eino_Tool_Wrapper)) *FuncPlugin {
	return &FuncPlugin{manifest: m, register: register}
}

func (p *FuncPlugin) Manifest() Manifest { return p.manifest }

// Register 调用注入的注册函数。
func (p *FuncPlugin) Register(w *tool.Eino_Tool_Wrapper) {
	if p != nil && p.register != nil {
		p.register(w)
	}
}

// PluginInfo 对外暴露的插件状态信息。
type PluginInfo struct {
	Manifest Manifest
	State    State
}

// Host 管理 plugin 生命周期。
type Host struct {
	mu      sync.RWMutex
	w       *tool.Eino_Tool_Wrapper
	plugins map[string]*entry
}

type entry struct {
	plugin Plugin
	state  State
}

// NewHost 创建 plugin host。
func NewHost(w *tool.Eino_Tool_Wrapper) *Host {
	return &Host{w: w, plugins: make(map[string]*entry)}
}

// Install 注册插件到 host（状态 installed），不启用。
func (h *Host) Install(p Plugin) error {
	if h == nil {
		return fmt.Errorf("plugin host is nil")
	}
	m := p.Manifest()
	if m.Name == "" {
		return fmt.Errorf("plugin manifest name is empty")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, exists := h.plugins[m.Name]; exists {
		return fmt.Errorf("plugin %s already installed", m.Name)
	}
	h.plugins[m.Name] = &entry{plugin: p, state: StateInstalled}
	return nil
}

// Enable 启用插件：调用 Register(w) 注册 capability，状态置 enabled (幂等)。
func (h *Host) Enable(name string) error {
	if h == nil {
		return fmt.Errorf("plugin host is nil")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	e, ok := h.plugins[name]
	if !ok {
		return fmt.Errorf("plugin %s not installed", name)
	}
	if e.state == StateEnabled {
		return nil
	}
	if h.w != nil {
		e.plugin.Register(h.w)
	}
	e.state = StateEnabled
	return nil
}

// Disable 禁用插件：按 Manifest.Capabilities 注销 capability，状态置 disabled (幂等)。
func (h *Host) Disable(name string) error {
	if h == nil {
		return fmt.Errorf("plugin host is nil")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	e, ok := h.plugins[name]
	if !ok {
		return fmt.Errorf("plugin %s not installed", name)
	}
	if e.state != StateEnabled {
		e.state = StateDisabled
		return nil
	}
	if h.w != nil {
		for _, capName := range e.plugin.Manifest().Capabilities {
			h.w.UnregisterCapability(capName)
		}
	}
	e.state = StateDisabled
	return nil
}

// Uninstall 卸载插件：若已启用先注销 capability，再从 host 移除。
func (h *Host) Uninstall(name string) error {
	if h == nil {
		return fmt.Errorf("plugin host is nil")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	e, ok := h.plugins[name]
	if !ok {
		return fmt.Errorf("plugin %s not installed", name)
	}
	if e.state == StateEnabled && h.w != nil {
		for _, capName := range e.plugin.Manifest().Capabilities {
			h.w.UnregisterCapability(capName)
		}
	}
	delete(h.plugins, name)
	return nil
}

// EnableAll 启用所有已安装但未启用的插件。
func (h *Host) EnableAll() error {
	if h == nil {
		return fmt.Errorf("plugin host is nil")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, e := range h.plugins {
		if e.state == StateEnabled {
			continue
		}
		if h.w != nil {
			e.plugin.Register(h.w)
		}
		e.state = StateEnabled
	}
	return nil
}

// List 返回所有已安装插件的状态信息 (按 name 排序)。
func (h *Host) List() []PluginInfo {
	if h == nil {
		return nil
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	names := make([]string, 0, len(h.plugins))
	for n := range h.plugins {
		names = append(names, n)
	}
	sort.Strings(names)
	out := make([]PluginInfo, 0, len(names))
	for _, n := range names {
		e := h.plugins[n]
		out = append(out, PluginInfo{Manifest: e.plugin.Manifest(), State: e.state})
	}
	return out
}

// Get 返回指定插件状态。
func (h *Host) Get(name string) (PluginInfo, bool) {
	if h == nil {
		return PluginInfo{}, false
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	e, ok := h.plugins[name]
	if !ok {
		return PluginInfo{}, false
	}
	return PluginInfo{Manifest: e.plugin.Manifest(), State: e.state}, true
}
