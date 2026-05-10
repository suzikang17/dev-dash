import Foundation

/// Persists information about app-spawned dev servers so we can re-attach to them
/// after DevDash is restarted. The actual server processes are orphaned to init
/// when DevDash quits — they keep running, and we re-find them by PID + log file.
struct ServerStateEntry: Codable, Equatable {
    let pid: Int32
    let logPath: String
    let startedAt: Date
    let command: String
}

enum ServerStateStore {
    private static var statePath: String {
        let dir = "\(NSHomeDirectory())/.devdash"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/server-state.json"
    }

    private static let queue = DispatchQueue(label: "devdash.server-state")

    static func load() -> [String: ServerStateEntry] {
        queue.sync {
            guard FileManager.default.fileExists(atPath: statePath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)) else { return [:] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([String: ServerStateEntry].self, from: data)) ?? [:]
        }
    }

    static func upsert(projectPath: String, entry: ServerStateEntry) {
        queue.sync {
            var current: [String: ServerStateEntry] = [:]
            if let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                current = (try? decoder.decode([String: ServerStateEntry].self, from: data)) ?? [:]
            }
            current[projectPath] = entry
            persist(current)
        }
    }

    static func remove(projectPath: String) {
        queue.sync {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var current = try? decoder.decode([String: ServerStateEntry].self, from: data) else { return }
            current.removeValue(forKey: projectPath)
            persist(current)
        }
    }

    private static func persist(_ map: [String: ServerStateEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath))
    }

    /// Send signal 0 to PID — succeeds iff the process exists.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}
