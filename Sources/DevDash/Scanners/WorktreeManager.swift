import Foundation

/// Safe, fail-forward git worktree lifecycle manager.
///
/// All public methods are async, perform no UI work, and return nil/false on
/// any failure — they never crash and never perform destructive operations on
/// paths they didn't create.
///
/// Git commands used:
///   create: git -C <repo> worktree add <path> -b <branch>
///           git -C <repo> worktree add <path> <branch>   (if branch already exists)
///   remove: git -C <repo> worktree remove <path> [--force]
///           git -C <repo> branch -D <branch>             (only after confirming HEAD matches)
///   resolve: git -C <path> rev-parse --path-format=absolute --git-common-dir
enum WorktreeManager {

    // MARK: - Naming

    /// Returns the branch name (`task/<id>-<slug>`) and directory name
    /// (`task-<id>-<slug>`) for a new worktree. Pure function — no I/O.
    static func slugBranch(taskId: String, title: String) -> (branch: String, dirName: String) {
        let slug = makeSlug(title)
        let branch = "task/\(taskId)-\(slug)"
        let dirName = "task-\(taskId)-\(slug)"
        return (branch, dirName)
    }

    // MARK: - Create

    /// Create a git worktree for a task.
    ///
    /// - Guards the repo is a real git repo (`.git` present or `git rev-parse` succeeds).
    /// - Ensures `.worktrees/` is excluded from main-repo status tracking by appending
    ///   to `<repo>/.git/info/exclude` (append-if-missing; handles gitdir-file repos).
    /// - Runs `git worktree add <path> -b <branch>`, retrying with a uniquified name only
    ///   on confirmed name-collision phrases; treats all other errors as unrecoverable.
    /// - Returns `(absoluteWorktreePath, branchName)` on success, `nil` on any failure.
    ///   Logs git stderr but never throws.
    static func create(repoPath: String, taskId: String, title: String) async -> (path: String, branch: String)? {
        // Guard: must be a git repo.
        guard await isGitRepo(repoPath) else {
            log("WorktreeManager.create: \(repoPath) is not a git repo — skipping worktree")
            return nil
        }

        let (baseBranch, baseDirName) = slugBranch(taskId: taskId, title: title)

        // Ensure .worktrees/ is in the exclude file so it doesn't appear as untracked.
        await ensureWorktreesExcluded(repoPath: repoPath)

        // Determine a unique branch + path, retrying ONLY on confirmed name-collision errors.
        var branch = baseBranch
        var dirName = baseDirName
        var attempt = 0
        let worktreesDir = "\(repoPath)/.worktrees"

        while attempt < 5 {
            let worktreePath = "\(worktreesDir)/\(dirName)"
            let fm = FileManager.default

            // Check if the target path already exists.
            var isDir: ObjCBool = false
            let pathExists = fm.fileExists(atPath: worktreePath, isDirectory: &isDir)

            if pathExists && isDir.boolValue {
                // Path exists — check if it's already the right worktree for this branch.
                let headBranch = await currentBranchInWorktree(worktreePath)
                if headBranch == branch {
                    // Worktree already exists at the right branch — reuse it.
                    log("WorktreeManager.create: reusing existing worktree \(worktreePath) on \(branch)")
                    return (worktreePath, branch)
                }
                // Path exists but different branch — uniquify.
                attempt += 1
                branch = baseBranch + "-\(attempt)"
                dirName = baseDirName + "-\(attempt)"
                continue
            }

            // Try to create the worktree.  First attempt uses -b <branch>; if the
            // branch already exists in the repo we retry without -b.
            let createResult = await runGit(
                ["-C", repoPath, "worktree", "add", worktreePath, "-b", branch],
                context: "worktree add -b \(branch)"
            )

            if createResult.ok {
                log("WorktreeManager.create: created worktree \(worktreePath) on branch \(branch)")
                return (worktreePath, branch)
            }

            // [FIX #5] Only retry on confirmed name-collision phrases.
            // "branch" alone matches nearly every git error; narrow to exact phrases.
            let output = createResult.output.lowercased()
            let isNameCollision = isCollisionError(output)

            if isNameCollision {
                // Check whether the branch already exists (vs. the path being taken).
                let branchExists = await gitBranchExists(repoPath: repoPath, branch: branch)
                if branchExists {
                    let retryResult = await runGit(
                        ["-C", repoPath, "worktree", "add", worktreePath, branch],
                        context: "worktree add (existing branch) \(branch)"
                    )
                    if retryResult.ok {
                        log("WorktreeManager.create: created worktree \(worktreePath) from existing branch \(branch)")
                        return (worktreePath, branch)
                    }
                    // Existing-branch retry also failed — uniquify.
                }
                attempt += 1
                branch = baseBranch + "-\(attempt)"
                dirName = baseDirName + "-\(attempt)"
                continue
            }

            // Unrecoverable failure (not a collision) — return nil immediately.
            log("WorktreeManager.create: git worktree add failed (unrecoverable): \(createResult.output)")
            return nil
        }

        log("WorktreeManager.create: exhausted uniquification attempts for \(baseBranch)")
        return nil
    }

    // MARK: - Remove

    /// Remove a git worktree and optionally delete its branch.
    ///
    /// Safety constraints:
    /// - `worktreePath` must not equal `repoPath` (guards against removing the main checkout).
    /// - `worktreePath` must be under `<repoPath>/.worktrees/` (structural path check).
    /// - [FIX #1] For branch deletion, resolves the worktree's ACTUAL HEAD branch via git
    ///   and requires it to equal the `branch` argument before running `branch -D`.
    ///   If HEAD doesn't match, the branch delete is skipped (logged) — remove still succeeds.
    /// - Returns `false` on any failure; logs the reason.
    static func remove(repoPath: String, worktreePath: String, branch: String, deleteBranch: Bool) async -> Bool {
        // Safety: never remove the main checkout.
        let normRepo = URL(fileURLWithPath: repoPath).standardized.path
        let normWorktree = URL(fileURLWithPath: worktreePath).standardized.path
        guard normWorktree != normRepo else {
            log("WorktreeManager.remove: refused — worktreePath equals repoPath (\(repoPath))")
            return false
        }

        // Safety: only remove worktrees that live under <repo>/.worktrees/.
        let expectedPrefix = normRepo + "/.worktrees/"
        guard normWorktree.hasPrefix(expectedPrefix) else {
            log("WorktreeManager.remove: refused — \(worktreePath) is not under .worktrees/")
            return false
        }

        // [FIX #1] Resolve the worktree's ACTUAL branch before removing it,
        // while the worktree still exists and the branch ref is readable.
        var verifiedBranch: String? = nil
        if deleteBranch {
            guard branch.hasPrefix("task/") else {
                log("WorktreeManager.remove: refused branch delete — branch '\(branch)' doesn't start with task/")
                return false
            }
            // Ask git for the real HEAD branch in this worktree — don't trust frontmatter alone.
            let actualBranch = await currentBranchInWorktree(worktreePath)
            if actualBranch == branch {
                verifiedBranch = branch
            } else {
                log("WorktreeManager.remove: branch mismatch — HEAD='\(actualBranch ?? "detached")' vs stored='\(branch)'; skipping branch delete")
                // Continue with worktree removal; just won't delete the branch.
            }
        }

        // Remove the worktree (try without --force first, then with).
        var removeResult = await runGit(
            ["-C", repoPath, "worktree", "remove", worktreePath],
            context: "worktree remove"
        )

        if !removeResult.ok {
            // If the worktree directory no longer exists, prune the stale ref instead.
            let pathGone = !FileManager.default.fileExists(atPath: worktreePath)
            if pathGone {
                _ = await runGit(["-C", repoPath, "worktree", "prune"], context: "worktree prune")
                removeResult = ShellRunner.CommandResult(output: "", exitCode: 0)
            } else {
                // Try --force for unclean worktrees.
                removeResult = await runGit(
                    ["-C", repoPath, "worktree", "remove", "--force", worktreePath],
                    context: "worktree remove --force"
                )
            }
        }

        guard removeResult.ok else {
            log("WorktreeManager.remove: git worktree remove failed: \(removeResult.output)")
            return false
        }

        // [FIX #1] Only delete the branch if HEAD matched the stored branch name.
        if let safeBranch = verifiedBranch {
            let branchResult = await runGit(
                ["-C", repoPath, "branch", "-D", safeBranch],
                context: "branch -D \(safeBranch)"
            )
            if !branchResult.ok {
                log("WorktreeManager.remove: git branch -D failed: \(branchResult.output)")
                // Not fatal — worktree was removed; just the branch lingers.
            }
        }

        log("WorktreeManager.remove: removed worktree \(worktreePath)"
            + (verifiedBranch != nil ? " and branch \(verifiedBranch!)" : ""))
        return true
    }

    // MARK: - Resolve main repo from worktree

    /// Derive the main repo path from a worktree path.
    ///
    /// [FIX #3] Primary strategy: strip the `/.worktrees/<dir>` suffix structurally
    /// (same construction create() used) — doesn't require a live git process.
    /// Cross-check via `git rev-parse --git-common-dir` using runResult (exit-status checked).
    /// Returns the structural derivation when it resolves to an existing directory,
    /// falls back to the git resolution, or nil if neither works.
    static func repoPath(forWorktree path: String) async -> String? {
        // [FIX #3] Primary: strip /.worktrees/<leafDir> structurally.
        let normalized = URL(fileURLWithPath: path).standardized.path
        let components = normalized.components(separatedBy: "/")
        // Find the last ".worktrees" component and take everything before it.
        if let idx = components.lastIndex(of: ".worktrees"), idx > 0 {
            let repoComponents = components[0..<idx]
            let derived = repoComponents.joined(separator: "/")
            let candidate = derived.isEmpty ? "/" : derived
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // [FIX #3] Cross-check: use runResult so we can verify exit status.
        let result = await ShellRunner.runResult(
            "/usr/bin/git",
            args: ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd: path
        )
        guard result.ok else {
            log("WorktreeManager.repoPath: git rev-parse failed (exit=\(result.exitCode))")
            return nil
        }

        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed)
        // If it ends in .git, the parent is the working tree.
        if url.lastPathComponent == ".git" {
            return url.deletingLastPathComponent().path
        }
        return trimmed
    }

    // MARK: - Private helpers

    private static func isGitRepo(_ path: String) async -> Bool {
        // Fast path: .git exists (works for standard repos and gitdir files).
        if FileManager.default.fileExists(atPath: "\(path)/.git") { return true }
        // Slow path: ask git (bare repos, non-standard layouts).
        let result = await runGit(["-C", path, "rev-parse", "--git-dir"], context: "rev-parse --git-dir")
        return result.ok
    }

    /// Append `.worktrees/` to `<repo>/.git/info/exclude` if not already present.
    ///
    /// [FIX #4] Uses FileHandle.seekToEndOfFile + write instead of read-modify-rewrite
    /// to avoid last-writer-wins clobbers under concurrent launches.
    /// Handles the gitdir-file case (the worktree's .git is a file pointing into a shared
    /// .git/worktrees/<name> dir) by resolving the common git dir.
    private static func ensureWorktreesExcluded(repoPath: String) async {
        let dotGit = "\(repoPath)/.git"
        let fm = FileManager.default

        var gitInfoDir: String
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotGit, isDirectory: &isDir), isDir.boolValue {
            // Standard repo: .git is a directory.
            gitInfoDir = "\(dotGit)/info"
        } else if fm.fileExists(atPath: dotGit),
                  let content = try? String(contentsOfFile: dotGit, encoding: .utf8) {
            // gitdir file: resolve the common dir, then find its info/ sibling.
            let gitdirLine = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let realGitDir: String
            if gitdirLine.hasPrefix("gitdir: ") {
                realGitDir = String(gitdirLine.dropFirst("gitdir: ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                realGitDir = gitdirLine
            }
            // Walk up to the common dir (strip /worktrees/<name> if present).
            let components = realGitDir.components(separatedBy: "/")
            if let idx = components.lastIndex(of: "worktrees"), idx >= 1 {
                let common = components[0..<idx].joined(separator: "/")
                gitInfoDir = common.isEmpty ? "/" : "\(common)/info"
            } else {
                gitInfoDir = "\(realGitDir)/info"
            }
        } else {
            // Can't determine the git dir — fall back to adding to .gitignore.
            await ensureWorktreesInGitignore(repoPath: repoPath)
            return
        }

        let excludePath = "\(gitInfoDir)/exclude"

        // Create the info dir if needed.
        try? fm.createDirectory(atPath: gitInfoDir, withIntermediateDirectories: true)

        // [FIX #4] Read-then-append-only: read existing content to check presence,
        // then append via FileHandle rather than rewriting the whole file.
        let existing = (try? String(contentsOfFile: excludePath, encoding: .utf8)) ?? ""
        let alreadyExcluded = existing.components(separatedBy: "\n").contains(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == ".worktrees/" || t == ".worktrees"
        })
        guard !alreadyExcluded else { return }

        // Create the file if it doesn't exist yet, then append.
        if !fm.fileExists(atPath: excludePath) {
            fm.createFile(atPath: excludePath, contents: nil)
        }
        let line = existing.hasSuffix("\n") || existing.isEmpty
            ? ".worktrees/\n"
            : "\n.worktrees/\n"
        if let data = line.data(using: .utf8),
           let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: excludePath)) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
            log("WorktreeManager: appended .worktrees/ to \(excludePath)")
        }
    }

    /// Fallback: add `.worktrees/` to the repo's .gitignore using FileHandle append.
    private static func ensureWorktreesInGitignore(repoPath: String) async {
        let ignorePath = "\(repoPath)/.gitignore"
        let fm = FileManager.default
        let existing = (try? String(contentsOfFile: ignorePath, encoding: .utf8)) ?? ""
        let alreadyIn = existing.components(separatedBy: "\n").contains(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == ".worktrees/" || t == ".worktrees"
        })
        guard !alreadyIn else { return }
        if !fm.fileExists(atPath: ignorePath) {
            fm.createFile(atPath: ignorePath, contents: nil)
        }
        let line = existing.hasSuffix("\n") || existing.isEmpty
            ? ".worktrees/\n"
            : "\n.worktrees/\n"
        if let data = line.data(using: .utf8),
           let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: ignorePath)) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
            log("WorktreeManager: appended .worktrees/ to \(ignorePath) (gitignore fallback)")
        }
    }

    private static func currentBranchInWorktree(_ path: String) async -> String? {
        let result = await ShellRunner.runResult(
            "/usr/bin/git", args: ["-C", path, "branch", "--show-current"],
            cwd: path
        )
        guard result.ok else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func gitBranchExists(repoPath: String, branch: String) async -> Bool {
        let result = await runGit(
            ["-C", repoPath, "rev-parse", "--verify", branch],
            context: "rev-parse --verify \(branch)"
        )
        return result.ok
    }

    /// [FIX #5] Returns true only for git's confirmed name-collision error phrases.
    /// "already exists" and "already checked out" cover branch and path collisions.
    /// "already used by worktree" covers the linked worktree ref collision.
    /// Does NOT match on bare "branch" which appears in many unrelated git errors.
    static func isCollisionError(_ lowercasedOutput: String) -> Bool {
        lowercasedOutput.contains("already exists")
            || lowercasedOutput.contains("already checked out")
            || lowercasedOutput.contains("already used by worktree")
    }

    /// Run a git command, return (combined output, exit code). Never throws.
    @discardableResult
    private static func runGit(_ args: [String], context: String) async -> ShellRunner.CommandResult {
        let result = await ShellRunner.runResult("/usr/bin/git", args: args)
        if !result.ok {
            log("WorktreeManager git[\(context)] exit=\(result.exitCode): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }

    /// Sanitise a title into a URL/branch-safe slug: lowercase, hyphenate spaces,
    /// strip unsafe characters, collapse runs of hyphens, cap at 40 characters.
    static func makeSlug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" || ch == "/" { out.append("-") }
            // all other characters are dropped
        }
        // Collapse runs of hyphens.
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        var s = String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if s.isEmpty { s = "task" }
        return s
    }

    private static func log(_ msg: String) {
        NSLog("%@", msg)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
