package skill

import (
	"context"
	"fmt"
	"strings"

	"github.com/light-code-ai/eion-tools/internal/capability"
	"github.com/light-code-ai/eion-tools/internal/tool"
)

func RegisterBuiltins(w *tool.Eino_Tool_Wrapper) error {
	reg := NewRegistry()
	if err := reg.Register(workspaceBriefingSpec()); err != nil {
		return err
	}
	return reg.RegisterTo(w)
}

func workspaceBriefingSpec() Spec {
	return Spec{
		Desc: capability.Normalize(capability.Desc{
			Name:        "workspace_briefing",
			Kind:        capability.KindSkill,
			Source:      "builtin",
			Version:     "v1",
			Description: "组合执行 repo_map 与 code_search，输出仓库概览、问题相关命中与建议上下文，适合在正式问答前先压缩上下文。",
			InputSchema: `{"type":"object","properties":{"query":{"type":"string","description":"必填，要关注的主题或关键字"},"root_path":{"type":"string","description":"可选，工作区根目录"},"repo_max_depth":{"type":"integer","description":"repo_map 深度，默认 3"},"repo_max_entries":{"type":"integer","description":"repo_map 最大条目数，默认 30"},"search_max_results":{"type":"integer","description":"code_search 最大命中数，默认 8"},"path_contains":{"type":"string","description":"可选，仅搜索路径包含该片段的文件"}},"required":["query"]}`,
			Streaming:   false,
			RiskLevel:   capability.RiskSafe,
			CostHint:    capability.CostLow,
			Tags:        []string{"skill", "workspace", "token-saving", "composition"},
		}),
		Run: runWorkspaceBriefing,
	}
}

func runWorkspaceBriefing(ctx context.Context, rt *Runtime, arguments map[string]any) (map[string]any, error) {
	query := strings.TrimSpace(stringArg(arguments, "query"))
	if query == "" {
		return nil, fmt.Errorf("query is required")
	}
	rootPath := strings.TrimSpace(stringArg(arguments, "root_path"))

	repoMap, err := rt.Call(ctx, "repo_map", map[string]any{
		"root_path":     rootPath,
		"max_depth":     intArg(arguments, "repo_max_depth", 3),
		"max_entries":   intArg(arguments, "repo_max_entries", 30),
		"include_files": false,
	})
	if err != nil {
		return nil, fmt.Errorf("repo_map failed: %w", err)
	}

	codeSearch, err := rt.Call(ctx, "code_search", map[string]any{
		"query":          query,
		"root_path":      rootPath,
		"max_results":    intArg(arguments, "search_max_results", 8),
		"case_sensitive": false,
		"path_contains":  stringArg(arguments, "path_contains"),
	})
	if err != nil {
		return nil, fmt.Errorf("code_search failed: %w", err)
	}

	searchCount := countFromMap(codeSearch, "count")
	topDirs := len(sliceFromMap(repoMap, "top_level_dirs"))
	matches := sliceFromMap(codeSearch, "matches")

	return map[string]any{
		"query":     query,
		"root_path": firstNonEmpty(stringArg(repoMap, "root_path"), rootPath),
		"summary": map[string]any{
			"top_level_dir_count":   topDirs,
			"search_hit_count":      searchCount,
			"recommended_next_step": recommendedNextStep(searchCount, len(matches)),
		},
		"repo_map":     repoMap,
		"code_search":  codeSearch,
		"skill_source": "workspace_briefing",
	}, nil
}

func stringArg(m map[string]any, key string) string {
	v, _ := m[key]
	s, _ := v.(string)
	return s
}

func intArg(m map[string]any, key string, fallback int) int {
	v, ok := m[key]
	if !ok || v == nil {
		return fallback
	}
	switch n := v.(type) {
	case int:
		if n > 0 {
			return n
		}
	case int32:
		if n > 0 {
			return int(n)
		}
	case int64:
		if n > 0 {
			return int(n)
		}
	case float64:
		if n > 0 {
			return int(n)
		}
	}
	return fallback
}

func countFromMap(m map[string]any, key string) int {
	return intArg(m, key, 0)
}

func sliceFromMap(m map[string]any, key string) []any {
	v, ok := m[key]
	if !ok || v == nil {
		return nil
	}
	items, _ := v.([]any)
	return items
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func recommendedNextStep(searchCount, matchCount int) string {
	if searchCount == 0 || matchCount == 0 {
		return "refine_query"
	}
	if searchCount > 5 {
		return "focus_on_top_matches"
	}
	return "open_matched_files"
}
