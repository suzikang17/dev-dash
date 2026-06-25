import Foundation

/// One-time migration that converts the existing task tree to the ticket model
/// (ADR-0008 Stage 1).
///
/// **What it does**
/// - Each TOP-LEVEL task (no `parent:` AND no `ticket:`) becomes a Ticket in
///   `docs/tickets/`.  The ticket doc is built by MOVING the original task's raw
///   text: `lore_type: task` → `lore_type: ticket`, plus a `migrated_from:` key.
///   ALL frontmatter keys and the body (including `## Status history`) are
///   preserved verbatim.
/// - Every child task gains a `ticket:` field pointing at the ancestor ticket's
///   numeric id.  Tasks whose DIRECT parent was a top-level task have `parent:`
///   cleared; all others keep `parent:`.
/// - A task whose `parent:` does not resolve to any surviving task is treated as
///   a root (orphan policy): it is promoted to a ticket and its dangling `parent:`
///   is cleared.
///
/// **Resumability / idempotency** (correct on partial re-run — no dependency on
/// the marker file for correctness):
/// - `topLevel` = tasks where `parent == nil` AND `ticket == nil`.  A task that
///   already has `ticket:` set is never promoted to a ticket.
/// - Before writing a ticket, skip if a ticket with `migrated_from == taskId`
///   already exists (dedup on re-run).
/// - Child re-point is idempotent: if `ticket:` is already set, skip.
/// - Backup: if the destination backup file already exists, it is overwritten
///   (re-run safe); the original is only removed after a CONFIRMED backup write.
///
/// **NOT called automatically** — must be invoked explicitly (Stage 2 wires it).
enum TicketMigrator {

    struct Result {
        let ticketsCreated: Int
        let tasksRepointed: Int
        /// True when the marker was present at the start of this call (fast-path).
        let skipped: Bool
    }

    // MARK: - Public entry point

    @discardableResult
    static func migrate(projectPath: String) -> Result {
        let markerPath = "\(projectPath)/.devdash/.tickets-migrated"

        // Fast-path: marker present → already fully migrated.
        if FileManager.default.fileExists(atPath: markerPath) {
            return Result(ticketsCreated: 0, tasksRepointed: 0, skipped: true)
        }

        let backupDir = "\(projectPath)/.devdash/migrated-tasks"
        try? FileManager.default.createDirectory(atPath: backupDir,
                                                  withIntermediateDirectories: true)

        let tasks = TaskStore.read(projectPath)
        guard !tasks.isEmpty else {
            writeMarker(at: markerPath)
            return Result(ticketsCreated: 0, tasksRepointed: 0, skipped: false)
        }

        let tasksDir = TaskStore.file(for: projectPath)
        let ticketDir = TicketStore.dir(for: projectPath)

        // Scan existing tickets for migrated_from values so re-runs skip already-
        // created tickets.
        let alreadyMigrated = existingMigratedFrom(in: ticketDir)

        // Collect all known task ids as a set of integers for parent-resolve checks.
        let allTaskIdInts: Set<Int> = Set(tasks.compactMap { Int($0.id) })

        // Resolve orphan parents: build a set of parent ids that DO NOT resolve to
        // any surviving task.  Tasks referencing these become additional roots.
        // A task is an "orphan root" if it has a parent that doesn't exist in the
        // current task list.
        let orphanRoots: Set<Int> = Set(
            tasks.compactMap { t -> Int? in
                guard let pid = t.parentId else { return nil }
                guard let pidInt = Int(pid) else { return Int(t.id) }
                return allTaskIdInts.contains(pidInt) ? nil : Int(t.id)
            }
        )

        // True top-level = no parent AND no ticket already set.
        // Orphan roots with no ticket set are also promoted.
        let topLevel = tasks.filter { t in
            let isRoot = t.parentId == nil && t.ticket == nil
            let isOrphanRoot: Bool = {
                guard let oid = Int(t.id) else { return false }
                return orphanRoots.contains(oid) && t.ticket == nil
            }()
            return isRoot || isOrphanRoot
        }

        // Build set of top-level task integer ids (for parent-clear logic).
        let topLevelIdInts: Set<Int> = Set(topLevel.compactMap { Int($0.id) })

        // Compute next ticket id from existing tickets dir.
        try? FileManager.default.createDirectory(atPath: ticketDir,
                                                  withIntermediateDirectories: true)
        var nextTicketInt = maxNumericId(in: ticketDir) + 1

        // taskId (string) → ticketId (string) mapping built as we create tickets.
        // Pre-populate from already-migrated tickets so re-runs use the same ids.
        var taskIdToTicketId: [String: String] = alreadyMigratedMapping(in: ticketDir)

        var ticketsCreated = 0

        for t in topLevel {
            // Skip if already migrated on a previous (partial) run.
            if alreadyMigrated.contains(t.id) {
                continue
            }
            // Also skip if a mapping already exists for this task id (belt-and-suspenders).
            if taskIdToTicketId[t.id] != nil {
                continue
            }

            // Read the original task doc raw text.
            guard let fname = TaskStore.findFile(id: t.id, in: tasksDir),
                  let rawTask = try? String(contentsOfFile: "\(tasksDir)/\(fname)",
                                            encoding: .utf8)
            else { continue }

            let ticketId = String(format: "%04d", nextTicketInt)
            nextTicketInt += 1

            // Build ticket doc: change lore_type, add migrated_from, clear parent
            // (for orphan roots), preserve everything else verbatim.
            var rawTicket = rawTask
            rawTicket = TaskStore.setOrAddFrontmatterKey(in: rawTicket, key: "lore_type",
                                                          value: "ticket")
            rawTicket = TaskStore.setOrAddFrontmatterKey(in: rawTicket, key: "migrated_from",
                                                          value: TaskStore.yamlStr(t.id))
            // If this was an orphan root (had a dangling parent), clear it on the ticket.
            if t.parentId != nil {
                rawTicket = TaskStore.removeFrontmatterKey(in: rawTicket, key: "parent")
            }

            let ticketFilename = "\(ticketId)-\(ticketSlug(t.title)).md"
            let ticketPath = "\(ticketDir)/\(ticketFilename)"
            do {
                try rawTicket.write(toFile: ticketPath, atomically: true, encoding: .utf8)
            } catch {
                continue  // don't record mapping or increment if write failed
            }

            taskIdToTicketId[t.id] = ticketId
            // Tolerate both "0001" and "1" forms in parent refs.
            if let n = Int(t.id) { taskIdToTicketId[String(n)] = ticketId }
            ticketsCreated += 1
        }

        // Re-point children: set ticket:, optionally clear parent:.
        var tasksRepointed = 0

        for task in tasks {
            // Top-level tasks (becoming tickets) don't need re-pointing in tasks/.
            let isTopLevel: Bool = {
                guard let tidInt = Int(task.id) else { return topLevel.contains(where: { $0.id == task.id }) }
                return topLevelIdInts.contains(tidInt)
            }()
            if isTopLevel { continue }

            // Determine the owning ticket id via ancestor walk.
            let ticketId = ancestorTicketId(for: task, in: tasks, mapping: taskIdToTicketId)

            // Determine whether parent should be cleared.
            // Parent was a top-level task (now a ticket) → clear.
            // Also clear if parent is an unresolvable orphan (dangles).
            let shouldClearParent: Bool = {
                guard let pid = task.parentId else { return false }
                // Use numEq-style: compare as integers when possible.
                if let pidInt = Int(pid) {
                    if topLevelIdInts.contains(pidInt) { return true }
                    if !allTaskIdInts.contains(pidInt) { return true }   // dangling
                } else {
                    // Non-numeric parent id: string match against top-level ids.
                    if topLevel.contains(where: { $0.id == pid }) { return true }
                    // Dangling non-numeric parent.
                    if !tasks.contains(where: { $0.id == pid }) { return true }
                }
                return false
            }()

            // If ticket is already set AND parent-clear is the only change, check
            // whether the existing ticket value already matches.
            guard let fname = TaskStore.findFile(id: task.id, in: tasksDir),
                  var raw = try? String(contentsOfFile: "\(tasksDir)/\(fname)",
                                        encoding: .utf8)
            else { continue }

            var changed = false

            if let tid = ticketId {
                let existing = TaskStore.parseTaskFrontmatter(raw)["ticket"]
                // Idempotent: skip if already set to the correct value.
                if existing != tid {
                    raw = TaskStore.setOrAddFrontmatterKey(in: raw, key: "ticket",
                                                           value: TaskStore.yamlStr(tid))
                    changed = true
                }
            }

            if shouldClearParent {
                let existingParent = TaskStore.parseTaskFrontmatter(raw)["parent"]
                if existingParent != nil {
                    raw = TaskStore.removeFrontmatterKey(in: raw, key: "parent")
                    changed = true
                }
            }

            if changed {
                try? raw.write(toFile: "\(tasksDir)/\(fname)", atomically: true,
                               encoding: .utf8)
                tasksRepointed += 1
            }
        }

        // Back up and remove original top-level task docs.
        // Only remove AFTER a confirmed backup write.
        for t in topLevel {
            guard let fname = TaskStore.findFile(id: t.id, in: tasksDir) else { continue }
            let src = "\(tasksDir)/\(fname)"
            let dst = "\(backupDir)/\(fname)"
            // Remove stale backup if present (re-run safety).
            try? FileManager.default.removeItem(atPath: dst)
            do {
                try FileManager.default.copyItem(atPath: src, toPath: dst)
                // Only remove original after confirmed copy.
                try? FileManager.default.removeItem(atPath: src)
            } catch {
                // Backup write failed — leave original in place (don't delete).
            }
        }

        writeMarker(at: markerPath)
        return Result(ticketsCreated: ticketsCreated, tasksRepointed: tasksRepointed,
                      skipped: false)
    }

    // MARK: - Private: ancestor walk

    /// Walk the parent chain to find the root task, then map it to its ticket id.
    /// If the chain ends at a node with no mapping (shouldn't happen post-migration
    /// but can during a partial run), return nil.
    private static func ancestorTicketId(
        for task: TaskItem,
        in allTasks: [TaskItem],
        mapping: [String: String]
    ) -> String? {
        // If this task already has a ticket, honour it (idempotent).
        if let existing = task.ticket, !existing.isEmpty { return existing }

        // Walk up parent links to find the root.
        var cursor: TaskItem = task
        var seen = Set<String>()
        while let pid = cursor.parentId {
            guard !seen.contains(cursor.id) else { break }   // cycle guard
            seen.insert(cursor.id)
            guard let parent = allTasks.first(where: { TaskStore.numEq($0.id, pid) }) else {
                // Unresolvable parent: cursor is the highest reachable node; use it.
                break
            }
            cursor = parent
        }
        // cursor is the root (or highest reachable node).
        return mapping[cursor.id] ?? mapping[String(Int(cursor.id) ?? -1)]
    }

    // MARK: - Private: ticket-dir scan helpers

    /// Returns the set of `migrated_from` values already present in the tickets dir.
    private static func existingMigratedFrom(in ticketDir: String) -> Set<String> {
        var result = Set<String>()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ticketDir)) ?? []
        for fname in files where fname.hasSuffix(".md") && fname.lowercased() != "index.md" {
            guard let raw = try? String(contentsOfFile: "\(ticketDir)/\(fname)",
                                         encoding: .utf8) else { continue }
            let fm = TaskStore.parseTaskFrontmatter(raw)
            if let mf = fm["migrated_from"], !mf.isEmpty { result.insert(mf) }
        }
        return result
    }

    /// Returns a task-id → ticket-id mapping from already-migrated ticket docs.
    private static func alreadyMigratedMapping(in ticketDir: String) -> [String: String] {
        var result: [String: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ticketDir)) ?? []
        for fname in files where fname.hasSuffix(".md") && fname.lowercased() != "index.md" {
            let numericPrefix = String(fname.prefix(while: { $0.isNumber }))
            guard !numericPrefix.isEmpty,
                  let raw = try? String(contentsOfFile: "\(ticketDir)/\(fname)",
                                         encoding: .utf8) else { continue }
            let fm = TaskStore.parseTaskFrontmatter(raw)
            if let mf = fm["migrated_from"], !mf.isEmpty {
                result[mf] = numericPrefix
                if let n = Int(mf) { result[String(n)] = numericPrefix }
            }
        }
        return result
    }

    /// Returns the max numeric filename prefix in a directory (0 if none).
    private static func maxNumericId(in dir: String) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files
            .filter { $0.hasSuffix(".md") && $0.lowercased() != "index.md" }
            .compactMap { Int($0.prefix(while: { $0.isNumber })) }
            .max() ?? 0
    }

    // MARK: - Private: slug + marker

    private static func ticketSlug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        var s = String(out.prefix(50)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if s.isEmpty { s = "ticket" }
        return s
    }

    private static func writeMarker(at path: String) {
        let devdashDir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: devdashDir,
                                                  withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try? timestamp.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
