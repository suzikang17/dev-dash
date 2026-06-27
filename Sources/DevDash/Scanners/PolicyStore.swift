import Foundation

/// Status of a policy doc. Only `.active` policies are injected into prompts.
enum PolicyStatus: String, Codable, Hashable {
    case draft, active, deprecated
}

/// A single agent-behavior policy, backed by a lore `policy` doc
/// (`docs/policies/<id>-<slug>.md`). `id` is the numeric filename prefix.
///
/// Mirrors `TicketStore`'s lore-adapter pattern: same frontmatter helpers,
/// numeric-id tolerance. `applies_to` / `trigger` are comma-separated string
/// values (lore has no list type; mirrors task.schema's `phases` convention),
/// parsed by `parseList` below.
struct Policy: Identifiable, Hashable {
    let id: String
    let title: String
    let appliesTo: [String]
    let trigger: [String]
    let status: PolicyStatus
    let priority: Int?
    let body: String
}

enum PolicyStore {

    static func dir(for projectPath: String) -> String {
        "\(projectPath)/docs/policies"
    }

    static func read(_ projectPath: String) -> [Policy] {
        let policyDir = dir(for: projectPath)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: policyDir) else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".md") && $0.lowercased() != "index.md" }
            .sorted()
            .compactMap { filename -> Policy? in
                let numericPrefix = String(filename.prefix(while: { $0.isNumber }))
                guard !numericPrefix.isEmpty,
                      let raw = try? String(contentsOfFile: "\(policyDir)/\(filename)", encoding: .utf8)
                else { return nil }
                return parsePolicy(id: numericPrefix, raw: raw)
            }
    }

    /// Parse a comma-separated value (`a, b, c`) into trimmed, non-empty
    /// strings. Tolerates a bare scalar (`a`) → `["a"]` and legacy bracket
    /// form (`[a, b]`).
    static func parseList(_ rawValue: String?) -> [String] {
        guard var v = rawValue?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return [] }
        if v.hasPrefix("[") && v.hasSuffix("]") {
            v = String(v.dropFirst().dropLast())
        }
        return v.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }

    private static func parsePolicy(id: String, raw: String) -> Policy? {
        let fm = TaskStore.parseTaskFrontmatter(raw)
        guard let title = fm["title"], !title.isEmpty else { return nil }
        let status = PolicyStatus(rawValue: fm["status"] ?? "") ?? .draft
        return Policy(
            id: id,
            title: title,
            appliesTo: parseList(fm["applies_to"]),
            trigger: parseList(fm["trigger"]),
            status: status,
            priority: fm["priority"].flatMap { Int($0) },
            body: extractBody(from: raw)
        )
    }

    /// Body = everything after the closing frontmatter fence, trimmed.
    private static func extractBody(from raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var fences = 0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("---") {
                fences += 1
                if fences == 2 {
                    return lines[(i + 1)...].joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return ""
    }
}
