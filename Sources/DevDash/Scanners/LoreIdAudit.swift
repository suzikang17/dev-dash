import Foundation

/// Detects duplicate numeric-id prefixes in a lore doc dir — the collision
/// mode where two parallel branches (agent worktrees) each mint `max+1`,
/// producing e.g. `0010-foo.md` and `0010-bar.md` after merge. Ids compare
/// numerically, so `010-x.md` also collides with `0010-y.md`.
///
/// Detection-only: renumbering is left to the human (cross-refs like
/// `ticket:`/`parent:` point at ids, so an auto-rename could silently
/// re-target them).
enum LoreIdAudit {

    /// Duplicate ids in one lore dir → sorted `(zero-padded id, filenames)`.
    static func collisions(inDir dir: String) -> [(id: String, files: [String])] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var byId: [Int: [String]] = [:]
        for f in files where f.hasSuffix(".md") && f.lowercased() != "index.md" {
            let prefix = String(f.prefix(while: { $0.isNumber }))
            guard !prefix.isEmpty, let n = Int(prefix) else { continue }
            byId[n, default: []].append(f)
        }
        return byId.filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { (String(format: "%04d", $0.key), $0.value.sorted()) }
    }

    /// Human-readable collision messages across a project's id-bearing lore
    /// types (tasks, tickets, policies). Empty = healthy.
    static func audit(projectPath: String) -> [String] {
        var msgs: [String] = []
        for (type, sub) in [("task", "tasks"), ("ticket", "tickets"), ("policy", "policies")] {
            for c in collisions(inDir: "\(projectPath)/docs/\(sub)") {
                msgs.append("\(type) \(c.id): \(c.files.joined(separator: ", "))")
            }
        }
        return msgs
    }
}
