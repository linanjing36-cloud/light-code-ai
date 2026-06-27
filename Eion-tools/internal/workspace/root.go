package workspace

import (
	"os"
	"path/filepath"
	"strings"
)

var ignoredDirs = map[string]struct{}{
	".git":         {},
	".idea":        {},
	".vscode":      {},
	"node_modules": {},
	"_build":       {},
	"dist":         {},
	"coverage":     {},
}

func ResolveRoot(explicit string) (string, error) {
	if explicit != "" {
		return filepath.Abs(explicit)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	dir, err := filepath.Abs(cwd)
	if err != nil {
		return "", err
	}
	for {
		if looksLikeWorkspaceRoot(dir) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return filepath.Abs(cwd)
		}
		dir = parent
	}
}

func looksLikeWorkspaceRoot(dir string) bool {
	markers := []string{
		".git",
		"Agent-brains",
		"Eion-tools",
		"Wails-v3",
	}
	found := 0
	for _, marker := range markers {
		if _, err := os.Stat(filepath.Join(dir, marker)); err == nil {
			found++
		}
	}
	return found >= 2
}

func ShouldSkipDir(name string) bool {
	_, ok := ignoredDirs[strings.ToLower(name)]
	return ok
}

func Rel(root, target string) string {
	rel, err := filepath.Rel(root, target)
	if err != nil {
		return filepath.ToSlash(target)
	}
	return filepath.ToSlash(rel)
}
