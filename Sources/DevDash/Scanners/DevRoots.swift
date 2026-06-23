import Foundation

enum DevRoots {
    static let home = NSHomeDirectory()

    /// Folders scanned out of the box. Used until the user customizes the list.
    static let defaultRoots: [String] = ["dev", "sbd", "projects", "code", "workspace"]
        .map { "\(home)/\($0)/" }

    /// UserDefaults key holding the user's customized root list.
    static let defaultsKey = "devdash.devRoots"

    /// Folders to scan for projects. Falls back to `defaultRoots` only when the
    /// user has never customized the list; a deliberately emptied list stays empty.
    static var roots: [String] {
        guard let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else {
            return defaultRoots
        }
        return stored.map(normalize)
    }

    /// Persist a customized root list (normalized + de-duplicated, order preserved).
    static func setRoots(_ newRoots: [String]) {
        var seen = Set<String>()
        let cleaned = newRoots
            .map(normalize)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        UserDefaults.standard.set(cleaned, forKey: defaultsKey)
    }

    /// Forget customization and revert to `defaultRoots`.
    static func resetRoots() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Expand a leading tilde (`~`, `~/…`, or `~user/…`), trim whitespace, and
    /// ensure a trailing slash so prefix matching in `isDevPath`/`rootGroup`
    /// behaves consistently.
    static func normalize(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "" }
        path = (path as NSString).expandingTildeInPath
        if !path.hasSuffix("/") { path += "/" }
        return path
    }

    static func isDevPath(_ path: String) -> Bool {
        roots.contains { path.hasPrefix($0) }
    }

    static func projectName(for path: String) -> String {
        for root in roots where path.hasPrefix(root) {
            let rel = String(path.dropFirst(root.count))
            let parts = rel.split(separator: "/").map(String.init)
            if parts.isEmpty { return path }
            if parts.count == 1 { return parts[0] }
            return "\(parts[0]) › \(parts.last!)"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func shortenPath(_ path: String) -> String {
        if path.hasPrefix("\(home)/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
    }

    /// First path segment under `~/` (e.g. "dev", "sbd", "projects").
    /// Used to group projects in the sidebar.
    static func rootGroup(for path: String) -> String {
        for root in roots where path.hasPrefix(root) {
            // root is like "/Users/suki/dev/" — strip the user-home prefix
            return URL(fileURLWithPath: String(root.dropLast())).lastPathComponent
        }
        return "Other"
    }
}
