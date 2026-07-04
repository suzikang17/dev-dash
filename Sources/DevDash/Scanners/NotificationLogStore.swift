import Foundation

/// The kind of an app notification — one case per trigger. Drives per-kind
/// banner toggles (Settings) and icons/labels in the notification center.
enum NotificationKind: String, Codable, CaseIterable {
    // existing triggers (previously raw Notifier.post calls)
    case taskCreated, prReviewTask, taskDone, artifactAdded, prOpened, sessionFinished
    // new triggers
    case needsInput, sessionIdle, prMerged, ticketStatusChanged

    var label: String {
        switch self {
        case .taskCreated:         return "New task created"
        case .prReviewTask:        return "PR review task created"
        case .taskDone:            return "Task completed"
        case .artifactAdded:       return "Artifact added"
        case .prOpened:            return "PR opened"
        case .sessionFinished:     return "Claude session finished"
        case .needsInput:          return "Claude needs input"
        case .sessionIdle:         return "Claude turn finished (idle)"
        case .prMerged:            return "PR merged"
        case .ticketStatusChanged: return "Ticket status changed"
        }
    }

    var systemImage: String {
        switch self {
        case .taskCreated:         return "plus.circle"
        case .prReviewTask:        return "eye.circle"
        case .taskDone:            return "checkmark.circle"
        case .artifactAdded:       return "doc.badge.plus"
        case .prOpened:            return "arrow.triangle.pull"
        case .sessionFinished:     return "sparkles"
        case .needsInput:          return "exclamationmark.bubble"
        case .sessionIdle:         return "zzz"
        case .prMerged:            return "checkmark.seal"
        case .ticketStatusChanged: return "square.stack.3d.up"
        }
    }
}

/// One notification in the feed. Codable → one NDJSON line per notification.
/// `projectPath`/`tab`/`taskId` are the click-to-navigate target (all optional).
struct AppNotification: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: NotificationKind
    let date: Date
    let title: String
    let body: String
    let projectPath: String?
    let tab: String?       // DetailTab rawValue
    let taskId: String?    // opens TaskDetailSheet when present
}

/// Append-only NDJSON notification log at `~/.devdash/notifications/<YYYY-MM-DD>.ndjson`
/// (machine-global — the feed spans projects). Same crash-safety contract as
/// `EventLogStore` (ADR 0013): seekToEnd + single write on a serial utility
/// queue, torn-tail healing, readers skip malformed lines.
enum NotificationLogStore {

    private static let queue = DispatchQueue(label: "devdash.notiflog", qos: .utility)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static var defaultDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".devdash/notifications")
    }

    static func filePath(dir: String = defaultDir, date: Date = Date()) -> String {
        "\(dir)/\(dayFormatter.string(from: date)).ndjson"
    }

    /// Fire-and-forget append, serialized off-main; errors swallowed.
    static func append(_ item: AppNotification, dirOverride: String? = nil) {
        let path = filePath(dir: dirOverride ?? defaultDir, date: item.date)
        queue.async { appendSync(item, to: path) }
    }

    /// Synchronous append — used directly by self-tests; production goes
    /// through `append` (same code, on the serial queue).
    static func appendSync(_ item: AppNotification, to path: String) {
        guard var data = try? encoder.encode(item) else { return }
        data.append(0x0A)
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
            // Heal a crash-torn tail (see EventLogStore.appendSync for rationale).
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

    /// Read one log file, skipping malformed lines.
    static func read(at path: String) -> [AppNotification] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return raw.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AppNotification.self, from: data)
        }
    }

    /// Launch-time feed reconstruction: today + the previous 2 days, newest
    /// first, capped at `limit`.
    static func restore(dir: String = defaultDir, now: Date = Date(), limit: Int = 300) -> [AppNotification] {
        var all: [AppNotification] = []
        for dayOffset in 0..<3 {
            let d = now.addingTimeInterval(-Double(dayOffset) * 86_400)
            all.append(contentsOf: read(at: filePath(dir: dir, date: d)))
        }
        all.sort { $0.date > $1.date }
        return Array(all.prefix(limit))
    }
}
