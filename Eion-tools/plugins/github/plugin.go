package githubplugin

import (
	"context"

	"github.com/light-code-ai/eion-tools/internal/tool"
)

func Register(w *tool.Eino_Tool_Wrapper) {
	repoDesc, repoHandler := RepoOverviewSpec()
	w.RegisterCapability(repoDesc, repoHandler)

	diffDesc, diffHandler := DiffSummarySpec()
	w.RegisterCapability(diffDesc, diffHandler)
}

func toolCtx(ctx context.Context) context.Context {
	if ctx == nil {
		return context.Background()
	}
	return ctx
}
