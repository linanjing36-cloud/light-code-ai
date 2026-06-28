package plugin

import (
	"context"
	"testing"

	"github.com/light-code-ai/eion-tools/internal/capability"
	"github.com/light-code-ai/eion-tools/internal/tool"
)

// registerFakeCap 返回一个注册假 capability 的函数，用于测试。
func registerFakeCap(name string) func(w *tool.Eino_Tool_Wrapper) {
	return func(w *tool.Eino_Tool_Wrapper) {
		w.RegisterCapability(capability.Normalize(capability.Desc{
			Name:        name,
			Kind:        capability.KindPlugin,
			Source:      "test",
			Description: "fake cap for test",
		}), func(ctx context.Context, argumentsJSON string) (string, error) {
			return `{"ok":true}`, nil
		})
	}
}

func TestHost_InstallEnableDisable(t *testing.T) {
	w := tool.New()
	h := NewHost(w)
	if err := h.Install(NewFuncPlugin(Manifest{
		Name: "p1", Capabilities: []string{"fake_cap"},
	}, registerFakeCap("fake_cap"))); err != nil {
		t.Fatalf("install: %v", err)
	}

	// installed 但未 enable，capability 不应在 wrapper
	if _, ok := w.Get("fake_cap"); ok {
		t.Fatal("cap should not be registered before enable")
	}

	if err := h.Enable("p1"); err != nil {
		t.Fatalf("enable: %v", err)
	}
	if _, ok := w.Get("fake_cap"); !ok {
		t.Fatal("cap should be registered after enable")
	}
	if !capInRegistry(w, "fake_cap") {
		t.Fatal("cap not in capability registry after enable")
	}

	if err := h.Disable("p1"); err != nil {
		t.Fatalf("disable: %v", err)
	}
	if _, ok := w.Get("fake_cap"); ok {
		t.Fatal("cap should be unregistered after disable")
	}
	if capInRegistry(w, "fake_cap") {
		t.Fatal("cap still in capability registry after disable")
	}
}

func TestHost_Uninstall(t *testing.T) {
	w := tool.New()
	h := NewHost(w)
	h.Install(NewFuncPlugin(Manifest{Name: "p1", Capabilities: []string{"c1"}}, registerFakeCap("c1")))
	h.Enable("p1")
	if err := h.Uninstall("p1"); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, ok := h.Get("p1"); ok {
		t.Fatal("plugin should be removed after uninstall")
	}
	if _, ok := w.Get("c1"); ok {
		t.Fatal("cap should be unregistered after uninstall")
	}
}

func TestHost_EnableAll(t *testing.T) {
	w := tool.New()
	h := NewHost(w)
	h.Install(NewFuncPlugin(Manifest{Name: "p1", Capabilities: []string{"c1"}}, registerFakeCap("c1")))
	h.Install(NewFuncPlugin(Manifest{Name: "p2", Capabilities: []string{"c2"}}, registerFakeCap("c2")))
	if err := h.EnableAll(); err != nil {
		t.Fatalf("enableAll: %v", err)
	}
	if _, ok := w.Get("c1"); !ok {
		t.Fatal("c1 should be registered")
	}
	if _, ok := w.Get("c2"); !ok {
		t.Fatal("c2 should be registered")
	}
	for _, info := range h.List() {
		if info.State != StateEnabled {
			t.Fatalf("plugin %s not enabled", info.Manifest.Name)
		}
	}
}

func TestHost_ListSorted(t *testing.T) {
	w := tool.New()
	h := NewHost(w)
	h.Install(NewFuncPlugin(Manifest{Name: "zeta", Capabilities: []string{"z"}}, registerFakeCap("z")))
	h.Install(NewFuncPlugin(Manifest{Name: "alpha", Capabilities: []string{"a"}}, registerFakeCap("a")))
	list := h.List()
	if len(list) != 2 || list[0].Manifest.Name != "alpha" || list[1].Manifest.Name != "zeta" {
		t.Fatalf("list not sorted: %+v", list)
	}
}

func TestHost_DoubleEnableIdempotent(t *testing.T) {
	w := tool.New()
	h := NewHost(w)
	h.Install(NewFuncPlugin(Manifest{Name: "p1", Capabilities: []string{"c1"}}, registerFakeCap("c1")))
	if err := h.Enable("p1"); err != nil {
		t.Fatal(err)
	}
	if err := h.Enable("p1"); err != nil {
		t.Fatalf("double enable should be idempotent: %v", err)
	}
}

func TestHost_DoubleDisableIdempotent(t *testing.T) {
	w := tool.New()
	h := NewHost(w)
	h.Install(NewFuncPlugin(Manifest{Name: "p1", Capabilities: []string{"c1"}}, registerFakeCap("c1")))
	h.Enable("p1")
	if err := h.Disable("p1"); err != nil {
		t.Fatal(err)
	}
	if err := h.Disable("p1"); err != nil {
		t.Fatalf("double disable should be idempotent: %v", err)
	}
}

func TestHost_InstallDuplicate(t *testing.T) {
	w := tool.New()
	h := NewHost(w)
	h.Install(NewFuncPlugin(Manifest{Name: "p1", Capabilities: []string{"c1"}}, registerFakeCap("c1")))
	if err := h.Install(NewFuncPlugin(Manifest{Name: "p1"}, registerFakeCap("c1"))); err == nil {
		t.Fatal("duplicate install should fail")
	}
}

func TestHost_NotInstalled(t *testing.T) {
	w := tool.New()
	h := NewHost(w)
	if err := h.Enable("nope"); err == nil {
		t.Fatal("enable not-installed should fail")
	}
	if err := h.Disable("nope"); err == nil {
		t.Fatal("disable not-installed should fail")
	}
	if err := h.Uninstall("nope"); err == nil {
		t.Fatal("uninstall not-installed should fail")
	}
}

func TestHost_EmptyManifestName(t *testing.T) {
	w := tool.New()
	h := NewHost(w)
	if err := h.Install(NewFuncPlugin(Manifest{}, registerFakeCap("c1"))); err == nil {
		t.Fatal("empty manifest name should fail")
	}
}

func capInRegistry(w *tool.Eino_Tool_Wrapper, name string) bool {
	for _, c := range w.CapabilityDescs() {
		if c.Name == name {
			return true
		}
	}
	return false
}
