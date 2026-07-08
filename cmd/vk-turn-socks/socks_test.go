package main

import (
	"bytes"
	"testing"
)

func TestParseUDPRequestIPv4(t *testing.T) {
	// RSV RSV FRAG ATYP=1 1.2.3.4 :53  DATA="hi"
	pkt := []byte{0x00, 0x00, 0x00, 0x01, 1, 2, 3, 4, 0x00, 53, 'h', 'i'}
	host, port, hdr, payload, ok := parseUDPRequest(pkt)
	if !ok {
		t.Fatal("expected ok")
	}
	if host != "1.2.3.4" || port != 53 {
		t.Fatalf("got %s:%d", host, port)
	}
	if !bytes.Equal(payload, []byte("hi")) {
		t.Fatalf("payload %q", payload)
	}
	// hdr must be ATYP + ADDR + PORT so it can be echoed back verbatim.
	if !bytes.Equal(hdr, []byte{0x01, 1, 2, 3, 4, 0x00, 53}) {
		t.Fatalf("hdr %v", hdr)
	}
}

func TestParseUDPRequestDomain(t *testing.T) {
	host := "example.com"
	pkt := []byte{0x00, 0x00, 0x00, 0x03, byte(len(host))}
	pkt = append(pkt, host...)
	pkt = append(pkt, 0x01, 0xBB) // port 443
	pkt = append(pkt, "data"...)
	gotHost, port, _, payload, ok := parseUDPRequest(pkt)
	if !ok || gotHost != host || port != 443 || string(payload) != "data" {
		t.Fatalf("got %q:%d ok=%v payload=%q", gotHost, port, ok, payload)
	}
}

func TestParseUDPRequestFragmentRejected(t *testing.T) {
	pkt := []byte{0x00, 0x00, 0x01, 0x01, 1, 2, 3, 4, 0x00, 53} // FRAG=1
	if _, _, _, _, ok := parseUDPRequest(pkt); ok {
		t.Fatal("fragmented datagram must be rejected")
	}
}

func TestParseUDPRequestTruncated(t *testing.T) {
	if _, _, _, _, ok := parseUDPRequest([]byte{0x00, 0x00, 0x00}); ok {
		t.Fatal("truncated datagram must be rejected")
	}
	// ATYP domain with length byte but missing address bytes.
	if _, _, _, _, ok := parseUDPRequest([]byte{0, 0, 0, 0x03, 10, 'a'}); ok {
		t.Fatal("short domain datagram must be rejected")
	}
}

func TestFilterWriterDropsNoise(t *testing.T) {
	var buf bytes.Buffer
	fw := filterWriter{w: &buf}
	drop := []string{
		"2026/07/08 10:31:53 proxy: memstats tick sys=17.6 MB\n",
		"2026/07/08 10:31:48 proxy: HEARTBEAT t+5s goroutines=240\n",
		"2026/07/08 10:33:44 pion/turnc: Refresh permissions successful\n",
		"  conn  2:  TX 2.1 KB/s (128.9 KB cum)  RX 24.6 KB/s (1.4 MB cum)\n",
		"  summary: 11 idle (combined <1KB in interval)\n",
	}
	for _, l := range drop {
		buf.Reset()
		n, _ := fw.Write([]byte(l))
		if n != len(l) || buf.Len() != 0 {
			t.Fatalf("expected %q to be dropped, wrote %d bytes to sink", l, buf.Len())
		}
	}
	keep := []string{
		"2026/07/08 10:31:45 tunnel up via TURN relay 95.163.34.140\n",
		"2026/07/08 10:31:44 vk: success via VK Calls captcha-free path\n",
		"2026/07/08 10:32:15 stats: up=32s conns=15/15 tx=1.1MB rx=8.6MB\n",
		"2026/07/08 09:55:20 proxy: [conn 0] SRTP TURN allocate quota error (486)\n",
		"WARNING: WireGuard got NO reply from the server\n",
	}
	for _, l := range keep {
		buf.Reset()
		fw.Write([]byte(l))
		if buf.String() != l {
			t.Fatalf("expected %q to pass through, got %q", l, buf.String())
		}
	}
}

func TestIsLoopbackHost(t *testing.T) {
	for _, h := range []string{"127.0.0.1", "::1", "localhost", "LocalHost"} {
		if !isLoopbackHost(h) {
			t.Fatalf("%q should be loopback", h)
		}
	}
	for _, h := range []string{"1.1.1.1", "example.com", "8.8.8.8"} {
		if isLoopbackHost(h) {
			t.Fatalf("%q should NOT be loopback", h)
		}
	}
}
