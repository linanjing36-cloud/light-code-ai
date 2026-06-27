package repomap

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestRepoMapHandler(t *testing.T) {
	root := t.TempDir()
	mustMkdirAll(t, filepath.Join(root, "Agent-brains", "src"))
	mustMkdirAll(t, filepath.Join(root, "Wails-v3", "frontend"))
	mustWriteFile(t, filepath.Join(root, "README.md"), "# demo")
	mustWriteFile(t, filepath.Join(root, "Agent-brains", "src", "main.erl"), "-module(main).")

	_, handler := Spec()
	out, err := handler(context.Background(), `{"root_path":"`+filepath.ToSlash(root)+`","max_depth":2,"max_entries":10,"include_files":true}`)
	if err != nil {
		t.Fatalf("handler failed: %v", err)
	}

	var payload struct {
		RootPath     string           `json:"root_path"`
		TopLevelDirs []string         `json:"top_level_dirs"`
		Entries      []map[string]any `json:"entries"`
	}
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		t.Fatalf("unmarshal output: %v", err)
	}
	if payload.RootPath == "" {
		t.Fatalf("expected root_path")
	}
	if len(payload.TopLevelDirs) == 0 {
		t.Fatalf("expected top_level_dirs")
	}
	if len(payload.Entries) == 0 {
		t.Fatalf("expected entries")
	}
}

func mustMkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
}

func mustWriteFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
