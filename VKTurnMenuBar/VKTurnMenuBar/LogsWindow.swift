import AppKit
import Foundation
import SwiftUI

// Live view of the current session's engine log (agent.log). Tails the file
// every second; shows newest at the bottom. Reveal/Clear act on the same file.
struct LogsWindow: View {
    @ObservedObject var controller: AgentController
    @State private var text = ""
    @State private var autoScroll = true
    @State private var pollTimer: Timer?
    @State private var isVisible = false
    private let pollInterval: TimeInterval = 1.0
    private let maxTailBytes = 256 * 1024

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "No logs yet. Press Connect (or enable Auto) to start." : text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("logbottom")
                }
                .onChange(of: text) { _ in
                    if autoScroll { withAnimation { proxy.scrollTo("logbottom", anchor: .bottom) } }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Spacer()
                Button { controller.revealLog() } label: {
                    Label("Reveal", systemImage: "folder")
                }
                Button {
                    controller.clearLog()
                    text = ""
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            .padding(8)
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            isVisible = true
            refreshLogTail()
            startLogPolling()
        }
        .onDisappear {
            isVisible = false
            stopLogPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard isVisible else { return }
            refreshLogTail()
            startLogPolling()
        }
    }

    private func startLogPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
            refreshLogTail()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopLogPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshLogTail() {
        let latest = controller.readLogTail(maxBytes: maxTailBytes)
        if latest != text { text = latest }
    }
}
