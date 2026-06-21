import Foundation

/// Describes a lore type a bullet can be supertagged into, including exactly how to
/// author a valid doc of that type (mirrors LoreSection.newDocFields semantics).
struct SupertagType: Equatable {
    let loreType: String        // singular CLI type, e.g. "task"
    let dir: String             // plural folder, e.g. "tasks"
    let label: String
    let bodyIsFree: Bool
    let requiredSections: [String]
    let frontmatterFields: [String]   // "k=v" pairs, e.g. ["status=open"]
}

/// The dynamic supertag set = all registered lore types. Built from LoreSection.all
/// plus task/devlog (which LoreSection does not model), minus note (the default).
enum SupertagRegistry {
    static func all() -> [SupertagType] {
        let task = SupertagType(loreType: "task", dir: "tasks", label: "Task",
                                bodyIsFree: true, requiredSections: [],
                                frontmatterFields: ["status=open", "owner=human", "category=engineering"])
        let devlog = SupertagType(loreType: "devlog", dir: "devlog", label: "Devlog",
                                  bodyIsFree: true, requiredSections: [], frontmatterFields: [])
        let fromSections: [SupertagType] = LoreSection.all.compactMap { s in
            guard s.loreType != "note" else { return nil }   // note = default, not offered
            return SupertagType(loreType: s.loreType, dir: s.dir, label: s.label,
                                bodyIsFree: s.bodyIsFree, requiredSections: s.requiredSections,
                                frontmatterFields: s.newDocFields)
        }
        // Stable, sensible order.
        let order = ["task", "idea", "decision", "kpi", "devlog", "overview"]
        let merged = [task, devlog] + fromSections
        return merged.sorted { (order.firstIndex(of: $0.loreType) ?? 99) < (order.firstIndex(of: $1.loreType) ?? 99) }
    }

    static func find(_ loreType: String) -> SupertagType? {
        all().first { $0.loreType == loreType }
    }
}
