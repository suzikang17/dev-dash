import Foundation
import AppKit

// MARK: - Simulator metadata

/// One entry from `baguette list` (newline-delimited JSON).
struct SimulatorDevice: Identifiable, Decodable, Hashable {
    let udid: String
    let name: String
    let state: String   // "Shutdown" | "Booted"
    let runtime: String // e.g. "iOS 26.4"

    var id: String { udid }
    var isBooted: Bool { state == "Booted" }

    /// Display label shown in the device picker.
    var displayLabel: String { "\(name) — \(runtime)" }
}

// MARK: - Errors

enum BaguetteError: LocalizedError {
    case notInstalled
    case spawnFailed(String)
    case portNeverCameUp

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "baguette is not installed. Install it with: brew install baguette (requires Xcode 26)."
        case .spawnFailed(let detail):
            return "Failed to start baguette serve: \(detail)"
        case .portNeverCameUp:
            return "baguette started but the server did not become reachable on port 8421."
        }
    }
}

// MARK: - Runner

/// Manages the `baguette serve` sidecar and provides a list of simulators.
/// All mutations must happen on the main actor; the binary-location helpers
/// are async but safe to call from any context.
@MainActor
final class BaguetteRunner: ObservableObject {

    /// The `baguette serve` sidecar is a single machine-wide server on a fixed
    /// port, so all simulator views must share ONE runner — otherwise each view
    /// spawns its own server that collides on the port, and stopping one kills it
    /// for the others. Every `SimulatorEmbedView` observes this shared instance.
    static let shared = BaguetteRunner()

    static let port: Int = 8421
    static let host: String = "127.0.0.1"

    /// URL root for the running baguette HTTP server.
    static var serverBase: URL {
        URL(string: "http://\(host):\(port)")!
    }

    /// Interactive embed URL for a given simulator.
    static func simulatorURL(udid: String) -> URL {
        serverBase.appendingPathComponent("simulators/\(udid)")
    }

    // MARK: Published state

    @Published var serverState: ServerState = .idle
    @Published var devices: [SimulatorDevice] = []
    @Published var selectedUDID: String? = nil
    @Published var lastError: BaguetteError? = nil

    enum ServerState: Equatable {
        case idle
        case starting
        case running
        case stopped
    }

    // MARK: Private

    private var process: RunningProcess? = nil
    private var terminationToken: NSObjectProtocol?

    init() {
        // Tear down `baguette serve` on app quit. Without this, the process is
        // reparented to launchd and leaks past Cmd-Q (onDisappear is not
        // reliably delivered before exit). Mirrors TerminalSessionStore.init.
        terminationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let terminationToken { NotificationCenter.default.removeObserver(terminationToken) }
    }

    // MARK: - Binary location

    /// Locate the `baguette` binary, mirroring `LoreRunner.lorePath()`.
    static func baguettePath() async -> String? {
        let candidates = [
            "/opt/homebrew/bin/baguette",
            "/usr/local/bin/baguette",
            NSHomeDirectory() + "/.local/bin/baguette",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        if let found = await ShellRunner.run("/usr/bin/which", args: ["baguette"]) {
            let t = found.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// Returns true if the baguette binary exists on this machine.
    static func isInstalled() async -> Bool {
        await baguettePath() != nil
    }

    // MARK: - Device list

    /// Run `baguette list` and parse the newline-delimited JSON output.
    func refreshDevices() async {
        guard let bin = await Self.baguettePath() else { return }
        guard let raw = await ShellRunner.run(bin, args: ["list"], timeout: 15) else { return }
        let decoder = JSONDecoder()
        var parsed: [SimulatorDevice] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let device = try? decoder.decode(SimulatorDevice.self, from: data) {
                parsed.append(device)
            }
        }
        devices = parsed.sorted { $0.name < $1.name }

        // Auto-select: prefer an already-booted device, then first available.
        if let current = selectedUDID, devices.contains(where: { $0.udid == current }) {
            // Keep current selection if it's still present.
        } else {
            selectedUDID = devices.first(where: { $0.isBooted })?.udid ?? devices.first?.udid
        }
    }

    // MARK: - Server lifecycle

    /// Boot the chosen simulator (if needed) and start `baguette serve`.
    /// Throws `BaguetteError` on failure; on success sets `serverState = .running`.
    func start() async throws {
        guard serverState == .idle || serverState == .stopped else { return }
        serverState = .starting
        lastError = nil

        // 1. Verify the binary exists.
        guard let bin = await Self.baguettePath() else {
            serverState = .idle
            let err = BaguetteError.notInstalled
            lastError = err
            throw err
        }

        // 2. If a baguette server is already serving on the port (left over from a
        //    previous launch, or started by another simulator view), adopt it
        //    instead of spawning a duplicate that would collide on the port.
        if await serverReachable() {
            serverState = .running
            await refreshDevices()
            return
        }

        // 3. Boot the selected simulator if it is Shutdown.
        if let udid = selectedUDID,
           let device = devices.first(where: { $0.udid == udid }),
           !device.isBooted {
            _ = await ShellRunner.run("/usr/bin/xcrun",
                                      args: ["simctl", "boot", udid],
                                      timeout: 60)
        }

        // 4. Spawn `baguette serve`.
        let proc: RunningProcess
        do {
            proc = try ShellRunner.start(bin, args: [
                "serve",
                "--port", "\(Self.port)",
                "--host", Self.host,
            ])
        } catch {
            serverState = .idle
            let err = BaguetteError.spawnFailed(error.localizedDescription)
            lastError = err
            throw err
        }
        process = proc

        // 4. Poll the HTTP root until it responds (up to ~10 s).
        let ready = await waitForPort(timeoutSeconds: 10)
        guard ready else {
            proc.stop()
            process = nil
            serverState = .idle
            let err = BaguetteError.portNeverCameUp
            lastError = err
            throw err
        }

        serverState = .running

        // 5. Refresh device list with up-to-date Booted states.
        await refreshDevices()

        // 6. Drain the process output in the background; finish it when it exits.
        Task { [weak self] in
            for await _ in proc.lines { /* consume output to avoid buffer back-pressure */ }
            await MainActor.run {
                guard let self else { return }
                if self.serverState == .running {
                    self.serverState = .stopped
                }
                self.process = nil
            }
        }
    }

    /// Terminate `baguette serve`.
    func stop() {
        process?.stop()
        process = nil
        serverState = .stopped
    }

    // MARK: - Private helpers

    /// Single quick probe: is a baguette server already answering on the port?
    private func serverReachable() async -> Bool {
        let url = Self.serverBase.appendingPathComponent("simulators")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: config)
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Poll `http://host:port/simulators` until it responds with HTTP 200,
    /// returning `true` if it comes up within the timeout.
    private func waitForPort(timeoutSeconds: Int) async -> Bool {
        let url = Self.serverBase.appendingPathComponent("simulators")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: config)
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            do {
                let (_, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return true
                }
            } catch {
                // Not up yet — wait a tick and retry.
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
        }
        return false
    }
}
