import SwiftUI

// VK Turn Proxy — menu-bar agent.
//
// A status-bar front-end for the `vk-turn-socks` engine. It has NOTHING to do
// with the system VPN / Network Extension: it launches the bundled
// `vk-turn-socks` binary as a subprocess (userspace SOCKS5/HTTP proxy) and
// talks to its localhost control API to show live stats and — when VK forces a
// captcha the engine can't auto-solve — pop a WebView to solve it by hand.
// Point Surge at 127.0.0.1:1080 as usual.
//
// No Apple Developer account, no entitlements, no system extension: an ordinary
// LSUIElement utility app (no Dock icon).
@main
struct VKTurnMenuBarApp: App {
    @StateObject private var controller = AgentController()

    var body: some Scene {
        // .window style shows a rich SwiftUI popover (the dashboard) rather than
        // a plain AppKit menu, so we can display live stats.
        MenuBarExtra {
            DashboardView(controller: controller)
        } label: {
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        // On-demand captcha window, opened from the dashboard when a captcha is
        // pending; closes itself once solved.
        Window("Solve VK Captcha", id: "captcha") {
            CaptchaWindow(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 720)

        // Live engine log.
        Window("VK Turn Proxy — Logs", id: "logs") {
            LogsWindow(controller: controller)
        }
        .defaultSize(width: 720, height: 460)
    }
}
