import AppKit
import Foundation

// AgentController manages the `vk-turn-socks` subprocess and its localhost
// control API. It owns:
//   • starting/stopping the bundled binary with the user's config,
//   • polling GET /status for live stats + a pending-captcha URL,
//   • handing a solved captcha token back via POST /solve.
//
// The config file lives at ~/Library/Application Support/VKTurnProxy/config.json.
// On first launch, if it's missing, we copy the bundled config.example.json
// there and reveal it so the user can fill it in.
@MainActor
final class AgentController: ObservableObject {
    @Published var isRunning = false
    @Published var statusLine = "Stopped"
    @Published var detail = ""
    @Published var relayIP = ""
    @Published var captchaPending = false
    @Published var captchaURL: URL?

    // Control API: a random loopback port + bearer token chosen per launch, so
    // nothing else on the machine can drive the engine.
    private let controlPort = Int.random(in: 49_200...49_900)
    private let controlToken = UUID().uuidString
    private var controlBase: String { "http://127.0.0.1:\(controlPort)" }

    private var process: Process?
    private var pollTimer: Timer?

    private let fm = FileManager.default

    var configURL: URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VKTurnProxy", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    var menuBarSymbol: String {
        if captchaPending { return "hourglass" }
        if isRunning && relayIP.isEmpty { return "hourglass" }
        return isRunning ? "shield.lefthalf.filled" : "shield.slash"
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }

        // Ensure a config exists; if not, seed from the bundled example and
        // stop so the user can edit it first.
        if !fm.fileExists(atPath: configURL.path) {
            if let example = Bundle.main.url(forResource: "config.example", withExtension: "json") {
                try? fm.copyItem(at: example, to: configURL)
            }
            detail = "Fill in config.json first, then Start."
            revealConfig()
            return
        }

        guard let binary = Bundle.main.url(forResource: "vk-turn-socks", withExtension: nil) else {
            detail = "Bundled vk-turn-socks binary missing from the app."
            return
        }
        // Copying into Resources can drop the execute bit — restore it.
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "-config", configURL.path,
            "-control", "127.0.0.1:\(controlPort)",
            "-control-token", controlToken,
        ]
        // Surface the engine's log in Console.app; the menu shows a summary.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.onProcessExit() }
        }
        do {
            try proc.run()
        } catch {
            detail = "Failed to launch: \(error.localizedDescription)"
            return
        }
        process = proc
        isRunning = true
        statusLine = "Connecting…"
        detail = ""
        startPolling()
    }

    func stop() {
        // Ask the engine to shut down gracefully via the control API, then
        // fall back to terminating the process.
        postControl("/stop")
        pollTimer?.invalidate()
        pollTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.process?.terminate()
        }
    }

    func quit() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private func onProcessExit() {
        process = nil
        isRunning = false
        captchaPending = false
        captchaURL = nil
        relayIP = ""
        statusLine = "Stopped"
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Config helpers

    func openConfig() {
        seedConfigIfNeeded()
        NSWorkspace.shared.open(configURL)
    }

    func revealConfig() {
        seedConfigIfNeeded()
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    private func seedConfigIfNeeded() {
        if !fm.fileExists(atPath: configURL.path),
           let example = Bundle.main.url(forResource: "config.example", withExtension: "json") {
            try? fm.copyItem(at: example, to: configURL)
        }
    }

    // MARK: - Control API polling

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        poll()
    }

    private func poll() {
        var req = URLRequest(url: URL(string: "\(controlBase)/status")!)
        req.timeoutInterval = 3
        req.setValue("Bearer \(controlToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let s = try? JSONDecoder().decode(Status.self, from: data) else { return }
            Task { @MainActor in self?.apply(s) }
        }.resume()
    }

    private func apply(_ s: Status) {
        relayIP = s.relay_ip
        if let ae = s.auth_error, !ae.isEmpty {
            statusLine = "VK session rejected — re-login"
            detail = ae
        } else if s.active_conns > 0 {
            statusLine = "Connected · \(s.active_conns)/\(s.total_conns) conns"
            detail = "↑ \(human(s.tx_bytes))  ↓ \(human(s.rx_bytes))  · pool \(s.pool_filled)/\(s.pool_with_creds)/\(s.pool_size)"
        } else {
            statusLine = "Connecting…"
        }

        let url = s.captcha_url ?? ""
        if !url.isEmpty {
            captchaPending = true
            captchaURL = URL(string: url)
        } else {
            captchaPending = false
            captchaURL = nil
        }
    }

    // MARK: - Captcha

    /// Called by the captcha WebView when it captures a success_token.
    func submitCaptcha(token: String) {
        postControl("/solve", query: [URLQueryItem(name: "token", value: token)])
        captchaPending = false
        captchaURL = nil
    }

    /// Ask the engine for a fresh captcha URL (the pending one may be stale).
    func refreshCaptcha(_ completion: @escaping (URL?) -> Void) {
        var req = URLRequest(url: URL(string: "\(controlBase)/refresh_captcha")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("Bearer \(controlToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let s = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in completion(URL(string: s)) }
        }.resume()
    }

    // MARK: - Helpers

    private func postControl(_ path: String, query: [URLQueryItem] = []) {
        var comps = URLComponents(string: controlBase + path)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("Bearer \(controlToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req).resume()
    }

    private func human(_ n: Int64) -> String {
        let f = Double(n)
        if f >= 1 << 30 { return String(format: "%.1fGB", f / Double(1 << 30)) }
        if f >= 1 << 20 { return String(format: "%.1fMB", f / Double(1 << 20)) }
        if f >= 1 << 10 { return String(format: "%.1fKB", f / Double(1 << 10)) }
        return "\(n)B"
    }
}

// Mirrors statusResponse in cmd/vk-turn-socks/control.go.
private struct Status: Decodable {
    let running: Bool
    let uptime_sec: Int64
    let active_conns: Int32
    let total_conns: Int32
    let pool_filled: Int32
    let pool_with_creds: Int32
    let pool_size: Int32
    let tx_bytes: Int64
    let rx_bytes: Int64
    let relay_ip: String
    let captcha_url: String?
    let auth_error: String?
}
