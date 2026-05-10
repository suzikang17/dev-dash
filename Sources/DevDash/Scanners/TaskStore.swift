import Foundation

/// Per-project structured task store at `.devdash/tasks.json`.
/// Migrates legacy `.devdash/todos.json` on first read and leaves the old
/// file in place (so old DevDash builds still work side-by-side).
enum TaskStore {
    static func file(for projectPath: String) -> String {
        "\(projectPath)/.devdash/tasks.json"
    }

    static func read(_ projectPath: String) -> [TaskItem] {
        let path = file(for: projectPath)
        if FileManager.default.fileExists(atPath: path),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let tasks = try? decoder.decode([TaskItem].self, from: data) {
            // Migrate legacy in_progress tasks to open+ai ownership
            let migrated = tasks.map { t -> TaskItem in
                guard t.status == .inProgress else { return t }
                var m = t
                m.status = .open
                if m.owner == .none { m.owner = .ai }
                m.hasAIRun = true
                return m
            }
            return migrated
        }
        // No tasks.json yet — migrate from legacy todos.json if present.
        let legacy = TodoStore.read(projectPath)
        guard !legacy.isEmpty else { return [] }
        let fromLegacy: [TaskItem] = legacy.map { todo in
            TaskItem(
                id: todo.id,
                title: todo.text,
                notes: nil,
                stage: nil,
                category: .other,
                source: .local,
                status: todo.done ? .done : .open,
                createdAt: ISO8601DateFormatter().date(from: todo.createdAt) ?? Date(),
                startedAt: nil,
                completedAt: todo.doneAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                ghIssueURL: nil
            )
        }
        // Migrate legacy in_progress tasks to open+ai ownership
        let migrated = fromLegacy.map { t -> TaskItem in
            guard t.status == .inProgress else { return t }
            var m = t
            m.status = .open
            if m.owner == .none { m.owner = .ai }
            m.hasAIRun = true
            return m
        }
        try? write(projectPath, tasks: migrated)
        return migrated
    }

    static func write(_ projectPath: String, tasks: [TaskItem]) throws {
        let dir = "\(projectPath)/.devdash"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(tasks)
        try data.write(to: URL(fileURLWithPath: file(for: projectPath)), options: .atomic)
    }

    static func add(
        projectPath: String,
        title: String,
        category: TaskCategory = .other,
        stage: String? = nil,
        notes: String? = nil,
        source: TaskSource = .local,
        parentId: String? = nil
    ) throws -> TaskItem {
        var tasks = read(projectPath)
        let task = TaskItem(
            id: UUID().uuidString,
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
            parentId: parentId
        )
        tasks.append(task)
        try write(projectPath, tasks: tasks)
        return task
    }

    /// Set or clear the parent of a task. Walks up the existing tree to make
    /// sure newParentId isn't a descendant of `id` — prevents cycles.
    static func setParent(projectPath: String, id: String, newParentId: String?) throws {
        var tasks = read(projectPath)
        guard tasks.contains(where: { $0.id == id }) else { return }
        if let newParent = newParentId {
            // Cycle guard: walk newParent's ancestors; if we ever hit `id`, abort.
            var cursor: String? = newParent
            var seen = Set<String>()
            while let c = cursor {
                if c == id { return }   // would create a cycle — silently no-op
                if seen.contains(c) { break }
                seen.insert(c)
                cursor = tasks.first(where: { $0.id == c })?.parentId
            }
        }
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].parentId = newParentId
        try write(projectPath, tasks: tasks)
    }

    /// Returns true if `id` has any children in the project's task list.
    static func hasChildren(projectPath: String, id: String) -> Bool {
        read(projectPath).contains { $0.parentId == id }
    }

    static func update(projectPath: String, _ updated: TaskItem) throws {
        var tasks = read(projectPath)
        guard let idx = tasks.firstIndex(where: { $0.id == updated.id }) else { return }
        tasks[idx] = updated
        try write(projectPath, tasks: tasks)
    }

    static func setStatus(projectPath: String, id: String, status: TaskStatus) throws {
        var tasks = read(projectPath)
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].status = status
        switch status {
        case .inProgress where tasks[idx].startedAt == nil:
            tasks[idx].startedAt = Date()
        case .done:
            tasks[idx].completedAt = Date()
        case .open, .skipped:
            break
        default:
            break
        }
        try write(projectPath, tasks: tasks)
    }

    static func setOwner(projectPath: String, id: String, owner: TaskOwner) throws {
        var tasks = read(projectPath)
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].owner = owner
        try write(projectPath, tasks: tasks)
    }

    static func setHasAIRun(projectPath: String, id: String) throws {
        var tasks = read(projectPath)
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].hasAIRun = true
        try write(projectPath, tasks: tasks)
    }

    static func setPhases(projectPath: String, id: String, phases: [String]) throws {
        var tasks = read(projectPath)
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].phases = phases
        try write(projectPath, tasks: tasks)
    }

    static func addCompletedPhase(projectPath: String, id: String, phase: String) throws {
        var tasks = read(projectPath)
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        if !tasks[idx].completedPhases.contains(phase) {
            tasks[idx].completedPhases.append(phase)
        }
        try write(projectPath, tasks: tasks)
    }

    static func delete(projectPath: String, id: String) throws {
        let tasks = read(projectPath).filter { $0.id != id }
        try write(projectPath, tasks: tasks)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
