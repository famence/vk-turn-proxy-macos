BUILDDIR ?= $(CURDIR)/build
DESTDIR ?= $(BUILDDIR)

# macOS SDK path
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
# Minimum macOS version. 13.0 (Ventura) is the floor: it matches the app's
# deployment target (SwiftUI NavigationStack, which the UI uses, is 13.0+).
# The Go archive itself has no such floor, but keeping the -mmacosx-version-min
# aligned with the app avoids linker "object file built for newer macOS" noise.
MACOS_MIN_VERSION := 13.0

# Go settings
export CGO_ENABLED := 1

GO_BUILD_FLAGS := -buildmode=c-archive -trimpath
export GONOSUMCHECK := *
export GONOSUMDB := *
export GOFLAGS := -mod=mod
GO_LDFLAGS := -s -w

# Patched GOROOT: replaces mach_absolute_time with mach_continuous_time
# so that Go timers keep ticking while the Mac is asleep (App Nap / sleep).
# The upstream diff patches the darwin arm64 + amd64 runtime, which is
# exactly what a macOS (GOOS=darwin) build compiles against.
REAL_GOROOT := $(shell go env GOROOT 2>/dev/null)
PATCHED_GOROOT := $(BUILDDIR)/goroot

.PHONY: all clean macos-arm64 macos-amd64 macos-universal xcframework goroot

all: xcframework

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Create a patched copy of GOROOT with a boottime monotonic clock.
goroot: $(BUILDDIR)
	@if [ ! -f "$(PATCHED_GOROOT)/.patched" ]; then \
		echo "==> Creating patched GOROOT (boottime monotonic clock)..."; \
		rm -rf "$(PATCHED_GOROOT)"; \
		mkdir -p "$(PATCHED_GOROOT)"; \
		rsync -a --delete --exclude=pkg/obj/go-build "$(REAL_GOROOT)/" "$(PATCHED_GOROOT)/"; \
		cd "$(PATCHED_GOROOT)" && patch -p1 -f -N -r- < "$(CURDIR)/goruntime-boottime-over-monotonic.diff"; \
		touch "$(PATCHED_GOROOT)/.patched"; \
		echo "==> GOROOT patched successfully"; \
	else \
		echo "==> Using cached patched GOROOT"; \
	fi

# Build for Apple Silicon (arm64) macOS.
# GOOS=darwin (the desktop target). Unlike the iOS build there is no
# sigaltstack restriction to work around, but GODEBUG=asyncpreemptoff=1 is
# still set from bridge.go's constructor and is harmless on macOS.
macos-arm64: goroot
	@echo "==> Building for macOS arm64..."
	GOROOT="$(PATCHED_GOROOT)" \
	CGO_CFLAGS="-isysroot $(MACOS_SDK) -arch arm64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	CGO_LDFLAGS="-isysroot $(MACOS_SDK) -arch arm64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	GOARCH=arm64 \
	GOOS=darwin \
	CGO_ENABLED=1 \
	CC="$(shell xcrun --sdk macosx -f clang) -isysroot $(MACOS_SDK) -arch arm64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	go build $(GO_BUILD_FLAGS) -ldflags "$(GO_LDFLAGS)" -o $(BUILDDIR)/libwg-turn-macos-arm64.a .
	@echo "==> Done: $(BUILDDIR)/libwg-turn-macos-arm64.a"

# Build for Intel (amd64) macOS.
macos-amd64: goroot
	@echo "==> Building for macOS amd64..."
	GOROOT="$(PATCHED_GOROOT)" \
	CGO_CFLAGS="-isysroot $(MACOS_SDK) -arch x86_64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	CGO_LDFLAGS="-isysroot $(MACOS_SDK) -arch x86_64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	GOARCH=amd64 \
	GOOS=darwin \
	CGO_ENABLED=1 \
	CC="$(shell xcrun --sdk macosx -f clang) -isysroot $(MACOS_SDK) -arch x86_64 -mmacosx-version-min=$(MACOS_MIN_VERSION)" \
	go build $(GO_BUILD_FLAGS) -ldflags "$(GO_LDFLAGS)" -o $(BUILDDIR)/libwg-turn-macos-amd64.a .
	@echo "==> Done: $(BUILDDIR)/libwg-turn-macos-amd64.a"

# Combine the two per-arch archives into one universal (fat) static library.
# An XCFramework carries ONE library per platform, so both slices must live
# in a single universal .a — lipo does exactly that.
macos-universal: macos-arm64 macos-amd64
	@echo "==> Creating universal (arm64+x86_64) static library..."
	lipo -create \
		$(BUILDDIR)/libwg-turn-macos-arm64.a \
		$(BUILDDIR)/libwg-turn-macos-amd64.a \
		-output $(BUILDDIR)/libwg-turn-macos-universal.a
	@echo "==> Done: $(BUILDDIR)/libwg-turn-macos-universal.a"

# Create the XCFramework the Xcode project links against.
xcframework: macos-universal
	@echo "==> Creating XCFramework..."
	rm -rf $(DESTDIR)/WireGuardTURN.xcframework
	xcodebuild -create-xcframework \
		-library $(BUILDDIR)/libwg-turn-macos-universal.a -headers $(CURDIR)/include \
		-output $(DESTDIR)/WireGuardTURN.xcframework
	@echo "==> Done: $(DESTDIR)/WireGuardTURN.xcframework"

clean:
	rm -rf $(BUILDDIR)
	rm -rf $(DESTDIR)/WireGuardTURN.xcframework
