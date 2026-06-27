package router

import (
	"log"
	"sync"

	"hermes/internal/brain"
)

// StreamHub 按事件类型分流 panel stream。
//
// 规则 (与架构约定一致):
//   - chunk / tool_event → 仅面板 (低延迟预览)
//   - final / error      → 面板 (Erlang 在 push_final 前已落 history)
//
// Phase C 可在 final 上增加 brain 侧 in-process ack 回调。
type StreamHub struct {
	mu     sync.RWMutex
	emit   func(brain.StreamEvent)
	tap    func(brain.StreamEvent)
	onFinal func(brain.StreamEvent) // Phase C hook
}

func NewStreamHub() *StreamHub {
	return &StreamHub{}
}

func (h *StreamHub) SetPanelEmitter(fn func(brain.StreamEvent)) {
	h.mu.Lock()
	h.emit = fn
	h.mu.Unlock()
}

func (h *StreamHub) SetTap(fn func(brain.StreamEvent)) {
	h.mu.Lock()
	h.tap = fn
	h.mu.Unlock()
}

// SetFinalHook Phase C: LLM 终态到达 Go 路由后通知大脑/其他订阅方。
func (h *StreamHub) SetFinalHook(fn func(brain.StreamEvent)) {
	h.mu.Lock()
	h.onFinal = fn
	h.mu.Unlock()
}

// Dispatch 由 Bridge reader 调用; 是唯一 stream 入口。
func (h *StreamHub) Dispatch(ev brain.StreamEvent) {
	switch ev.Kind {
	case "chunk", "tool_event":
		h.toPanel(ev)
	case "final":
		h.onFinalLocked(ev)
		h.toPanel(ev)
	case "error":
		h.toPanel(ev)
		log.Printf("[router] stream error stream_id=%s msg=%v", ev.StreamID, ev.Payload["message"])
	default:
		h.toPanel(ev)
	}
	h.tapLocked(ev)
}

func (h *StreamHub) onFinalLocked(ev brain.StreamEvent) {
	h.mu.RLock()
	fn := h.onFinal
	h.mu.RUnlock()
	if fn != nil {
		fn(ev)
	}
}

func (h *StreamHub) toPanel(ev brain.StreamEvent) {
	h.mu.RLock()
	emit := h.emit
	h.mu.RUnlock()
	if emit != nil {
		emit(ev)
	}
}

func (h *StreamHub) tapLocked(ev brain.StreamEvent) {
	h.mu.RLock()
	tap := h.tap
	h.mu.RUnlock()
	if tap != nil {
		tap(ev)
	}
}
