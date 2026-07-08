import SwiftUI

// Live view of the current session's engine log (agent.log). Tails the file
// every second; shows newest at the bottom. Reveal/Clear act on the same file.
struct LogsWindow: View {
    @ObservedObject var controller: AgentController
    @State private var text = ""
    @State private var autoScroll = true
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
        .onAppear { text = controller.readLog() }
        .onReceive(timer) { _ in
            let latest = controller.readLog()
            if latest != text { text = latest }
        }
    }
}
