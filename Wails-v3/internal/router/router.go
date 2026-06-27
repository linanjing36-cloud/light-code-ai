// Package router 是 Wails 进程内的 Go 路由枢纽。
//
// 流量模型 (Phase A 起):
//
//	面板 UI → Router → Erlang panel_server (编排)
//	Erlang → bridge_manager → Eion (LLM/工具, Phase B 经 panel exec 进程内)
//	Erlang panel stream → Bridge → Router.StreamHub → 面板 (chunk/final 分流)
//
// Router 不做 ReAct 业务决策; 会话/FSM 真相仍在 Erlang。
package router

import (
	"context"
	"log"
	"sync"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
	"hermes/internal/eion"
	eionserver "github.com/light-code-ai/eion-tools/pkg/server"
)

// Router 统一面板 ↔ 大脑 ↔ 流式分发的 Go 侧入口。
type Router struct {
	bridge  *brain.Bridge
	hub     *StreamHub
	eionEmb *eion.Embedded
	eion    *EionExecutor

	mu  sync.Mutex
	ctx context.Context
}

// New 创建 Router; eionEmb 可选, 在 ServiceStartup 时绑定进程内 Eion。
func New(bridge *brain.Bridge, eionEmb *eion.Embedded) *Router {
	return &Router{
		bridge:  bridge,
		hub:     NewStreamHub(),
		eionEmb: eionEmb,
	}
}

// Bridge 返回底层 panel 连接池 (生命周期仍由 Wails Service 管理)。
func (r *Router) Bridge() *brain.Bridge {
	return r.bridge
}

// StreamHub 返回流式分发器 (测试/扩展用)。
func (r *Router) StreamHub() *StreamHub {
	return r.hub
}

// ServiceStartup 安装 stream 路由: Bridge 收到的 panel stream 经 Hub 再分发到 UI。
func (r *Router) ServiceStartup(ctx context.Context, _ application.ServiceOptions) error {
	r.mu.Lock()
	r.ctx = ctx
	r.mu.Unlock()

	r.hub.SetPanelEmitter(defaultPanelEmitter)
	brain.SetStreamHandler(r.hub.Dispatch)
	if r.eionEmb != nil && r.eionEmb.Server() != nil {
		r.AttachEion(r.eionEmb.Server())
	}
	brain.SetExecHandler(r.handlePanelExec)
	log.Println("[router] stream hub installed (chunk/tool→panel; final→panel after erlang commit)")
	return nil
}

// ServiceShutdown 清除 stream 处理器。
func (r *Router) ServiceShutdown() error {
	brain.SetStreamHandler(nil)
	brain.SetExecHandler(nil)
	log.Println("[router] stream hub removed")
	return nil
}

// CallPanel 转发 RPC 到 Erlang panel_server。
func (r *Router) CallPanel(method string, args map[string]any) (any, error) {
	return r.bridge.Call(method, args)
}

// AttachEion 在 embedded Eion 启动后注入 (Phase B 入口)。
func (r *Router) AttachEion(srv *eionserver.Server) {
	r.eion = NewEionExecutor(srv)
	if addr := r.eion.ListenAddr(); addr != "" {
		log.Printf("[router] eion executor attached @ %s", addr)
	}
}

// Eion 返回进程内执行器 (可能未就绪)。
func (r *Router) Eion() *EionExecutor {
	return r.eion
}

func defaultPanelEmitter(ev brain.StreamEvent) {
	app := application.Get()
	if app == nil {
		return
	}
	w := app.Window.Current()
	if w == nil {
		return
	}
	w.EmitEvent("panel:stream", ev)
}

// SetStreamTap 追加 stream 监听 (e2e/调试); 在 Hub 分流之后调用。
func (r *Router) SetStreamTap(fn func(brain.StreamEvent)) {
	r.hub.SetTap(fn)
}

func (r *Router) handlePanelExec(ctx context.Context, _ uint64, reqBin []byte, emit func([]byte, string, bool) error) error {
	if r.eion == nil || !r.eion.Ready() {
		return emit(nil, "eion executor not ready", true)
	}
	runCtx := ctx
	r.mu.Lock()
	if r.ctx != nil {
		runCtx = r.ctx
	}
	r.mu.Unlock()
	return r.eion.RunAgent(runCtx, reqBin, ExecEmit(emit))
}
