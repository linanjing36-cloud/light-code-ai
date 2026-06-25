//go:build windows

package brain

import (
	"net"
	"time"
)

// dialPanel 在 Windows 上通过 TCP 连接 panel_server。
// addr 格式: "127.0.0.1:<port>" (由 panel_server 写入端口文件)。
func dialPanel(addr string, timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout("tcp", addr, timeout)
}
