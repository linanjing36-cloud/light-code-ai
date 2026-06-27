package skill

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/light-code-ai/eion-tools/internal/capability"
	"github.com/light-code-ai/eion-tools/internal/tool"
)

type Spec struct {
	Desc capability.Desc
	Run  func(ctx context.Context, rt *Runtime, arguments map[string]any) (map[string]any, error)
}

type Registry struct {
	specs map[string]Spec
}

func NewRegistry() *Registry {
	return &Registry{specs: map[string]Spec{}}
}

func (r *Registry) Register(spec Spec) error {
	if r == nil {
		return fmt.Errorf("skill registry is nil")
	}
	spec.Desc = capability.Normalize(spec.Desc)
	if spec.Desc.Name == "" {
		return fmt.Errorf("skill name is empty")
	}
	if spec.Desc.Kind == "" {
		spec.Desc.Kind = capability.KindSkill
	}
	if spec.Run == nil {
		return fmt.Errorf("skill %s has no runner", spec.Desc.Name)
	}
	r.specs[spec.Desc.Name] = spec
	return nil
}

func (r *Registry) RegisterTo(w *tool.Eino_Tool_Wrapper) error {
	if r == nil || w == nil {
		return nil
	}
	rt := NewRuntime(w)
	for _, spec := range r.specs {
		spec := spec
		w.RegisterCapability(spec.Desc, func(ctx context.Context, argumentsJSON string) (string, error) {
			args := map[string]any{}
			if argumentsJSON != "" {
				if err := json.Unmarshal([]byte(argumentsJSON), &args); err != nil {
					return "", fmt.Errorf("parse skill args: %w", err)
				}
			}
			out, err := spec.Run(ctx, rt, args)
			if err != nil {
				return "", err
			}
			bin, err := json.Marshal(out)
			if err != nil {
				return "", fmt.Errorf("marshal skill result: %w", err)
			}
			return string(bin), nil
		})
	}
	return nil
}
