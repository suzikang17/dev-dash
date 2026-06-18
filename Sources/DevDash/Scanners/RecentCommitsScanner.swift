import Foundation

/// Cross-project recent commit feed. Runs `git log` per project in parallel
/// and merges by commit time descending.
enum RecentCommitsScanner {
    static func scan(projects: [Project], perProject: Int = 5) async -> [RecentCommit] {
        let result = await withTaskGroup(of: [RecentCommit].self) { group -> [RecentCommit] in
            for proj in projects {
                group.addTask {
                    await load(name: proj.name, path: proj.path, limit: perProject)
                }
            }
            var all: [RecentCommit] = []
            for await commits in group { all.append(contentsOf: commits) }
            return all.sorted { $0.time > $1.time }
        }
        return result
    }

    private static func load(name: String, path: String, limit: Int) async -> [RecentCommit] {
        guard FileManager.default.fileExists(atPath: "\(path)/.git") else { return [] }
        // ASCII unit separator (\u{1f}) avoids collisions with commit subjects.
        let raw = await ShellRunner.run(
            "/usr/bin/git",
            args: ["log", "-n", String(limit), "--no-merges",
                   "--format=%H\u{1f}%s\u{1f}%cI\u{1f}%an"],
            cwd: path,
            timeout: 4
        ) ?? ""

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var out: [RecentCommit] = []
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            guard let time = formatter.date(from: parts[2]) else { continue }
            out.append(RecentCommit(
                hash: parts[0],
                subject: parts[1],
                time: time,
                author: parts[3],
                projectPath: path,
                projectName: name
            ))
        }
        return out
    }
}
