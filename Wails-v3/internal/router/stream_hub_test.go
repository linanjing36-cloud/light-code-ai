package router

import (
	"testing"

	"hermes/internal/brain"
)

func TestStreamHub_DispatchRoutes(t *testing.T) {
	hub := NewStreamHub()
	var panelKinds []string
	hub.SetPanelEmitter(func(ev brain.StreamEvent) {
		panelKinds = append(panelKinds, ev.Kind)
	})

	hub.Dispatch(brain.StreamEvent{Kind: "chunk", StreamID: "s1"})
	hub.Dispatch(brain.StreamEvent{Kind: "tool_event", StreamID: "s1"})
	hub.Dispatch(brain.StreamEvent{Kind: "final", StreamID: "s1"})
	hub.Dispatch(brain.StreamEvent{Kind: "error", StreamID: "s1", Payload: map[string]any{"message": "x"}})

	if len(panelKinds) != 4 {
		t.Fatalf("panel events=%d want 4", len(panelKinds))
	}
	want := []string{"chunk", "tool_event", "final", "error"}
	for i := range want {
		if panelKinds[i] != want[i] {
			t.Fatalf("panelKinds[%d]=%q want %q", i, panelKinds[i], want[i])
		}
	}
}

func TestStreamHub_FinalHook(t *testing.T) {
	hub := NewStreamHub()
	var finalSeen bool
	hub.SetFinalHook(func(ev brain.StreamEvent) {
		finalSeen = ev.Kind == "final"
	})
	hub.SetPanelEmitter(func(_ brain.StreamEvent) {})

	hub.Dispatch(brain.StreamEvent{Kind: "final", StreamID: "s2"})
	if !finalSeen {
		t.Fatal("final hook not called")
	}
}
