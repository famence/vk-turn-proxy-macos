//go:build darwin

package proxy

import (
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

// bindControl binds a socket to the named interface using IP_BOUND_IF /
// IPV6_BOUND_IF. On macOS this forces the socket to egress via that interface
// regardless of the routing table, so it bypasses a system-wide TUN (Surge
// Enhanced Mode) that would otherwise capture and loop the traffic.
func bindControl(ifName string) func(network, address string, c syscall.RawConn) error {
	return func(network, address string, c syscall.RawConn) error {
		iface, err := net.InterfaceByName(ifName)
		if err != nil {
			return err
		}
		var soErr error
		ctrlErr := c.Control(func(fd uintptr) {
			// Set both families; ignore the IPv6 error (v4-only sockets).
			soErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, iface.Index)
			_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, iface.Index)
		})
		if ctrlErr != nil {
			return ctrlErr
		}
		return soErr
	}
}
