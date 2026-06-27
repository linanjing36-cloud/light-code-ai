package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
	"hermes/internal/eion"
	"hermes/internal/router"
)

type capabilityCase struct {
	Name            string
	ArgsJSON        string
	ExpectKind      string
	ExpectSource    string
	ExpectStreaming bool
	RequiredPaths   []string
}

type routerPanel struct{ r *router.Router }

func (p *routerPanel) Call(method string, args map[string]any) (any, error) {
	return p.r.CallPanel(method, args)
}

type panelCaller interface {
	Call(method string, args map[string]any) (any, error)
}

func main() {
	timeout := flag.Duration("timeout", 45*time.Second, "单次 capability 调用超时")
	rootPath := flag.String("root", "", "工作区根目录；为空时默认取 Wails-v3 的上一级目录")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	root := *rootPath
	if strings.TrimSpace(root) == "" {
		wd, err := os.Getwd()
		if err != nil {
			fail("getwd", err)
		}
		root = filepath.Clean(filepath.Join(wd, ".."))
	}
	root, err := filepath.Abs(root)
	if err != nil {
		fail("abs(root)", err)
	}
	if strings.TrimSpace(os.Getenv("HERMES_PANEL_E2E_QUIET_RUNTIME_LOGS")) == "1" {
		log.SetOutput(io.Discard)
	}

	cases := []capabilityCase{
		{
			Name:            "workspace_briefing",
			ArgsJSON:        mustJSON(map[string]any{"query": "panel_server", "root_path": filepath.ToSlash(root), "search_max_results": 6}),
			ExpectKind:      "skill",
			ExpectSource:    "builtin",
			ExpectStreaming: false,
			RequiredPaths: []string{
				"summary",
				"repo_map",
				"code_search",
				"skill_source",
			},
		},
		{
			Name:            "github_repo_overview",
			ArgsJSON:        mustJSON(map[string]any{"root_path": filepath.ToSlash(root), "recent_commit_count": 5}),
			ExpectKind:      "plugin",
			ExpectSource:    "local",
			ExpectStreaming: false,
			RequiredPaths: []string{
				"branch",
				"head",
				"working_tree",
				"recent_commits",
			},
		},
		{
			Name:            "github_diff_summary",
			ArgsJSON:        mustJSON(map[string]any{"root_path": filepath.ToSlash(root), "max_files": 20, "include_name_status": true}),
			ExpectKind:      "plugin",
			ExpectSource:    "local",
			ExpectStreaming: false,
			RequiredPaths: []string{
				"summary",
				"diff_stat",
				"changed_files",
				"include_worktree",
			},
		},
	}
	if strings.TrimSpace(os.Getenv("HERMES_MCP_SERVERS_JSON")) != "" {
		cases = append(cases, capabilityCase{
			Name:            "mcp_echo",
			ArgsJSON:        mustJSON(map[string]any{"text": "hello-from-mcp"}),
			ExpectKind:      "mcp",
			ExpectSource:    "mock-mcp",
			ExpectStreaming: false,
			RequiredPaths: []string{
				"structuredContent",
				"content",
			},
		})
	}

	b := brain.NewBridge()
	eionEmb := eion.NewEmbedded()
	rt := router.New(b, eionEmb)
	pc := &routerPanel{r: rt}

	fmt.Println("=== panel capability e2e ===")
	fmt.Printf("workspace_root=%s\n", filepath.ToSlash(root))

	_ = os.Setenv("HERMES_EXEC_VIA_PANEL", "1")

	if err := eionEmb.ServiceStartup(ctx, application.ServiceOptions{}); err != nil {
		fail("eion embed", err)
	}
	defer eionEmb.ServiceShutdown()

	if err := b.Start(ctx); err != nil {
		fail("bridge start", err)
	}
	defer b.Stop()

	if err := rt.ServiceStartup(ctx, application.ServiceOptions{}); err != nil {
		fail("router startup", err)
	}
	defer rt.ServiceShutdown()

	caps, err := listCapabilities(pc)
	if err != nil {
		fail("list_capabilities", err)
	}
	fmt.Printf("[list_capabilities] count=%d\n", len(caps))

	for _, item := range cases {
		if err := runCapabilityCase(pc, caps, item, *timeout); err != nil {
			fail(item.Name, err)
		}
	}

	fmt.Println("=== panel_capability_e2e OK ===")
}

func listCapabilities(pc panelCaller) ([]brain.CapabilityDesc, error) {
	out, err := pc.Call("list_capabilities", nil)
	if err != nil {
		return nil, err
	}
	caps, ok := out.([]brain.CapabilityDesc)
	if !ok {
		return nil, fmt.Errorf("unexpected list_capabilities type %T", out)
	}
	return caps, nil
}

func runCapabilityCase(pc panelCaller, caps []brain.CapabilityDesc, item capabilityCase, timeout time.Duration) error {
	desc, ok := findCapability(caps, item.Name)
	if !ok {
		return fmt.Errorf("capability not found in list_capabilities")
	}
	if desc.Kind != item.ExpectKind {
		return fmt.Errorf("kind=%q want %q", desc.Kind, item.ExpectKind)
	}
	if desc.Source != item.ExpectSource {
		return fmt.Errorf("source=%q want %q", desc.Source, item.ExpectSource)
	}
	if desc.Streaming != item.ExpectStreaming {
		return fmt.Errorf("streaming=%v want %v", desc.Streaming, item.ExpectStreaming)
	}

	fmt.Printf("\n[%s] kind=%s source=%s streaming=%v risk=%s cost=%s\n",
		item.Name, desc.Kind, desc.Source, desc.Streaming, desc.RiskLevel, desc.CostHint)
	fmt.Printf("[%s] args=%s\n", item.Name, item.ArgsJSON)

	out, err := pc.Call("debug_capability", map[string]any{
		"capability_name": item.Name,
		"arguments_json":  item.ArgsJSON,
		"timeout_ms":      int(timeout / time.Millisecond),
	})
	if err != nil {
		return err
	}
	result, ok := out.(brain.DebugCapabilityResult)
	if !ok {
		return fmt.Errorf("unexpected debug_capability type %T", out)
	}
	if strings.TrimSpace(result.Error) != "" {
		return fmt.Errorf("debug_capability error: %s", result.Error)
	}

	var payload map[string]any
	if err := json.Unmarshal([]byte(result.ResultJSON), &payload); err != nil {
		return fmt.Errorf("result json invalid: %w", err)
	}
	for _, path := range item.RequiredPaths {
		if _, ok := payload[path]; !ok {
			return fmt.Errorf("missing result field %q", path)
		}
	}

	pretty, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	fmt.Printf("[%s] result=%s\n", item.Name, string(pretty))
	return nil
}

func findCapability(caps []brain.CapabilityDesc, name string) (brain.CapabilityDesc, bool) {
	for _, item := range caps {
		if item.Name == name {
			return item, true
		}
	}
	return brain.CapabilityDesc{}, false
}

func mustJSON(v any) string {
	bin, err := json.Marshal(v)
	if err != nil {
		fail("marshal args", err)
	}
	return string(bin)
}

func fail(step string, err error) {
	fmt.Fprintf(os.Stderr, "FAIL [%s]: %v\n", step, err)
	os.Exit(1)
}
