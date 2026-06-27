package githubplugin

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/light-code-ai/eion-tools/internal/capability"
	"github.com/light-code-ai/eion-tools/internal/tool"
)

func RepoOverviewSpec() (capability.Desc, tool.HandlerFunc) {
	return capability.Normalize(capability.Desc{
		Name:        "github_repo_overview",
		Kind:        capability.KindPlugin,
		Source:      "local",
		Version:     "v1",
		Description: "读取当前 git 仓库的分支、远端、最近提交和工作区状态，输出适合大模型消费的精简仓库概览。",
		InputSchema: `{"type":"object","properties":{"root_path":{"type":"string","description":"可选，仓库根目录；为空时自动探测"},"recent_commit_count":{"type":"integer","description":"最近提交条数，默认 5"}}}`,
		Streaming:   false,
		RiskLevel:   capability.RiskSafe,
		CostHint:    capability.CostLow,
		Tags:        []string{"plugin", "github", "git", "token-saving"},
	}), repoOverviewHandler
}

func repoOverviewHandler(ctx context.Context, argumentsJSON string) (string, error) {
	var args struct {
		RootPath          string `json:"root_path"`
		RecentCommitCount int    `json:"recent_commit_count"`
	}
	if argumentsJSON != "" {
		if err := json.Unmarshal([]byte(argumentsJSON), &args); err != nil {
			return "", fmt.Errorf("parse arguments: %w", err)
		}
	}
	if args.RecentCommitCount <= 0 {
		args.RecentCommitCount = 5
	}
	root, err := resolveGitRoot(args.RootPath)
	if err != nil {
		return "", err
	}
	branch, err := runGit(ctx, root, "rev-parse", "--abbrev-ref", "HEAD")
	if err != nil {
		return "", err
	}
	head, err := runGit(ctx, root, "rev-parse", "--short", "HEAD")
	if err != nil {
		return "", err
	}
	remoteURL, _ := runGit(ctx, root, "remote", "get-url", "origin")
	statusRaw, _ := runGit(ctx, root, "status", "--short")
	commitsRaw, _ := runGit(ctx, root, "log", fmt.Sprintf("-%d", args.RecentCommitCount), "--pretty=format:%h|%s")

	changedFiles := parseStatusLines(statusRaw)
	recentCommits := parseRecentCommits(commitsRaw)

	out, err := json.Marshal(map[string]any{
		"root_path":      filepath.ToSlash(root),
		"branch":         branch,
		"head":           head,
		"remote_origin":  remoteURL,
		"working_tree":   summarizeWorkingTree(changedFiles),
		"changed_files":  changedFiles,
		"recent_commits": recentCommits,
	})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func parseStatusLines(raw string) []map[string]any {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	lines := strings.Split(raw, "\n")
	out := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimRight(line, "\r")
		if len(strings.TrimSpace(line)) < 3 {
			continue
		}
		code := strings.TrimSpace(line[:2])
		path := strings.TrimSpace(line[2:])
		out = append(out, map[string]any{
			"status": code,
			"path":   filepath.ToSlash(path),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return fmt.Sprint(out[i]["path"]) < fmt.Sprint(out[j]["path"])
	})
	return out
}

func summarizeWorkingTree(files []map[string]any) map[string]any {
	summary := map[string]int{
		"modified":  0,
		"added":     0,
		"deleted":   0,
		"renamed":   0,
		"untracked": 0,
	}
	for _, item := range files {
		status := fmt.Sprint(item["status"])
		switch {
		case strings.Contains(status, "??"):
			summary["untracked"]++
		case strings.Contains(status, "R"):
			summary["renamed"]++
		case strings.Contains(status, "A"):
			summary["added"]++
		case strings.Contains(status, "D"):
			summary["deleted"]++
		default:
			summary["modified"]++
		}
	}
	return map[string]any{
		"total":    len(files),
		"by_state": summary,
	}
}

func parseRecentCommits(raw string) []map[string]any {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	lines := strings.Split(raw, "\n")
	out := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 2)
		if len(parts) != 2 {
			out = append(out, map[string]any{"sha": line, "message": ""})
			continue
		}
		out = append(out, map[string]any{
			"sha":     parts[0],
			"message": parts[1],
		})
	}
	return out
}
