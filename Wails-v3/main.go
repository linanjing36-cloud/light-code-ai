// Package main 是 Hermes Agent Workbench 的 Wails v3 入口。
//
// 流量 (Phase A):
//
//	面板 UI → HermesService → Router → Erlang panel_server
//	Erlang → bridge_manager → panel exec → embedded Eion (进程内 LLM/工具)
//	panel stream → Bridge → Router.StreamHub → 面板
package main

import (
	"context"
	"embed"
	"io"
	"log"
	"os"
	"path/filepath"

	"github.com/wailsapp/wails/v3/pkg/application"

	"hermes/internal/brain"
	"hermes/internal/eion"
	"hermes/internal/router"
)

//go:embed all:frontend/dist
var assets embed.FS

func initFileLogger() func() {
	logDir := os.Getenv("HERMES_LOG_DIR")
	if logDir == "" {
		if exePath, err := os.Executable(); err == nil {
			logDir = filepath.Join(filepath.Dir(exePath), "log")
		}
	}
	if logDir == "" {
		return func() {}
	}
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		log.Printf("create log dir failed: %v", err)
		return func() {}
	}
	logFile := filepath.Join(logDir, "hermes-wails.log")
	f, err := os.OpenFile(logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("open log file failed: %v", err)
		return func() {}
	}
	log.SetFlags(log.LstdFlags | log.Lmicroseconds | log.Lshortfile)
	if os.Getenv("HERMES_LOG_STDOUT") == "1" {
		log.SetOutput(io.MultiWriter(f, os.Stdout))
	} else {
		log.SetOutput(f)
	}
	log.Printf("wails logger ready: %s", logFile)
	return func() {
		_ = f.Close()
	}
}

func main() {
	closeLog := initFileLogger()
	defer closeLog()

	embeddedEion := eion.NewEmbedded()
	bootstrapCtx, bootstrapCancel := context.WithCancel(context.Background())
	defer bootstrapCancel()
	if err := embeddedEion.ServiceStartup(bootstrapCtx, application.ServiceOptions{}); err != nil {
		log.Fatalf("embedded eion startup failed: %v", err)
	}
	defer func() {
		if err := embeddedEion.ServiceShutdown(); err != nil {
			log.Printf("embedded eion shutdown error: %v", err)
		}
	}()
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
