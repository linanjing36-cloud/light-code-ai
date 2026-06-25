//go:build windows

package main

import "os"

// Windows 用 TCP (loopback)。UDS 虽在 Win10+ 可用, 但 TCP 在 localhost
// 性能足够, 且与 Erlang 侧 gen_tcp 对齐 (Erlang UDS 需 OTP socket 模块, 较复杂)。
//
// network 返回 net.Listen 的网络类型。
func network() string { return "tcp" }

// defaultAddr 返回默认监听地址 (port 0 = ephemeral, 由 OS 分配)。
// Windows TCP 用 "127.0.0.1:0"。
func defaultAddr() string { return "127.0.0.1:0" }

// sigForTerm 返回终止信号; Windows 无 SIGTERM, 返回 nil (只用 os.Interrupt)。
func sigForTerm() os.Signal { return nil }
