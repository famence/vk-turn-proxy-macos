// SystemExtensionManager.swift
//
// macOS-only glue that has no iOS counterpart.
//
// On iOS the PacketTunnel is an APP extension embedded in the app bundle and
// iOS loads it automatically — nothing to "install". On macOS, a packet-tunnel
// provider distributed outside the Mac App Store must be a SYSTEM extension
// (Apple TN3134): the app has to explicitly ask the OS to install/activate the
// .systemextension via OSSystemExtensionRequest, and the user approves it once
// in System Settings ▸ General ▸ Login Items & Extensions (or "Privacy &
// Security" on Ventura). After that the NETunnelProviderManager flow is
// identical to iOS.
//
// This object drives that one-time activation and publishes a coarse state the
// UI can reflect. It is safe to call `activate()` repeatedly — if the extension
// is already active the request completes immediately with `.completed`.
//
// (If you instead ship via the Mac App Store, switch the PacketTunnel target to
// an app extension and delete this file — see docs/setup.md. The rest of the
// app doesn't care which packaging is used.)

import Foundation
import SystemExtensions
import os.log

@MainActor
final class SystemExtensionManager: NSObject, ObservableObject {

    enum State: Equatable {
        case unknown
        case activating
        case needsApproval          // user must approve in System Settings
        case active
        case failed(String)

        var isActive: Bool { self == .active }
    }

    @Published private(set) var state: State = .unknown

    private let extensionIdentifier = AppGroup.tunnelProviderBundleID
    private let log = OSLog(subsystem: "com.vkturnproxy.mac", category: "SysExt")

    /// Kick off (or re-check) activation of the packet-tunnel system extension.
    /// Idempotent: the OS returns `.completed` immediately if it's already
    /// installed at the current version.
    func activate() {
        // Never downgrade a known-active state back to "activating" on a
        // redundant call (e.g. ContentView re-appearing).
        if state == .activating { return }
        os_log("requesting activation of %{public}@", log: log, type: .default, extensionIdentifier)
        state = .activating
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func log(_ msg: String) {
        os_log("%{public}@", log: log, type: .default, msg)
        SharedLogger.shared.log("[SysExt] \(msg)")
    }
}

extension SystemExtensionManager: OSSystemExtensionRequestDelegate {

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Always take the copy bundled in THIS app build — it's the one whose
        // Go xcframework + Swift are guaranteed to match the running app.
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.log("needs user approval — open System Settings ▸ General ▸ Login Items & Extensions ▸ Network Extensions and allow \"VK Turn Proxy\"")
            self.state = .needsApproval
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.log("activation completed")
                self.state = .active
            case .willCompleteAfterReboot:
                self.log("activation will complete after reboot")
                self.state = .needsApproval
            @unknown default:
                self.log("activation finished with unknown result \(result.rawValue)")
                self.state = .active
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFailWithError error: Error) {
        Task { @MainActor in
            let ns = error as NSError
            self.log("activation FAILED: \(error.localizedDescription) (domain=\(ns.domain) code=\(ns.code))")
            self.state = .failed(error.localizedDescription)
        }
    }
}
