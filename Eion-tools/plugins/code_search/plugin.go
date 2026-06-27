package codesearch

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/light-code-ai/eion-tools/internal/capability"
	"github.com/light-code-ai/eion-tools/internal/tool"
	"github.com/light-code-ai/eion-tools/internal/workspace"
)

var allowedExts = map[string]struct{}{
	".go":   {},
	".erl":  {},
	".hrl":  {},
	".ts":   {},
	".tsx":  {},
	".js":   {},
	".json": {},
	".proto": {},
	".md":   {},
	".txt":  {},
	".ps1":  {},
	".bat":  {},
	".cmd":  {},
	".sh":   {},
	".yml":  {},
	".yaml": {},
	".html": {},
	".css":  {},
}

func Register(w *tool.Eino_Tool_Wrapper) {
	desc, handler := Spec()
	w.RegisterCapability(desc, handler)
}

func Spec() (capability.Desc, tool.HandlerFunc) {
	return capability.Normalize(capability.Desc{
		Name:        "code_search",
		Kind:        capability.KindPlugin,
		Source:      "local",
		Version:     "v1",
		Description: "在当前工作区内按关键字扫描代码和文档，返回命中的文件、行号和片段，适合先缩小上下文再喂给大模型。",
		InputSchema: `{"type":"object","properties":{"query":{"type":"string","description":"必填，搜索关键字"},"root_path":{"type":"string","description":"可选，仓库根目录；为空时自动探测"},"max_results":{"type":"integer","description":"最多返回多少条命中，默认 20"},"case_sensitive":{"type":"boolean","description":"是否大小写敏感，默认 false"},"path_contains":{"type":"string","description":"可选，仅搜索路径包含该片段的文件"}},"required":["query"]}`,
		Streaming:   false,
		RiskLevel:   capability.RiskSafe,
		CostHint:    capability.CostLow,
		Tags:        []string{"plugin", "code", "search", "token-saving"},
	}), handler
}

func handler(ctx context.Context, argumentsJSON string) (string, error) {
	var args struct {
		Query         string `json:"query"`
		RootPath      string `json:"root_path"`
		MaxResults    int    `json:"max_results"`
		CaseSensitive bool   `json:"case_sensitive"`
		PathContains  string `json:"path_contains"`
	}
	if err := json.Unmarshal([]byte(argumentsJSON), &args); err != nil {
		return "", fmt.Errorf("parse arguments: %w", err)
	}
	if strings.TrimSpace(args.Query) == "" {
		return "", fmt.Errorf("query is required")
	}
	if args.MaxResults <= 0 {
		args.MaxResults = 20
	}
	root, err := workspace.ResolveRoot(args.RootPath)
	if err != nil {
		return "", err
	}
	query := args.Query
	if !args.CaseSensitive {
		query = strings.ToLower(query)
	}
	pathFilter := strings.ToLower(args.PathContains)
	matches := make([]map[string]any, 0, args.MaxResults)
	scannedFiles := 0

	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if d.IsDir() {
			if workspace.ShouldSkipDir(d.Name()) {
				return filepath.SkipDir
			}
			return nil
		}
		if !isAllowedFile(path) {
			return nil
		}
		rel := workspace.Rel(root, path)
		if pathFilter != "" && !strings.Contains(strings.ToLower(rel), pathFilter) {
			return nil
		}
		scannedFiles++
		fileMatches, err := searchFile(path, rel, query, args.CaseSensitive, args.MaxResults-len(matches))
		if err != nil {
			return nil
		}
		matches = append(matches, fileMatches...)
		if len(matches) >= args.MaxResults {
			return fs.SkipAll
		}
		return nil
	})
	if err != nil && err != fs.SkipAll && err != context.Canceled {
		return "", err
	}
	out, err := json.Marshal(map[string]any{
		"root_path":     root,
		"query":         args.Query,
		"count":         len(matches),
		"scanned_files": scannedFiles,
		"matches":       matches,
	})
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func isAllowedFile(path string) bool {
	if info, err := os.Stat(path); err != nil || info.Size() > 1024*1024 {
		return false
	}
	_, ok := allowedExts[strings.ToLower(filepath.Ext(path))]
	return ok
}

func searchFile(path, rel, query string, caseSensitive bool, budget int) ([]map[string]any, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	matches := make([]map[string]any, 0, minInt(4, budget))
	scanner := bufio.NewScanner(file)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		line := scanner.Text()
		haystack := line
		if !caseSensitive {
			haystack = strings.ToLower(line)
		}
		if !strings.Contains(haystack, query) {
			continue
		}
		matches = append(matches, map[string]any{
			"path":    rel,
			"line":    lineNo,
			"snippet": strings.TrimSpace(line),
		})
		if len(matches) >= budget {
			break
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return matches, nil
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
