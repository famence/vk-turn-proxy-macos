# Top-level convenience wrapper for the macOS build. All the real work happens
# in WireGuardBridge/Makefile (the Go → XCFramework step) and in Xcode via the
# xcodegen-generated project. These targets just chain them in the right order.
#
# Prerequisites (macOS host):
#   - Xcode 16.2+ with the macOS SDK and command-line tools
#   - Go 1.25.5+          (brew install go)
#   - xcodegen            (brew install xcodegen)
#   - rsync, patch        (bundled with macOS)
#
# Typical first build:
#   make bridge      # compile the Go core into WireGuardBridge/build/WireGuardTURN.xcframework
#   make project     # generate VKTurnProxy/VKTurnProxy.xcodeproj from project.yml
#   open VKTurnProxy/VKTurnProxy.xcodeproj   # then set your Team + build/run in Xcode
#
# Or in one shot:
#   make all

.PHONY: all bridge project app socks menubar clean

all: bridge project

# Build the Go WireGuardTURN.xcframework (universal arm64 + x86_64 static lib).
bridge:
	$(MAKE) -C WireGuardBridge

# Generate the Xcode project from project.yml (requires xcodegen).
project:
	cd VKTurnProxy && xcodegen generate

# Command-line archive/build of the app (after `make bridge project`). Signing
# needs a real Team ID + the packet-tunnel-provider-systemextension entitlement,
# so this usually runs in Xcode; kept here for CI reference.
app:
	cd VKTurnProxy && xcodebuild -project VKTurnProxy.xcodeproj \
		-scheme VKTurnProxy -configuration Release \
		-derivedDataPath build build

# Build the standalone SOCKS5/HTTP proxy binary for the host arch (pure Go, no
# Xcode needed). Cross-compile with GOOS/GOARCH for other targets.
socks:
	CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o vk-turn-socks ./cmd/vk-turn-socks
	@echo "==> Built ./vk-turn-socks"

# Build the menu-bar agent .app (macOS only; see scripts/build_menubar.sh).
menubar:
	scripts/build_menubar.sh

# Install/manage the background launchd service (macOS only). Pass ACTION=...
# e.g. `make service ACTION=install` | start | stop | status | logs | uninstall.
ACTION ?= install
service:
	scripts/service.sh $(ACTION)

clean:
	$(MAKE) -C WireGuardBridge clean
	rm -rf VKTurnProxy/build VKTurnProxy/VKTurnProxy.xcodeproj
	rm -rf VKTurnMenuBar/VKTurnMenuBar.xcodeproj VKTurnMenuBar/VKTurnMenuBar/Resources/vk-turn-socks
	rm -f vk-turn-socks
