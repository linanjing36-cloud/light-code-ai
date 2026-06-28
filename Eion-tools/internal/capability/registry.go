package capability

import (
	"fmt"
	"sort"
	"sync"
)

type Registry struct {
	mu    sync.RWMutex
	descs map[string]Desc
}

func NewRegistry() *Registry {
	return &Registry{
		descs: make(map[string]Desc),
	}
}

func (r *Registry) Register(desc Desc) error {
	if r == nil {
		return fmt.Errorf("capability registry is nil")
	}
	desc = Normalize(desc)
	if desc.Name == "" {
		return fmt.Errorf("capability name is empty")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.descs[desc.Name] = desc
	return nil
}

func (r *Registry) Get(name string) (Desc, bool) {
	if r == nil {
		return Desc{}, false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	desc, ok := r.descs[name]
	return desc, ok
}

func (r *Registry) List() []Desc {
	if r == nil {
		return nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	names := make([]string, 0, len(r.descs))
	for name := range r.descs {
		names = append(names, name)
	}
	sort.Strings(names)
	out := make([]Desc, 0, len(names))
	for _, name := range names {
		out = append(out, r.descs[name])
	}
	return out
}

// Unregister 从注册表移除指定 capability (EXEC-P1-002: 供 plugin host disable 使用)。
func (r *Registry) Unregister(name string) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.descs, name)
}
