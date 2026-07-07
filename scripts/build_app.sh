#!/usr/bin/env bash
#
# build_app.sh — one-shot build of VK Turn Proxy.app on a Mac.
#
# THIS MUST RUN ON macOS. A macOS .app (SwiftUI/AppKit + a signed packet-tunnel
# system extension) cannot be produced on Linux — there is no Apple toolchain
# or macOS SDK there, and system extensions require Apple code signing.
#
# Prerequisites:
#   - macOS 13 (Ventura) or newer
#   - Xcode 16.2+ and command-line tools   (xcode-select --install)
#   - Go 1.25.5+                            (brew install go)
#   - xcodegen                              (brew install xcodegen)
#   - A PAID Apple Developer account — the Network Extension (packet-tunnel)
#     capability is NOT available to a free personal team, so the app cannot
#     build/run the VPN without it.
#
# Usage:
#   TEAM_ID=ABCDE12345 scripts/build_app.sh
#
# The script:
#   1. builds the Go core into WireGuardTURN.xcframework (universal),
#   2. generates the Xcode project from project.yml,
#   3. builds a Release VK Turn Proxy.app into ./build/,
#   4. prints the path to the resulting .app.
#
# NOTE on identifiers: the demo Team ID "CDMQ33VFQC" is hard-coded in
# VKTurnProxy/VKTurnProxy/AppGroup.swift and both .entitlements files. Replace
# it with your own Team ID there before building (see docs/setup.md) — passing
# TEAM_ID here only overrides the Xcode DEVELOPMENT_TEAM build setting, not
# those source/entitlement strings.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this script must run on macOS (uname is '$(uname -s)')." >&2
  echo "A macOS .app cannot be built on Linux — build it on your Mac." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID, e.g. TEAM_ID=ABCDE12345 $0}"

for tool in go xcodegen xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not found in PATH." >&2; exit 1; }
done

echo "==> [1/3] Building Go core (WireGuardTURN.xcframework)…"
make -C WireGuardBridge

echo "==> [2/3] Generating Xcode project…"
( cd VKTurnProxy && xcodegen generate )

echo "==> [3/3] Building VK Turn Proxy.app (Release)…"
DERIVED="$REPO_ROOT/build/DerivedData"
xcodebuild \
  -project VKTurnProxy/VKTurnProxy.xcodeproj \
  -scheme VKTurnProxy \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates \
  build

APP_PATH="$DERIVED/Build/Products/Release/VK Turn Proxy.app"
if [[ ! -d "$APP_PATH" ]]; then
  # Fall back to the product name Xcode actually used.
  APP_PATH="$(/usr/bin/find "$DERIVED/Build/Products/Release" -maxdepth 1 -name '*.app' -print -quit || true)"
fi

echo
echo "==> Done."
echo "    App: $APP_PATH"
echo
echo "To run it on THIS Mac for personal use:"
echo "  1. Copy the .app into /Applications (system extensions only load from there)."
echo "  2. Launch it; approve the system extension in System Settings ▸ General ▸"
echo "     Login Items & Extensions ▸ Network Extensions (Ventura: Privacy & Security)."
echo "  3. For a locally-signed (non-notarized) build you may also need, once:"
echo "       systemextensionsctl developer on"
echo
echo "To distribute to OTHER Macs you must sign with Developer ID and notarize"
echo "(xcrun notarytool + stapler) — see docs/setup.md."
