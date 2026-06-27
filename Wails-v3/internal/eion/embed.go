// Package eion 在 Wails 进程内嵌入 Eion-tools TCP 服务。
//
// Erlang bridge_manager 仍通过 eion-tools.addr + gen_tcp 连接，协议不变。
package eion

import (
	"context"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"

	eionserver "github.com/light-code-ai/eion-tools/pkg/server"
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

// Server 返回已启动的 embedded 实例 (未启动时为 nil)。
func (e *Embedded) Server() *eionserver.Server {
	return e.srv
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

// EnsureHeadless 若 addr 文件指向的服务不可达则 embedded 启动，否则复用外部进程。
func EnsureHeadless(ctx context.Context, addrFile string) (stop func(), started bool, err error) {
	if addrFile == "" {
		addrFile = resolveAddrFile()
	}
	if addrReachable(addrFile) {
		log.Printf("[eion] reusing external eion-tools @ %s", readAddr(addrFile))
		return func() {}, false, nil
	}
	stop, err = StartHeadless(ctx, addrFile)
	return stop, true, err
}

func addrReachable(addrFile string) bool {
	addr := strings.TrimSpace(readAddr(addrFile))
	if addr == "" {
		return false
	}
	conn, err := net.DialTimeout("tcp", addr, 800*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func readAddr(addrFile string) string {
	b, err := os.ReadFile(addrFile)
	if err != nil {
		return ""
	}
	return string(b)
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
