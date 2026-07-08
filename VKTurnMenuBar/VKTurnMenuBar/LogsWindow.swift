import SwiftUI

// Live view of the current session's engine log (agent.log). Tails the file
// every second; shows newest at the bottom. Reveal/Clear act on the same file.
struct LogsWindow: View {
    @ObservedObject var controller: AgentController
    @State private var text = ""
    @State private var autoScroll = true
    @State private var refreshTask: Task<Void, Never>?
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
            // Tail, and do the file I/O off the main thread.
            text = controller.readLogTail(maxBytes: maxTailBytes)
            refreshTask?.cancel()
            refreshTask = Task {
                while !Task.isCancelled {
                    let latest = await Task.detached(priority: .utility) {
                        controller.readLogTail(maxBytes: maxTailBytes)
                    }.value
                    if latest != text {
                        await MainActor.run { text = latest }
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }
}
