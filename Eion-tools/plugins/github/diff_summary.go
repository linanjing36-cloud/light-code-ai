package githubplugin

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/light-code-ai/eion-tools/internal/capability"
	"github.com/light-code-ai/eion-tools/internal/tool"
)

func DiffSummarySpec() (capability.Desc, tool.HandlerFunc) {
	return capability.Normalize(capability.Desc{
		Name:        "github_diff_summary",
		Kind:        capability.KindPlugin,
		Source:      "local",
		Version:     "v1",
		Description: "读取当前 git 仓库的 diff 统计、变更文件和概要信息，把大 diff 压缩成适合大模型消费的结构化摘要。",
		InputSchema: `{"type":"object","properties":{"root_path":{"type":"string","description":"可选，仓库根目录；为空时自动探测"},"base_ref":{"type":"string","description":"可选，diff 基准；为空时比较工作区"},"head_ref":{"type":"string","description":"可选，diff 终点；与 base_ref 配合使用"},"max_files":{"type":"integer","description":"最多返回多少个变更文件，默认 30"},"include_name_status":{"type":"boolean","description":"是否附带 name-status，默认 true"}}}`,
		Streaming:   false,
		RiskLevel:   capability.RiskSafe,
		CostHint:    capability.CostLow,
		Tags:        []string{"plugin", "github", "git", "diff", "token-saving"},
	}), diffSummaryHandler
}

func diffSummaryHandler(ctx context.Context, argumentsJSON string) (string, error) {
	var args struct {
		RootPath          string `json:"root_path"`
		BaseRef           string `json:"base_ref"`
		HeadRef           string `json:"head_ref"`
		MaxFiles          int    `json:"max_files"`
		IncludeNameStatus *bool  `json:"include_name_status"`
	}
	if argumentsJSON != "" {
		if err := json.Unmarshal([]byte(argumentsJSON), &args); err != nil {
			return "", fmt.Errorf("parse arguments: %w", err)
		}
	}
	if args.MaxFiles <= 0 {
		args.MaxFiles = 30
	}
	includeNameStatus := true
	if args.IncludeNameStatus != nil {
		includeNameStatus = *args.IncludeNameStatus
	}
	root, err := resolveGitRoot(args.RootPath)
	if err != nil {
		return "", err
	}
	rangeArgs := buildDiffRangeArgs(args.BaseRef, args.HeadRef)
	statOut, err := runGit(ctx, root, append([]string{"diff", "--stat"}, rangeArgs...)...)
	if err != nil {
		return "", err
	}
	shortStat, err := runGit(ctx, root, append([]string{"diff", "--shortstat"}, rangeArgs...)...)
	if err != nil {
		return "", err
	}
	files := []map[string]any{}
	if includeNameStatus {
		nameStatus, err := runGit(ctx, root, append([]string{"diff", "--name-status"}, rangeArgs...)...)
		if err == nil {
			files = parseNameStatus(nameStatus, args.MaxFiles)
		}
	}
	out, err := json.Marshal(map[string]any{
		"root_path":        filepath.ToSlash(root),
		"base_ref":         args.BaseRef,
		"head_ref":         args.HeadRef,
		"summary":          strings.TrimSpace(shortStat),
		"diff_stat":        splitNonEmpty(statOut),
		"changed_files":    files,
		"truncated_to":     args.MaxFiles,
		"include_worktree": args.BaseRef == "" && args.HeadRef == "",
	})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func buildDiffRangeArgs(baseRef, headRef string) []string {
	switch {
	case baseRef != "" && headRef != "":
		return []string{fmt.Sprintf("%s..%s", baseRef, headRef)}
	case baseRef != "":
		return []string{baseRef}
	default:
		return nil
	}
}

func parseNameStatus(raw string, maxFiles int) []map[string]any {
	lines := splitNonEmpty(raw)
	if maxFiles > 0 && len(lines) > maxFiles {
		lines = lines[:maxFiles]
	}
	out := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}
		item := map[string]any{
			"status": parts[0],
			"path":   filepath.ToSlash(parts[len(parts)-1]),
		}
		if len(parts) > 2 {
			item["from_path"] = filepath.ToSlash(parts[1])
		}
		out = append(out, item)
	}
	return out
}

func splitNonEmpty(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	lines := strings.Split(raw, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(strings.TrimRight(line, "\r"))
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}
