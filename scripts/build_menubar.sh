#!/usr/bin/env bash
#
# build_menubar.sh — build the VK Turn Proxy menu-bar agent (.app) on a Mac.
#
# The agent is an ordinary utility app (no Network Extension, no system
# extension, no Apple Developer account required to run locally). It bundles the
# pure-Go `vk-turn-socks` engine as a subprocess and drives it via a localhost
# control API, popping a WebView when a captcha needs solving by hand.
#
# Prerequisites (macOS):
#   - macOS 13+ and Xcode command-line tools (xcode-select --install)
#   - Xcode 16.2+ (for xcodebuild)
#   - Go 1.25.5+            (brew install go)
#   - xcodegen              (brew install xcodegen)
#
# Usage:
#   scripts/build_menubar.sh                 # ad-hoc signed, for local use
#   TEAM_ID=ABCDE12345 scripts/build_menubar.sh   # Developer-ID signed
#
# Result: build/DerivedData/Build/Products/Release/VK Turn Proxy Agent.app

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: run this on macOS." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

for tool in go xcodegen xcodebuild lipo; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not found." >&2; exit 1; }
done

RES_DIR="VKTurnMenuBar/VKTurnMenuBar/Resources"
mkdir -p "$RES_DIR"

echo "==> [1/4] Building universal vk-turn-socks (arm64 + x86_64, pure Go)…"
GOFLAGS=-mod=mod GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "$RES_DIR/vk-turn-socks-arm64" ./cmd/vk-turn-socks
GOFLAGS=-mod=mod GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "$RES_DIR/vk-turn-socks-amd64" ./cmd/vk-turn-socks
lipo -create "$RES_DIR/vk-turn-socks-arm64" "$RES_DIR/vk-turn-socks-amd64" -output "$RES_DIR/vk-turn-socks"
rm -f "$RES_DIR/vk-turn-socks-arm64" "$RES_DIR/vk-turn-socks-amd64"
chmod +x "$RES_DIR/vk-turn-socks"

echo "==> [2/4] Ensuring bundled config.example.json is current…"
cp cmd/vk-turn-socks/config.example.json "$RES_DIR/config.example.json"

echo "==> [3/4] Generating Xcode project…"
( cd VKTurnMenuBar && xcodegen generate )

echo "==> [4/4] Building the app (universal arm64 + x86_64)…"
DERIVED="$REPO_ROOT/build/DerivedData"
XCARGS=(
  -project VKTurnMenuBar/VKTurnMenuBar.xcodeproj
  -scheme VKTurnMenuBar
  -configuration Release
  -derivedDataPath "$DERIVED"
  # Universal app so ONE download runs on both Apple Silicon and Intel.
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
)
if [[ -n "${TEAM_ID:-}" ]]; then
  XCARGS+=( DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates )
else
  # Ad-hoc local signing (no team / no account needed).
  XCARGS+=( CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" )
fi
xcodebuild "${XCARGS[@]}" build

APP="$DERIVED/Build/Products/Release/VK Turn Proxy Agent.app"
if [[ ! -d "$APP" ]]; then
  # Fall back to whatever .app the build produced (robust to a renamed product).
  APP="$(/usr/bin/find "$DERIVED/Build/Products/Release" -maxdepth 1 -name '*.app' -print -quit || true)"
fi
[[ -d "$APP" ]] || { echo "ERROR: built app not found under $DERIVED/Build/Products/Release" >&2; exit 1; }
echo
echo "==> Done: $APP"
echo
echo "Run it:  open \"$APP\""
echo "First launch: use the menu-bar icon → Edit config… to fill in your server/keys,"
echo "then Start. Point Surge at 127.0.0.1:1080 (SOCKS5, TCP+UDP)."
echo
echo "Keep egress DIRECT if Surge runs in enhanced mode — see docs/socks.md #4:"
echo "  add a rule  PROCESS-NAME,vk-turn-socks,DIRECT  (and the printed TURN relay IP)."
