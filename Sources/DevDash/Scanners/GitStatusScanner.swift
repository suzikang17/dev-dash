import Foundation

struct GitStatus {
    let branch: String?
    let upstream: String?
    let aheadCount: Int
    let behindCount: Int
    let stagedCount: Int
    let unstagedCount: Int
    let untrackedCount: Int
    let stashCount: Int
    let localBranches: [String]
    let worktrees: [Worktree]

    struct Worktree: Identifiable, Hashable {
        let path: String
        let branch: String?
        let isMain: Bool
        var id: String { path }
        var displayName: String { (path as NSString).lastPathComponent }
    }

    var isClean: Bool { stagedCount == 0 && unstagedCount == 0 && untrackedCount == 0 }
    var totalChanged: Int { stagedCount + unstagedCount + untrackedCount }
}

enum GitStatusScanner {
    static func scan(path: String) async -> GitStatus? {
        guard FileManager.default.fileExists(atPath: "\(path)/.git") else { return nil }

        let script = """
        git status --short --branch 2>/dev/null
        printf '\\n===BRANCHES===\\n'
        git branch --format='%(refname:short)' 2>/dev/null
        printf '\\n===STASH===\\n'
        git stash list 2>/dev/null | wc -l | tr -d ' '
        printf '\\n===WORKTREES===\\n'
        git worktree list --porcelain 2>/dev/null
        """

        guard let raw = await runShell("/bin/sh", args: ["-c", script], cwd: path, timeoutSeconds: 5) else {
            return nil
        }

        var sections: [String: String] = [:]
        var currentKey = "STATUS"
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

        var branch: String? = nil
        var upstream: String? = nil
        var ahead = 0, behind = 0
        var staged = 0, unstaged = 0, untracked = 0

        for (i, line) in (sections["STATUS"] ?? "").components(separatedBy: "\n").enumerated() {
            if i == 0 && line.hasPrefix("## ") {
                let rest = String(line.dropFirst(3))
                ahead = captureInt(#"ahead (\d+)"#, in: rest) ?? 0
                behind = captureInt(#"behind (\d+)"#, in: rest) ?? 0
                let branchPart = (rest.components(separatedBy: " [").first ?? rest)
                let dotParts = branchPart.components(separatedBy: "...")
                let b = dotParts[0].trimmingCharacters(in: .whitespaces)
                branch = (b.isEmpty || b == "HEAD") ? nil : b
                if dotParts.count > 1 {
                    upstream = dotParts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if line.count >= 2 {
                let chars = Array(line)
                let x = chars[0], y = chars[1]
                if x == "?" && y == "?" { untracked += 1 }
                else {
                    if x != " " { staged += 1 }
                    if y != " " { unstaged += 1 }
                }
            }
        }

        let localBranches = (sections["BRANCHES"] ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let stashCount = Int((sections["STASH"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let worktrees = parseWorktrees(sections["WORKTREES"] ?? "", mainPath: path)

        return GitStatus(
            branch: branch,
            upstream: upstream,
            aheadCount: ahead,
            behindCount: behind,
            stagedCount: staged,
            unstagedCount: unstaged,
            untrackedCount: untracked,
            stashCount: stashCount,
            localBranches: localBranches,
            worktrees: worktrees
        )
    }

    /// Run a mutating git operation. Returns (combined stdout+stderr, success).
    static func op(_ args: [String], in path: String) async -> (String, Bool) {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: path)

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("devdash-git-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let fh = try? FileHandle(forWritingTo: tempURL) else {
                cont.resume(returning: ("", false)); return
            }
            process.standardOutput = fh
            process.standardError = fh

            let lock = NSLock()
            var resumed = false
            func done(_ success: Bool) {
                lock.lock(); defer { lock.unlock() }
                if resumed { return }
                resumed = true
                try? fh.close()
                let out = (try? Data(contentsOf: tempURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                try? FileManager.default.removeItem(at: tempURL)
                cont.resume(returning: (out, success))
            }

            process.terminationHandler = { p in done(p.terminationStatus == 0) }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if process.isRunning { process.terminate() }
                }
            } catch { done(false) }
        }
    }

    private static func captureInt(_ pattern: String, in str: String) -> Int? {
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
              let r = Range(m.range(at: 1), in: str) else { return nil }
        return Int(str[r])
    }

    private static func parseWorktrees(_ raw: String, mainPath: String) -> [GitStatus.Worktree] {
        var result: [GitStatus.Worktree] = []
        var pendingPath: String? = nil
        var pendingBranch: String? = nil

        func flush() {
            guard let p = pendingPath else { return }
            // `git worktree list --porcelain` always emits the PRIMARY worktree
            // first, regardless of which checkout the command was run from.
            // Mark index 0 (first flushed entry) as main; all others are linked worktrees.
            let isMain = result.isEmpty
            result.append(.init(path: p, branch: pendingBranch, isMain: isMain))
        }

        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                flush()
                pendingPath = String(line.dropFirst("worktree ".count))
                pendingBranch = nil
            } else if line.hasPrefix("branch ") {
                pendingBranch = String(line.dropFirst("branch ".count))
                    .components(separatedBy: "/").last
            }
        }
        flush()
        return result
    }
}
