#!/usr/bin/env bash
#
# package_dmg.sh — build the menu-bar agent and wrap it in a drag-to-install
# .dmg, plus zip up the headless CLI binaries. macOS only.
#
# Output (in dist/):
#   VK-Turn-Proxy-Agent.dmg          ← universal app; open, drag to Applications
#   vk-turn-socks-darwin-arm64.zip   ← headless CLI, Apple Silicon
#   vk-turn-socks-darwin-amd64.zip   ← headless CLI, Intel
#
# This is what a GitHub release ships. The app is universal, so ONE DMG runs on
# both Apple Silicon and Intel — no need to pick.
#
#   scripts/package_dmg.sh                 # ad-hoc signed (local / unsigned release)
#   TEAM_ID=ABCDE12345 scripts/package_dmg.sh   # Developer-ID signed
#
# Prereqs: macOS 13+, Xcode 16.2+, Go 1.25.5+, xcodegen, hdiutil (built-in).

set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "ERROR: macOS only." >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
DIST="$REPO_ROOT/dist"
mkdir -p "$DIST"

echo "==> Building the menu-bar agent (universal)…"
scripts/build_menubar.sh

APP="$REPO_ROOT/build/DerivedData/Build/Products/Release/VK Turn Proxy Agent.app"
[[ -d "$APP" ]] || { echo "ERROR: app not found at $APP" >&2; exit 1; }

echo "==> Assembling DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"    # drag-to-install target

DMG="$DIST/VK-Turn-Proxy-Agent.dmg"
rm -f "$DMG"
hdiutil create \
  -volname "VK Turn Proxy" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"
rm -rf "$STAGE"
echo "==> Wrote $DMG"

echo "==> Building headless CLI binaries…"
GOFLAGS=-mod=mod GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "$DIST/vk-turn-socks-darwin-arm64" ./cmd/vk-turn-socks
GOFLAGS=-mod=mod GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "$DIST/vk-turn-socks-darwin-amd64" ./cmd/vk-turn-socks
( cd "$DIST" && \
  zip -q -j vk-turn-socks-darwin-arm64.zip vk-turn-socks-darwin-arm64 && \
  zip -q -j vk-turn-socks-darwin-amd64.zip vk-turn-socks-darwin-amd64 && \
  shasum -a 256 VK-Turn-Proxy-Agent.dmg vk-turn-socks-darwin-arm64 vk-turn-socks-darwin-amd64 > SHA256SUMS.txt )

echo
echo "==> Done. Artifacts in dist/:"
ls -1 "$DIST"
echo
echo "Install (user): open the DMG, drag \"VK Turn Proxy Agent\" to Applications, launch it."
echo "Unsigned build: first launch needs right-click → Open (or: xattr -dr com.apple.quarantine \"/Applications/VK Turn Proxy Agent.app\")."
