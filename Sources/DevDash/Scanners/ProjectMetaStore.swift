import Foundation

/// Per-project metadata at `.devdash/project.json`. Drives template selection,
/// current stage, exit-criteria gating, and roadmap freshness detection.
enum ProjectMetaStore {
    static func file(for projectPath: String) -> String {
        "\(projectPath)/.devdash/project.json"
    }

    static func read(_ projectPath: String) -> ProjectMeta {
        let path = file(for: projectPath)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let meta = try? decoder.decode(ProjectMeta.self, from: data) else {
            return .empty
        }
        return meta
    }

    static func write(_ projectPath: String, meta: ProjectMeta) throws {
        let dir = "\(projectPath)/.devdash"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var m = meta
        m.updatedAt = Date()
        let data = try encoder.encode(m)
        try data.write(to: URL(fileURLWithPath: file(for: projectPath)), options: .atomic)
    }

    /// Apply a template to a project: set templateId, jump to first stage,
    /// reset checked exit criteria. Existing tasks are left alone.
    static func applyTemplate(_ template: LaunchTemplate, to projectPath: String) throws {
        var meta = read(projectPath)
        meta.templateId = template.id
        meta.currentStageId = template.stages.first?.id
        meta.stageStartedAt = Date()
        meta.checkedExitCriteria = []
        try write(projectPath, meta: meta)
    }

    static func setStage(_ stageId: String, for projectPath: String) throws {
        var meta = read(projectPath)
        meta.currentStageId = stageId
        meta.stageStartedAt = Date()
        // Reset exit criteria for the new stage; criteria are stage-keyed
        // so leaving them in place is harmless, but clearing keeps it tidy.
        meta.checkedExitCriteria = meta.checkedExitCriteria.filter {
            $0.hasPrefix("\(stageId):") == false
        }
        try write(projectPath, meta: meta)
    }

    static func toggleExitCriterion(_ criterion: String, stageId: String, for projectPath: String) throws {
        var meta = read(projectPath)
        let key = "\(stageId):\(criterion)"
        if meta.checkedExitCriteria.contains(key) {
            meta.checkedExitCriteria.remove(key)
        } else {
            meta.checkedExitCriteria.insert(key)
        }
        try write(projectPath, meta: meta)
    }

    /// Discover a roadmap document by trying common filenames.
    static func discoverRoadmap(in projectPath: String) -> String? {
        let candidates = [
            "ROADMAP.md", "Roadmap.md", "roadmap.md",
            "TODO.md", "Todo.md", "todo.md",
            "docs/ROADMAP.md", "docs/roadmap.md", "docs/todo.md"
        ]
        let fm = FileManager.default
        for c in candidates {
            let p = "\(projectPath)/\(c)"
            if fm.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// Days since the resolved roadmap file was last modified, or nil if no roadmap.
    static func roadmapAgeDays(in projectPath: String) -> Int? {
        guard let path = discoverRoadmap(in: projectPath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: mtime, to: Date()).day ?? 0
        return max(0, days)
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
