// Command server 是 Eion-tools 独立进程入口（亦可嵌入 Wails，见 internal/server）。
package main

import (
	"context"
	"os"
	"os/signal"

	"github.com/light-code-ai/eion-tools/internal/logging"
	"github.com/light-code-ai/eion-tools/internal/server"
	"go.uber.org/zap"
)

func main() {
	defer func() { _ = logging.Logger.Sync() }()

	srv, err := server.New(server.Options{})
	if err != nil {
		logging.Logger.Fatal("init server", zap.Error(err))
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	addr, err := srv.Start(ctx)
	if err != nil {
		logging.Logger.Fatal("start server", zap.Error(err))
	}
	logging.Logger.Info("standalone eion-tools ready", zap.String("addr", addr))

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt)
	if sig := sigForTerm(); sig != nil {
		signal.Notify(sigCh, sig)
	}
	<-sigCh
	logging.Logger.Info("shutting down")
	_ = srv.Stop()
}
