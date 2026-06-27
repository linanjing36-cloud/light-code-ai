//go:build !windows

package server

import "os"

func network() string { return "unix" }

func defaultListenAddr() string { return "/tmp/hermes-eion.sock" }

func prepareListenAddr(addr string) error {
	if network() == "unix" {
		_ = os.Remove(addr)
	}
	return nil
}
