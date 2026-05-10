import Foundation

enum ProcessScanner {
    static let infraPorts: Set<Int> = [27017, 5432, 6379, 11434, 3306]
    // Specific extras outside the 3000-9999 default range.
    static let extraDevPorts: Set<Int> = [1313 /* Hugo */, 4321 /* Astro */, 1234, 2368 /* Ghost */]

    static func isDevPort(_ port: Int) -> Bool {
        if port >= 3000 && port <= 9999 { return true }
        return extraDevPorts.contains(port)
    }
    // System / app ports that aren't dev servers
    static let skipPorts: Set<Int> = [
        5000, 7000,        // macOS Control Center
        7265,              // Raycast
        7679,              // Google Drive
        3333,              // Roam Research
        7337,              // FNM helper
        49324, 11434       // (Ollama 11434 is in infraPorts; ignore here)
    ]
    static let infraNames: [Int: String] = [
        27017: "MongoDB",
        5432: "PostgreSQL",
        6379: "Redis",
        11434: "Ollama",
        3306: "MySQL"
    ]

    static func scan() async -> [Service] {
        guard let lsofOutput = await runShell("/usr/sbin/lsof", args: ["-iTCP", "-sTCP:LISTEN", "-nP"]) else {
            return []
        }

        struct PidEntry { let port: Int; let processName: String }
        var pidMap: [Int32: PidEntry] = [:]

        let lines = lsofOutput.split(separator: "\n").dropFirst()
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let processName = String(parts[0])
            guard let pid = Int32(parts[1]) else { continue }
            let nameField = String(parts[8])
            guard let portStr = nameField.split(separator: ":").last,
                  let port = Int(portStr) else { continue }

            if skipPorts.contains(port) { continue }
            if !infraPorts.contains(port) && !ProcessScanner.isDevPort(port) { continue }

            if pidMap[pid] == nil {
                pidMap[pid] = PidEntry(port: port, processName: processName)
            }
        }

        guard !pidMap.isEmpty else { return [] }

        let pidsCSV = pidMap.keys.map { String($0) }.joined(separator: ",")
        let cwdMap = await readCwds(pids: pidsCSV)

        var services: [Service] = []
        for (pid, entry) in pidMap {
            let isInfra = infraPorts.contains(entry.port)
            let cwd = cwdMap[pid] ?? ""

            if !isInfra && !DevRoots.isDevPath(cwd) { continue }

            let name: String
            let framework: String
            if isInfra {
                let n = infraNames[entry.port] ?? "Port \(entry.port)"
                name = n
                framework = n
            } else {
                name = cwd.isEmpty ? entry.processName : DevRoots.projectName(for: cwd)
                framework = FrameworkDetector.detect(cwd: cwd, processName: entry.processName)
            }

            services.append(Service(
                id: "\(pid)-\(entry.port)",
                pid: pid,
                port: entry.port,
                name: name,
                cwd: cwd,
                framework: framework,
                isInfra: isInfra
            ))
        }

        return services.sorted {
            if $0.isInfra != $1.isInfra { return !$0.isInfra }
            return $0.port < $1.port
        }
    }

    private static func readCwds(pids: String) async -> [Int32: String] {
        guard let output = await runShell("/usr/sbin/lsof", args: ["-p", pids]) else { return [:] }
        var map: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            guard parts[3] == "cwd" else { continue }
            guard let pid = Int32(parts[1]) else { continue }
            let cwd = parts[8...].joined(separator: " ")
            map[pid] = cwd
        }
        return map
    }
}

func runShell(_ binary: String, args: [String]) async -> String? {
    return await runShell(binary, args: args, cwd: nil, timeoutSeconds: 30)
}

func runShell(_ binary: String, args: [String], cwd: String, timeoutSeconds: Double = 3) async -> String? {
    return await runShell(binary, args: args, cwd: Optional(cwd), timeoutSeconds: timeoutSeconds)
}

private func runShell(_ binary: String, args: [String], cwd: String?, timeoutSeconds: Double) async -> String? {
    return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        if let cwd = cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        // Pipe buffers (typically 64KB on macOS) can deadlock if the child writes
        // more than that before we read. Use a temp file for stdout to avoid this.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devdash-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: tempURL) else {
            cont.resume(returning: nil)
            return
        }
        process.standardOutput = outHandle
        process.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var resumed = false
        func resumeOnce(_ value: String?) {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return }
            resumed = true
            try? outHandle.close()
            cont.resume(returning: value)
        }

        process.terminationHandler = { _ in
            try? outHandle.close()
            let data = (try? Data(contentsOf: tempURL)) ?? Data()
            try? FileManager.default.removeItem(at: tempURL)
            resumeOnce(String(data: data, encoding: .utf8))
        }

        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                if process.isRunning {
                    process.terminate()
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            resumeOnce(nil)
        }
    }
}
