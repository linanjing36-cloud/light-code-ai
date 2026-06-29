package server

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/light-code-ai/eion-tools/internal/logging"
)

func TestServerRegistersMCPAsCapability(t *testing.T) {
	logging.Init()
	cfg := []map[string]any{
		{
			"name":               "mock-mcp",
			"command":            "go",
			"args":               []string{"run", "./cmd/mock_mcp_stdio"},
			"cwd":                "e:\\light-code-ai-1\\Eion-tools",
			"enabled":            true,
			"connect_timeout_ms": 3000,
			"retry_delay_ms":     300,
		},
	}
	raw, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal cfg: %v", err)
	}
	t.Setenv("HERMES_MCP_SERVERS_JSON", string(raw))
	t.Setenv("HERMES_MEMORY_DISABLE", "1")

	srv, err := New(Options{})
	if err != nil {
		t.Fatalf("server new: %v", err)
	}
	defer srv.Stop()

	if _, err := srv.Start(context.Background()); err != nil {
		t.Fatalf("server start: %v", err)
	}

	caps := srv.Dispatcher().ToolWrapper().CapabilityDescs()
	found := false
	for _, cap := range caps {
		if cap.Name != "mcp_echo" {
			continue
		}
		found = true
		if string(cap.Kind) != "mcp" {
			t.Fatalf("unexpected kind: %s", cap.Kind)
		}
		if cap.Source != "mock-mcp" {
			t.Fatalf("unexpected source: %s", cap.Source)
		}
	}
	if !found {
		t.Fatalf("mcp_echo not found in capabilities: %#v", caps)
	}
}

func TestServerRegistersBuiltInSkillAsCapability(t *testing.T) {
	logging.Init()
	t.Setenv("HERMES_MCP_SERVERS_JSON", "")
	t.Setenv("HERMES_MEMORY_DISABLE", "1")

	srv, err := New(Options{})
	if err != nil {
		t.Fatalf("server new: %v", err)
	}
	defer srv.Stop()

	caps := srv.Dispatcher().ToolWrapper().CapabilityDescs()
	found := false
	for _, cap := range caps {
		if cap.Name != "workspace_briefing" {
			continue
		}
		found = true
		if string(cap.Kind) != "skill" {
			t.Fatalf("unexpected kind: %s", cap.Kind)
		}
		if cap.Source != "builtin" {
			t.Fatalf("unexpected source: %s", cap.Source)
		}
	}
	if !found {
		t.Fatalf("workspace_briefing not found in capabilities: %#v", caps)
	}
}

func TestServerRegistersMemoryWriteCapabilitiesAsReviewRisk(t *testing.T) {
	logging.Init()
	t.Setenv("HERMES_MCP_SERVERS_JSON", "")
	t.Setenv("HERMES_MEMORY_DISABLE", "0")
	t.Setenv("HERMES_MEMORY_BACKEND", "dev")
	t.Setenv("HERMES_MEMORY_MOCK_EMBED", "1")

	srv, err := New(Options{})
	if err != nil {
		t.Fatalf("server new: %v", err)
	}
	defer srv.Stop()

	caps := srv.Dispatcher().ToolWrapper().CapabilityDescs()
	expected := map[string]string{
		"memory_store":  "low",
		"memory_import": "medium",
	}
	found := map[string]bool{}
	for _, cap := range caps {
		wantCost, ok := expected[cap.Name]
		if !ok {
			continue
		}
		found[cap.Name] = true
		if string(cap.Kind) != "tool" {
			t.Fatalf("%s unexpected kind: %s", cap.Name, cap.Kind)
		}
		if cap.Source != "builtin" {
			t.Fatalf("%s unexpected source: %s", cap.Name, cap.Source)
		}
		if string(cap.RiskLevel) != "review" {
			t.Fatalf("%s unexpected risk level: %s", cap.Name, cap.RiskLevel)
		}
		if string(cap.CostHint) != wantCost {
			t.Fatalf("%s unexpected cost hint: %s", cap.Name, cap.CostHint)
		}
	}
	for name := range expected {
		if !found[name] {
			t.Fatalf("%s not found in capabilities: %#v", name, caps)
		}
	}
}
