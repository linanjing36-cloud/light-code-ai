// Package main 是 Hermes Agent Workbench 的 Wails v3 入口。
//
// 架构定位:
//
//	Wails/Go (本进程)  ──spawn──▶  Erlang ERTS (Agent-brains)
//	                                     │
//	                           TCP+JSON  │ RPC (panel_server)
//	                                     ▼
//	                               agent_fsm (ReAct 编排)
//	                                     │
//	                           Protobuf  │ IPC
//	                                     ▼
//	                               Eion-tools (Go/Eino)  ← 无状态执行
//
// 本进程是"哑终端": 只渲染 UI + 转发用户操作到 Erlang 大脑。
// LLM 推理与工具编排全在 Erlang 侧完成, Wails 不直接接触 LLM API。
package main

import (
	"embed"
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
)

// Wails 使用 Go 的 `embed` 包把前端文件嵌入到二进制中。
// frontend/dist 目录下所有文件都会被打包, 经 AssetFileServerFS 暴露给前端。
//go:embed all:frontend/dist
var assets embed.FS

func main() {
	// brain.Bridge 是 Erlang 子进程的生命周期管理者 (实现 Wails v3 Service 接口):
	//   - ServiceStartup: spawn erl + 等 panel_server 上线 (TCP 连接就绪)
	//   - ServiceShutdown: rpc init:stop 优雅退出
	bridge := brain.NewBridge()

	// HermesService 是暴露给前端 (TS) 的 RPC 对象:
	//   - StartSession / Send / BrainStatus / ApproveToolCall / ListTools
	//   - 内部全部走 bridge.Call → Erlang panel_server
	svc := NewHermesService(bridge)

	app := application.New(application.Options{
		Name:        "Hermes",
		Description: "Hermes Agent Workbench — Erlang/OTP orchestration + Wails UI",
		Services: []application.Service{
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
