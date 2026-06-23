import Foundation

enum GitDiffScanner {

    /// Parse `git status --porcelain=v1`. X = staged column, Y = worktree column.
    static func changedFiles(path: String) async -> [ChangedFile] {
        guard let raw = await ShellRunner.run("/usr/bin/git",
            args: ["-c", "core.quotepath=false", "status", "--porcelain=v1"],
            cwd: path, timeout: 10) else { return [] }

        var files: [ChangedFile] = []
        for line in raw.components(separatedBy: "\n") where line.count >= 4 {
            let chars = Array(line)
            let x = chars[0]
            let y = chars[1]
            var pathPart = String(line.dropFirst(3))
            if let arrow = pathPart.range(of: " -> ") {   // rename: "old -> new"
                pathPart = String(pathPart[arrow.upperBound...])
            }
            pathPart = pathPart.trimmingCharacters(in: .whitespaces)
            let untracked = (x == "?" && y == "?")
            files.append(ChangedFile(
                path: pathPart,
                stagedStatus: (x == " " || x == "?") ? nil : x,
                unstagedStatus: (y == " ") ? nil : y,
                isUntracked: untracked))
        }
        return files
    }

    static func commits(path: String, limit: Int = 60) async -> [GitCommit] {
        let fmt = "%H%x1f%h%x1f%s%x1f%an%x1f%cr"
        guard let raw = await ShellRunner.run("/usr/bin/git",
            args: ["log", "-n", "\(limit)", "--pretty=format:\(fmt)"],
            cwd: path, timeout: 10) else { return [] }

        var commits: [GitCommit] = []
        for line in raw.components(separatedBy: "\n") where !line.isEmpty {
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count == 5 else { continue }
            commits.append(GitCommit(sha: f[0], shortSha: f[1], subject: f[2],
                                     author: f[3], relativeDate: abbreviateRelative(f[4])))
        }
        return commits
    }

    /// Abbreviate git's `%cr` ("34 seconds ago" -> "34s", "3 minutes ago" -> "3m").
    static func abbreviateRelative(_ s: String) -> String {
        let abbr = ["second": "s", "minute": "m", "hour": "h",
                    "day": "d", "week": "w", "month": "mo", "year": "y"]
        let pattern = #"^(?:(\d+)|an?)\s+(second|minute|hour|day|week|month|year)s?\s+ago$"#
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let unitRange = Range(m.range(at: 2), in: s) else { return s }
        let num = Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? "1"
        return "\(num)\(abbr[String(s[unitRange])] ?? "")"
    }

    /// Files changed in a single commit (vs its first parent).
    static func commitFiles(path: String, sha: String) async -> [ChangedFile] {
        guard let raw = await ShellRunner.run("/usr/bin/git",
            args: ["-c", "core.quotepath=false", "show", "--name-status", "--format=", sha],
            cwd: path, timeout: 10) else { return [] }

        var files: [ChangedFile] = []
        for line in raw.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            let status = parts[0].first ?? "M"
            let filePath = (parts.last ?? "").trimmingCharacters(in: .whitespaces)
            files.append(ChangedFile(path: filePath, stagedStatus: status,
                                     unstagedStatus: nil, isUntracked: false))
        }
        return files
    }

    /// The full multi-file diff for a commit (vs its first parent), in one call.
    /// Split with `UnifiedDiffParser.parseMultiFile`.
    static func commitFullDiff(path: String, sha: String) async -> String? {
        await ShellRunner.run("/usr/bin/git",
            args: ["-c", "core.quotepath=false", "show", "--format=", sha],
            cwd: path, timeout: 20)
    }

    /// Diff for "what a Claude Code session changed": compares the given files from
    /// the commit just BEFORE the session started up to the current working tree, so
    /// changes that were since committed still show. Falls back to vs-HEAD if no
    /// `since` or no earlier commit. Empty list -> empty diff.
    static func sessionDiff(path: String, files: [String], since: Date?) async -> String? {
        guard !files.isEmpty else { return "" }
        var base = "HEAD"
        if let since {
            let iso = ISO8601DateFormatter().string(from: since)
            if let sha = await ShellRunner.run("/usr/bin/git",
                args: ["rev-list", "-1", "--before=\(iso)", "HEAD"], cwd: path, timeout: 10)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty {
                base = sha
            }
        }
        return await ShellRunner.run("/usr/bin/git",
            args: ["-c", "core.quotepath=false", "diff", base, "--"] + files,
            cwd: path, timeout: 20)
    }

    // MARK: - GitHub PRs (via gh)

    private struct GHAuthor: Decodable { let login: String? }
    private struct GHPR: Decodable {
        let number: Int; let title: String; let state: String
        let author: GHAuthor?; let headRefName: String?
    }

    /// List PRs (open + merged/closed) via `gh`. Returns [] if gh is missing/unauthed.
    static func pullRequests(path: String) async -> [PRSummary] {
        let cmd = "gh pr list --state all --limit 50 --json number,title,state,author,headRefName"
        guard let raw = await ShellRunner.run("/bin/zsh", args: ["-lc", cmd], cwd: path, timeout: 25),
              let data = raw.data(using: .utf8),
              let prs = try? JSONDecoder().decode([GHPR].self, from: data) else { return [] }
        return prs.map {
            PRSummary(number: $0.number, title: $0.title, state: $0.state,
                      author: $0.author?.login ?? "?", headRefName: $0.headRefName ?? "")
        }
    }

    static func prDiff(path: String, number: Int) async -> String? {
        await ShellRunner.run("/bin/zsh", args: ["-lc", "gh pr diff \(number)"], cwd: path, timeout: 30)
    }

    static func openPRWeb(path: String, number: Int) async {
        _ = await ShellRunner.run("/bin/zsh", args: ["-lc", "gh pr view \(number) --web"], cwd: path, timeout: 15)
    }

    static func browseCommit(path: String, sha: String) async {
        _ = await ShellRunner.run("/bin/zsh", args: ["-lc", "gh browse \(sha)"], cwd: path, timeout: 15)
    }

    /// Raw unified diff for one file from the requested source. `untracked` files
    /// have no tracked diff, so use --no-index against /dev/null to show them as added.
    static func fileDiff(path: String, file: String, source: FileDiffSource,
                         untracked: Bool = false) async -> String? {
        let args: [String]
        switch source {
        case .unstaged:
            args = untracked
                ? ["diff", "--no-index", "--", "/dev/null", file]
                : ["diff", "--", file]
        case .staged:
            args = ["diff", "--cached", "--", file]
        case .commit(let sha):
            args = ["show", sha, "--", file]
        }
        return await ShellRunner.run("/usr/bin/git", args: args, cwd: path, timeout: 15)
    }

    // MARK: - Mutations (return success)

    static func stage(path: String, file: String) async -> Bool {
        await GitStatusScanner.op(["add", "--", file], in: path).1
    }

    static func unstage(path: String, file: String) async -> Bool {
        await GitStatusScanner.op(["reset", "HEAD", "--", file], in: path).1
    }

    static func revert(path: String, file: String, untracked: Bool) async -> Bool {
        if untracked {
            return await GitStatusScanner.op(["clean", "-f", "--", file], in: path).1
        } else {
            return await GitStatusScanner.op(["checkout", "--", file], in: path).1
        }
    }
}
