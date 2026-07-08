import SwiftUI

// The menu-bar popover: status, a connect/disconnect (or Auto) control, and a
// compact live-stats panel (connections, pool, traffic, speed, uptime, relay).
struct DashboardView: View {
    @ObservedObject var controller: AgentController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if controller.captchaPending {
                Button {
                    openWindow(id: "captcha")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Solve captcha…", systemImage: "exclamationmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            controls

            if controller.isRunning {
                Divider()
                stats
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text("VK Turn Proxy").font(.headline)
                Text(controller.statusLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var controls: some View {
        // Auto mode owns the lifecycle when enabled; otherwise a manual toggle.
        Toggle(isOn: $controller.autoMode) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto (failover)")
                Text("Run only when direct internet is down")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .toggleStyle(.switch)

        if !controller.autoMode {
            Button {
                if controller.isRunning { controller.stop() } else { controller.start() }
            } label: {
                Label(controller.isRunning ? "Disconnect" : "Connect",
                      systemImage: controller.isRunning ? "stop.circle" : "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isRunning ? .red : .accentColor)
        }
    }

    private var stats: some View {
        VStack(spacing: 8) {
            HStack {
                stat("↓ Down", speed(controller.rxRate), sub: bytes(controller.rxBytes))
                stat("↑ Up", speed(controller.txRate), sub: bytes(controller.txBytes))
            }
            HStack {
                stat("Conns", "\(controller.activeConns)/\(controller.totalConns)", sub: "active/total")
                stat("Pool", "\(controller.poolFilled)/\(controller.poolWithCreds)/\(controller.poolSize)", sub: "avail/creds/size")
            }
            HStack {
                stat("Uptime", uptime(controller.uptimeSec), sub: nil)
                stat("Relay", controller.relayIP.isEmpty ? "—" : controller.relayIP, sub: "keep DIRECT")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Direct access to the single config file (app-support). "Edit"
            // opens it in the default editor; "Reveal" shows it in Finder.
            HStack(spacing: 12) {
                Button { controller.openConfig() } label: {
                    Label("Edit config…", systemImage: "square.and.pencil")
                }
                Button { controller.revealConfig() } label: {
                    Label("Reveal", systemImage: "folder")
                }
                Spacer()
                Button("Quit") { controller.quit() }
            }
            .font(.caption)
            .buttonStyle(.link)

            Text("Config: ~/Library/Application Support/VKTurnProxy/config.json")
                .font(.caption2)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Bits

    private func stat(_ title: String, _ value: String, sub: String?) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let sub { Text(sub).font(.caption2).foregroundColor(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(nsColor: .underPageBackgroundColor))
        .cornerRadius(8)
    }

    private var statusColor: Color {
        if controller.captchaPending { return .orange }
        if controller.isRunning { return controller.activeConns > 0 ? .green : .yellow }
        if controller.autoMode { return controller.directOK ? .blue : .yellow }
        return .gray
    }

    private func speed(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        if bps > 0 { return String(format: "%.0f B/s", bps) }
        return "0"
    }

    private func bytes(_ n: Int64) -> String {
        let f = Double(n)
        if f >= 1_073_741_824 { return String(format: "%.1f GB", f / 1_073_741_824) }
        if f >= 1_048_576 { return String(format: "%.1f MB", f / 1_048_576) }
        if f >= 1024 { return String(format: "%.0f KB", f / 1024) }
        return "\(n) B"
    }

    private func uptime(_ s: Int64) -> String {
        guard s > 0 else { return "—" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
