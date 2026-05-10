import Foundation

/// Reads and persists per-project AI-generated recap summaries to `.devdash/recap.json`.
enum RecapStore {
    static func filePath(for projectPath: String) -> String {
        "\(projectPath)/.devdash/recap.json"
    }

    static func read(_ projectPath: String) -> ProjectRecap? {
        let path = filePath(for: projectPath)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProjectRecap.self, from: data)
    }

    static func write(_ projectPath: String, recap: ProjectRecap) throws {
        let dir = "\(projectPath)/.devdash"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(recap)
        try data.write(to: URL(fileURLWithPath: filePath(for: projectPath)))
    }

    /// Read recent git log entries with subjects for a project.
    static func recentCommits(in projectPath: String, limit: Int = 20) async -> [String] {
        guard FileManager.default.fileExists(atPath: "\(projectPath)/.git") else { return [] }
        let raw = await ShellRunner.run(
            "/usr/bin/git",
            args: ["log", "-\(limit)", "--format=%h %cr — %s", "--no-merges"],
            cwd: projectPath,
            timeout: 4
        ) ?? ""
        return raw
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Build a single context string suitable for prompting Claude.
    static func buildContext(
        projectName: String,
        commits: [String],
        sessions: [ClaudeSession],
        runningPort: Int?,
        openTodoCount: Int,
        branch: String?
    ) -> String {
        var lines: [String] = []
        lines.append("Project: \(projectName)")
        if let branch = branch { lines.append("Branch: \(branch)") }
        if let port = runningPort { lines.append("Currently running on port \(port)") }
        if openTodoCount > 0 { lines.append("Open todos: \(openTodoCount)") }
        lines.append("")

        if !commits.isEmpty {
            lines.append("# Recent commits")
            lines.append(contentsOf: commits.prefix(15))
            lines.append("")
        }

        if !sessions.isEmpty {
            lines.append("# Recent Claude Code sessions")
            for s in sessions.prefix(8) {
                let when = s.lastActivity.map { relativeDate($0) } ?? "unknown"
                let intent = s.firstUserMessage.map { trimToOneLine($0, max: 200) } ?? "(no user message captured)"
                lines.append("- [\(when), \(s.messageCount) msgs] \(intent)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func trimToOneLine(_ s: String, max: Int) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= max { return oneLine }
        return String(oneLine.prefix(max)) + "…"
    }

    private static func relativeDate(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
