import SwiftUI

// VK Turn Proxy — menu-bar agent.
//
// A tiny status-bar front-end for the `vk-turn-socks` engine. It has NOTHING
// to do with the system VPN / Network Extension: it just launches the bundled
// `vk-turn-socks` binary as a subprocess (userspace SOCKS5/HTTP proxy) and
// talks to its localhost control API to show status and — when VK forces a
// captcha the engine can't auto-solve — pop a WebView so you can solve it by
// hand. Point Surge at 127.0.0.1:1080 as usual.
//
// No Apple Developer account, no entitlements, no system extension: this is an
// ordinary utility app (LSUIElement, so no Dock icon).
@main
struct VKTurnMenuBarApp: App {
    @StateObject private var controller = AgentController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            // SF Symbol reflects state: filled shield when connected, slashed
            // when stopped, hourglass while connecting / solving captcha.
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        // On-demand captcha window. Opened from the menu when a captcha is
        // pending; closes itself once solved.
        Window("Solve VK Captcha", id: "captcha") {
            CaptchaWindow(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 720)
    }
}

struct MenuContent: View {
    @ObservedObject var controller: AgentController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.statusLine)
        if !controller.relayIP.isEmpty {
            Text("TURN relay: \(controller.relayIP) (keep DIRECT in Surge)")
        }
        if !controller.detail.isEmpty {
            Text(controller.detail)
        }

        Divider()

        if controller.isRunning {
            Button("Stop") { controller.stop() }
        } else {
            Button("Start") { controller.start() }
        }

        if controller.captchaPending {
            Button("Solve captcha…") {
                openWindow(id: "captcha")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Button("Edit config…") { controller.openConfig() }
        Button("Reveal config in Finder") { controller.revealConfig() }

        Divider()

        Button("Quit") { controller.quit() }
    }
}
