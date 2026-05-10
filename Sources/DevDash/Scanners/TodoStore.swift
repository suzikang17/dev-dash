import Foundation

enum TodoStore {
    static func file(for projectPath: String) -> String {
        "\(projectPath)/.devdash/todos.json"
    }

    static func read(_ projectPath: String) -> [Todo] {
        let path = file(for: projectPath)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let todos = try? JSONDecoder().decode([Todo].self, from: data) else {
            return []
        }
        return todos
    }

    static func write(_ projectPath: String, todos: [Todo]) throws {
        let dir = "\(projectPath)/.devdash"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(todos)
        try data.write(to: URL(fileURLWithPath: file(for: projectPath)))
    }

    static func add(projectPath: String, text: String) throws -> Todo {
        var todos = read(projectPath)
        let todo = Todo(
            id: UUID().uuidString,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            done: false,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            doneAt: nil
        )
        todos.append(todo)
        try write(projectPath, todos: todos)
        return todo
    }

    static func toggle(projectPath: String, id: String) throws {
        var todos = read(projectPath)
        guard let idx = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[idx].done.toggle()
        todos[idx].doneAt = todos[idx].done ? ISO8601DateFormatter().string(from: Date()) : nil
        try write(projectPath, todos: todos)
    }

    static func delete(projectPath: String, id: String) throws {
        let todos = read(projectPath).filter { $0.id != id }
        try write(projectPath, todos: todos)
    }

    static func gather(projectPaths: [String]) async -> [(path: String, name: String, todos: [Todo])] {
        return await withTaskGroup(of: (String, String, [Todo])?.self) { group in
            for path in projectPaths {
                group.addTask {
                    let todos = read(path)
                    if todos.isEmpty { return nil }
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return (path, name, todos)
                }
            }
            var results: [(String, String, [Todo])] = []
            for await r in group { if let r = r { results.append(r) } }
            return results.map { (path: $0.0, name: $0.1, todos: $0.2) }
        }
    }
}
