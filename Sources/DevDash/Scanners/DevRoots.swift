import Foundation

enum DevRoots {
    static let home = NSHomeDirectory()
    static let roots: [String] = [
        "\(home)/dev/",
        "\(home)/sbd/",
        "\(home)/projects/",
        "\(home)/code/",
        "\(home)/workspace/"
    ]

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
