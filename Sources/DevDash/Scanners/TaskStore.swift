import Foundation

/// Per-project structured task store backed by lore task docs (`docs/tasks/*.md`).
///
/// `TaskItem.id` is the zero-padded numeric filename prefix (e.g. "0042").
/// Files are named `<id>-<slug>.md` and found by numeric id lookup (tolerates
/// non-zero-padded names written by the `lore` CLI, e.g. "1-foo.md").
///
/// **Migrate-on-load**: if `.devdash/tasks.json` exists, `read(_:)` calls
/// `TaskLoreMigrator.migrate(projectPath:)` once, then renames the file to
/// `tasks.json.migrated` so subsequent reads skip migration entirely.
enum TaskStore {

    // MARK: - Directory helpers

    /// The tasks directory for a project.  Returned by the public `file(for:)` to
    /// preserve the historic call-site signature (callers treat it as a reference path).
    static func file(for projectPath: String) -> String {
        "\(projectPath)/docs/tasks"
    }

    // MARK: - Read

    static func read(_ projectPath: String) -> [TaskItem] {
        let dir = file(for: projectPath)
        let fm = FileManager.default

        // Migrate from .devdash/tasks.json if it still exists (one-time).
        let jsonPath = "\(projectPath)/.devdash/tasks.json"
        if fm.fileExists(atPath: jsonPath) {
            let result = TaskLoreMigrator.migrate(projectPath: projectPath)
            // Mark migration done by renaming the source file so we never migrate again.
            // Only rename if something was actually processed (created+skipped > 0 means
            // the JSON had content; created==0 && skipped==0 means it was empty — rename
            // anyway to stop looping on an empty file).
            let migratedPath = "\(projectPath)/.devdash/tasks.json.migrated"
            _ = result  // suppress unused warning
            try? fm.moveItem(atPath: jsonPath, toPath: migratedPath)
        }

        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        let items: [TaskItem] = files
            .filter { $0.hasSuffix(".md") && $0.lowercased() != "index.md" }
            .sorted()
            .compactMap { filename -> TaskItem? in
                let numericPrefix = String(filename.prefix(while: { $0.isNumber }))
                guard !numericPrefix.isEmpty,
                      let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
                else { return nil }
                return parseTaskItem(id: numericPrefix, raw: raw)
            }
        return items
    }

    // MARK: - Write (bulk)

    static func write(_ projectPath: String, tasks: [TaskItem]) throws {
        let dir = file(for: projectPath)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for task in tasks {
            if let existingFile = findFile(id: task.id, in: dir) {
                // File exists — patch known fields in-place to preserve unknown keys.
                let path = "\(dir)/\(existingFile)"
                if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                    let patched = applyTaskItemToDoc(task, existingDoc: raw)
                    try patched.write(toFile: path, atomically: true, encoding: .utf8)
                    continue
                }
            }
            // No existing file — write fresh.
            let filename = "\(task.id)-\(slug(task.title)).md"
            let content = taskDoc(for: task)
            try content.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Add

    static func add(
        projectPath: String,
        title: String,
        category: TaskCategory = .other,
        stage: String? = nil,
        notes: String? = nil,
        source: TaskSource = .local,
        parentId: String? = nil,
        linkedDocPath: String? = nil
    ) throws -> TaskItem {
        let dir = file(for: projectPath)
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Compute next id: max existing numeric prefix + 1.
        let existingFiles = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let maxId = existingFiles
            .filter { $0.hasSuffix(".md") && $0.lowercased() != "index.md" }
            .compactMap { Int($0.prefix(while: { $0.isNumber })) }
            .max() ?? 0
        let newId = String(format: "%04d", maxId + 1)

        let task = TaskItem(
            id: newId,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            stage: stage,
            category: category,
            source: source,
            status: .open,
            createdAt: Date(),
            startedAt: nil,
            completedAt: nil,
            ghIssueURL: nil,
            parentId: parentId,
            linkedDocPath: linkedDocPath
        )

        let filename = "\(newId)-\(slug(task.title)).md"
        let content = taskDoc(for: task)
        try content.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
        return task
    }

    // MARK: - Mutators

    static func setStatus(projectPath: String, id: String, status: TaskStatus) throws {
        let dir = file(for: projectPath)
        guard let filename = findFile(id: id, in: dir),
              let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else { return }

        let fm = parseTaskFrontmatter(raw)
        let oldStatus = fm["status"] ?? "open"
        let newStatusRaw = status.rawValue

        var result = setOrAddFrontmatterKey(in: raw, key: "status", value: newStatusRaw)

        // Update started/completed dates.
        switch status {
        case .inProgress:
            let existing = parseTaskFrontmatter(result)["started"] ?? ""
            if existing.isEmpty {
                result = setOrAddFrontmatterKey(in: result, key: "started",
                                                value: dateFmt.string(from: Date()))
            }
        case .done:
            result = setOrAddFrontmatterKey(in: result, key: "completed",
                                            value: dateFmt.string(from: Date()))
        case .open, .blocked, .skipped:
            break
        }

        // Append status history entry using sentinel-delimited block so user notes
        // containing "## Status history" aren't accidentally truncated on re-read.
        if oldStatus != newStatusRaw {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let entry = "- \(df.string(from: Date())) \(oldStatus) → \(newStatusRaw)"
            let sentinel = statusHistorySentinel
            if result.contains(sentinel) {
                result = result.trimmingCharacters(in: .newlines) + "\n" + entry + "\n"
            } else {
                result = result.trimmingCharacters(in: .newlines)
                    + "\n\(sentinel)\n## Status history\n" + entry + "\n"
            }
        }

        try result.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    static func setOwner(projectPath: String, id: String, owner: TaskOwner) throws {
        let dir = file(for: projectPath)
        guard let filename = findFile(id: id, in: dir),
              let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else { return }
        let result = setOrAddFrontmatterKey(in: raw, key: "owner", value: owner.rawValue)
        try result.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    static func setHasAIRun(projectPath: String, id: String) throws {
        let dir = file(for: projectPath)
        guard let filename = findFile(id: id, in: dir),
              let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else { return }
        let result = setOrAddFrontmatterKey(in: raw, key: "ai_run", value: "true")
        try result.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    /// Set or clear the `pr:` frontmatter key in place, preserving all other keys and body.
    /// Passing nil or empty string removes the key.
    static func setPR(projectPath: String, id: String, url: String?) throws {
        let dir = file(for: projectPath)
        guard let filename = findFile(id: id, in: dir),
              let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else { return }
        let result: String
        if let url = url, !url.isEmpty {
            result = setOrAddFrontmatterKey(in: raw, key: "pr", value: yamlStr(url))
        } else {
            result = removeFrontmatterKey(in: raw, key: "pr")
        }
        try result.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    /// Set or clear the `worktree:` and `branch:` frontmatter keys in place.
    /// Passing nil for both removes both keys.
    static func setWorktree(projectPath: String, id: String, worktree: String?, branch: String?) throws {
        let dir = file(for: projectPath)
        guard let filename = findFile(id: id, in: dir),
              let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else { return }
        var result = raw
        if let wt = worktree, !wt.isEmpty {
            result = setOrAddFrontmatterKey(in: result, key: "worktree", value: yamlStr(wt))
        } else {
            result = removeFrontmatterKey(in: result, key: "worktree")
        }
        if let br = branch, !br.isEmpty {
            result = setOrAddFrontmatterKey(in: result, key: "branch", value: yamlStr(br))
        } else {
            result = removeFrontmatterKey(in: result, key: "branch")
        }
        try result.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    static func setPhases(projectPath: String, id: String, phases: [String]) throws {
        let dir = file(for: projectPath)
        guard let filename = findFile(id: id, in: dir),
              let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else { return }
        let result: String
        if phases.isEmpty {
            result = removeFrontmatterKey(in: raw, key: "phases")
        } else {
            result = setOrAddFrontmatterKey(in: raw, key: "phases",
                                            value: yamlStr(encodePhases(phases)))
        }
        try result.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    static func addCompletedPhase(projectPath: String, id: String, phase: String) throws {
        let dir = file(for: projectPath)
        guard let filename = findFile(id: id, in: dir),
              let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else { return }
        let fm = parseTaskFrontmatter(raw)
        var existing = decodePhases(fm["completedPhases"] ?? "")
        if !existing.contains(phase) { existing.append(phase) }
        let result = setOrAddFrontmatterKey(in: raw, key: "completedPhases",
                                            value: yamlStr(encodePhases(existing)))
        try result.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    /// Set or clear the parent of a task. Cycle-safe: walks up the existing tree to
    /// make sure `newParentId` isn't a descendant of `id` (numeric comparison).
    static func setParent(projectPath: String, id: String, newParentId: String?) throws {
        let tasks = read(projectPath)
        guard tasks.contains(where: { numEq($0.id, id) }) else { return }

        if let newParent = newParentId {
            // Cycle guard: walk newParent's ancestors; if we ever hit `id`, abort.
            var cursor: String? = newParent
            var seen = Set<String>()
            while let c = cursor {
                if numEq(c, id) { return }   // would create a cycle — silently no-op
                if seen.contains(c) { break }
                seen.insert(c)
                cursor = tasks.first(where: { numEq($0.id, c) })?.parentId
            }
        }

        let dir = file(for: projectPath)
        guard let filename = findFile(id: id, in: dir),
              let raw = try? String(contentsOfFile: "\(dir)/\(filename)", encoding: .utf8)
        else { return }

        let result: String
        if let pid = newParentId {
            result = setOrAddFrontmatterKey(in: raw, key: "parent", value: yamlStr(pid))
        } else {
            result = removeFrontmatterKey(in: raw, key: "parent")
        }
        try result.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    static func hasChildren(projectPath: String, id: String) -> Bool {
        read(projectPath).contains { t in
            guard let p = t.parentId else { return false }
            return numEq(p, id)
        }
    }

    /// Update a task in-place, preserving all unknown frontmatter keys.
    static func update(projectPath: String, _ updated: TaskItem) throws {
        let dir = file(for: projectPath)
        guard let filename = findFile(id: updated.id, in: dir) else { return }
        let path = "\(dir)/\(filename)"
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let patched = applyTaskItemToDoc(updated, existingDoc: existing)
            try patched.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            // File disappeared — recreate from scratch.
            let content = taskDoc(for: updated)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func delete(projectPath: String, id: String) throws {
        let tasks = read(projectPath)
        // Collect the target and all descendants (numeric cascade delete).
        var toDeleteInts: Set<Int> = []
        if let n = Int(id) { toDeleteInts.insert(n) }
        var changed = true
        while changed {
            changed = false
            for t in tasks {
                guard let tn = Int(t.id), !toDeleteInts.contains(tn) else { continue }
                if let p = t.parentId, let pn = Int(p), toDeleteInts.contains(pn) {
                    toDeleteInts.insert(tn)
                    changed = true
                }
            }
        }
        let dir = file(for: projectPath)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        for filename in files where filename.hasSuffix(".md") {
            let numericPrefix = String(filename.prefix(while: { $0.isNumber }))
            if let n = Int(numericPrefix), toDeleteInts.contains(n) {
                try? fm.removeItem(atPath: "\(dir)/\(filename)")
            }
        }
    }

    // MARK: - Internal serialisation (used by add() and TaskLoreMigrator)

    /// Serialise a TaskItem to a fresh lore task doc (frontmatter + body).
    /// Used only for NEW files — existing files use `applyTaskItemToDoc` to
    /// preserve unknown keys.
    static func taskDoc(for t: TaskItem) -> String {
        var lines = ["---", "lore_type: task"]

        func bare(_ k: String, _ v: String?) {
            if let v = v, !v.isEmpty { lines.append("\(k): \(v)") }
        }
        func str(_ k: String, _ v: String?) {
            guard let v = v, !v.isEmpty else { return }
            lines.append("\(k): \(yamlStr(v))")
        }

        str("title", t.title)
        bare("status", t.status.rawValue)
        bare("owner", t.owner == .none ? nil : t.owner.rawValue)
        bare("category", t.category.rawValue)
        bare("created", dateFmt.string(from: t.createdAt))
        bare("completed", t.completedAt.map { dateFmt.string(from: $0) })
        bare("started", t.startedAt.map { dateFmt.string(from: $0) })
        str("stage", t.stage)
        if t.hasAIRun { lines.append("ai_run: true") }
        bare("source", t.source.rawValue)
        str("ghIssue", t.ghIssueURL?.absoluteString)
        if let ph = t.phases, !ph.isEmpty {
            lines.append("phases: \(yamlStr(encodePhases(ph)))")
        }
        if !t.completedPhases.isEmpty {
            lines.append("completedPhases: \(yamlStr(encodePhases(t.completedPhases)))")
        }
        str("persona", t.gstackPersonaOverride)
        str("linkedDoc", t.linkedDocPath)
        str("pr", t.pr)
        str("worktree", t.worktree)
        str("branch", t.branch)
        if let pid = t.parentId, !pid.isEmpty { lines.append("parent: \(yamlStr(pid))") }
        lines.append("---")

        let frontmatter = lines.joined(separator: "\n")
        let body = (t.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return frontmatter + "\n" + (body.isEmpty ? "# \(t.title)\n" : body + "\n")
    }

    /// Patch an EXISTING doc's known fields in-place, preserving every unknown key
    /// (e.g. `devdash_id`, `lore_type`, `pr`, and future keys).  Also rewrites the
    /// body from `task.notes`, preserving any sentinel-delimited status-history block.
    static func applyTaskItemToDoc(_ t: TaskItem, existingDoc raw: String) -> String {
        var doc = raw

        // --- Frontmatter scalar patches ---
        func setStr(_ key: String, _ v: String?) {
            if let v = v, !v.isEmpty {
                doc = setOrAddFrontmatterKey(in: doc, key: key, value: yamlStr(v))
            } else {
                doc = removeFrontmatterKey(in: doc, key: key)
            }
        }
        func setBare(_ key: String, _ v: String?) {
            if let v = v, !v.isEmpty {
                doc = setOrAddFrontmatterKey(in: doc, key: key, value: v)
            } else {
                doc = removeFrontmatterKey(in: doc, key: key)
            }
        }

        setStr("title", t.title)
        setBare("status", t.status.rawValue)
        setBare("owner", t.owner == .none ? nil : t.owner.rawValue)
        setBare("category", t.category.rawValue)
        setBare("created", dateFmt.string(from: t.createdAt))
        setBare("completed", t.completedAt.map { dateFmt.string(from: $0) })
        setBare("started", t.startedAt.map { dateFmt.string(from: $0) })
        setStr("stage", t.stage)
        if t.hasAIRun {
            doc = setOrAddFrontmatterKey(in: doc, key: "ai_run", value: "true")
        } else {
            doc = removeFrontmatterKey(in: doc, key: "ai_run")
        }
        setBare("source", t.source.rawValue)
        setStr("ghIssue", t.ghIssueURL?.absoluteString)
        if let ph = t.phases, !ph.isEmpty {
            doc = setOrAddFrontmatterKey(in: doc, key: "phases",
                                         value: yamlStr(encodePhases(ph)))
        } else {
            doc = removeFrontmatterKey(in: doc, key: "phases")
        }
        if !t.completedPhases.isEmpty {
            doc = setOrAddFrontmatterKey(in: doc, key: "completedPhases",
                                         value: yamlStr(encodePhases(t.completedPhases)))
        } else {
            doc = removeFrontmatterKey(in: doc, key: "completedPhases")
        }
        setStr("persona", t.gstackPersonaOverride)
        setStr("linkedDoc", t.linkedDocPath)
        setStr("pr", t.pr)
        setStr("worktree", t.worktree)
        setStr("branch", t.branch)
        if let pid = t.parentId, !pid.isEmpty {
            doc = setOrAddFrontmatterKey(in: doc, key: "parent", value: yamlStr(pid))
        } else {
            doc = removeFrontmatterKey(in: doc, key: "parent")
        }

        // --- Body patch: preserve status-history block, replace notes ---
        let historyBlock = extractStatusHistoryBlock(from: doc)
        let notesBody = (t.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let newBody: String
        if notesBody.isEmpty {
            newBody = "# \(t.title)\n"
        } else {
            newBody = notesBody + "\n"
        }
        doc = replaceBody(in: doc, newBody: newBody + (historyBlock.map { "\n\($0)\n" } ?? ""))

        return doc
    }

    // MARK: - Private helpers

    static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// HTML comment sentinel that marks the start of the auto-managed status-history
    /// block.  Using an HTML comment means it's invisible in rendered Markdown and
    /// is guaranteed not to appear in user-authored content.
    static let statusHistorySentinel = "<!-- devdash:status-history -->"

    /// YAML double-quoted scalar: escapes backslash + quote, collapses newlines.
    static func yamlStr(_ v: String) -> String {
        let esc = v
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(esc)\""
    }

    /// Reverse of yamlStr: strips outer double-quotes and unescapes `\"` → `"` and
    /// `\\` → `\`.  Only applied to double-quoted values; bare values pass through.
    static func unescapeYamlStr(_ v: String) -> String {
        guard v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 else { return v }
        let inner = String(v.dropFirst().dropLast())
        // Unescape in the right order: \\" first so we don't double-process.
        var result = ""
        var i = inner.startIndex
        while i < inner.endIndex {
            let ch = inner[i]
            if ch == "\\" {
                let next = inner.index(after: i)
                if next < inner.endIndex {
                    let nch = inner[next]
                    if nch == "\"" { result.append("\""); i = inner.index(after: next); continue }
                    if nch == "\\" { result.append("\\"); i = inner.index(after: next); continue }
                }
            }
            result.append(ch)
            i = inner.index(after: i)
        }
        return result
    }

    private static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        var s = String(out.prefix(50)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if s.isEmpty { s = "task" }
        return s
    }

    // MARK: - Numeric id comparison

    /// Compare two task id strings numerically so "0001" == "1", "0042" == "42", etc.
    /// Falls back to string equality if either side isn't a valid integer.
    static func numEq(_ a: String, _ b: String) -> Bool {
        if let ia = Int(a), let ib = Int(b) { return ia == ib }
        return a == b
    }

    /// Find the filename whose numeric prefix matches `id` (numeric comparison).
    static func findFile(id: String, in dir: String) -> String? {
        guard let idInt = Int(id) else {
            // Fall back to string prefix match for non-numeric ids.
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return files.first { f in
                guard f.hasSuffix(".md") else { return false }
                return String(f.prefix(while: { $0.isNumber })) == id
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.first { filename in
            guard filename.hasSuffix(".md") else { return false }
            let prefix = String(filename.prefix(while: { $0.isNumber }))
            return Int(prefix) == idInt
        }
    }

    // MARK: - Phases encoding (JSON array to survive commas in phase names)

    /// Encode a phases array as a compact JSON array string, e.g. `["a","b,c"]`.
    /// Stored as the *value* of a yamlStr()-quoted frontmatter field.
    static func encodePhases(_ phases: [String]) -> String {
        // Use JSONEncoder for correctness; it always produces compact valid JSON.
        let data = (try? JSONEncoder().encode(phases)) ?? Data()
        return String(data: data, encoding: .utf8) ?? phases.joined(separator: ", ")
    }

    /// Decode a phases value that may be JSON array or legacy comma-separated.
    static func decodePhases(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr
        }
        // Legacy: comma-separated.
        return trimmed.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Frontmatter in-place editing

    /// Set a frontmatter key: replaces if present, inserts before closing `---` if not.
    static func setOrAddFrontmatterKey(in raw: String, key: String, value: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        var fences = 0
        for i in lines.indices {
            let line = lines[i]
            if line.hasPrefix("---") {
                fences += 1
                if fences == 2 {
                    lines.insert("\(key): \(value)", at: i)
                    return lines.joined(separator: "\n")
                }
                continue
            }
            guard fences == 1 else { continue }
            if line.hasPrefix("\(key):") {
                lines[i] = "\(key): \(value)"
                return lines.joined(separator: "\n")
            }
        }
        return raw   // malformed — return unchanged
    }

    /// Remove a frontmatter key line entirely.
    static func removeFrontmatterKey(in raw: String, key: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        var fences = 0
        var removeIdx: Int? = nil
        for i in lines.indices {
            let line = lines[i]
            if line.hasPrefix("---") {
                fences += 1
                if fences == 2 { break }
                continue
            }
            guard fences == 1 else { continue }
            if line.hasPrefix("\(key):") { removeIdx = i; break }
        }
        if let idx = removeIdx { lines.remove(at: idx) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Body helpers

    /// Replace everything after the closing frontmatter fence with `newBody`.
    private static func replaceBody(in raw: String, newBody: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var fences = 0
        for i in lines.indices {
            if lines[i].hasPrefix("---") {
                fences += 1
                if fences == 2 {
                    // Keep lines 0...i (the frontmatter incl. closing fence), replace rest.
                    let fm = lines[0...i].joined(separator: "\n")
                    return fm + "\n" + newBody
                }
            }
        }
        return raw  // no closing fence found
    }

    /// Extract the sentinel-delimited status-history block from a doc, including
    /// the sentinel line itself, so it can be re-appended after a notes update.
    private static func extractStatusHistoryBlock(from doc: String) -> String? {
        guard let range = doc.range(of: statusHistorySentinel) else { return nil }
        return String(doc[range.lowerBound...]).trimmingCharacters(in: .newlines)
    }

    // MARK: - Parsing

    /// Parse frontmatter from a lore task doc, unescaping yamlStr-encoded values.
    /// This is TaskStore's own parser — it does NOT replace LoreReader.parseFrontmatter
    /// which other consumers depend on.
    static func parseTaskFrontmatter(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        var fences = 0
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("---") {
                fences += 1
                if fences == 2 { break }
                continue
            }
            guard fences == 1, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Unescape double-quoted values written by yamlStr().
            let value: String
            if rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"") && rawValue.count >= 2 {
                value = unescapeYamlStr(rawValue)
            } else if (rawValue.hasPrefix("'") && rawValue.hasSuffix("'")) && rawValue.count >= 2 {
                value = String(rawValue.dropFirst().dropLast())
            } else {
                value = rawValue
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static func parseTaskItem(id: String, raw: String) -> TaskItem? {
        let fm = parseTaskFrontmatter(raw)
        guard let title = fm["title"], !title.isEmpty else { return nil }

        let status: TaskStatus     = TaskStatus(rawValue: fm["status"] ?? "") ?? .open
        let owner: TaskOwner       = TaskOwner(rawValue: fm["owner"] ?? "") ?? .none
        let category: TaskCategory = TaskCategory(rawValue: fm["category"] ?? "") ?? .other
        let source: TaskSource     = TaskSource(rawValue: fm["source"] ?? "") ?? .local

        let createdAt   = fm["created"].flatMap  { dateFmt.date(from: $0) } ?? Date()
        let startedAt   = fm["started"].flatMap  { dateFmt.date(from: $0) }
        let completedAt = fm["completed"].flatMap { dateFmt.date(from: $0) }

        let hasAIRun = fm["ai_run"] == "true"
        let ghIssueURL: URL? = fm["ghIssue"].flatMap { URL(string: $0) }

        let phases: [String]? = fm["phases"].map { decodePhases($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let completedPhases: [String] = decodePhases(fm["completedPhases"] ?? "")

        let parentId: String? = fm["parent"].flatMap { s -> String? in
            let v = s.trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }

        let notes: String? = extractNotes(from: raw, title: title)

        return TaskItem(
            id: id,
            title: title,
            notes: notes,
            stage: fm["stage"].flatMap { $0.isEmpty ? nil : $0 },
            category: category,
            source: source,
            status: status,
            createdAt: createdAt,
            startedAt: startedAt,
            completedAt: completedAt,
            ghIssueURL: ghIssueURL,
            parentId: parentId,
            owner: owner,
            hasAIRun: hasAIRun,
            phases: phases,
            completedPhases: completedPhases,
            gstackPersonaOverride: fm["persona"].flatMap { $0.isEmpty ? nil : $0 },
            linkedDocPath: fm["linkedDoc"].flatMap { $0.isEmpty ? nil : $0 },
            pr: fm["pr"].flatMap { $0.isEmpty ? nil : $0 },
            worktree: fm["worktree"].flatMap { $0.isEmpty ? nil : $0 },
            branch: fm["branch"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Extract the user's notes: the body after the frontmatter closing fence, with:
    ///   - the first non-empty line stripped if it equals `# <title>` (auto-generated heading)
    ///   - the sentinel-delimited status-history block stripped entirely
    /// User content containing "## Status history" or "# <title>" in other positions
    /// is preserved.
    private static func extractNotes(from raw: String, title: String) -> String? {
        // Split on newlines, find the closing "---" fence (second one), take everything after.
        let allLines = raw.components(separatedBy: "\n")
        var fences = 0
        var bodyLineStart: Int? = nil
        for (i, line) in allLines.enumerated() {
            if line.hasPrefix("---") {
                fences += 1
                if fences == 2 { bodyLineStart = i + 1; break }
            }
        }
        guard let start = bodyLineStart else { return nil }
        var body = allLines[start...].joined(separator: "\n")

        // Strip the sentinel-delimited status-history block.
        if let sentinelRange = body.range(of: "\n" + statusHistorySentinel) {
            body = String(body[body.startIndex..<sentinelRange.lowerBound])
        } else if body.hasPrefix(statusHistorySentinel) {
            body = ""
        }
        // Strip ONLY the first non-empty line if it is the auto-generated title heading.
        var lines = body.components(separatedBy: "\n")
        if let firstNonEmpty = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[firstNonEmpty] == "# \(title)" {
            lines.remove(at: firstNonEmpty)
        }
        body = lines.joined(separator: "\n")

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
