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
