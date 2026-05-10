import Foundation

/// Renders a living `ROADMAP.md` from template + meta + tasks.
/// File is overwritten on every state change, so users should keep their
/// own narrative notes outside of it (or in a separate doc) — the generator
/// owns the file. The header makes that explicit.
enum RoadmapGenerator {
    static let header = "<!-- managed by devdash — edit answers/exit criteria in the dashboard, not this file -->"
    static let folderRel = "docs/devdash"

    static func folderPath(for projectPath: String) -> String {
        "\(projectPath)/\(folderRel)"
    }

    static func filePath(for projectPath: String) -> String {
        "\(folderPath(for: projectPath))/ROADMAP.md"
    }

    /// Legacy locations we'll migrate from on first write.
    private static let legacyPaths = ["ROADMAP.md"]

    /// Generate and write `docs/devdash/ROADMAP.md`. Only does anything if a
    /// template is applied. Returns the written path on success.
    @discardableResult
    static func write(
        projectName: String,
        projectPath: String,
        meta: ProjectMeta,
        template: LaunchTemplate,
        tasks: [TaskItem]
    ) -> String? {
        let body = render(
            projectName: projectName,
            meta: meta,
            template: template,
            tasks: tasks
        )
        let path = filePath(for: projectPath)

        // Bail if a non-DevDash-managed file already exists at the target.
        if FileManager.default.fileExists(atPath: path),
           let existing = try? String(contentsOfFile: path, encoding: .utf8),
           !existing.contains(header) {
            return nil
        }

        // Ensure docs/devdash/ exists.
        try? FileManager.default.createDirectory(
            atPath: folderPath(for: projectPath),
            withIntermediateDirectories: true
        )

        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        // Clean up legacy ROADMAP.md at project root if it's a DevDash-managed
        // copy from before the move; leave user-authored ones alone.
        for legacy in legacyPaths {
            let legacyAbs = "\(projectPath)/\(legacy)"
            guard FileManager.default.fileExists(atPath: legacyAbs),
                  let existing = try? String(contentsOfFile: legacyAbs, encoding: .utf8),
                  existing.contains(header) else { continue }
            try? FileManager.default.removeItem(atPath: legacyAbs)
        }

        return path
    }

    /// Render to a string without writing, e.g. for previewing.
    static func render(
        projectName: String,
        meta: ProjectMeta,
        template: LaunchTemplate,
        tasks: [TaskItem]
    ) -> String {
        var out: [String] = []
        out.append(header)
        out.append("")
        out.append("# \(projectName) — Roadmap")
        out.append("")
        out.append("> **Methodology:** \(template.name)  ")
        if let stage = template.stages.first(where: { $0.id == meta.currentStageId }) {
            out.append("> **Current stage:** \(stage.title)")
        }
        out.append("")
        if !template.methodology.isEmpty {
            out.append("_\(template.methodology)_")
            out.append("")
        }

        // Stage timeline summary
        out.append("## Progress")
        out.append("")
        for s in template.stages {
            let status = stageStatus(s, in: template, meta: meta)
            let marker: String
            switch status {
            case .done:    marker = "✅"
            case .current: marker = "▶︎"
            case .pending: marker = "◯"
            }
            let exitChecked = s.exitCriteria.filter {
                meta.checkedExitCriteria.contains("\(s.id):\($0)")
            }.count
            let exitTotal = s.exitCriteria.count
            out.append("- \(marker) **\(s.title)** — \(exitChecked)/\(exitTotal) exit criteria")
        }
        out.append("")

        // Per-stage detail
        for s in template.stages {
            let status = stageStatus(s, in: template, meta: meta)
            let badge: String
            switch status {
            case .done:    badge = "_done_"
            case .current: badge = "_in progress_"
            case .pending: badge = "_pending_"
            }
            out.append("---")
            out.append("")
            out.append("## \(s.title) — \(badge)")
            out.append("")
            out.append("**Purpose:** \(s.purpose)")
            out.append("")
            if !s.methodology.isEmpty {
                out.append("> \(s.methodology)")
                out.append("")
            }

            // Q&A
            let answers = meta.stageAnswers[s.id] ?? [:]
            let answeredCount = s.guidingQuestions.filter { (answers[$0] ?? "").isEmpty == false }.count
            if !s.guidingQuestions.isEmpty {
                out.append("### Questions (\(answeredCount)/\(s.guidingQuestions.count) answered)")
                out.append("")
                for q in s.guidingQuestions {
                    out.append("**\(q)**")
                    let a = (answers[q] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if a.isEmpty {
                        out.append("> _unanswered_")
                    } else {
                        // Quote multi-line answers properly
                        for line in a.split(separator: "\n", omittingEmptySubsequences: false) {
                            out.append("> \(line)")
                        }
                    }
                    out.append("")
                }
            }

            // Exit criteria
            if !s.exitCriteria.isEmpty {
                out.append("### Exit criteria")
                out.append("")
                for c in s.exitCriteria {
                    let checked = meta.checkedExitCriteria.contains("\(s.id):\(c)")
                    out.append("- [\(checked ? "x" : " ")] \(c)")
                }
                out.append("")
            }

            // Tasks
            let stageTasks = tasks.filter { $0.stage == s.id }
            if !stageTasks.isEmpty {
                out.append("### Tasks")
                out.append("")
                for t in stageTasks {
                    let mark: String
                    switch t.status {
                    case .done:       mark = "[x]"
                    case .skipped:    mark = "[~]"
                    case .inProgress: mark = "[/]"
                    case .blocked:    mark = "[!]"
                    case .open:       mark = "[ ]"
                    }
                    out.append("- \(mark) \(t.title) _(\(t.category.label))_")
                }
                out.append("")
            }
        }

        // Unstaged tasks at the end
        let unstaged = tasks.filter { $0.stage == nil }
        if !unstaged.isEmpty {
            out.append("---")
            out.append("")
            out.append("## Unstaged tasks")
            out.append("")
            for t in unstaged {
                let mark: String
                switch t.status {
                case .done:       mark = "[x]"
                case .skipped:    mark = "[~]"
                case .inProgress: mark = "[/]"
                case .blocked:    mark = "[!]"
                case .open:       mark = "[ ]"
                }
                out.append("- \(mark) \(t.title) _(\(t.category.label))_")
            }
            out.append("")
        }

        out.append("---")
        out.append("")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        out.append("_Last updated: \(f.string(from: Date()))_")
        out.append("")
        return out.joined(separator: "\n")
    }

    private enum StageStatus { case done, current, pending }

    private static func stageStatus(_ stage: TemplateStage, in template: LaunchTemplate, meta: ProjectMeta) -> StageStatus {
        guard let currentId = meta.currentStageId,
              let currentIdx = template.stages.firstIndex(where: { $0.id == currentId }),
              let thisIdx = template.stages.firstIndex(where: { $0.id == stage.id }) else {
            return stage.id == meta.currentStageId ? .current : .pending
        }
        if thisIdx < currentIdx { return .done }
        if thisIdx == currentIdx { return .current }
        return .pending
    }
}
