package main

import (
	"bufio"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy"
)

// controlStopCh is closed by POST /stop so run() can shut down gracefully.
var (
	controlStopOnce sync.Once
	controlStopCh   = make(chan struct{})
)

func signalStop() { controlStopOnce.Do(func() { close(controlStopCh) }) }

// statusResponse is what GET /status returns — everything a front-end (the
// menu-bar agent) needs to render state and drive manual captcha.
type statusResponse struct {
	Running       bool   `json:"running"`
	UptimeSec     int64  `json:"uptime_sec"`
	ActiveConns   int32  `json:"active_conns"`
	TotalConns    int32  `json:"total_conns"`
	PoolFilled    int32  `json:"pool_filled"`
	PoolWithCreds int32  `json:"pool_with_creds"`
	PoolSize      int32  `json:"pool_size"`
	TxBytes       int64  `json:"tx_bytes"`
	RxBytes       int64  `json:"rx_bytes"`
	RelayIP       string `json:"relay_ip"`    // TURN relay IP — keep DIRECT in Surge
	CaptchaURL    string `json:"captcha_url"` // non-empty when a captcha is pending
	AuthError     string `json:"auth_error"`  // non-empty when a cookie auth was rejected
}

// startControlAPI starts the localhost control server. If token != "", every
// request must carry "Authorization: Bearer <token>". It binds to the given
// address (validated to be loopback) so it's never reachable off-box.
func startControlAPI(addr, token string, p *proxy.Proxy) error {
	if err := requireLoopback(addr); err != nil {
		return err
	}
	mux := http.NewServeMux()

	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		s := p.GetStats()
		resp := statusResponse{
			Running:       true,
			UptimeSec:     s.TunnelUptimeSec,
			ActiveConns:   s.ActiveConns,
			TotalConns:    s.TotalConns,
			PoolFilled:    s.CredPoolFilled,
			PoolWithCreds: s.CredPoolWithCreds,
			PoolSize:      s.CredPoolSize,
			TxBytes:       s.TxBytes,
			RxBytes:       s.RxBytes,
			RelayIP:       p.TURNServerIP(),
			CaptchaURL:    s.CaptchaImageURL,
			AuthError:     s.AuthError,
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})

	// POST /solve  — body {"token":"…"} or ?token=… — hand a manually-solved
	// captcha success_token to the engine.
	mux.HandleFunc("/solve", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		token := r.URL.Query().Get("token")
		if token == "" {
			var body struct {
				Token string `json:"token"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			token = body.Token
		}
		token = strings.TrimSpace(token)
		if token == "" {
			http.Error(w, "missing token", http.StatusBadRequest)
			return
		}
		log.Printf("control: captcha token received (%d chars) via /solve", len(token))
		p.SolveCaptcha(token)
		w.WriteHeader(http.StatusNoContent)
	})

	// POST /refresh_captcha — ask VK for a fresh captcha URL (in case the
	// pending one went stale while the user was getting to it). Returns the
	// fresh URL as text/plain.
	mux.HandleFunc("/refresh_captcha", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		_, _ = w.Write([]byte(p.RefreshCaptchaURL()))
	})

	// POST /stop — graceful shutdown, used by the menu-bar agent's Quit.
	mux.HandleFunc("/stop", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		w.WriteHeader(http.StatusNoContent)
		signalStop()
	})

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: bearerAuth(mux, token)}
	go func() { _ = srv.Serve(ln) }()
	return nil
}

// bearerAuth wraps a handler with an optional bearer-token check. Empty token
// disables auth (fine for a loopback-only server on a single-user Mac, but the
// menu-bar agent sets a random token as defense in depth).
func bearerAuth(next http.Handler, token string) http.Handler {
	if token == "" {
		return next
	}
	want := "Bearer " + token
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != want {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// requireLoopback rejects a control-listen address that isn't on loopback, so
// the control API (which can shut the tunnel down and accept captcha tokens)
// can never be exposed to the network.
func requireLoopback(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return &net.AddrError{Err: "control_listen must be a loopback address (127.0.0.1 / ::1)", Addr: addr}
	}
	return nil
}

// watchCaptchaStdin prompts on the terminal to paste a captcha success_token
// whenever the engine surfaces a pending captcha (‑captcha-stdin). This is the
// headless manual-captcha fallback; the menu-bar agent uses the WebView + the
// control /solve endpoint instead.
func watchCaptchaStdin(p *proxy.Proxy) {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	var lastURL string
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		url := p.GetStats().CaptchaImageURL
		if url == "" || url == lastURL {
			continue
		}
		lastURL = url
		log.Printf("\n*** CAPTCHA REQUIRED ***\nOpen this URL in a browser and solve it, then paste the success_token here:\n%s\n> ", url)
		if !scanner.Scan() {
			return
		}
		token := strings.TrimSpace(scanner.Text())
		if token != "" {
			p.SolveCaptcha(token)
			log.Printf("captcha token submitted (%d chars)", len(token))
		}
	}
}
