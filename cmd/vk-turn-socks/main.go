// Command vk-turn-socks runs the VK TURN proxy engine WITHOUT any macOS
// Network Extension, exposing the tunnel as a local SOCKS5 (and optional HTTP)
// proxy you point Surge / any app at.
//
// It reuses the exact same engine as the iOS/macOS apps — pkg/proxy (VK
// credentials, TURN allocations, DTLS/SRTP/WRAP/WRAP-A transports, cred pool,
// auto-captcha) and pkg/turnbind (the WireGuard conn.Bind that routes packets
// through the TURN relay). The only difference is what terminates WireGuard:
// instead of a system TUN interface (which needs a Packet Tunnel Provider),
// this uses wireguard-go's userspace gVisor netstack. Traffic that enters the
// SOCKS5/HTTP listener is dialed from *inside* the tunnel, so DNS and TCP both
// egress through your VPS — exactly what you want behind Surge.
//
// Because there's no system extension and no cgo, it's a plain executable:
// build it with `go build`, run it, and set Surge's proxy to 127.0.0.1:1080.
//
// Limitations vs the full app:
//   - TCP only (SOCKS5 CONNECT + HTTP). No SOCKS5 UDP ASSOCIATE yet — for
//     most browsing that's fine; let Surge handle UDP/QUIC outside this proxy
//     or disable QUIC.
//   - No captcha WebView. The engine auto-solves VK captcha (PoW + slider) in
//     the common case; if VK forces an unsolvable captcha, bootstrap will fail
//     and you retry (or use a logged-in cookie via -cookie).
package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy"
	"github.com/cacggghp/vk-turn-proxy/pkg/turnbind"

	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// CLIConfig is the JSON config file schema. WireGuard keys are base64 (the
// form `wg genkey` emits and the app's Settings accept); they're converted to
// hex for the UAPI internally. In srtp-wrap-a mode the WireGuard block is
// ignored — the server provisions it via GETCONF.
type CLIConfig struct {
	VKLink                  string   `json:"vk_link"`
	PeerAddr                string   `json:"peer_addr"`
	Mode                    string   `json:"mode"` // legacy | srtp | srtp-wrap | srtp-wrap-a
	UseUDP                  bool     `json:"use_udp"`
	WrapKeyHex              string   `json:"wrap_key_hex,omitempty"`
	WrapAPassword           string   `json:"wrap_a_password,omitempty"`
	DeviceID                string   `json:"device_id,omitempty"`
	NumConns                int      `json:"num_conns,omitempty"`
	TurnServer              string   `json:"turn_server,omitempty"`
	TurnPort                string   `json:"turn_port,omitempty"`
	CredPoolCooldownSeconds int      `json:"cred_pool_cooldown_seconds,omitempty"`
	WireGuard               WGConfig `json:"wireguard"`
	SocksListen             string   `json:"socks_listen,omitempty"`
	HTTPListen              string   `json:"http_listen,omitempty"`
	// Cookie (VKAuth) mode: a logged-in VK "Cookie:" header ("remixsid=…; p=…").
	// When set, the engine uses ONLY the cookie cred path (no anonymous fallback),
	// which keeps working when VK disables anonymous call-join.
	CookieHeader string `json:"cookie_header,omitempty"`
}

type WGConfig struct {
	PrivateKey          string `json:"private_key"`     // base64 (wg genkey)
	PeerPublicKey       string `json:"peer_public_key"` // base64
	PresharedKey        string `json:"preshared_key,omitempty"`
	Address             string `json:"address"` // e.g. 192.168.102.3/24
	DNS                 string `json:"dns"`     // e.g. 1.1.1.1 (comma-separated allowed)
	MTU                 int    `json:"mtu,omitempty"`
	PersistentKeepalive int    `json:"persistent_keepalive,omitempty"`
}

func main() {
	cfgPath := flag.String("config", "config.json", "path to JSON config file")
	socksFlag := flag.String("socks", "", "SOCKS5 listen address (overrides config; e.g. 127.0.0.1:1080)")
	httpFlag := flag.String("http", "", "HTTP proxy listen address (overrides config; empty disables)")
	verbose := flag.Bool("v", false, "verbose WireGuard logging")
	flag.Parse()

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	if *socksFlag != "" {
		cfg.SocksListen = *socksFlag
	}
	if *httpFlag != "" {
		cfg.HTTPListen = *httpFlag
	}
	if cfg.SocksListen == "" {
		cfg.SocksListen = "127.0.0.1:1080"
	}
	if cfg.NumConns <= 0 {
		cfg.NumConns = 30
	}

	logLevel := device.LogLevelError
	if *verbose {
		logLevel = device.LogLevelVerbose
	}

	if err := run(cfg, logLevel); err != nil {
		log.Fatalf("fatal: %v", err)
	}
}

func loadConfig(path string) (*CLIConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c CLIConfig
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if c.VKLink == "" {
		return nil, errors.New("vk_link is required")
	}
	if c.PeerAddr == "" {
		return nil, errors.New("peer_addr is required")
	}
	return &c, nil
}

func run(cfg *CLIConfig, logLevel int) error {
	// Map the string mode to the engine's transport flags (same precedence as
	// the app: wrap-a > srtp > srtp-wrap > legacy).
	useSrtp, useWrap, useWrapA := false, false, false
	switch strings.ToLower(cfg.Mode) {
	case "", "srtp":
		useSrtp = true
	case "legacy":
		// all false
	case "srtp-wrap", "wrap":
		useWrap = true
	case "srtp-wrap-a", "wrap-a", "wrapa":
		useWrapA = true
	default:
		return fmt.Errorf("unknown mode %q (use legacy|srtp|srtp-wrap|srtp-wrap-a)", cfg.Mode)
	}

	var wrapKey []byte
	if useWrap {
		k, err := hex.DecodeString(strings.TrimSpace(cfg.WrapKeyHex))
		if err != nil || len(k) != 32 {
			return fmt.Errorf("wrap_key_hex must be 64 hex chars (32 bytes)")
		}
		wrapKey = k
	}
	if useWrapA && cfg.WrapAPassword == "" {
		return errors.New("wrap_a_password is required in srtp-wrap-a mode")
	}

	// Cookie (VKAuth) mode: push the logged-in cookie into the engine before
	// bootstrap; it then uses ONLY the cookie cred path.
	if cfg.CookieHeader != "" {
		proxy.SetVKCookieAuth(true, cfg.CookieHeader, []string{cfg.VKLink})
		log.Printf("VKAuth: using logged-in cookie path (no anonymous fallback)")
	}

	// Best-effort pre-resolution of VK API hosts, mirroring the app. On a
	// normal Mac the engine's own resolver works, but seeding IPs is cheap
	// insurance on restrictive networks.
	if ips := resolveVKHosts(); len(ips) > 0 {
		proxy.SetVKHostIPs(ips)
	}

	p := proxy.NewProxy(proxy.Config{
		PeerAddr:         cfg.PeerAddr,
		TurnServer:       cfg.TurnServer,
		TurnPort:         cfg.TurnPort,
		VKLink:           cfg.VKLink,
		UseDTLS:          true,
		UseUDP:           cfg.UseUDP,
		UseWrap:          useWrap,
		WrapKey:          wrapKey,
		UseSrtp:          useSrtp,
		UseWrapA:         useWrapA,
		WrapAPassword:    cfg.WrapAPassword,
		DeviceID:         cfg.DeviceID,
		NumConns:         cfg.NumConns,
		CredPoolCooldown: time.Duration(cfg.CredPoolCooldownSeconds) * time.Second,
	})

	// Resolve the WireGuard interface address + DNS + UAPI config. In WRAP-A
	// mode these come from the server (GETCONF) after bootstrap; otherwise from
	// the config file.
	var wgAddrs []netip.Addr
	var dnsAddrs []netip.Addr
	var uapi string
	mtu := 1280

	if useWrapA {
		// Bootstrap first (no device yet) so the server can mint our config.
		log.Printf("bootstrapping (WRAP-A GETCONF)…")
		go func() {
			if err := p.Start(); err != nil {
				log.Printf("proxy.Start: %v", err)
			}
		}()
		if err := p.WaitBootstrap(120 * time.Second); err != nil {
			return fmt.Errorf("bootstrap: %w", err)
		}
		prov, err := p.WaitWrapAProvision(30 * time.Second)
		if err != nil {
			return fmt.Errorf("wrap-a provision: %w", err)
		}
		uapi = prov.UAPIConfig()
		if prov.MTU > 0 {
			mtu = prov.MTU
		}
		a, err := parseCIDRAddr(prov.Address)
		if err != nil {
			return fmt.Errorf("provisioned address %q: %w", prov.Address, err)
		}
		wgAddrs = []netip.Addr{a}
		dnsAddrs = parseDNS(prov.DNS)
		log.Printf("WRAP-A provisioned: address=%s dns=%s mtu=%d", prov.Address, prov.DNS, mtu)
	} else {
		u, err := buildUAPI(cfg.WireGuard, cfg.PeerAddr)
		if err != nil {
			return err
		}
		uapi = u
		if cfg.WireGuard.MTU > 0 {
			mtu = cfg.WireGuard.MTU
		}
		a, err := parseCIDRAddr(cfg.WireGuard.Address)
		if err != nil {
			return fmt.Errorf("wireguard.address %q: %w", cfg.WireGuard.Address, err)
		}
		wgAddrs = []netip.Addr{a}
		dnsAddrs = parseDNS(cfg.WireGuard.DNS)
	}
	if len(dnsAddrs) == 0 {
		dnsAddrs = []netip.Addr{netip.MustParseAddr("1.1.1.1")}
	}

	// Userspace WireGuard: gVisor netstack TUN → we get a Net that dials from
	// inside the tunnel. This replaces the system TUN a Packet Tunnel Provider
	// would otherwise supply.
	tunDev, tnet, err := netstack.CreateNetTUN(wgAddrs, dnsAddrs, mtu)
	if err != nil {
		return fmt.Errorf("netstack CreateNetTUN: %w", err)
	}

	bind := turnbind.NewTURNBind(p)
	dev := device.NewDevice(tunDev, bind, device.NewLogger(logLevel, "(wg-turn) "))
	if err := dev.IpcSet(uapi); err != nil {
		return fmt.Errorf("wireguard IpcSet: %w", err)
	}
	if err := dev.Up(); err != nil { // triggers turnbind.Open → proxy.Start (idempotent)
		return fmt.Errorf("wireguard Up: %w", err)
	}

	// Wait for the first live TURN+DTLS session before accepting proxy clients,
	// so Surge doesn't see connection failures during the ~1-15s bootstrap.
	log.Printf("waiting for tunnel to come up…")
	if err := p.WaitBootstrap(120 * time.Second); err != nil {
		dev.Close()
		return fmt.Errorf("bootstrap: %w (VK captcha may be blocking; retry, or set cookie_header)", err)
	}
	if ip := p.TURNServerIP(); ip != "" {
		log.Printf("tunnel up via TURN relay %s", ip)
	} else {
		log.Printf("tunnel up")
	}

	dialer := &tunnelDialer{net: tnet}

	// SOCKS5 listener (primary — this is what you point Surge at).
	socksLn, err := net.Listen("tcp", cfg.SocksListen)
	if err != nil {
		dev.Close()
		return fmt.Errorf("listen socks %s: %w", cfg.SocksListen, err)
	}
	go serveSocks5(socksLn, dialer)
	log.Printf("SOCKS5 proxy listening on %s", cfg.SocksListen)

	// Optional HTTP proxy (CONNECT + plain forwarding).
	if cfg.HTTPListen != "" {
		httpLn, err := net.Listen("tcp", cfg.HTTPListen)
		if err != nil {
			dev.Close()
			return fmt.Errorf("listen http %s: %w", cfg.HTTPListen, err)
		}
		go serveHTTPProxy(httpLn, dialer)
		log.Printf("HTTP proxy listening on %s", cfg.HTTPListen)
	}

	// Periodic one-line stats so you can see it's alive and moving bytes.
	stop := make(chan struct{})
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				s := p.GetStats()
				log.Printf("stats: up=%ds conns=%d/%d pool=%d/%d/%d tx=%s rx=%s",
					s.TunnelUptimeSec, s.ActiveConns, s.TotalConns,
					s.CredPoolFilled, s.CredPoolWithCreds, s.CredPoolSize,
					humanBytes(s.TxBytes), humanBytes(s.RxBytes))
			}
		}
	}()

	// Block until Ctrl-C / SIGTERM, then tear down cleanly.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Printf("shutting down…")
	close(stop)
	_ = socksLn.Close()
	p.StopWithTimeout(2 * time.Second)
	dev.Close()
	return nil
}

// tunnelDialer dials TCP from inside the WireGuard tunnel via netstack.
type tunnelDialer struct{ net *netstack.Net }

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

	var ips []netip.Addr
	if a, err := netip.ParseAddr(host); err == nil {
		ips = []netip.Addr{a}
	} else {
		// Resolve through the tunnel's DNS (no DNS leak).
		hosts, err := t.net.LookupHost(host)
		if err != nil {
			return nil, fmt.Errorf("tunnel resolve %s: %w", host, err)
		}
		for _, h := range hosts {
			if a, e := netip.ParseAddr(h); e == nil {
				ips = append(ips, a)
			}
		}
		if len(ips) == 0 {
			return nil, fmt.Errorf("tunnel resolve %s: no addresses", host)
		}
	}

	var lastErr error
	for _, ip := range ips {
		c, err := t.net.DialContextTCPAddrPort(ctx, netip.AddrPortFrom(ip, uint16(port)))
		if err == nil {
			return c, nil
		}
		lastErr = err
	}
	return nil, fmt.Errorf("tunnel dial %s: %w", address, lastErr)
}

// ---------------- SOCKS5 (RFC 1928, CONNECT only, no auth) ----------------

func serveSocks5(ln net.Listener, dialer *tunnelDialer) {
	for {
		c, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		go handleSocks5(c, dialer)
	}
}

func handleSocks5(client net.Conn, dialer *tunnelDialer) {
	defer client.Close()
	br := bufio.NewReader(client)

	// Greeting: VER NMETHODS METHODS...
	ver, err := br.ReadByte()
	if err != nil || ver != 0x05 {
		return
	}
	nMethods, err := br.ReadByte()
	if err != nil {
		return
	}
	if _, err := io.CopyN(io.Discard, br, int64(nMethods)); err != nil {
		return
	}
	// Reply: no authentication required.
	if _, err := client.Write([]byte{0x05, 0x00}); err != nil {
		return
	}

	// Request: VER CMD RSV ATYP DST.ADDR DST.PORT
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(br, hdr); err != nil {
		return
	}
	if hdr[0] != 0x05 {
		return
	}
	cmd, atyp := hdr[1], hdr[3]
	if cmd != 0x01 { // only CONNECT
		socksReply(client, 0x07) // command not supported
		return
	}

	var host string
	switch atyp {
	case 0x01: // IPv4
		b := make([]byte, 4)
		if _, err := io.ReadFull(br, b); err != nil {
			return
		}
		host = net.IP(b).String()
	case 0x04: // IPv6
		b := make([]byte, 16)
		if _, err := io.ReadFull(br, b); err != nil {
			return
		}
		host = net.IP(b).String()
	case 0x03: // domain
		l, err := br.ReadByte()
		if err != nil {
			return
		}
		b := make([]byte, int(l))
		if _, err := io.ReadFull(br, b); err != nil {
			return
		}
		host = string(b)
	default:
		socksReply(client, 0x08) // address type not supported
		return
	}
	pb := make([]byte, 2)
	if _, err := io.ReadFull(br, pb); err != nil {
		return
	}
	port := int(pb[0])<<8 | int(pb[1])

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	upstream, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	cancel()
	if err != nil {
		socksReply(client, 0x05) // connection refused
		return
	}
	defer upstream.Close()

	// Success reply (bound addr 0.0.0.0:0 — clients ignore it for CONNECT).
	if _, err := client.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}

	pipe(client, upstream, br)
}

func socksReply(c net.Conn, code byte) {
	_, _ = c.Write([]byte{0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
}

// ---------------- HTTP proxy (CONNECT tunneling + plain forwarding) --------

func serveHTTPProxy(ln net.Listener, dialer *tunnelDialer) {
	transport := &http.Transport{
		DialContext:           dialer.DialContext,
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		ExpectContinueTimeout: time.Second,
	}
	srv := &http.Server{
		Handler: &httpProxyHandler{dialer: dialer, transport: transport},
	}
	_ = srv.Serve(ln)
}

type httpProxyHandler struct {
	dialer    *tunnelDialer
	transport *http.Transport
}

func (h *httpProxyHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		h.handleConnect(w, r)
		return
	}
	// Plain forward proxy: strip hop-by-hop headers, re-issue via the tunnel.
	r.RequestURI = ""
	removeHopByHop(r.Header)
	resp, err := h.transport.RoundTrip(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	removeHopByHop(resp.Header)
	for k, vs := range resp.Header {
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (h *httpProxyHandler) handleConnect(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	upstream, err := h.dialer.DialContext(ctx, "tcp", r.Host)
	cancel()
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		upstream.Close()
		http.Error(w, "hijacking not supported", http.StatusInternalServerError)
		return
	}
	client, _, err := hj.Hijack()
	if err != nil {
		upstream.Close()
		return
	}
	_, _ = client.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
	pipe(client, upstream, nil)
}

var hopByHop = []string{
	"Connection", "Proxy-Connection", "Keep-Alive", "Proxy-Authenticate",
	"Proxy-Authorization", "Te", "Trailer", "Transfer-Encoding", "Upgrade",
}

func removeHopByHop(h http.Header) {
	for _, k := range hopByHop {
		h.Del(k)
	}
}

// ---------------- helpers ----------------

// pipe copies bidirectionally between client and upstream and closes when
// either side ends. `clientReader`, if non-nil, is a buffered reader wrapping
// the client conn (SOCKS path) so any bytes already buffered aren't lost.
func pipe(client, upstream net.Conn, clientReader io.Reader) {
	if clientReader == nil {
		clientReader = client
	}
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(upstream, clientReader); done <- struct{}{} }()
	go func() { _, _ = io.Copy(client, upstream); done <- struct{}{} }()
	<-done
	_ = client.Close()
	_ = upstream.Close()
}

// buildUAPI renders the WireGuard UAPI config from base64 keys (converted to
// hex), a full-tunnel allowed_ip, and a throwaway endpoint (turnbind ignores
// it). Mirrors the app's buildUAPIConfig.
func buildUAPI(wg WGConfig, peerAddr string) (string, error) {
	priv, err := wgKeyHex(wg.PrivateKey)
	if err != nil {
		return "", fmt.Errorf("private_key: %w", err)
	}
	pub, err := wgKeyHex(wg.PeerPublicKey)
	if err != nil {
		return "", fmt.Errorf("peer_public_key: %w", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", priv)
	b.WriteString("replace_peers=true\n")
	fmt.Fprintf(&b, "public_key=%s\n", pub)
	fmt.Fprintf(&b, "endpoint=%s\n", peerAddr)
	ka := wg.PersistentKeepalive
	if ka <= 0 {
		ka = 25
	}
	fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", ka)
	b.WriteString("allowed_ip=0.0.0.0/0\n")
	b.WriteString("allowed_ip=::/0\n")
	if psk := strings.TrimSpace(wg.PresharedKey); psk != "" {
		p, err := wgKeyHex(psk)
		if err != nil {
			return "", fmt.Errorf("preshared_key: %w", err)
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", p)
	}
	return b.String(), nil
}

// wgKeyHex converts a base64 (standard or URL-safe, padded or not) 32-byte
// WireGuard key to hex.
func wgKeyHex(s string) (string, error) {
	t := strings.TrimSpace(s)
	if t == "" {
		return "", errors.New("empty key")
	}
	t = strings.ReplaceAll(t, "-", "+")
	t = strings.ReplaceAll(t, "_", "/")
	if m := len(t) % 4; m != 0 {
		t += strings.Repeat("=", 4-m)
	}
	raw, err := base64.StdEncoding.DecodeString(t)
	if err != nil {
		return "", fmt.Errorf("not valid base64")
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("decoded to %d bytes, expected 32", len(raw))
	}
	return hex.EncodeToString(raw), nil
}

// parseCIDRAddr extracts the host address from "ip/prefix" (or a bare "ip").
func parseCIDRAddr(s string) (netip.Addr, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return netip.Addr{}, errors.New("empty address")
	}
	if i := strings.IndexByte(s, '/'); i >= 0 {
		s = s[:i]
	}
	return netip.ParseAddr(s)
}

func parseDNS(s string) []netip.Addr {
	var out []netip.Addr
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if a, err := netip.ParseAddr(part); err == nil {
			out = append(out, a)
		}
	}
	return out
}

// resolveVKHosts pre-resolves the VK API hosts using the host resolver, so the
// engine can dial them by IP. Best-effort — returns an empty map on failure.
func resolveVKHosts() map[string][]string {
	hosts := []string{"login.vk.ru", "api.vk.ru", "id.vk.ru"}
	out := make(map[string][]string)
	r := &net.Resolver{}
	for _, h := range hosts {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		addrs, err := r.LookupHost(ctx, h)
		cancel()
		if err != nil {
			continue
		}
		var v4 []string
		for _, a := range addrs {
			if ip := net.ParseIP(a); ip != nil && ip.To4() != nil {
				v4 = append(v4, a)
			}
		}
		if len(v4) > 0 {
			out[h] = v4
		}
	}
	return out
}

func humanBytes(n int64) string {
	f := float64(n)
	switch {
	case f >= 1<<30:
		return fmt.Sprintf("%.1fGB", f/(1<<30))
	case f >= 1<<20:
		return fmt.Sprintf("%.1fMB", f/(1<<20))
	case f >= 1<<10:
		return fmt.Sprintf("%.1fKB", f/(1<<10))
	default:
		return strconv.FormatInt(n, 10) + "B"
	}
}
