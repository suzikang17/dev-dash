import Foundation

/// Local git identity of a repo: enough to eyeball whether two machines are
/// running the same build (branch + short SHA + commit date) plus optional
/// ahead/behind vs. the last-known upstream (no network — reflects whatever
/// `git fetch` last ran; use `checkRemote` for a live comparison).
struct RepoVersionInfo: Identifiable {
    let name: String
    let path: String
    let branch: String?
    let shortSHA: String?
    let commitDate: Date?
    var ahead: Int = 0
    var behind: Int = 0
    /// nil until `checkRemote` has been run this session.
    var remoteChecked: Bool = false

    var id: String { path }
}

enum RepoVersionScanner {

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Walk up from `path` to find the nearest ancestor containing `.git`.
    static func findRepoRoot(from path: String) -> String? {
        var dir = URL(fileURLWithPath: path).standardized
        // If `path` is a file (e.g. a symlink target), start from its directory.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue {
            dir.deleteLastPathComponent()
        }
        for _ in 0..<20 {   // bounded walk — never spin on a detached/root path
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // reached filesystem root
            dir = parent
        }
        return nil
    }

    /// Resolve the lore CLI's source repo by following the `lore` symlink
    /// (`~/.local/bin/lore` → `.../packages/cli/bin/lore.js`) up to its git root.
    /// Falls back to `which lore` if the well-known path isn't a symlink there.
    static func resolveLoreRepoPath() async -> String? {
        let wellKnown = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/lore")
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: wellKnown) {
            let resolved = target.hasPrefix("/")
                ? target
                : (wellKnown as NSString).deletingLastPathComponent + "/" + target
            if let root = findRepoRoot(from: resolved) { return root }
        }
        if let which = await runShell("/usr/bin/which", args: ["lore"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !which.isEmpty {
            return findRepoRoot(from: which)
        }
        return nil
    }

    /// Local-only info: branch, short SHA, commit date, and ahead/behind vs.
    /// whatever upstream ref git already has cached (no fetch).
    static func scan(name: String, path: String) async -> RepoVersionInfo? {
        guard FileManager.default.fileExists(atPath: "\(path)/.git") else { return nil }

        let script = """
        git rev-parse --abbrev-ref HEAD 2>/dev/null
        printf '\\n===SHA===\\n'
        git rev-parse --short HEAD 2>/dev/null
        printf '\\n===DATE===\\n'
        git log -1 --format=%cI HEAD 2>/dev/null
        printf '\\n===AHEADBEHIND===\\n'
        git rev-list --left-right --count HEAD...@{u} 2>/dev/null
        """
        guard let raw = await runShell("/bin/sh", args: ["-c", script], cwd: path, timeoutSeconds: 5) else {
            return nil
        }

        var sections: [String: String] = [:]
        var currentKey = "BRANCH"
        var buf: [String] = []
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("===") && line.hasSuffix("===") {
                sections[currentKey] = buf.joined(separator: "\n")
                currentKey = String(line.dropFirst(3).dropLast(3))
                buf = []
            } else {
                buf.append(line)
            }
        }
        sections[currentKey] = buf.joined(separator: "\n")

        func trimmed(_ key: String) -> String? {
            let v = (sections[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }

        let branch = trimmed("BRANCH")
        let sha = trimmed("SHA")
        let date = trimmed("DATE").flatMap { isoFormatter.date(from: $0) }

        var ahead = 0, behind = 0
        if let ab = trimmed("AHEADBEHIND") {
            let parts = ab.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        }

        return RepoVersionInfo(name: name, path: path, branch: branch, shortSHA: sha,
                               commitDate: date, ahead: ahead, behind: behind)
    }

    /// Live comparison: fetches the remote, then re-scans ahead/behind.
    /// Network I/O — only call from an explicit user action, never on a timer.
    static func checkRemote(name: String, path: String) async -> RepoVersionInfo? {
        _ = await runShell("/usr/bin/git", args: ["fetch", "--quiet"], cwd: path, timeoutSeconds: 15)
        guard var info = await scan(name: name, path: path) else { return nil }
        info.remoteChecked = true
        return info
    }
}
