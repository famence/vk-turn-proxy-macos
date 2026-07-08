package proxy

import "syscall"

// bindInterfaceName, when non-empty, is the physical network interface (e.g.
// "en0") that all outbound engine sockets are pinned to via IP_BOUND_IF. This
// bypasses a system-wide TUN that owns the default route (e.g. Surge Enhanced
// Mode), preventing the engine's own relay/API traffic from being captured and
// looped back into the local proxy. Empty = disabled (normal routing).
var bindInterfaceName string

// SetBindInterface sets the outbound-bind interface. Call before Start.
func SetBindInterface(name string) { bindInterfaceName = name }

// socketControl returns a net.Dialer/net.ListenConfig Control function that
// binds new sockets to bindInterfaceName, or nil when disabled or unsupported
// on this OS. Applied at every client-side outbound dial site.
func socketControl() func(network, address string, c syscall.RawConn) error {
	if bindInterfaceName == "" {
		return nil
	}
	return bindControl(bindInterfaceName)
}
