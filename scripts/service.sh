#!/usr/bin/env bash
#
# service.sh — run vk-turn-socks as a background macOS service (launchd
# LaunchAgent), so you don't keep a terminal open. Starts at login, restarts on
# crash, logs to a file. Toggle it on/off with start/stop.
#
#   scripts/service.sh install     # build/copy binary, install + load the agent
#   scripts/service.sh start       # start (connect)
#   scripts/service.sh stop        # stop (disconnect) — stays installed
#   scripts/service.sh restart
#   scripts/service.sh status
#   scripts/service.sh logs        # tail the service log
#   scripts/service.sh uninstall   # unload + remove the agent
#
# Config lives at ~/Library/Application Support/VKTurnProxy/config.json (shared
# with the terminal CLI and the menu-bar agent). Fill it in first (see
# docs/config.md) — `install` seeds it from the example if missing.
#
# No Apple Developer account, no root: this is a per-user LaunchAgent.

set -euo pipefail

LABEL="com.vkturnproxy.socks"
SUPPORT_DIR="$HOME/Library/Application Support/VKTurnProxy"
BIN="$SUPPORT_DIR/vk-turn-socks"
CONFIG="$SUPPORT_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OUT_LOG="$SUPPORT_DIR/socks.out.log"
ERR_LOG="$SUPPORT_DIR/socks.err.log"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."

domain="gui/$(id -u)"
svc="$domain/$LABEL"

build_or_copy_binary() {
  mkdir -p "$SUPPORT_DIR"
  local arch; arch="$(uname -m)"
  local pre=""
  case "$arch" in
    arm64) pre="$REPO_ROOT/dist/vk-turn-socks-darwin-arm64" ;;
    x86_64) pre="$REPO_ROOT/dist/vk-turn-socks-darwin-amd64" ;;
  esac
  if [[ -n "$pre" && -f "$pre" ]]; then
    echo "==> Using prebuilt $pre"
    cp "$pre" "$BIN"
  elif command -v go >/dev/null 2>&1; then
    echo "==> Building vk-turn-socks with go…"
    ( cd "$REPO_ROOT" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$BIN" ./cmd/vk-turn-socks )
  else
    die "no prebuilt binary for $arch in dist/ and Go isn't installed to build one."
  fi
  chmod +x "$BIN"
}

seed_config() {
  if [[ ! -f "$CONFIG" ]]; then
    if [[ -f "$REPO_ROOT/cmd/vk-turn-socks/config.example.json" ]]; then
      cp "$REPO_ROOT/cmd/vk-turn-socks/config.example.json" "$CONFIG"
      echo "==> Seeded $CONFIG from the example — EDIT IT before starting (see docs/config.md)."
    else
      echo "WARNING: no config at $CONFIG and no example to copy. Create it before starting."
    fi
  fi
}

write_plist() {
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>-config</string>
        <string>$CONFIG</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$OUT_LOG</string>
    <key>StandardErrorPath</key><string>$ERR_LOG</string>
    <key>WorkingDirectory</key><string>$SUPPORT_DIR</string>
</dict>
</plist>
PLIST
}

load_agent() {
  # Modern launchctl (bootstrap) with a fallback to legacy load.
  launchctl bootstrap "$domain" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
}

unload_agent() {
  launchctl bootout "$svc" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
}

case "${1:-}" in
  install)
    build_or_copy_binary
    seed_config
    write_plist
    unload_agent
    load_agent
    echo "==> Installed + loaded $LABEL."
    echo "    Config: $CONFIG"
    echo "    Logs:   $OUT_LOG"
    echo "    Point Surge at SOCKS5 127.0.0.1:1080 (udp-relay=true)."
    ;;
  start)
    launchctl kickstart -k "$svc" 2>/dev/null || load_agent
    echo "==> started"
    ;;
  stop)
    # Stop the running process but keep the agent installed. `bootout` unloads;
    # to merely stop while keeping RunAtLoad, disable+kill then re-enable.
    launchctl kill SIGTERM "$svc" 2>/dev/null || true
    echo "==> stop signal sent (KeepAlive will NOT restart after an explicit kill via 'stop'; use 'uninstall' to remove, 'start' to run again)"
    ;;
  restart)
    launchctl kickstart -k "$svc" 2>/dev/null || { unload_agent; load_agent; }
    echo "==> restarted"
    ;;
  status)
    if launchctl print "$svc" >/dev/null 2>&1; then
      launchctl print "$svc" | grep -E "state|pid|program|last exit" || true
    else
      echo "not loaded"
    fi
    ;;
  logs)
    echo "==> tailing $OUT_LOG (Ctrl-C to stop)"
    touch "$OUT_LOG"
    tail -f "$OUT_LOG"
    ;;
  uninstall)
    unload_agent
    rm -f "$PLIST"
    echo "==> uninstalled $LABEL (binary + config left in $SUPPORT_DIR)"
    ;;
  *)
    echo "usage: $0 {install|start|stop|restart|status|logs|uninstall}" >&2
    exit 2
    ;;
esac
