import SwiftUI

// The menu-bar popover: status, a connect/disconnect (or Auto) control, and a
// compact live-stats panel (connections, pool, traffic, speed, uptime, relay).
struct DashboardView: View {
    @ObservedObject var controller: AgentController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 11, height: 11)
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
        switchRow(title: "Auto (failover)",
                  subtitle: "Run only when direct internet is down",
                  isOn: $controller.autoMode)

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
            .controlSize(.large)
        }

        switchRow(title: "Launch at login",
                  subtitle: nil,
                  isOn: Binding(get: { controller.launchAtLogin },
                                set: { controller.setLaunchAtLogin($0) }))
    }

    private var stats: some View {
        VStack(spacing: 12) {
            // Hero: live speed. Two equal-width tiles with a light gradient and a
            // large, easy-to-read rate.
            HStack(spacing: 10) {
                speedTile(title: "Download", symbol: "arrow.down",
                          rate: speed(controller.rxRate), total: bytes(controller.rxBytes),
                          tint: .blue)
                speedTile(title: "Upload", symbol: "arrow.up",
                          rate: speed(controller.txRate), total: bytes(controller.txBytes),
                          tint: .green)
            }

            // Details: borderless table — label left, value right.
            VStack(spacing: 0) {
                infoRow("Connections",
                        "\(controller.activeConns) / \(controller.totalConns)",
                        help: "Active / total proxy sessions.")
                Divider().opacity(0.35)
                infoRow("Credential pool",
                        "\(controller.poolFilled) / \(controller.poolWithCreds) / \(controller.poolSize)",
                        help: "Ready / with-credentials / capacity.")
                Divider().opacity(0.35)
                infoRow("Uptime", uptime(controller.uptimeSec), help: nil)
                Divider().opacity(0.35)
                infoRow("Relay (keep DIRECT)",
                        controller.relayIP.isEmpty ? "—" : controller.relayIP,
                        help: "VK's TURN relay the tunnel is using. Add IP-CIDR,\(controller.relayIP.isEmpty ? "<relay>" : controller.relayIP)/32,DIRECT in Surge so the proxy's own traffic to VK bypasses the tunnel instead of looping back through it.",
                        showInfo: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button { controller.openConfig() } label: {
                Label("Edit config", systemImage: "square.and.pencil")
            }
            Button {
                openWindow(id: "logs")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }
            Spacer()
            Button("Quit") { controller.quit() }
        }
        .font(.caption)
        .buttonStyle(.link)
    }

    // MARK: - Reusable bits

    /// A label on the left and a switch pinned to the right.
    private func switchRow(title: String, subtitle: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    /// A live-speed tile: label, big rate, and a session total below. Filled with
    /// a light diagonal gradient in `tint` so the pair reads at a glance.
    private func speedTile(title: String, symbol: String, rate: String, total: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundColor(tint)
                Text(title).font(.caption2).foregroundColor(.secondary)
            }
            Text(rate)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(total)
                .font(.caption2).monospacedDigit().foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.05)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 0.5)
        )
    }

    /// A borderless table row: label on the left, value pinned to the right.
    /// Hover shows `help` as a tooltip; `showInfo` adds a small info glyph.
    private func infoRow(_ label: String, _ value: String, help: String?, showInfo: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.title3)
                .foregroundColor(.secondary)
            if showInfo {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundColor(.secondary.opacity(0.6))
            }
            Spacer(minLength: 10)
            Text(value)
                .font(.title3).fontWeight(.bold)
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .help(help ?? "")
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
        return "0 KB/s"
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
