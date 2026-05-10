import Foundation

/// Runs validation commands defined by templates and captures the result.
/// Goes through `/bin/zsh -ic` so PATH (fnm/asdf/brew shims) is correct.
enum HealthCheckRunner {
    private static let outputTailBytes = 4096

    static func run(_ check: HealthCheckSpec, projectPath: String) async -> HealthRunResult {
        let startedAt = Date()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devdash-health-out-\(UUID().uuidString)")
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devdash-health-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ic", check.command]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        if let outHandle = try? FileHandle(forWritingTo: outURL) {
            process.standardOutput = outHandle
        }
        if let errHandle = try? FileHandle(forWritingTo: errURL) {
            process.standardError = errHandle
        }

        var timedOut = false
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
            return HealthRunResult(
                checkId: check.id, stageId: check.stageId, command: check.command,
                startedAt: startedAt, finishedAt: Date(),
                exitCode: -1, timedOut: false,
                stdoutTail: "", stderrTail: "Failed to launch: \(error.localizedDescription)"
            )
        }

        // Race between exit and timeout. Process.terminate() if we hit timeout.
        let timeoutNanos = UInt64(check.timeoutSeconds) * 1_000_000_000
        let exited: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let deadline = DispatchTime.now() + .seconds(check.timeoutSeconds)
                while process.isRunning {
                    if DispatchTime.now() > deadline { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.5)
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: true)
                }
            }
        }
        timedOut = !exited
        _ = timeoutNanos // (kept for clarity; loop above uses seconds)

        process.waitUntilExit()

        let stdout = readTail(outURL)
        let stderr = readTail(errURL)
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)

        return HealthRunResult(
            checkId: check.id, stageId: check.stageId, command: check.command,
            startedAt: startedAt, finishedAt: Date(),
            exitCode: process.terminationStatus, timedOut: timedOut,
            stdoutTail: stdout, stderrTail: stderr
        )
    }

    private static func readTail(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let tail = data.suffix(outputTailBytes)
        return String(data: tail, encoding: .utf8) ?? ""
    }
}
