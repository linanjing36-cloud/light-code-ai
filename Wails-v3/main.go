// Package main 是 Hermes Agent Workbench 的 Wails v3 入口。
//
// 架构定位 (Wails 进程内嵌 Eion-tools + 独立 Erlang 大脑):
//
//	Wails/Go (本进程)
//	  ├─ embedded Eion-tools (loopback TCP, 写 eion-tools.addr)
//	  └─ brain.Bridge ──TCP──▶  Erlang panel_server (Agent-brains, 独立进程)
//	                                    │
//	                              bridge_manager ──TCP──▶ 本进程内 Eion-tools
//
// 本进程是"哑终端": 只渲染 UI + 转发用户操作到 Erlang 大脑。
// LLM/工具执行在进程内 Eion-tools 完成; ReAct 编排在 Erlang 侧。
// 启动顺序: Wails(含 Eion) → Agent-brains (读 eion-tools.addr + 写 panel.addr)。
package main

import (
	"embed"
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
	"hermes/internal/eion"
)

// Wails 使用 Go 的 `embed` 包把前端文件嵌入到二进制中。
// frontend/dist 目录下所有文件都会被打包, 经 AssetFileServerFS 暴露给前端。
//go:embed all:frontend/dist
var assets embed.FS

func main() {
	// 嵌入 Eion-tools 须先于 Bridge 启动，以便 Agent-brains 启动时能读到 eion-tools.addr。
	embeddedEion := eion.NewEmbedded()
	bridge := brain.NewBridge()
	svc := NewHermesService(bridge)

	app := application.New(application.Options{
		Name:        "Hermes",
		Description: "Hermes Agent Workbench — Erlang/OTP orchestration + Wails UI",
		Services: []application.Service{
			application.NewService(embeddedEion),
			application.NewService(bridge),
			application.NewService(svc),
		},
		Assets: application.AssetOptions{
			Handler: application.AssetFileServerFS(assets),
		},
		Mac: application.MacOptions{
			ApplicationShouldTerminateAfterLastWindowClosed: true,
		},
	})

	// Atelier Terminal 主窗口: 暖色深底 + 藏红强调色 (致敬 Hermes 权杖)
	app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:  "Hermes — Agent Workbench",
		Width:  1280,
		Height: 820,
		Mac: application.MacWindow{
			InvisibleTitleBarHeight: 50,
			Backdrop:                application.MacBackdropTranslucent,
			TitleBar:                application.MacTitleBarHiddenInset,
		},
		BackgroundColour: application.NewRGB(20, 17, 13), // #14110D warm dark
		URL:              "/",
	})

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}
