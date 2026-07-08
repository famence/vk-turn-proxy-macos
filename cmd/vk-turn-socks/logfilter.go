package main

import (
	"bytes"
	"io"
	"log"
	"os"
)

// The engine is the same code as the iOS app, and it logs a LOT of
// high-frequency diagnostics (memstats every 10s, a 5s HEARTBEAT, per-conn
// conn-stats dumps, pion TURN refresh chatter, alloc-spike detection…) that
// exist to post-mortem a memory-constrained Network Extension. On a desktop
// CLI that's just noise, so by default we drop those lines and keep the
// meaningful ones (bootstrap, session/handshake progress, the periodic
// stats: summary, warnings, errors). Pass -v to see everything unfiltered.
var noisyMarkers = [][]byte{
	[]byte("proxy: memstats"),
	[]byte("proxy: HEARTBEAT"),
	[]byte("proxy: pathstats"),
	[]byte("proxy: conn-stats"),
	[]byte("proxy: ALLOC-SPIKE"),
	[]byte("proxy: heartbeat window"),
	[]byte("pion/turnc:"),
	[]byte(" cum)"),          // per-conn "conn N: TX … (… cum) RX …" rows
	[]byte("idle (combined"), // conn-stats summary row
}

// filterWriter drops whole log lines that match any noisy marker.
type filterWriter struct{ w io.Writer }

func (f filterWriter) Write(p []byte) (int, error) {
	for _, m := range noisyMarkers {
		if bytes.Contains(p, m) {
			return len(p), nil // silently drop; report success to the logger
		}
	}
	return f.w.Write(p)
}

// installQuietLogger routes the standard logger through the noise filter.
// Called unless -v is set.
func installQuietLogger() {
	log.SetOutput(filterWriter{w: os.Stderr})
}
