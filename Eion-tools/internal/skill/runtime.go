package skill

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/light-code-ai/eion-tools/internal/tool"
)

type Runtime struct {
	w *tool.Eino_Tool_Wrapper
}

func NewRuntime(w *tool.Eino_Tool_Wrapper) *Runtime {
	return &Runtime{w: w}
}

func (r *Runtime) Call(ctx context.Context, name string, args map[string]any) (map[string]any, error) {
	if r == nil || r.w == nil {
		return nil, fmt.Errorf("skill runtime is nil")
	}
	bin, err := json.Marshal(args)
	if err != nil {
		return nil, fmt.Errorf("marshal nested args: %w", err)
	}
	out, err := r.w.Invoke(ctx, name, string(bin))
	if err != nil {
		return nil, err
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		return nil, fmt.Errorf("decode nested result from %s: %w", name, err)
	}
	return payload, nil
}
