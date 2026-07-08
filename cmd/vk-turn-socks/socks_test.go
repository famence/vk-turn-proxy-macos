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
