import Foundation

/// A reference to a lore document (devlog, decision) — the trimmed fields the
/// status snapshot needs, not the whole entry.
struct LoreRef: Codable, Hashable {
    let title: String
    let date: Date?
}

/// Deterministic, always-current snapshot of one project. Synthesized from data
/// the store already holds plus lore reads — never persisted to lore, never AI.
/// Codable so a future cross-project board can serialize a list of these.
struct ProjectStatus: Codable, Hashable {
    let projectName: String
    let tagline: String?
    let lastSession: LoreRef?
    let activeTaskCount: Int
    let blockedTaskCount: Int
    let recentDecision: LoreRef?
    let commits7d: Int
    let runningPorts: [Int]
    let health: HealthStatus
    let generatedAt: Date
}
