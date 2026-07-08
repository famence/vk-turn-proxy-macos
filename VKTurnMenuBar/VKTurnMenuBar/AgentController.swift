import AppKit
import Foundation

// AgentController manages the `vk-turn-socks` subprocess and its localhost
// control API, and publishes live stats for the menu-bar dashboard.
//
// It owns:
//   • starting/stopping the bundled binary with the user's config,
//   • polling GET /status for stats (conns, pool, traffic, relay, captcha),
//   • deriving live up/down speed from traffic deltas,
//   • an optional Auto mode: probe direct internet and start the tunnel only
//     when the direct path is down, stop it when the direct path recovers.
//
// Config lives at ~/Library/Application Support/VKTurnProxy/config.json — the
// SAME file the terminal CLI and the launchd service use.
@MainActor
final class AgentController: ObservableObject {
    // Lifecycle / status
    @Published var isRunning = false
    @Published var statusLine = "Stopped"
    @Published var detail = ""
    @Published var relayIP = ""
    @Published var captchaPending = false
    @Published var captchaURL: URL?

    // Live stats
    @Published var activeConns: Int32 = 0
    @Published var totalConns: Int32 = 0
    @Published var poolFilled: Int32 = 0
    @Published var poolWithCreds: Int32 = 0
    @Published var poolSize: Int32 = 0
    @Published var txBytes: Int64 = 0
    @Published var rxBytes: Int64 = 0
    @Published var txRate: Double = 0 // bytes/sec
    @Published var rxRate: Double = 0 // bytes/sec
    @Published var uptimeSec: Int64 = 0

    // Auto mode (failover): when on, the agent starts the tunnel only while the
    // direct internet path is down, and stops it when direct recovers.
    @Published var autoMode: Bool = UserDefaults.standard.bool(forKey: "autoMode") {
        didSet {
            UserDefaults.standard.set(autoMode, forKey: "autoMode")
            if autoMode {
                startAutoProbe()
            } else {
                stopAutoProbe()
            }
        }
    }
    @Published var directOK = true // last direct-probe result (for the UI)

    // Control API: random loopback port + bearer token per launch.
    private let controlPort = Int.random(in: 49_200...49_900)
    private let controlToken = UUID().uuidString
    private var controlBase: String { "http://127.0.0.1:\(controlPort)" }

    private var process: Process?
    private var startedByAuto = false
    private var pollTimer: Timer?

    // Speed derivation.
    private var prevTx: Int64 = 0
    private var prevRx: Int64 = 0
    private var prevSample = Date()

    // Auto-probe state.
    private var probeTimer: Timer?
    private var failStreak = 0
    private var okStreak = 0
    // Probe a captive-check endpoint. Force this host DIRECT in Surge so the
    // probe reflects REAL direct connectivity even while the tunnel is up (see
    // docs/automation.md). generate_204 returns 204 with an empty body.
    private let probeURL = URL(string: "http://www.gstatic.com/generate_204")!

    private let fm = FileManager.default

    var configURL: URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VKTurnProxy", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    init() {
        if autoMode { startAutoProbe() }
    }

    var menuBarSymbol: String {
        if captchaPending { return "exclamationmark.shield.fill" }
        if isRunning && activeConns > 0 { return "shield.lefthalf.filled" }
        if isRunning { return "shield.lefthalf.filled" }
        return "shield.slash"
    }

    // MARK: - Lifecycle

    func start() { startInternal(auto: false) }

    private func startInternal(auto: Bool) {
        guard process == nil else { return }

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
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "-config", configURL.path,
            "-control", "127.0.0.1:\(controlPort)",
            "-control-token", controlToken,
        ]
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
        startedByAuto = auto
        isRunning = true
        statusLine = "Connecting…"
        detail = ""
        resetSpeed()
        startPolling()
    }

    func stop() { stopInternal() }

    private func stopInternal() {
        postControl("/stop")
        pollTimer?.invalidate()
        pollTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.process?.terminate()
        }
    }

    func quit() {
        stopAutoProbe()
        stopInternal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    private func onProcessExit() {
        process = nil
        startedByAuto = false
        isRunning = false
        captchaPending = false
        captchaURL = nil
        relayIP = ""
        activeConns = 0; totalConns = 0
        poolFilled = 0; poolWithCreds = 0; poolSize = 0
        txBytes = 0; rxBytes = 0; txRate = 0; rxRate = 0
        uptimeSec = 0
        statusLine = autoMode ? "Auto: idle (direct OK)" : "Stopped"
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Config helpers

    func openConfig() { seedConfigIfNeeded(); NSWorkspace.shared.open(configURL) }
    func revealConfig() { seedConfigIfNeeded(); NSWorkspace.shared.activateFileViewerSelecting([configURL]) }

    private func seedConfigIfNeeded() {
        if !fm.fileExists(atPath: configURL.path),
           let example = Bundle.main.url(forResource: "config.example", withExtension: "json") {
            try? fm.copyItem(at: example, to: configURL)
        }
    }

    // MARK: - Control API polling

    private func resetSpeed() {
        prevTx = 0; prevRx = 0; prevSample = Date()
    }

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
        activeConns = s.active_conns
        totalConns = s.total_conns
        poolFilled = s.pool_filled
        poolWithCreds = s.pool_with_creds
        poolSize = s.pool_size
        uptimeSec = s.uptime_sec

        // Derive live speed from byte deltas.
        let now = Date()
        let dt = now.timeIntervalSince(prevSample)
        if dt > 0.5 && prevTx > 0 {
            txRate = max(0, Double(s.tx_bytes - prevTx) / dt)
            rxRate = max(0, Double(s.rx_bytes - prevRx) / dt)
        }
        prevTx = s.tx_bytes; prevRx = s.rx_bytes; prevSample = now
        txBytes = s.tx_bytes; rxBytes = s.rx_bytes

        if let ae = s.auth_error, !ae.isEmpty {
            statusLine = "VK session rejected — re-login"
            detail = ae
        } else if s.active_conns > 0 {
            statusLine = "Connected"
            detail = ""
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

    func submitCaptcha(token: String) {
        postControl("/solve", query: [URLQueryItem(name: "token", value: token)])
        captchaPending = false
        captchaURL = nil
    }

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

    // MARK: - Auto mode (direct-internet failover)

    private func startAutoProbe() {
        stopAutoProbe()
        if !isRunning { statusLine = "Auto: idle (direct OK)" }
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeDirect() }
        }
        RunLoop.main.add(t, forMode: .common)
        probeTimer = t
        probeDirect()
    }

    private func stopAutoProbe() {
        probeTimer?.invalidate()
        probeTimer = nil
        failStreak = 0
        okStreak = 0
    }

    /// Probe the direct internet path. The probe host MUST be forced DIRECT in
    /// Surge (see docs/automation.md) so this reflects real direct connectivity
    /// even while the tunnel is up. Ephemeral session, no caching, short timeout.
    private func probeDirect() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 5
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.allowsConstrainedNetworkAccess = true
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: probeURL)
        req.httpMethod = "GET"
        session.dataTask(with: req) { [weak self] _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse).map { (200...399).contains($0.statusCode) } ?? false
            Task { @MainActor in self?.onProbeResult(ok: ok) }
        }.resume()
    }

    private func onProbeResult(ok: Bool) {
        guard autoMode else { return }
        directOK = ok
        if ok {
            okStreak += 1; failStreak = 0
            // Direct recovered — stop the auto-started tunnel after a couple of
            // confirmations (hysteresis) so a single blip doesn't flap it.
            if isRunning && startedByAuto && okStreak >= 3 {
                statusLine = "Auto: direct recovered — stopping tunnel"
                stopInternal()
            } else if !isRunning {
                statusLine = "Auto: idle (direct OK)"
            }
        } else {
            failStreak += 1; okStreak = 0
            // Direct down — bring the tunnel up after 2 consecutive failures.
            if !isRunning && failStreak >= 2 {
                statusLine = "Auto: direct down — starting tunnel"
                startInternal(auto: true)
            }
        }
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
