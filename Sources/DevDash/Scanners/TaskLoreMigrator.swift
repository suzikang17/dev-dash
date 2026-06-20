import Foundation

/// One-time, idempotent export of TaskStore (`.devdash/tasks.json`) tasks into
/// lore task docs (`docs/tasks/*.md`), porting every field. Parent UUIDs are
/// remapped to lore sequential ids. Re-running skips tasks already exported
/// (matched by `devdash_id` frontmatter), so it never duplicates.
enum TaskLoreMigrator {
    struct Result { let created: Int; let skipped: Int }

    @discardableResult
    static func migrate(projectPath: String) -> Result {
        let tasks = TaskStore.read(projectPath)
        guard !tasks.isEmpty else { return Result(created: 0, skipped: 0) }

        let dir = "\(projectPath)/docs/tasks"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Scan existing lore tasks: which devdash_ids are already exported, the
        // max numeric id, and a uuid→loreId map (so parent refs resolve to docs
        // that already exist as well as ones we're about to write).
        var alreadyExported = Set<String>()
        var uuidToLoreId: [String: String] = [:]
        var maxId = 0
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            guard f.hasSuffix(".md"), f.lowercased() != "index.md" else { continue }
            // Parse the full numeric prefix (not a fixed 4 chars) so 5-digit ids
            // don't truncate-collide.
            guard let n = Int(f.prefix(while: { $0.isNumber })) else { continue }
            maxId = max(maxId, n)
            guard let raw = try? String(contentsOfFile: "\(dir)/\(f)", encoding: .utf8) else { continue }
            if let did = LoreReader.parseFrontmatter(raw)["devdash_id"] {
                alreadyExported.insert(did)
                uuidToLoreId[did] = String(format: "%04d", n)
            }
        }

        // Assign new lore ids to not-yet-exported tasks (preserving TaskStore order).
        let toCreate = tasks.filter { !alreadyExported.contains($0.id) }
        var nextId = maxId
        for t in toCreate { nextId += 1; uuidToLoreId[t.id] = String(format: "%04d", nextId) }

        var created = 0
        for t in toCreate {
            guard let loreId = uuidToLoreId[t.id] else { continue }
            let path = "\(dir)/\(loreId)-\(slug(t.title)).md"
            var content = frontmatter(for: t, uuidToLoreId: uuidToLoreId)
            let body = (t.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            content += "\n" + (body.isEmpty ? "# \(t.title)\n" : body + "\n")
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                created += 1
            } catch {
                // Don't count a failed write, and drop its id so later children
                // don't emit a parent ref to a file that was never created.
                uuidToLoreId[t.id] = nil
            }
        }
        if created > 0 {
            let bin = loreBinary
            Task.detached(priority: .utility) {
                _ = await ShellRunner.run(bin, args: ["reindex", "task"], cwd: projectPath)
            }
        }
        return Result(created: created, skipped: tasks.count - toCreate.count)
    }

    /// Resolve the lore binary — PATH isn't reliable inside the app host process.
    private static let loreBinary: String = {
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/lore").path
        return FileManager.default.isExecutableFile(atPath: local) ? local : "lore"
    }()

    // MARK: - Frontmatter

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()

    private static func frontmatter(for t: TaskItem, uuidToLoreId: [String: String]) -> String {
        var lines = ["---", "lore_type: task"]
        // Bare scalars only for values we control (enums/dates/ids) — no special chars.
        func bare(_ k: String, _ v: String?) { if let v = v, !v.isEmpty { lines.append("\(k): \(v)") } }
        // Any free-text or joined value goes through yaml(): a double-quoted scalar
        // that gray-matter parses safely (escapes \ and ", collapses newlines) and
        // that the app's line-based parser tolerates (it strips the outer quotes).
        func str(_ k: String, _ v: String?) {
            guard let v = v, !v.isEmpty else { return }
            lines.append("\(k): \(yaml(v))")
        }
        str("title", t.title)
        bare("status", t.status.rawValue)        // open/in_progress/blocked/done/skipped — matches lore
        bare("owner", t.owner.rawValue)          // human/ai/none — matches lore
        bare("category", t.category.rawValue)    // matches lore category enum
        bare("created", dateFmt.string(from: t.createdAt))
        bare("completed", t.completedAt.map(dateFmt.string(from:)))
        bare("started", t.startedAt.map(dateFmt.string(from:)))
        str("stage", t.stage)
        if t.hasAIRun { lines.append("ai_run: true") }   // key the rest of the app reads/writes
        bare("source", t.source.rawValue)
        str("ghIssue", t.ghIssueURL?.absoluteString)
        str("phases", t.phases?.joined(separator: ", "))
        str("completedPhases", t.completedPhases.isEmpty ? nil : t.completedPhases.joined(separator: ", "))
        str("persona", t.gstackPersonaOverride)
        str("linkedDoc", t.linkedDocPath)
        // Quote the parent id so gray-matter keeps it a zero-padded STRING (bare 0003
        // would parse as the number 3 and lose the padding → broken ref).
        if let pid = t.parentId, let parentLore = uuidToLoreId[pid] { lines.append("parent: \(yaml(parentLore))") }
        str("devdash_id", t.id)
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// YAML double-quoted scalar safe for gray-matter (escapes backslash + quote,
    /// collapses newlines). The app's line-based parser strips the outer quotes.
    private static func yaml(_ v: String) -> String {
        let esc = v
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(esc)\""
    }

    private static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("-") }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        // Truncate FIRST, then trim — otherwise prefix(50) can re-add a trailing hyphen.
        var s = String(out.prefix(50)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if s.isEmpty { s = "task" }
        return s
    }
}
