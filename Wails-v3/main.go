// Package main 是 Hermes Agent Workbench 的 Wails v3 入口。
//
// 流量 (Phase A):
//
//	面板 UI → HermesService → Router → Erlang panel_server
//	Erlang → bridge_manager → panel exec → embedded Eion (进程内 LLM/工具)
//	panel stream → Bridge → Router.StreamHub → 面板
package main

import (
	"embed"
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
	"hermes/internal/eion"
	"hermes/internal/router"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	embeddedEion := eion.NewEmbedded()
	bridge := brain.NewBridge()
	rt := router.New(bridge, embeddedEion)
	svc := NewHermesService(rt)

	app := application.New(application.Options{
		Name:        "Hermes",
		Description: "Hermes Agent Workbench — Erlang/OTP orchestration + Wails UI",
		Services: []application.Service{
			application.NewService(embeddedEion),
			application.NewService(bridge),
			application.NewService(rt),
			application.NewService(svc),
		},
		Assets: application.AssetOptions{
			Handler: application.AssetFileServerFS(assets),
		},
		Mac: application.MacOptions{
			ApplicationShouldTerminateAfterLastWindowClosed: true,
		},
	})

	app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:  "Hermes — Agent Workbench",
		Width:  1280,
		Height: 820,
		Mac: application.MacWindow{
			InvisibleTitleBarHeight: 50,
			Backdrop:                application.MacBackdropTranslucent,
			TitleBar:                application.MacTitleBarHiddenInset,
		},
		BackgroundColour: application.NewRGB(20, 17, 13),
		URL:              "/",
	})

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}
