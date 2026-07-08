// AppGroup.swift
//
// Single source of truth for the shared-container and shared-keychain
// identifiers, plus the packet-tunnel provider bundle id. On iOS these
// were hard-coded string literals scattered across half a dozen files;
// on macOS the identifiers have platform-specific constraints (see below),
// so they live here once and every call site references the constant.
//
// ── App Group on macOS (why Team-ID-prefixed, not "group.") ─────────
// This app ships the packet tunnel as a network SYSTEM extension (the model
// required for direct / Developer-ID distribution — see docs/setup.md). A
// system extension runs in a global system context, not tied to a Mac App
// Store receipt, so the shared container it agrees on with the app MUST be a
// Team-ID-prefixed app group ("<TeamID>.<name>"), exactly like Apple's own
// wireguard-apple macOS build uses "$(TeamIdentifierPrefix)com.wireguard.macos".
// The iOS "group.<name>" form does NOT work for a macOS system extension.
//
// The value here is the RUNTIME expansion of the entitlement
// "$(TeamIdentifierPrefix)com.vkturnproxy.mac" — i.e. "<TeamID>.com.vkturnproxy.mac".
// It MUST stay byte-identical across three places or the app and the tunnel
// resolve DIFFERENT containers and silently stop sharing vpn.log /
// creds-pool.json / vk_profile.json / the lastTurnServerIP hand-off:
//   1. this constant,
//   2. VKTurnProxy.entitlements  (com.apple.security.application-groups),
//   3. PacketTunnel.entitlements (com.apple.security.application-groups).
// When you re-sign with your own team, replace the CDMQ33VFQC prefix below AND
// keep the $(TeamIdentifierPrefix) forms in the two entitlements files (they
// expand to your team id automatically).
//
// ── Keychain access group ───────────────────────────────────────────
// The VKAuth cookie lives in a shared keychain group so both the app and the
// tunnel extension can read it. Also Team-ID-prefixed
// ("$(AppIdentifierPrefix)com.vkturnproxy.shared" in entitlements →
// "<TeamID>.com.vkturnproxy.shared" at runtime).

import Foundation

enum AppGroup {
    /// Shared App Group container id (Team-ID-prefixed). Must equal the runtime
    /// expansion of the `com.apple.security.application-groups` entitlement in
    /// both targets. See the file header.
    static let identifier = "CDMQ33VFQC.com.vkturnproxy.mac"

    /// Shared keychain access group (Team-ID-prefixed). Must match the
    /// resolved `keychain-access-groups` entitlement in both targets.
    static let keychainAccessGroup = "CDMQ33VFQC.com.vkturnproxy.shared"

    /// Bundle id of the packet-tunnel provider (the network SYSTEM extension).
    /// `providerBundleIdentifier` on the NETunnelProviderProtocol must equal it
    /// exactly, and it's the identifier passed to OSSystemExtensionRequest.
    static let tunnelProviderBundleID = "com.vkturnproxy.mac.tunnel"

    /// Convenience: the shared container URL, or nil if unavailable.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
