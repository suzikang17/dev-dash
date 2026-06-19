import Foundation

/// Builds a `ProjectStatus` from already-loaded store data + lore reads.
/// Pure and deterministic given its inputs (lore reads aside) — no AI, no store.
enum ProjectStatusSynthesizer {
    static func synthesize(
        project: Project,
        meta: ProjectMeta,
        tasks: [TaskItem],
        heatmap: CommitHeatmapStore.Heatmap?,
        services: [Service],
        now: Date
    ) -> ProjectStatus {
        let active = tasks.filter {
            $0.kanbanColumn.ownerIsHuman && $0.status != .done && $0.status != .skipped
        }.count
        let blocked = tasks.filter { $0.kanbanColumn == .blocked }.count
        let commits7d = heatmap?.dayCounts.suffix(7).reduce(0, +) ?? 0
        let ports = services.map(\.port).sorted()

        let tagline: String? = {
            if let firstLine = meta.notes?
                .split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }) {
                return firstLine
            }
            return project.stack ?? project.framework
        }()

        return ProjectStatus(
            projectName: project.name,
            tagline: tagline,
            lastSession: LoreReader.latest(type: "devlog", in: project.path),
            activeTaskCount: active,
            blockedTaskCount: blocked,
            recentDecision: LoreReader.latest(type: "decisions", in: project.path),
            commits7d: commits7d,
            runningPorts: ports,
            health: project.health,
            generatedAt: now
        )
    }
}
