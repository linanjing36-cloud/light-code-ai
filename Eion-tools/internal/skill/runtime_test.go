package skill

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/light-code-ai/eion-tools/internal/tool"
	codesearch "github.com/light-code-ai/eion-tools/plugins/code_search"
	repomap "github.com/light-code-ai/eion-tools/plugins/repo_map"
)

func TestRegisterBuiltinsAndInvoke(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "panel_server.erl"), []byte("-module(panel_server).\nhandle_call(test, State) -> State.\n"), 0o644); err != nil {
		t.Fatalf("write source: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(root, "docs"), 0o755); err != nil {
		t.Fatalf("mkdir docs: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "docs", "readme.md"), []byte("panel_server capability notes"), 0o644); err != nil {
		t.Fatalf("write docs: %v", err)
	}

	w := tool.New()
	repomap.Register(w)
	codesearch.Register(w)
	if err := RegisterBuiltins(w); err != nil {
		t.Fatalf("register builtins: %v", err)
	}

	caps := w.CapabilityDescs()
	found := false
	for _, cap := range caps {
		if cap.Name == "workspace_briefing" {
			found = true
			if string(cap.Kind) != "skill" {
				t.Fatalf("unexpected kind: %s", cap.Kind)
			}
		}
	}
	if !found {
		t.Fatalf("workspace_briefing not found in capabilities: %#v", caps)
	}

	out, err := w.Invoke(context.Background(), "workspace_briefing", `{"query":"panel_server","root_path":"`+filepath.ToSlash(root)+`","search_max_results":5}`)
	if err != nil {
		t.Fatalf("invoke workspace_briefing: %v", err)
	}
	if !strings.Contains(out, `"skill_source":"workspace_briefing"`) {
		t.Fatalf("unexpected output: %s", out)
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		t.Fatalf("decode output: %v", err)
	}
	codeSearch, _ := payload["code_search"].(map[string]any)
	if count, _ := codeSearch["count"].(float64); count < 1 {
		t.Fatalf("expected code_search hits, got %#v", payload)
	}
}
