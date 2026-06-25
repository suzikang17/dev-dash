import Foundation

/// Global store for ProjectGroups at `~/.devdash/groups.json`.
/// Also manages per-group Linear task caches at `~/.devdash/group-tasks/<groupId>.json`.
enum GroupStore {

    // MARK: - Directory helpers

    private static var globalDir: String {
        let dir = "\(NSHomeDirectory())/.devdash"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var groupsPath: String {
        "\(globalDir)/groups.json"
    }

    private static func tasksPath(groupId: String) -> String {
        let dir = "\(globalDir)/group-tasks"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/\(groupId).json"
    }

    // MARK: - Codecs

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

    // MARK: - Groups CRUD

    static func read() -> [ProjectGroup] {
        guard FileManager.default.fileExists(atPath: groupsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: groupsPath)),
              let groups = try? decoder.decode([ProjectGroup].self, from: data) else {
            return []
        }
        return groups
    }

    static func write(_ groups: [ProjectGroup]) {
        guard let data = try? encoder.encode(groups) else { return }
        try? data.write(to: URL(fileURLWithPath: groupsPath), options: .atomic)
    }

    // MARK: - Per-group Linear task cache

    static func readTasks(groupId: String) -> [TaskItem] {
        let path = tasksPath(groupId: groupId)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let tasks = try? decoder.decode([TaskItem].self, from: data) else {
            return []
        }
        return tasks
    }

    static func writeTasks(groupId: String, tasks: [TaskItem]) {
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: URL(fileURLWithPath: tasksPath(groupId: groupId)), options: .atomic)
    }

    static func deleteTasks(groupId: String) {
        try? FileManager.default.removeItem(atPath: tasksPath(groupId: groupId))
    }
}
