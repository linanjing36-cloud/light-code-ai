// Package eion 在 Wails 进程内嵌入 Eion-tools TCP 服务。
//
// Erlang bridge_manager 仍通过 eion-tools.addr + gen_tcp 连接，协议不变。
package eion

import (
	"context"
	"log"
	"os"
	"path/filepath"

	"github.com/wailsapp/wails/v3/pkg/application"

	eionserver "github.com/light-code-ai/eion-tools/internal/server"
)

// Embedded 实现 Wails Service 生命周期，在 UI 启动前拉起 loopback listener。
type Embedded struct {
	srv *eionserver.Server
}

func NewEmbedded() *Embedded {
	return &Embedded{}
}

func (e *Embedded) ServiceStartup(ctx context.Context, _ application.ServiceOptions) error {
	if os.Getenv("HERMES_EMBED_EION") == "0" {
		log.Println("[eion] HERMES_EMBED_EION=0, 使用外部 eion-tools 进程")
		return nil
	}

	addrFile := resolveAddrFile()
	if err := os.MkdirAll(filepath.Dir(addrFile), 0o755); err != nil {
		return err
	}
	_ = os.Setenv("EION_TOOLS_ADDR_FILE", addrFile)

	srv, err := eionserver.New(eionserver.Options{AddrFile: addrFile})
	if err != nil {
		return err
	}
	addr, err := srv.Start(ctx)
	if err != nil {
		return err
	}
	e.srv = srv
	log.Printf("[eion] embedded eion-tools listening %s (addr_file=%s)", addr, addrFile)
	return nil
}

func (e *Embedded) ServiceShutdown() error {
	if e.srv == nil {
		return nil
	}
	err := e.srv.Stop()
	e.srv = nil
	log.Println("[eion] embedded eion-tools stopped")
	return err
}

// StartHeadless 供 CLI e2e 等无 Wails 场景在进程内启动 Eion-tools。
func StartHeadless(ctx context.Context, addrFile string) (stop func(), err error) {
	e := &Embedded{}
	if addrFile != "" {
		_ = os.Setenv("EION_TOOLS_ADDR_FILE", addrFile)
		_ = os.Setenv("HERMES_EION_ADDR_FILE", addrFile)
	}
	if err := e.ServiceStartup(ctx, application.ServiceOptions{}); err != nil {
		return nil, err
	}
	return func() { _ = e.ServiceShutdown() }, nil
}

func resolveAddrFile() string {
	if f := os.Getenv("EION_TOOLS_ADDR_FILE"); f != "" {
		return f
	}
	if f := os.Getenv("HERMES_EION_ADDR_FILE"); f != "" {
		return f
	}
	wd, _ := os.Getwd()
	for _, c := range []string{
		filepath.Join(wd, "..", "bin", "run", "eion-tools.addr"),
		filepath.Join(wd, "bin", "run", "eion-tools.addr"),
	} {
		if abs, err := filepath.Abs(c); err == nil {
			return abs
		}
	}
	return filepath.Join(wd, "..", "bin", "run", "eion-tools.addr")
}
