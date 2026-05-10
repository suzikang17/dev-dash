import Foundation

/// Manages app-spawned dev servers. Output is redirected to a log file on disk so
/// the server's process can survive a DevDash quit and we can re-attach to its
/// log stream on the next launch via `LogFileTailer`.
actor ServerRunner {
    static let shared = ServerRunner()

    private var tailers: [String: LogFileTailer] = [:]

    enum StartError: Error, LocalizedError {
        case noStartCommand
        case alreadyRunning
        case spawnFailed(String)

        var errorDescription: String? {
            switch self {
            case .noStartCommand: return "Couldn't detect a dev script (no package.json, manage.py, etc.)"
            case .alreadyRunning: return "This project is already running."
            case .spawnFailed(let msg): return "Failed to start: \(msg)"
            }
        }
    }

    struct StartCommand {
        let label: String
        let shellCommand: String
    }

    /// Inspect the project to figure out what dev command to run.
    static func detectCommand(projectPath: String) -> StartCommand? {
        let fm = FileManager.default
        let pkgPath = "\(projectPath)/package.json"

        if fm.fileExists(atPath: pkgPath) {
            let pm: String
            if fm.fileExists(atPath: "\(projectPath)/pnpm-lock.yaml") { pm = "pnpm" }
            else if fm.fileExists(atPath: "\(projectPath)/bun.lockb") || fm.fileExists(atPath: "\(projectPath)/bun.lock") { pm = "bun" }
            else if fm.fileExists(atPath: "\(projectPath)/yarn.lock") { pm = "yarn" }
            else { pm = "npm" }

            var script = "dev"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: pkgPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let scripts = json["scripts"] as? [String: String] {
                if scripts["dev"] != nil { script = "dev" }
                else if scripts["start"] != nil { script = "start" }
                else if let first = scripts.keys.sorted().first { script = first }
            }

            let runWord = pm == "npm" ? "run \(script)" : script
            return StartCommand(label: "\(pm) \(runWord)", shellCommand: "\(pm) \(runWord)")
        }
        if fm.fileExists(atPath: "\(projectPath)/manage.py") {
            return StartCommand(label: "python manage.py runserver", shellCommand: "python manage.py runserver")
        }
        if fm.fileExists(atPath: "\(projectPath)/app.py") {
            return StartCommand(label: "python app.py", shellCommand: "python app.py")
        }
        if fm.fileExists(atPath: "\(projectPath)/Cargo.toml") {
            return StartCommand(label: "cargo run", shellCommand: "cargo run")
        }
        if fm.fileExists(atPath: "\(projectPath)/Gemfile") {
            return StartCommand(label: "bundle exec rails server", shellCommand: "bundle exec rails server")
        }
        return nil
    }

    /// Start the dev server. Output is redirected to `.devdash/logs/server-<ts>.log`
    /// inside the project. Streams new lines via `onLine`. Persists state so we can
    /// re-attach on the next DevDash launch.
    @discardableResult
    func start(projectPath: String, onLine: @escaping @Sendable (String) -> Void) throws -> StartCommand {
        let existing = ServerStateStore.load()
        if let entry = existing[projectPath], ServerStateStore.isAlive(entry.pid) {
            attachTail(projectPath: projectPath, logPath: entry.logPath, onLine: onLine, fromBeginning: true)
            throw StartError.alreadyRunning
        }

        guard let cmd = ServerRunner.detectCommand(projectPath: projectPath) else {
            throw StartError.noStartCommand
        }

        let logsDir = "\(projectPath)/.devdash/logs"
        try FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let logPath = "\(logsDir)/server-\(stamp).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)

        let qPath = shellQuote(projectPath)
        let qLog = shellQuote(logPath)
        // exec replaces zsh in-place. When DevDash quits, the dev process gets
        // adopted by init and keeps running — we re-find it by PID + log file.
        let line = "cd \(qPath) && exec \(cmd.shellCommand) > \(qLog) 2>&1"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-ic", line]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw StartError.spawnFailed(error.localizedDescription)
        }

        let pid = task.processIdentifier
        let entry = ServerStateEntry(
            pid: pid,
            logPath: logPath,
            startedAt: Date(),
            command: cmd.label
        )
        ServerStateStore.upsert(projectPath: projectPath, entry: entry)

        attachTail(projectPath: projectPath, logPath: logPath, onLine: onLine, fromBeginning: false)
        return cmd
    }

    /// Re-attach to a server we (or a previous DevDash instance) started.
    func reattach(projectPath: String, entry: ServerStateEntry, onLine: @escaping @Sendable (String) -> Void) {
        attachTail(projectPath: projectPath, logPath: entry.logPath, onLine: onLine, fromBeginning: true)
    }

    private func attachTail(projectPath: String, logPath: String, onLine: @escaping @Sendable (String) -> Void, fromBeginning: Bool) {
        tailers[projectPath]?.stop()
        let tailer = LogFileTailer(path: logPath, fromBeginning: fromBeginning)
        tailers[projectPath] = tailer
        Task.detached {
            for await line in tailer.lines {
                onLine(line)
            }
        }
    }

    func stop(projectPath: String) {
        let state = ServerStateStore.load()
        if let entry = state[projectPath] {
            stopPid(entry.pid)
        }
        tailers[projectPath]?.stop()
        tailers.removeValue(forKey: projectPath)
        ServerStateStore.remove(projectPath: projectPath)
    }

    func stop(pid: Int32) {
        stopPid(pid)
        for (path, entry) in ServerStateStore.load() where entry.pid == pid {
            tailers[path]?.stop()
            tailers.removeValue(forKey: path)
            ServerStateStore.remove(projectPath: path)
        }
    }

    private func stopPid(_ pid: Int32) {
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    func isManaged(_ projectPath: String) -> Bool {
        ServerStateStore.load()[projectPath] != nil
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
