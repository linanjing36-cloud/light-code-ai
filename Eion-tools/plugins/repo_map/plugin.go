package repomap

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"path/filepath"
	"sort"
	"strings"

	"github.com/light-code-ai/eion-tools/internal/capability"
	"github.com/light-code-ai/eion-tools/internal/tool"
	"github.com/light-code-ai/eion-tools/internal/workspace"
)

func Register(w *tool.Eino_Tool_Wrapper) {
	desc, handler := Spec()
	w.RegisterCapability(desc, handler)
}

func Spec() (capability.Desc, tool.HandlerFunc) {
	return capability.Normalize(capability.Desc{
		Name:        "repo_map",
		Kind:        capability.KindPlugin,
		Source:      "local",
		Version:     "v1",
		Description: "扫描当前工作区，输出仓库结构摘要、顶层模块和文件分布，帮助代码问答先缩小上下文范围。",
		InputSchema: `{"type":"object","properties":{"root_path":{"type":"string","description":"可选，仓库根目录；为空时自动探测"},"max_depth":{"type":"integer","description":"最大扫描深度，默认 3"},"max_entries":{"type":"integer","description":"最多返回的结构条目数，默认 60"},"include_files":{"type":"boolean","description":"是否返回文件条目，默认 false"}}}`,
		Streaming:   false,
		RiskLevel:   capability.RiskSafe,
		CostHint:    capability.CostLow,
		Tags:        []string{"plugin", "code", "workspace", "token-saving"},
	}), handler
}

func handler(ctx context.Context, argumentsJSON string) (string, error) {
	_ = ctx
	var args struct {
		RootPath     string `json:"root_path"`
		MaxDepth     int    `json:"max_depth"`
		MaxEntries   int    `json:"max_entries"`
		IncludeFiles bool   `json:"include_files"`
	}
	if argumentsJSON != "" {
		if err := json.Unmarshal([]byte(argumentsJSON), &args); err != nil {
			return "", fmt.Errorf("parse arguments: %w", err)
		}
	}
	root, err := workspace.ResolveRoot(args.RootPath)
	if err != nil {
		return "", err
	}
	if args.MaxDepth <= 0 {
		args.MaxDepth = 3
	}
	if args.MaxEntries <= 0 {
		args.MaxEntries = 60
	}
	entries := make([]map[string]any, 0, args.MaxEntries)
	topLevelDirs := make([]string, 0, 16)
	fileTypeCount := map[string]int{}
	totalDirs := 0
	totalFiles := 0

	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if path == root {
			return nil
		}
		rel := workspace.Rel(root, path)
		depth := depthOf(rel)
		if d.IsDir() {
			if workspace.ShouldSkipDir(d.Name()) {
				return filepath.SkipDir
			}
			totalDirs++
			if depth == 1 {
				topLevelDirs = append(topLevelDirs, rel)
			}
			if depth <= args.MaxDepth && len(entries) < args.MaxEntries {
				entries = append(entries, map[string]any{
					"path":  rel,
					"type":  "dir",
					"depth": depth,
				})
			}
			return nil
		}
		totalFiles++
		ext := filepath.Ext(rel)
		if ext == "" {
			ext = "<none>"
		}
		fileTypeCount[ext]++
		if !args.IncludeFiles || depth > args.MaxDepth || len(entries) >= args.MaxEntries {
			return nil
		}
		info, err := d.Info()
		size := int64(0)
		if err == nil {
			size = info.Size()
		}
		entries = append(entries, map[string]any{
			"path":  rel,
			"type":  "file",
			"depth": depth,
			"size":  size,
		})
		return nil
	})
	if err != nil {
		return "", err
	}

	sort.Strings(topLevelDirs)
	return marshal(map[string]any{
		"root_path":      root,
		"top_level_dirs": topLevelDirs,
		"summary": map[string]any{
			"total_dirs":  totalDirs,
			"total_files": totalFiles,
			"file_types":  topFileTypes(fileTypeCount, 12),
		},
		"entries": entries,
	})
}

func depthOf(rel string) int {
	if rel == "." || rel == "" {
		return 0
	}
	return len(split(rel))
}

func split(rel string) []string {
	parts := make([]string, 0, 8)
	for _, p := range strings.Split(filepath.ToSlash(rel), "/") {
		if p != "" {
			parts = append(parts, p)
		}
	}
	return parts
}

func topFileTypes(counts map[string]int, limit int) []map[string]any {
	type kv struct {
		Ext   string
		Count int
	}
	items := make([]kv, 0, len(counts))
	for ext, count := range counts {
		items = append(items, kv{Ext: ext, Count: count})
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].Count == items[j].Count {
			return items[i].Ext < items[j].Ext
		}
		return items[i].Count > items[j].Count
	})
	if limit > 0 && len(items) > limit {
		items = items[:limit]
	}
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		out = append(out, map[string]any{
			"ext":   item.Ext,
			"count": item.Count,
		})
	}
	return out
}

func marshal(v any) (string, error) {
	bin, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return string(bin), nil
}
