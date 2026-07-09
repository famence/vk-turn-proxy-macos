import SwiftUI

// The menu-bar popover: status, a connect/disconnect (or Auto) control, and a
// compact live-stats panel (connections, pool, traffic, speed, uptime, relay).
struct DashboardView: View {
    @ObservedObject var controller: AgentController
    @Environment(\.openWindow) private var openWindow
    @State private var showRelayHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
        .frame(width: 360)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .shadow(color: statusColor.opacity(0.55), radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("VK Turn Proxy")
                    .font(.system(size: 17, weight: .semibold))
                Text(controller.statusLine)
                    .font(.system(size: 12, weight: .medium))
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
                    .font(.system(size: 15, weight: .semibold))
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
        VStack(spacing: 14) {
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
                        detail: "active / total",
                        help: "Active / total proxy sessions.")
                Divider().opacity(0.25)
                infoRow("Credential pool",
                        "\(controller.poolFilled) / \(controller.poolWithCreds) / \(controller.poolSize)",
                        detail: "ready / credentials / capacity",
                        help: "Ready / with-credentials / capacity.")
                Divider().opacity(0.25)
                infoRow("Uptime", uptime(controller.uptimeSec),
                        detail: "current session", help: nil)
                Divider().opacity(0.25)
                relayRow
                if showRelayHint {
                    relayHint
                }
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
                    .font(.system(size: 15, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 1)
    }

    /// A live-speed tile: label, big rate, and a session total below. Filled with
    /// a light diagonal gradient in `tint` so the pair reads at a glance.
    private func speedTile(title: String, symbol: String, rate: String, total: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Text(rate)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            HStack(spacing: 6) {
                Text("Session")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.8))
                Spacer(minLength: 4)
                Text(total)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.17), tint.opacity(0.045)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.75)
        )
    }

    /// A borderless table row: label on the left, value pinned to the right.
    private func infoRow(_ label: String, _ value: String, detail: String?, help: String?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.72))
                }
            }
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minHeight: 50)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(help ?? "")
    }

    private var relayRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("VK TURN relay")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showRelayHint.toggle()
                        }
                    } label: {
                        Image(systemName: showRelayHint ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(showRelayHint ? .accentColor : .secondary.opacity(0.7))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Почему соединение с релеем должно идти DIRECT")
                }
                Text("service connection")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.72))
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 3) {
                Text(controller.relayIP.isEmpty ? "—" : controller.relayIP)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("DIRECT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.12))
                    )
            }
        }
        .frame(minHeight: 54)
        .padding(.vertical, 3)
    }

    private var relayHint: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("Why DIRECT?")
                    .font(.system(size: 12, weight: .semibold))
                Text("Служебное соединение с VK TURN должно обходить прокси, иначе трафик зациклится.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("IP-CIDR,\(controller.relayIP.isEmpty ? "<relay>" : controller.relayIP)/32,DIRECT")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
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
