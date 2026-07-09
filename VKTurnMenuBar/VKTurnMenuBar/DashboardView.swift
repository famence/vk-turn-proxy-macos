import SwiftUI

// The menu-bar popover: status, a connect/disconnect (or Auto) control, and a
// compact live-stats panel (connections, pool, traffic, speed, uptime, relay).
struct DashboardView: View {
    @ObservedObject var controller: AgentController
    @Environment(\.openWindow) private var openWindow
    @State private var showRelayHint = false

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
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
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
            HStack(spacing: 8) {
                speedTile(title: "Download", symbol: "arrow.down",
                          rate: speed(controller.rxRate), total: bytes(controller.rxBytes),
                          tint: .blue)
                speedTile(title: "Upload", symbol: "arrow.up",
                          rate: speed(controller.txRate), total: bytes(controller.txBytes),
                          tint: .green)
            }

            VStack(spacing: 0) {
                infoRow("Connections", "\(controller.activeConns) / \(controller.totalConns)",
                        help: "Active / total proxy sessions.")
                statDivider()
                infoRow("Pool",
                        "\(controller.poolFilled) / \(controller.poolWithCreds) / \(controller.poolSize)",
                        help: "Ready / with credentials / capacity.")
                statDivider()
                infoRow("Uptime", uptime(controller.uptimeSec), help: nil)
                statDivider()
                relayRow
                if showRelayHint { relayHint }
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

    private func statDivider() -> some View {
        Divider().opacity(0.22).padding(.vertical, 2)
    }

    private func speedTile(title: String, symbol: String, rate: String, total: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(rate)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(total)
                .font(.caption2)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.14), tint.opacity(0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 0.5)
        )
    }

    /// Label left (small), value right (slightly larger) — one calm step apart.
    private func infoRow(_ label: String, _ value: String, help: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(help ?? "")
    }

    private var relayRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                Text("Relay")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRelayHint.toggle() }
                } label: {
                    Image(systemName: showRelayHint ? "info.circle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundColor(showRelayHint ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Почему релей должен идти DIRECT в Surge")
            }
            Spacer(minLength: 8)
            Text(controller.relayIP.isEmpty ? "—" : controller.relayIP)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 6)
    }

    private var relayHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Служебный трафик к VK TURN — только DIRECT, иначе петля.")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("IP-CIDR,\(controller.relayIP.isEmpty ? "<relay>" : controller.relayIP)/32,DIRECT")
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.bottom, 4)
        .transition(.opacity)
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
