package githubplugin

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestRepoOverviewHandler(t *testing.T) {
	root := initGitRepo(t)
	writeFile(t, filepath.Join(root, "README.md"), "# demo\n")
	runGitCmd(t, root, "add", ".")
	runGitCmd(t, root, "commit", "-m", "init repo")
	writeFile(t, filepath.Join(root, "README.md"), "# demo changed\n")

	out, err := repoOverviewHandler(context.Background(), `{"root_path":"`+filepath.ToSlash(root)+`","recent_commit_count":3}`)
	if err != nil {
		t.Fatalf("repo overview failed: %v", err)
	}
	var payload struct {
		Branch        string           `json:"branch"`
		ChangedFiles  []map[string]any `json:"changed_files"`
		RecentCommits []map[string]any `json:"recent_commits"`
	}
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		t.Fatalf("unmarshal overview: %v", err)
	}
	if payload.Branch == "" {
		t.Fatalf("expected branch")
	}
	if len(payload.ChangedFiles) == 0 {
		t.Fatalf("expected changed files")
	}
	if len(payload.RecentCommits) == 0 {
		t.Fatalf("expected recent commits")
	}
}

func TestDiffSummaryHandler(t *testing.T) {
	root := initGitRepo(t)
	writeFile(t, filepath.Join(root, "main.go"), "package main\n")
	runGitCmd(t, root, "add", ".")
	runGitCmd(t, root, "commit", "-m", "init repo")
	writeFile(t, filepath.Join(root, "main.go"), "package main\n\nfunc main() {}\n")

	out, err := diffSummaryHandler(context.Background(), `{"root_path":"`+filepath.ToSlash(root)+`","max_files":10}`)
	if err != nil {
		t.Fatalf("diff summary failed: %v", err)
	}
	var payload struct {
		Summary      string           `json:"summary"`
		DiffStat     []string         `json:"diff_stat"`
		ChangedFiles []map[string]any `json:"changed_files"`
	}
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		t.Fatalf("unmarshal diff summary: %v", err)
	}
	if payload.Summary == "" {
		t.Fatalf("expected summary")
	}
	if len(payload.DiffStat) == 0 {
		t.Fatalf("expected diff stat")
	}
	if len(payload.ChangedFiles) == 0 {
		t.Fatalf("expected changed files")
	}
}

func initGitRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	root := t.TempDir()
	runGitCmd(t, root, "init")
	runGitCmd(t, root, "config", "user.email", "test@example.com")
	runGitCmd(t, root, "config", "user.name", "tester")
	return root
}

func runGitCmd(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v failed: %v\n%s", args, err, string(out))
	}
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
}
