//go:build !windows

package main

import (
	"os"
	"syscall"
)

func sigForTerm() os.Signal { return syscall.SIGTERM }
