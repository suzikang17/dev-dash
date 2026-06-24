import Foundation

/// One-time, idempotent export of `.devdash/tasks.json` tasks into lore task
/// docs (`docs/tasks/*.md`), porting every field.  Parent UUIDs are remapped
/// to lore sequential ids.  Re-running skips tasks already exported (matched
/// by `devdash_id` frontmatter), so it never duplicates.
///
/// **Cycle note**: This deliberately reads `.devdash/tasks.json` directly
/// (not via `TaskStore.read`) to avoid the mutual-recursion that would arise
/// because `TaskStore.read` calls `migrate` when the JSON file exists.
///
/// **Reindex**: After writing files, `lore reindex task` runs synchronously
/// (blocking the calling thread) before migrate() returns so subsequent reads
/// see a stable lore index.
enum TaskLoreMigrator {
    struct Result { let created: Int; let skipped: Int }

    @discardableResult
    static func migrate(projectPath: String) -> Result {
        // Read directly from JSON — do NOT call TaskStore.read here (cycle).
        let tasks = readTasksFromJSON(projectPath)
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
            guard let n = Int(f.prefix(while: { $0.isNumber })) else { continue }
            maxId = max(maxId, n)
            guard let raw = try? String(contentsOfFile: "\(dir)/\(f)", encoding: .utf8) else { continue }
            if let did = LoreReader.parseFrontmatter(raw)["devdash_id"] {
                alreadyExported.insert(did)
                uuidToLoreId[did] = String(format: "%04d", n)
            }
        }

        // Assign new lore ids to not-yet-exported tasks (preserving order).
        let toCreate = tasks.filter { !alreadyExported.contains($0.id) }
        var nextId = maxId
        for t in toCreate { nextId += 1; uuidToLoreId[t.id] = String(format: "%04d", nextId) }

        var created = 0
        for t in toCreate {
            guard let loreId = uuidToLoreId[t.id] else { continue }

            // Build a TaskItem with the lore numeric id and remapped parent.
            let loreTask = TaskItem(
                id: loreId,
                title: t.title,
                notes: t.notes,
                stage: t.stage,
                category: t.category,
                source: t.source,
                status: t.status,
                createdAt: t.createdAt,
                startedAt: t.startedAt,
                completedAt: t.completedAt,
                ghIssueURL: t.ghIssueURL,
                parentId: t.parentId.flatMap { uuidToLoreId[$0] },
                owner: t.owner,
                hasAIRun: t.hasAIRun,
                phases: t.phases,
                completedPhases: t.completedPhases,
                gstackPersonaOverride: t.gstackPersonaOverride,
                linkedDocPath: t.linkedDocPath
            )

            // Write fresh doc then inject devdash_id to make migration idempotent.
            var doc = TaskStore.taskDoc(for: loreTask)
            doc = TaskStore.setOrAddFrontmatterKey(in: doc, key: "devdash_id",
                                                   value: TaskStore.yamlStr(t.id))

            let path = "\(dir)/\(loreId)-\(slug(t.title)).md"
            do {
                try doc.write(toFile: path, atomically: true, encoding: .utf8)
                created += 1
            } catch {
                uuidToLoreId[t.id] = nil
            }
        }

        // Reindex synchronously so reads after migration see a stable lore index.
        if created > 0 {
            let bin = loreBinary
            let sema = DispatchSemaphore(value: 0)
            Task.detached(priority: .utility) {
                _ = await ShellRunner.run(bin, args: ["reindex", "task"], cwd: projectPath)
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 30)
        }

        return Result(created: created, skipped: tasks.count - toCreate.count)
    }

    // MARK: - JSON reader (cycle-breaker)

    /// Read tasks directly from `.devdash/tasks.json`, bypassing `TaskStore.read`.
    private static func readTasksFromJSON(_ projectPath: String) -> [TaskItem] {
        let path = "\(projectPath)/.devdash/tasks.json"
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let tasks = try? jsonDecoder.decode([TaskItem].self, from: data)
        else { return [] }

        // Apply the same legacy in_progress migration that old TaskStore.read applied.
        return tasks.map { t -> TaskItem in
            guard t.status == .inProgress else { return t }
            var m = t
            m.status = .open
            if m.owner == .none { m.owner = .ai }
            m.hasAIRun = true
            return m
        }
    }

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Lore binary

    private static let loreBinary: String = {
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/lore").path
        return FileManager.default.isExecutableFile(atPath: local) ? local : "lore"
    }()

    // MARK: - Slug (matches TaskStore exactly)

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
}
