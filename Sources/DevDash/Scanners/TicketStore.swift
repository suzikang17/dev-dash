import Foundation

/// Per-project structured ticket store backed by lore ticket docs (`docs/tickets/*.md`).
///
/// `Ticket.id` is the zero-padded numeric filename prefix (e.g. "0001").
/// Files are named `<id>-<slug>.md` and found by numeric id lookup (tolerates
/// non-zero-padded names written by the `lore` CLI, e.g. "1-foo.md").
///
/// This store mirrors `TaskStore`'s lore-adapter pattern: same frontmatter helpers,
/// same serialisation conventions, same numeric-id tolerance.
enum TicketStore {

    // MARK: - Directory helpers

    /// The tickets directory for a project.
    static func dir(for projectPath: String) -> String {
        "\(projectPath)/docs/tickets"
    }

    // MARK: - Read

    static func read(_ projectPath: String) -> [Ticket] {
        let ticketDir = dir(for: projectPath)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: ticketDir) else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".md") && $0.lowercased() != "index.md" }
            .sorted()
            .compactMap { filename -> Ticket? in
                let numericPrefix = String(filename.prefix(while: { $0.isNumber }))
                guard !numericPrefix.isEmpty,
                      let raw = try? String(contentsOfFile: "\(ticketDir)/\(filename)", encoding: .utf8)
                else { return nil }
                return parseTicket(id: numericPrefix, raw: raw)
            }
    }

    // MARK: - Add

    @discardableResult
    static func add(
        projectPath: String,
        title: String,
        category: TaskCategory = .other,
        owner: TaskOwner = .none,
        notes: String? = nil
    ) throws -> Ticket {
        let ticketDir = dir(for: projectPath)
        let fm = FileManager.default
        try fm.createDirectory(atPath: ticketDir, withIntermediateDirectories: true)

        // Compute next id: max existing numeric prefix + 1.
        let existingFiles = (try? fm.contentsOfDirectory(atPath: ticketDir)) ?? []
        let maxId = existingFiles
            .filter { $0.hasSuffix(".md") && $0.lowercased() != "index.md" }
            .compactMap { Int($0.prefix(while: { $0.isNumber })) }
            .max() ?? 0
        let newId = String(format: "%04d", maxId + 1)

        let ticket = Ticket(
            id: newId,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .open,
            owner: owner,
            category: category,
            pr: nil,
            createdAt: Date(),
            completedAt: nil,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            priority: nil,
            effort: nil
        )

        let filename = "\(newId)-\(ticketSlug(ticket.title)).md"
        let content = ticketDoc(for: ticket)
        try content.write(toFile: "\(ticketDir)/\(filename)", atomically: true, encoding: .utf8)
        return ticket
    }

    // MARK: - Mutators

    static func setStatus(projectPath: String, id: String, status: TaskStatus) throws {
        let ticketDir = dir(for: projectPath)
        guard let filename = findFile(id: id, in: ticketDir),
              let raw = try? String(contentsOfFile: "\(ticketDir)/\(filename)", encoding: .utf8)
        else { return }

        let fm = TaskStore.parseTaskFrontmatter(raw)
        let oldStatus = fm["status"] ?? "open"
        let newStatusRaw = status.rawValue

        var result = TaskStore.setOrAddFrontmatterKey(in: raw, key: "status", value: newStatusRaw)

        // Update completed date.
        switch status {
        case .done:
            result = TaskStore.setOrAddFrontmatterKey(in: result, key: "completed",
                                                      value: TaskStore.dateFmt.string(from: Date()))
        case .open, .inProgress, .blocked, .skipped:
            break
        }

        // Append status history using same sentinel convention as TaskStore.
        if oldStatus != newStatusRaw {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let entry = "- \(df.string(from: Date())) \(oldStatus) → \(newStatusRaw)"
            let sentinel = TaskStore.statusHistorySentinel
            if result.contains(sentinel) {
                result = result.trimmingCharacters(in: .newlines) + "\n" + entry + "\n"
            } else {
                result = result.trimmingCharacters(in: .newlines)
                    + "\n\(sentinel)\n## Status history\n" + entry + "\n"
            }
        }

        try result.write(toFile: "\(ticketDir)/\(filename)", atomically: true, encoding: .utf8)
    }

    static func setOwner(projectPath: String, id: String, owner: TaskOwner) throws {
        let ticketDir = dir(for: projectPath)
        guard let filename = findFile(id: id, in: ticketDir),
              let raw = try? String(contentsOfFile: "\(ticketDir)/\(filename)", encoding: .utf8)
        else { return }
        let result = TaskStore.setOrAddFrontmatterKey(in: raw, key: "owner", value: owner.rawValue)
        try result.write(toFile: "\(ticketDir)/\(filename)", atomically: true, encoding: .utf8)
    }

    /// Set or clear the `pr:` frontmatter key in place.
    static func setPR(projectPath: String, id: String, url: String?) throws {
        let ticketDir = dir(for: projectPath)
        guard let filename = findFile(id: id, in: ticketDir),
              let raw = try? String(contentsOfFile: "\(ticketDir)/\(filename)", encoding: .utf8)
        else { return }
        let result: String
        if let url = url, !url.isEmpty {
            result = TaskStore.setOrAddFrontmatterKey(in: raw, key: "pr",
                                                      value: TaskStore.yamlStr(url))
        } else {
            result = TaskStore.removeFrontmatterKey(in: raw, key: "pr")
        }
        try result.write(toFile: "\(ticketDir)/\(filename)", atomically: true, encoding: .utf8)
    }

    /// Update a ticket in-place, preserving all unknown frontmatter keys.
    static func update(projectPath: String, _ updated: Ticket) throws {
        let ticketDir = dir(for: projectPath)
        guard let filename = findFile(id: updated.id, in: ticketDir) else { return }
        let path = "\(ticketDir)/\(filename)"
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let patched = applyTicketToDoc(updated, existingDoc: existing)
            try patched.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            let content = ticketDoc(for: updated)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Delete a ticket doc. Does NOT cascade-delete its tasks (policy deferred to Stage 2).
    static func delete(projectPath: String, id: String) throws {
        let ticketDir = dir(for: projectPath)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: ticketDir)) ?? []
        for filename in files where filename.hasSuffix(".md") {
            let prefix = String(filename.prefix(while: { $0.isNumber }))
            if numEq(prefix, id) {
                try? fm.removeItem(atPath: "\(ticketDir)/\(filename)")
            }
        }
    }

    // MARK: - Serialisation

    /// Serialise a Ticket to a fresh lore ticket doc (frontmatter + body).
    static func ticketDoc(for t: Ticket) -> String {
        var lines = ["---", "lore_type: ticket"]

        func bare(_ k: String, _ v: String?) {
            if let v = v, !v.isEmpty { lines.append("\(k): \(v)") }
        }
        func str(_ k: String, _ v: String?) {
            guard let v = v, !v.isEmpty else { return }
            lines.append("\(k): \(TaskStore.yamlStr(v))")
        }

        str("title", t.title)
        bare("status", t.status.rawValue)
        bare("owner", t.owner == .none ? nil : t.owner.rawValue)
        bare("category", t.category.rawValue)
        str("pr", t.pr)
        bare("created", TaskStore.dateFmt.string(from: t.createdAt))
        bare("completed", t.completedAt.map { TaskStore.dateFmt.string(from: $0) })
        bare("priority", t.priority)
        bare("effort", t.effort)
        lines.append("---")

        let frontmatter = lines.joined(separator: "\n")
        let body = (t.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return frontmatter + "\n" + (body.isEmpty ? "# \(t.title)\n" : body + "\n")
    }

    /// Patch an EXISTING ticket doc's known fields in-place, preserving unknown keys.
    static func applyTicketToDoc(_ t: Ticket, existingDoc raw: String) -> String {
        var doc = raw

        func setStr(_ key: String, _ v: String?) {
            if let v = v, !v.isEmpty {
                doc = TaskStore.setOrAddFrontmatterKey(in: doc, key: key,
                                                       value: TaskStore.yamlStr(v))
            } else {
                doc = TaskStore.removeFrontmatterKey(in: doc, key: key)
            }
        }
        func setBare(_ key: String, _ v: String?) {
            if let v = v, !v.isEmpty {
                doc = TaskStore.setOrAddFrontmatterKey(in: doc, key: key, value: v)
            } else {
                doc = TaskStore.removeFrontmatterKey(in: doc, key: key)
            }
        }

        setStr("title", t.title)
        setBare("status", t.status.rawValue)
        setBare("owner", t.owner == .none ? nil : t.owner.rawValue)
        setBare("category", t.category.rawValue)
        setStr("pr", t.pr)
        setBare("created", TaskStore.dateFmt.string(from: t.createdAt))
        setBare("completed", t.completedAt.map { TaskStore.dateFmt.string(from: $0) })
        setBare("priority", t.priority)
        setBare("effort", t.effort)

        // Body patch: preserve status-history block, replace notes.
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

    // MARK: - File helpers

    /// Find the filename whose numeric prefix matches `id` (numeric comparison).
    static func findFile(id: String, in ticketDir: String) -> String? {
        guard let idInt = Int(id) else {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: ticketDir)) ?? []
            return files.first { f in
                guard f.hasSuffix(".md") else { return false }
                return String(f.prefix(while: { $0.isNumber })) == id
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ticketDir)) ?? []
        return files.first { filename in
            guard filename.hasSuffix(".md") else { return false }
            let prefix = String(filename.prefix(while: { $0.isNumber }))
            return Int(prefix) == idInt
        }
    }

    /// Compare two id strings numerically (tolerates "0001" == "1").
    static func numEq(_ a: String, _ b: String) -> Bool {
        if let ia = Int(a), let ib = Int(b) { return ia == ib }
        return a == b
    }

    // MARK: - Parsing

    private static func parseTicket(id: String, raw: String) -> Ticket? {
        let fm = TaskStore.parseTaskFrontmatter(raw)
        guard let title = fm["title"], !title.isEmpty else { return nil }

        let status: TaskStatus     = TaskStatus(rawValue: fm["status"] ?? "") ?? .open
        let owner: TaskOwner       = TaskOwner(rawValue: fm["owner"] ?? "") ?? .none
        let category: TaskCategory = TaskCategory(rawValue: fm["category"] ?? "") ?? .other

        let createdAt   = fm["created"].flatMap  { TaskStore.dateFmt.date(from: $0) } ?? Date()
        let completedAt = fm["completed"].flatMap { TaskStore.dateFmt.date(from: $0) }

        let pr = fm["pr"].flatMap { $0.isEmpty ? nil : $0 }
        let priority = fm["priority"].flatMap { $0.isEmpty ? nil : $0 }
        let effort   = fm["effort"].flatMap   { $0.isEmpty ? nil : $0 }
        let notes    = extractTicketNotes(from: raw, title: title)

        return Ticket(
            id: id,
            title: title,
            status: status,
            owner: owner,
            category: category,
            pr: pr,
            createdAt: createdAt,
            completedAt: completedAt,
            notes: notes,
            priority: priority,
            effort: effort
        )
    }

    /// Extract notes from the body after the frontmatter, stripping the auto-generated
    /// title heading and the sentinel-delimited status-history block.
    private static func extractTicketNotes(from raw: String, title: String) -> String? {
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

        // Strip sentinel-delimited status-history block.
        let sentinel = TaskStore.statusHistorySentinel
        if let sentinelRange = body.range(of: "\n" + sentinel) {
            body = String(body[body.startIndex..<sentinelRange.lowerBound])
        } else if body.hasPrefix(sentinel) {
            body = ""
        }
        // Strip auto-generated title heading (first non-empty line only).
        var lines = body.components(separatedBy: "\n")
        if let firstNonEmpty = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[firstNonEmpty] == "# \(title)" {
            lines.remove(at: firstNonEmpty)
        }
        body = lines.joined(separator: "\n")
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Body helpers (mirrors TaskStore)

    private static func replaceBody(in raw: String, newBody: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var fences = 0
        for i in lines.indices {
            if lines[i].hasPrefix("---") {
                fences += 1
                if fences == 2 {
                    let fm = lines[0...i].joined(separator: "\n")
                    return fm + "\n" + newBody
                }
            }
        }
        return raw
    }

    private static func extractStatusHistoryBlock(from doc: String) -> String? {
        let sentinel = TaskStore.statusHistorySentinel
        guard let range = doc.range(of: sentinel) else { return nil }
        return String(doc[range.lowerBound...]).trimmingCharacters(in: .newlines)
    }

    // MARK: - Slug

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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
