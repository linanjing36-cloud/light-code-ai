package codesearch

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestCodeSearchHandler(t *testing.T) {
	root := t.TempDir()
	srcDir := filepath.Join(root, "Wails-v3", "frontend", "src")
	if err := os.MkdirAll(srcDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(srcDir, "main.ts"), []byte("const tool = 'repo_map'\nconst query = 'needle'\n"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	_, handler := Spec()
	out, err := handler(context.Background(), `{"root_path":"`+filepath.ToSlash(root)+`","query":"needle","max_results":5}`)
	if err != nil {
		t.Fatalf("handler failed: %v", err)
	}

	var payload struct {
		Count   int              `json:"count"`
		Matches []map[string]any `json:"matches"`
	}
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		t.Fatalf("unmarshal output: %v", err)
	}
	if payload.Count < 1 || len(payload.Matches) < 1 {
		t.Fatalf("expected matches, got %#v", payload)
	}
}
