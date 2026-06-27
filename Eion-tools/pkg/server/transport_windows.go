//go:build windows

package server

func network() string { return "tcp" }

func defaultListenAddr() string { return "127.0.0.1:0" }

func prepareListenAddr(addr string) error { return nil }
