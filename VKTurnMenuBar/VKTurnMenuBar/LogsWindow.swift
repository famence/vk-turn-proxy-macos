import Foundation
import SwiftUI

// Live view of the current session's engine log (agent.log). Tails the file
// every second; shows newest at the bottom. Reveal/Clear act on the same file.
struct LogsWindow: View {
    @ObservedObject var controller: AgentController
    @State private var text = ""
    @State private var autoScroll = true
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
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
            text = tailText(at: controller.logURL, maxBytes: maxTailBytes)
        }
        .onReceive(timer) { _ in
            let url = controller.logURL
            Task {
                let latest = await Task.detached(priority: .utility) {
                    tailText(at: url, maxBytes: maxTailBytes)
                }.value
                if latest != text { text = latest }
            }
        }
    }

    private func tailText(at url: URL, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeAny = attrs[.size],
              let size = sizeAny as? NSNumber else {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        let fileSize = size.int64Value
        if fileSize <= 0 { return "" }
        let start = max(Int64(0), fileSize - Int64(maxBytes))

        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: UInt64(start))
            let data = try h.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }
}
