package main

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"

	"golang.zx2c4.com/wireguard/tun/netstack"
)

// tunnelDialer dials TCP/UDP from inside the WireGuard tunnel via netstack.
//
// Anti-loop guards (see docs/socks.md #4): the tunnel must only ever carry
// traffic OUT to the real internet via VK TURN. It must never dial back into
// this process or the local machine — otherwise a misconfigured client
// (e.g. Surge told to route 127.0.0.1 or the proxy's own port through us)
// could create an infinite loop. So we reject loopback / unspecified /
// link-local destinations and any of our own listen addresses outright.
type tunnelDialer struct {
	net       *netstack.Net
	selfHosts map[string]struct{} // "host:port" of our own listeners (socks/http/control)
}

func newTunnelDialer(tnet *netstack.Net, selfAddrs []string) *tunnelDialer {
	self := make(map[string]struct{})
	for _, a := range selfAddrs {
		if a == "" {
			continue
		}
		self[a] = struct{}{}
	}
	return &tunnelDialer{net: tnet, selfHosts: self}
}

// resolve turns host (IP or name) + port into candidate netip.AddrPorts,
// resolving names through the tunnel's DNS (no DNS leak). It applies the
// anti-loop guard and drops any disallowed address.
func (t *tunnelDialer) resolve(ctx context.Context, host string, port int) ([]netip.AddrPort, error) {
	if _, bad := t.selfHosts[net.JoinHostPort(host, strconv.Itoa(port))]; bad {
		return nil, fmt.Errorf("refusing to dial our own listener %s:%d (loop guard)", host, port)
	}
	var ips []netip.Addr
	if a, err := netip.ParseAddr(host); err == nil {
		ips = []netip.Addr{a}
	} else {
		hosts, err := t.net.LookupHost(host)
		if err != nil {
			return nil, fmt.Errorf("tunnel resolve %s: %w", host, err)
		}
		for _, h := range hosts {
			if a, e := netip.ParseAddr(h); e == nil {
				ips = append(ips, a)
			}
		}
	}
	var out []netip.AddrPort
	for _, ip := range ips {
		if ip.IsLoopback() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
			// Never tunnel to loopback/self/link-local — this is the hard
			// anti-loop guarantee. Such a destination through a VPN is never
			// legitimate and is the only way traffic could fold back on itself.
			continue
		}
		out = append(out, netip.AddrPortFrom(ip.Unmap(), uint16(port)))
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no routable address for %s:%d (loopback/self blocked)", host, port)
	}
	return out, nil
}

// DialContext dials TCP through the tunnel. Used by SOCKS5 CONNECT and the
// HTTP proxy.
func (t *tunnelDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	switch network {
	case "tcp", "tcp4", "tcp6":
	default:
		return nil, fmt.Errorf("tunnel dial: unsupported network %q", network)
	}
	host, portStr, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return nil, fmt.Errorf("bad port %q", portStr)
	}
	targets, err := t.resolve(ctx, host, port)
	if err != nil {
		return nil, err
	}
	var lastErr error
	for _, ap := range targets {
		c, err := t.net.DialContextTCPAddrPort(ctx, ap)
		if err == nil {
			return c, nil
		}
		lastErr = err
	}
	return nil, fmt.Errorf("tunnel dial %s: %w", address, lastErr)
}

// DialUDP dials a connected UDP socket through the tunnel to a single target
// (IP or hostname). Used by the SOCKS5 UDP relay.
func (t *tunnelDialer) DialUDP(ctx context.Context, host string, port int) (net.Conn, error) {
	targets, err := t.resolve(ctx, host, port)
	if err != nil {
		return nil, err
	}
	var lastErr error
	for _, ap := range targets {
		c, err := t.net.DialUDPAddrPort(netip.AddrPort{}, ap)
		if err == nil {
			return c, nil
		}
		lastErr = err
	}
	return nil, fmt.Errorf("tunnel udp dial %s:%d: %w", host, port, lastErr)
}

// isLoopbackHost reports whether the given host string is a loopback literal.
// Used to reject SOCKS requests that name localhost directly.
func isLoopbackHost(host string) bool {
	if a, err := netip.ParseAddr(host); err == nil {
		return a.IsLoopback()
	}
	h := strings.ToLower(host)
	return h == "localhost"
}
