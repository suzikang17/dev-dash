import Foundation

/// Codable mirror of a hook event for the durable NDJSON operation log
/// (ADR 0013). Deliberately NOT `ClaudeIntegrationEvent` — that view struct
/// isn't Codable and its `id`/`timestamp` are construction-time.
struct PersistedEvent: Codable {
    let ts: String          // ISO-8601 with fractional seconds
    let id: String          // stable UUID string
    let session: String?    // session_id from the hook payload
    let cwd: String?
    let hook: String        // raw hook_event_name
    let cat: String         // ClaudeIntegrationEvent.Category rawValue
    let detail: String      // human-readable one-liner
}

/// Append-only NDJSON operation log: one JSON object per line, per project,
/// at `<projectPath>/.devdash/events/<YYYY-MM-DD>.ndjson` (source of truth;
/// `DashboardStore.recentEvents` is a 300-cap tail view). Events with no
/// matched project go to `~/.devdash/events/_unmatched.ndjson`.
///
/// Crash-safety: appends are `seekToEnd` + single write on a serial utility
/// queue — never read-modify-write. Readers skip malformed lines, so a line
/// torn by a crash can't poison the log.
enum EventLogStore {

    /// Serial queue: keeps appends off the main thread AND ordered.
    private static let queue = DispatchQueue(label: "devdash.eventlog", qos: .utility)

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    static func dir(forProject projectPath: String) -> String {
        "\(projectPath)/.devdash/events"
    }

    static var unmatchedDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".devdash/events")
    }

    /// Log file path for a project (or the global unmatched file when nil).
    static func filePath(projectPath: String?, date: Date = Date(),
                         unmatchedDirOverride: String? = nil) -> String {
        if let projectPath {
            return "\(dir(forProject: projectPath))/\(dayFormatter.string(from: date)).ndjson"
        }
        return "\(unmatchedDirOverride ?? unmatchedDir)/_unmatched.ndjson"
    }

    /// Append one event. Fire-and-forget: serialized off-main; errors are
    /// swallowed (the log is an observability surface, never a blocker).
    static func append(_ event: PersistedEvent, projectPath: String?,
                       date: Date = Date(), unmatchedDirOverride: String? = nil) {
        let path = filePath(projectPath: projectPath, date: date,
                            unmatchedDirOverride: unmatchedDirOverride)
        queue.async { appendSync(event, to: path) }
    }

    /// Synchronous append — used directly by self-tests; production goes
    /// through `append` (same code, on the serial queue).
    static func appendSync(_ event: PersistedEvent, to path: String) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)   // newline
        let fm = FileManager.default
        let dirPath = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forUpdatingAtPath: path) else { return }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end > 0 {
            // Heal a crash-torn tail: if the file doesn't end in a newline the
            // previous write was interrupted — terminate that line so this
            // append starts clean. Only the torn line is lost (readers skip
            // malformed lines); never read-modify-write.
            try? handle.seek(toOffset: end - 1)
            let last = try? handle.read(upToCount: 1)
            _ = try? handle.seekToEnd()
            if last?.first != 0x0A {
                try? handle.write(contentsOf: Data([0x0A]))
            }
        }
        try? handle.write(contentsOf: data)
    }

    /// Block until all queued appends have been written (tests + shutdown).
    static func flush() {
        queue.sync {}
    }

    /// Read a log file, skipping malformed lines (e.g. a crash-torn tail).
    static func read(at path: String) -> [PersistedEvent] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return raw.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(PersistedEvent.self, from: data)
        }
    }

    /// Today's events for a project (tail-view reconstruction on launch).
    static func readToday(projectPath: String, date: Date = Date()) -> [PersistedEvent] {
        read(at: filePath(projectPath: projectPath, date: date))
    }
}
