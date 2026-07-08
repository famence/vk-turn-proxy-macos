package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// importConfig converts an existing iOS "connection link"
// (vkturnproxy://import?data=… or its bare base64 payload) OR a Full-Backup /
// connection JSON file into a vk-turn-socks config.json. This is the easy path
// for someone who already set up the iOS app: generate a link with
// `quick_link.py` (or Export a backup in the app) and feed it here instead of
// hand-writing the WireGuard keys.
//
// It writes the result to outPath and returns a short human summary.
func importConfig(src, outPath string) (string, error) {
	settings, err := loadSettings(src)
	if err != nil {
		return "", err
	}

	cfg := CLIConfig{
		VKLink:        firstNonEmpty(getStr(settings, "vkLink"), getStr(settings, "vk_link")),
		PeerAddr:      firstNonEmpty(getStr(settings, "peerAddress"), getStr(settings, "peer_addr")),
		UseUDP:        getBool(settings, "useUDP"),
		WrapKeyHex:    getStr(settings, "wrapKeyHex"),
		WrapAPassword: getStr(settings, "wrapAPassword"),
		NumConns:      getInt(settings, "numConnections"),
		SocksListen:   "127.0.0.1:1080",
		HTTPListen:    "127.0.0.1:1087",
		WireGuard: WGConfig{
			PrivateKey:          getStr(settings, "privateKey"),
			PeerPublicKey:       getStr(settings, "peerPublicKey"),
			PresharedKey:        getStr(settings, "presharedKey"),
			Address:             firstNonEmpty(getStr(settings, "tunnelAddress"), "192.168.102.3/24"),
			DNS:                 firstNonEmpty(getStr(settings, "dnsServers"), "1.1.1.1"),
			MTU:                 1280,
			PersistentKeepalive: 25,
		},
	}

	// Server mode: precedence useWrapA > useSrtp > useWrap, default srtp (the
	// app's production default), matching serverModeBinding on the iOS side.
	switch {
	case getBool(settings, "useWrapA"):
		cfg.Mode = "srtp-wrap-a"
	case getBool(settings, "useSrtp"):
		cfg.Mode = "srtp"
	case getBool(settings, "useWrap"):
		cfg.Mode = "srtp-wrap"
	case hasKey(settings, "useSrtp") || hasKey(settings, "useWrap") || hasKey(settings, "useWrapA"):
		cfg.Mode = "legacy" // all three present and false → legacy
	default:
		cfg.Mode = "srtp"
	}

	// turnServerOverride "IP:port" → turn_server / turn_port.
	if ov := getStr(settings, "turnServerOverride"); ov != "" {
		if i := strings.LastIndexByte(ov, ':'); i > 0 {
			cfg.TurnServer = ov[:i]
			cfg.TurnPort = ov[i+1:]
		}
	}

	if cfg.NumConns <= 0 {
		cfg.NumConns = 30
	}

	out, err := json.MarshalIndent(&cfg, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(outPath, append(out, '\n'), 0o600); err != nil {
		return "", fmt.Errorf("write %s: %w", outPath, err)
	}

	// Human summary + sanity warnings.
	var b strings.Builder
	fmt.Fprintf(&b, "wrote %s (mode=%s, server=%s)\n", outPath, cfg.Mode, cfg.PeerAddr)
	if cfg.Mode != "srtp-wrap-a" {
		if cfg.WireGuard.PrivateKey == "" {
			b.WriteString("WARNING: wireguard.private_key is empty — fill it in (see docs/config.md).\n")
		}
		if cfg.WireGuard.PeerPublicKey == "" {
			b.WriteString("WARNING: wireguard.peer_public_key is empty — fill it in (see docs/config.md).\n")
		}
	}
	b.WriteString("Run: ./vk-turn-socks -config " + outPath)
	return b.String(), nil
}

// loadSettings returns the flat settings map from either a connection link
// string or a JSON file (Full Backup / connection). Backup/link JSON nests the
// fields under "settings"; a bare settings object is also accepted.
func loadSettings(src string) (map[string]any, error) {
	trimmed := strings.TrimSpace(src)
	lower := strings.ToLower(trimmed)

	var raw []byte
	if strings.HasPrefix(lower, "vkturnproxy://") || (!strings.ContainsAny(trimmed, "/\\") && looksBase64(trimmed)) {
		// Connection link (URL or bare base64 payload).
		b64 := trimmed
		if strings.HasPrefix(lower, "vkturnproxy://") {
			if i := strings.Index(trimmed, "data="); i >= 0 {
				b64 = trimmed[i+len("data="):]
				if amp := strings.IndexByte(b64, '&'); amp >= 0 {
					b64 = b64[:amp]
				}
			} else {
				return nil, fmt.Errorf("connection link has no data= parameter")
			}
		}
		dec, err := decodeFlexibleBase64(b64)
		if err != nil {
			return nil, fmt.Errorf("decode connection link: %w", err)
		}
		raw = dec
	} else {
		// File path.
		data, err := os.ReadFile(trimmed)
		if err != nil {
			return nil, err
		}
		raw = data
	}

	var top map[string]any
	if err := json.Unmarshal(raw, &top); err != nil {
		return nil, fmt.Errorf("parse import JSON: %w", err)
	}
	if s, ok := top["settings"].(map[string]any); ok {
		return s, nil
	}
	return top, nil
}

func decodeFlexibleBase64(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	s = strings.ReplaceAll(s, "-", "+")
	s = strings.ReplaceAll(s, "_", "/")
	if m := len(s) % 4; m != 0 {
		s += strings.Repeat("=", 4-m)
	}
	return base64.StdEncoding.DecodeString(s)
}

func looksBase64(s string) bool {
	if len(s) < 16 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r >= '0' && r <= '9',
			r == '+', r == '/', r == '-', r == '_', r == '=':
		default:
			return false
		}
	}
	return true
}

// ---- typed getters over map[string]any ----

func hasKey(m map[string]any, k string) bool { _, ok := m[k]; return ok }

func getStr(m map[string]any, k string) string {
	if v, ok := m[k].(string); ok {
		return strings.TrimSpace(v)
	}
	return ""
}

func getBool(m map[string]any, k string) bool {
	b, _ := m[k].(bool)
	return b
}

func getInt(m map[string]any, k string) int {
	switch v := m[k].(type) {
	case float64:
		return int(v)
	case int:
		return v
	}
	return 0
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
