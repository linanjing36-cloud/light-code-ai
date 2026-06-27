//go:build windows

package main

import "os"

func sigForTerm() os.Signal { return nil }
