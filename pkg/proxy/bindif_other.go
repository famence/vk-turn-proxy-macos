//go:build !darwin

package proxy

import "syscall"

// bindControl is a no-op on non-darwin platforms (IP_BOUND_IF is macOS-specific).
func bindControl(string) func(network, address string, c syscall.RawConn) error {
	return nil
}
