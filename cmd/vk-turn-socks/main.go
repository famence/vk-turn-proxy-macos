// Command vk-turn-socks runs the VK TURN proxy engine WITHOUT any macOS
// Network Extension, exposing the tunnel as a local SOCKS5 (TCP + UDP) and
// optional HTTP proxy you point Surge / any app at.
//
// It reuses the exact same engine as the iOS/macOS apps — pkg/proxy (VK
// credentials, TURN allocations, DTLS/SRTP/WRAP/WRAP-A transports, cred pool,
// auto-captcha) and pkg/turnbind (the WireGuard conn.Bind that routes packets
// through the TURN relay). The only difference is what terminates WireGuard:
// instead of a system TUN interface (which needs a Packet Tunnel Provider),
// this uses wireguard-go's userspace gVisor netstack. Traffic that enters the
// SOCKS5/HTTP listener is dialed from *inside* the tunnel, so DNS and TCP/UDP
// all egress through your VPS — exactly what you want behind Surge.
//
// Direct-egress guarantee (see docs/socks.md): the engine's OWN sockets — to
// the VK API and to the VK TURN relay carrying the WireGuard transport — use
// plain net.Dial on the OS default route. They never traverse this proxy or
// the tunnel. Additionally the tunnel dialer refuses loopback / self targets
// (dial.go), so app traffic can never fold back on itself.
//
// A local control API (‑control) lets a front-end (the menu-bar agent) read
// status, learn the current TURN relay IP, and hand back a manually-solved
// captcha token.
//
// Limitations vs the full app: no captcha WebView in the CLI itself (the
// engine auto-solves in the common case; for manual solving use the menu-bar
// agent, the control API /solve endpoint, or a logged-in cookie).
package main

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
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
	// ControlListen enables the local control API (status / solve captcha /
	// stop) used by the menu-bar agent. 127.0.0.1 only.
	ControlListen string `json:"control_listen,omitempty"`
	ControlToken  string `json:"control_token,omitempty"`
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
	importSrc := flag.String("import", "", "generate config.json from an iOS connection link (vkturnproxy://… or bare base64) or a Full-Backup/connection JSON file, then exit. Writes to -config.")
	socksFlag := flag.String("socks", "", "SOCKS5 listen address (overrides config; e.g. 127.0.0.1:1080)")
	httpFlag := flag.String("http", "", "HTTP proxy listen address (overrides config; empty disables)")
	controlFlag := flag.String("control", "", "control API listen address (overrides config; e.g. 127.0.0.1:1099)")
	controlTokenFlag := flag.String("control-token", "", "control API bearer token (overrides config)")
	captchaStdin := flag.Bool("captcha-stdin", false, "prompt on stdin to paste a captcha success_token when one is required")
	verbose := flag.Bool("v", false, "verbose WireGuard logging")
	flag.Parse()

	// -import: build a config.json from an existing iOS connection link / backup
	// and exit. The easiest path if you already set up the iOS app.
	if *importSrc != "" {
		summary, err := importConfig(*importSrc, *cfgPath)
		if err != nil {
			log.Fatalf("import: %v", err)
		}
		fmt.Println(summary)
		return
	}

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
	if *controlFlag != "" {
		cfg.ControlListen = *controlFlag
	}
	if *controlTokenFlag != "" {
		cfg.ControlToken = *controlTokenFlag
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
	} else {
		// Quiet the engine's iOS-extension diagnostic spam (memstats /
		// HEARTBEAT / pion refresh / per-conn dumps). -v shows everything.
		installQuietLogger()
	}

	if err := run(cfg, logLevel, *captchaStdin); err != nil {
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

func run(cfg *CLIConfig, logLevel int, captchaStdin bool) error {
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

	// Best-effort pre-resolution of VK API hosts, mirroring the app.
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
		// CaptchaSolver left nil → engine uses waitForCaptchaAnswer, which
		// surfaces the URL via GetStats().CaptchaImageURL and blocks until
		// p.SolveCaptcha() is called (by the control API or the stdin prompt).
	})

	// Resolve the WireGuard interface address + DNS + UAPI config. In WRAP-A
	// mode these come from the server (GETCONF) after bootstrap; otherwise from
	// the config file.
	var wgAddrs, dnsAddrs []netip.Addr
	var uapi string
	mtu := 1280

	// Start the local control API + optional stdin captcha prompt EARLY so a
	// captcha encountered during bootstrap can be solved (bootstrap blocks in
	// WaitBootstrap below). Both just observe p's stats and call p.SolveCaptcha.
	if cfg.ControlListen != "" {
		if err := startControlAPI(cfg.ControlListen, cfg.ControlToken, p); err != nil {
			return fmt.Errorf("control API: %w", err)
		}
		log.Printf("control API listening on %s", cfg.ControlListen)
	}
	if captchaStdin {
		go watchCaptchaStdin(p)
	}

	// Kick off the engine bootstrap (VK creds + TURN alloc + DTLS/SRTP) in the
	// background. Doing this explicitly — rather than letting dev.Up()'s
	// bind.Open trigger p.Start() synchronously — is important: p.Start()
	// blocks until the first conn is live, so if it's stuck retrying a failing
	// handshake, a synchronous trigger would hang dev.Up() and the SOCKS
	// listener would never start. Start() is idempotent, so dev.Up()'s later
	// call is a no-op.
	go func() {
		if err := p.Start(); err != nil {
			log.Printf("proxy.Start: %v", err)
		}
	}()

	if useWrapA {
		log.Printf("bootstrapping (WRAP-A GETCONF)…")
		if err := p.WaitBootstrap(120 * time.Second); err != nil {
			return fmt.Errorf("tunnel did not come up: %w\n\n%s", err, bootstrapHint(cfg))
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

	// Userspace WireGuard: gVisor netstack TUN → a Net that dials from inside
	// the tunnel. Replaces the system TUN a Packet Tunnel Provider would supply.
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

	log.Printf("waiting for tunnel to come up…")
	if err := p.WaitBootstrap(120 * time.Second); err != nil {
		dev.Close()
		return fmt.Errorf("tunnel did not come up: %w\n\n%s", err, bootstrapHint(cfg))
	}
	if ip := p.TURNServerIP(); ip != "" {
		// Print the relay IP prominently: to keep egress DIRECT even if you run
		// Surge in enhanced (system-wide TUN) mode, add a rule sending this IP
		// DIRECT — see docs/socks.md #4.
		log.Printf("tunnel up via TURN relay %s — keep it DIRECT in Surge (IP-CIDR,%s/32,DIRECT)", ip, ip)
	} else {
		log.Printf("tunnel up")
	}

	// Watch for the "handshake sent, nothing comes back" symptom (WireGuard
	// key/peer mismatch) and warn once — the transport can be fully up while
	// WG stays silent, which otherwise looks like a mysterious "no internet".
	go warnIfNoRx(p)

	// Anti-loop: the tunnel dialer must never dial our own listeners or
	// loopback. Register every local listener as forbidden.
	dialer := newTunnelDialer(tnet, []string{cfg.SocksListen, cfg.HTTPListen, cfg.ControlListen})

	socksLn, err := net.Listen("tcp", cfg.SocksListen)
	if err != nil {
		dev.Close()
		return fmt.Errorf("listen socks %s: %w", cfg.SocksListen, err)
	}
	go serveSocks5(socksLn, dialer)
	log.Printf("SOCKS5 proxy (TCP + UDP) listening on %s", cfg.SocksListen)

	if cfg.HTTPListen != "" {
		httpLn, err := net.Listen("tcp", cfg.HTTPListen)
		if err != nil {
			dev.Close()
			return fmt.Errorf("listen http %s: %w", cfg.HTTPListen, err)
		}
		go serveHTTPProxy(httpLn, dialer)
		log.Printf("HTTP proxy listening on %s", cfg.HTTPListen)
	}

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

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-sig:
	case <-controlStopCh: // POST /stop from the menu-bar agent
	}
	log.Printf("shutting down…")
	close(stop)
	_ = socksLn.Close()
	p.StopWithTimeout(2 * time.Second)
	dev.Close()
	return nil
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
		pk, err := wgKeyHex(psk)
		if err != nil {
			return "", fmt.Errorf("preshared_key: %w", err)
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", pk)
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

// bootstrapHint returns an actionable message for a bootstrap timeout. By this
// point VK auth + the TURN allocation have (almost always) succeeded — the
// failure is the DTLS/SRTP handshake to YOUR server *through* the relay timing
// out, which means packets reach the VK relay but your server behind it never
// completes the handshake. That's a server / peer_addr / mode problem, not a
// SOCKS/Surge one.
func bootstrapHint(cfg *CLIConfig) string {
	mode := cfg.Mode
	if mode == "" {
		mode = "srtp"
	}
	return "The tunnel's handshake to your server timed out (VK auth + TURN relay were fine,\n" +
		"but the DTLS/SRTP handshake to peer_addr never completed). Check, in order:\n" +
		"  1. mode — must match how your server is running. mode=" + mode + " needs the\n" +
		"     server started with -srtp; a legacy/WRAP/WRAP-A server (or SRTP on a\n" +
		"     different port) fails exactly like this.\n" +
		"  2. peer_addr=" + cfg.PeerAddr + " — must be your vk-turn-proxy server's -listen\n" +
		"     IP:port (the SRTP listener), NOT the WireGuard port and NOT the TURN relay.\n" +
		"  3. The server must be running and reachable from VK's relay; the firewall must\n" +
		"     allow inbound to that IP:port.\n" +
		"  4. Since your iOS app works with the same server, the surest fix is to copy its\n" +
		"     exact settings: in the app make a connection link (or Export Full Backup) and\n" +
		"     run  ./vk-turn-socks -import '<link-or-file>' -config config.json  (see docs/config.md).\n" +
		"If VK forces an unsolvable captcha instead, use -captcha-stdin, the menu-bar agent,\n" +
		"or set cookie_header."
}

// warnIfNoRx detects the "WireGuard handshake unanswered" state: the SRTP+TURN
// transport is up and WireGuard keeps sending 148-byte handshake initiations
// (tx climbs), but the server never replies (rx stays 0), so the tunnel goes
// "stale" and reconnects on a loop. That's almost always a WireGuard key/peer
// mismatch on the server side (the server silently drops handshakes from an
// unknown public key). We warn once so this doesn't look like a generic
// "no internet". Returns as soon as any bytes are received (all good).
func warnIfNoRx(p *proxy.Proxy) {
	deadline := time.Now().Add(25 * time.Second)
	t := time.NewTicker(3 * time.Second)
	defer t.Stop()
	warned := false
	for range t.C {
		s := p.GetStats()
		if s.RxBytes > 0 {
			return // handshake completed, traffic flowing
		}
		// Fire once the tunnel is clearly up-but-silent: rx stays 0 while
		// either WG is sending handshakes (tx>0) or the tunnel keeps going
		// stale and reconnecting (reconnects>0, the churn seen with many
		// conns). Both mean the server isn't answering WireGuard.
		if !warned && time.Now().After(deadline) && (s.TxBytes > 0 || s.Reconnects > 0) {
			warned = true
			log.Printf("WARNING: the SRTP+TURN transport to your server is UP, but WireGuard gets NO\n" +
				"reply (rx=0, sessions go stale and reconnect on a loop). The 486 quota errors and\n" +
				"climbing goroutines/memory are just fallout from that reconnect storm — fix the\n" +
				"WireGuard side and they stop. This is a WireGuard key/address mismatch:\n" +
				"  • wireguard.peer_public_key must be the WG SERVER's public key — NOT the peer's.\n" +
				"    In 3x-ui this is the INBOUND's public key (the WireGuard inbound itself), shown\n" +
				"    at the inbound level; the per-peer public key is a DIFFERENT value and is the\n" +
				"    #1 mistake here.\n" +
				"  • wireguard.private_key must be THIS peer's private key, and that peer's AllowedIPs\n" +
				"    in 3x-ui must cover wireguard.address (your tunnel IP, e.g. 192.168.102.7/32).\n" +
				"  • the vk-turn-proxy server's -connect must point at the 3x-ui WireGuard inbound's\n" +
				"    listen port (it does for your working iOS setup — use the SAME inbound).\n" +
				"  • don't run iOS + this Mac at once with the SAME key/IP — give each its own peer.\n" +
				"  • fastest check: turn the iOS client OFF and -import its exact working config\n" +
				"    (its key is already accepted by the server). See docs/config.md.")
		}
	}
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
		return fmt.Sprintf("%dB", n)
	}
}
