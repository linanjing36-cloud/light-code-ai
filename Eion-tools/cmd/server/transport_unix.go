//go:build !windows

package main

import (
	"os"
	"syscall"
)

// 非 Windows (Linux/macOS) 用 Unix Domain Socket。
// UDS 比 loopback TCP 快 2-3x (无 TCP/IP 栈开销), 且有文件系统权限控制。
// Go net.Listen("unix", path) 原生支持。
//
// network 返回 net.Listen 的网络类型。
func network() string { return "unix" }

// defaultAddr 返回默认监听地址 (UDS 路径)。
// 用 /tmp 下固定路径, 启动前会 unlink 旧 socket 文件。
func defaultAddr() string { return "/tmp/hermes-eion.sock" }

// sigForTerm 返回 SIGTERM (Unix 标准终止信号)。
func sigForTerm() os.Signal { return syscall.SIGTERM }
