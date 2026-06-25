//go:build !windows

package brain

import (
	"net"
	"time"
)

// dialPanel 在非 Windows 系统上通过 Unix Domain Socket 连接 panel_server。
// addr 格式: "/tmp/hermes-panel.sock" (由 panel_server 写入端口文件)。
// 注: panel_server 需同步支持 UDS listen (Task 5), 否则连接失败。
func dialPanel(addr string, timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout("unix", addr, timeout)
}
