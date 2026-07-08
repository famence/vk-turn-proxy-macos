package main

import (
	"bufio"
	"context"
	"errors"
	"io"
	"log"
	"net"
	"strconv"
	"sync"
	"time"
)

// SOCKS5 (RFC 1928): no-auth, CONNECT (TCP) + UDP ASSOCIATE. BIND is not
// supported. All egress goes through the WireGuard tunnel via tunnelDialer,
// which enforces the anti-loop guards (dial.go).

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

	host, port, err := readSocksAddr(br, atyp)
	if err != nil {
		socksReply(client, 0x08) // address type not supported
		return
	}

	switch cmd {
	case 0x01: // CONNECT (TCP)
		handleConnect(client, br, dialer, host, port)
	case 0x03: // UDP ASSOCIATE
		handleUDPAssociate(client, br, dialer)
	default:
		socksReply(client, 0x07) // command not supported
	}
}

func handleConnect(client net.Conn, br *bufio.Reader, dialer *tunnelDialer, host string, port int) {
	if isLoopbackHost(host) {
		socksReply(client, 0x02) // connection not allowed (anti-loop)
		return
	}
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

// ---------------- UDP ASSOCIATE ----------------

// handleUDPAssociate binds a localhost UDP relay socket, tells the client its
// address, and relays datagrams to/from the tunnel until the TCP control
// connection closes (RFC 1928 §7 ties the association's lifetime to it).
func handleUDPAssociate(client net.Conn, br *bufio.Reader, dialer *tunnelDialer) {
	relay, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0})
	if err != nil {
		socksReply(client, 0x01) // general failure
		return
	}
	la := relay.LocalAddr().(*net.UDPAddr)

	// Reply: success + the relay address the client must send its UDP
	// datagrams to (127.0.0.1:relayPort).
	rep := []byte{0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, byte(la.Port >> 8), byte(la.Port)}
	if _, err := client.Write(rep); err != nil {
		relay.Close()
		return
	}

	assoc := &udpAssoc{relay: relay, dialer: dialer, targets: map[string]*udpTarget{}}
	go assoc.relayLoop()

	// Block until the client closes the TCP control connection, then tear the
	// association down. (Also drains any bytes the client sends on it.)
	_, _ = io.Copy(io.Discard, br)
	assoc.close()
}

type udpAssoc struct {
	relay  *net.UDPConn
	dialer *tunnelDialer

	mu         sync.Mutex
	clientAddr *net.UDPAddr // learned from the first datagram
	targets    map[string]*udpTarget
	closed     bool
}

type udpTarget struct {
	conn   net.Conn // tunnel UDP conn to the destination
	hdr    []byte   // cached SOCKS5 [ATYP DST.ADDR DST.PORT] for reply framing
	cancel context.CancelFunc
}

func (a *udpAssoc) relayLoop() {
	buf := make([]byte, 65535)
	for {
		n, src, err := a.relay.ReadFromUDP(buf)
		if err != nil {
			return
		}
		a.mu.Lock()
		a.clientAddr = src
		a.mu.Unlock()

		host, port, hdr, payload, ok := parseUDPRequest(buf[:n])
		if !ok || isLoopbackHost(host) {
			continue // drop malformed / fragmented / loopback-targeted
		}
		t := a.getOrDial(host, port, hdr)
		if t == nil {
			continue
		}
		_, _ = t.conn.Write(payload)
	}
}

func (a *udpAssoc) getOrDial(host string, port int, hdr []byte) *udpTarget {
	key := net.JoinHostPort(host, strconv.Itoa(port))
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return nil
	}
	if t, ok := a.targets[key]; ok {
		a.mu.Unlock()
		return t
	}
	a.mu.Unlock()

	ctx, cancel := context.WithCancel(context.Background())
	conn, err := a.dialer.DialUDP(ctx, host, port)
	if err != nil {
		cancel()
		log.Printf("socks udp: dial %s failed: %v", key, err)
		return nil
	}
	t := &udpTarget{conn: conn, hdr: append([]byte(nil), hdr...), cancel: cancel}

	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		cancel()
		conn.Close()
		return nil
	}
	a.targets[key] = t
	a.mu.Unlock()

	go a.targetReadLoop(key, t)
	return t
}

// targetReadLoop reads responses from the tunnel and forwards them back to the
// client, re-framed with the SOCKS5 UDP header. Idle targets (60s no traffic)
// are reaped.
func (a *udpAssoc) targetReadLoop(key string, t *udpTarget) {
	defer a.removeTarget(key, t)
	buf := make([]byte, 65535)
	for {
		_ = t.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		n, err := t.conn.Read(buf)
		if err != nil {
			return
		}
		a.mu.Lock()
		client := a.clientAddr
		closed := a.closed
		a.mu.Unlock()
		if closed || client == nil {
			return
		}
		// Reply datagram: RSV(2)=0 FRAG=0 [cached ATYP/ADDR/PORT] DATA
		out := make([]byte, 0, 3+len(t.hdr)+n)
		out = append(out, 0x00, 0x00, 0x00)
		out = append(out, t.hdr...)
		out = append(out, buf[:n]...)
		if _, err := a.relay.WriteToUDP(out, client); err != nil {
			return
		}
	}
}

func (a *udpAssoc) removeTarget(key string, t *udpTarget) {
	a.mu.Lock()
	if cur, ok := a.targets[key]; ok && cur == t {
		delete(a.targets, key)
	}
	a.mu.Unlock()
	t.cancel()
	_ = t.conn.Close()
}

func (a *udpAssoc) close() {
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return
	}
	a.closed = true
	targets := a.targets
	a.targets = map[string]*udpTarget{}
	a.mu.Unlock()

	_ = a.relay.Close()
	for _, t := range targets {
		t.cancel()
		_ = t.conn.Close()
	}
}

// parseUDPRequest parses a SOCKS5 UDP request datagram, returning the target
// host/port, the raw [ATYP DST.ADDR DST.PORT] header slice (for reply framing),
// and the payload. Fragmented datagrams (FRAG != 0) are rejected (ok=false).
func parseUDPRequest(b []byte) (host string, port int, hdr []byte, payload []byte, ok bool) {
	if len(b) < 4 {
		return "", 0, nil, nil, false
	}
	if b[2] != 0x00 { // FRAG — no reassembly support
		return "", 0, nil, nil, false
	}
	atyp := b[3]
	rest := b[4:]
	var addrLen int
	switch atyp {
	case 0x01: // IPv4
		if len(rest) < 4+2 {
			return "", 0, nil, nil, false
		}
		host = net.IP(rest[:4]).String()
		addrLen = 4
	case 0x04: // IPv6
		if len(rest) < 16+2 {
			return "", 0, nil, nil, false
		}
		host = net.IP(rest[:16]).String()
		addrLen = 16
	case 0x03: // domain
		if len(rest) < 1 {
			return "", 0, nil, nil, false
		}
		l := int(rest[0])
		if len(rest) < 1+l+2 {
			return "", 0, nil, nil, false
		}
		host = string(rest[1 : 1+l])
		addrLen = 1 + l
	default:
		return "", 0, nil, nil, false
	}
	port = int(rest[addrLen])<<8 | int(rest[addrLen+1])
	// hdr = ATYP + ADDR + PORT, i.e. b[3 : 4+addrLen+2]
	hdr = b[3 : 4+addrLen+2]
	payload = rest[addrLen+2:]
	return host, port, hdr, payload, true
}

// ---------------- shared helpers ----------------

func readSocksAddr(br *bufio.Reader, atyp byte) (host string, port int, err error) {
	switch atyp {
	case 0x01: // IPv4
		b := make([]byte, 4)
		if _, err = io.ReadFull(br, b); err != nil {
			return
		}
		host = net.IP(b).String()
	case 0x04: // IPv6
		b := make([]byte, 16)
		if _, err = io.ReadFull(br, b); err != nil {
			return
		}
		host = net.IP(b).String()
	case 0x03: // domain
		var l byte
		if l, err = br.ReadByte(); err != nil {
			return
		}
		b := make([]byte, int(l))
		if _, err = io.ReadFull(br, b); err != nil {
			return
		}
		host = string(b)
	default:
		return "", 0, errors.New("unsupported address type")
	}
	pb := make([]byte, 2)
	if _, err = io.ReadFull(br, pb); err != nil {
		return
	}
	port = int(pb[0])<<8 | int(pb[1])
	return host, port, nil
}

func socksReply(c net.Conn, code byte) {
	_, _ = c.Write([]byte{0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
}

// pipe copies bidirectionally between client and upstream and closes when
// either side ends. clientReader, if non-nil, is a buffered reader wrapping
// the client conn (so any bytes already buffered aren't lost).
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
