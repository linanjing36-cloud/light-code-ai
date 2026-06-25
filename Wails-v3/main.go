package main

import (
	"embed"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/mac"

	"hermes/internal/brain"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	// 启动 Erlang 编排大脑 (Agent-brains) 子进程。
	// Hermes 面板本身只做 UI 与桥接,所有 ReAct 编排由 Erlang 侧闭环。
	// Wails 不直接引入 Eion-tools —— 它只与 Erlang 对话,
	// Erlang 再通过 Protobuf 调用 Eion-tools (Go/Eino) 执行 LLM 推理与工具。
	brainBridge := brain.NewBridge()
	if err := brainBridge.Start(); err != nil {
		panic(err)
	}
	defer brainBridge.Stop()

	app := NewApp(brainBridge)

	err := wails.Run(&options.App{
		Title:  "Hermes — Agent Workbench",
		Width:  1280,
		Height: 820,
		MinWidth: 960,
		MinHeight: 640,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		BackgroundColour: &options.RGBA{R: 20, G: 17, B: 13, A: 1},
		OnStartup:       app.OnStartup,
		Mac: &mac.Options{
			TitleBar: mac.TitleBarHiddenInset(),
		},
		Bind: []interface{}{
			app,
		},
	})

	if err != nil {
		panic(err)
	}
}
