import Foundation

/// Read-only store for lore artifact docs (`docs/artifacts/*.md`).
///
/// Artifact files are named `<id>-<slug>.md` (e.g. `0001-summary.md`).
/// The numeric filename prefix is the artifact's `id`; the `task` frontmatter
/// field links it to a task by numeric id (tolerates zero-padding like TaskStore).
enum ArtifactStore {

    // MARK: - Directory

    static func dir(for projectPath: String) -> String {
        "\(projectPath)/docs/artifacts"
    }

    // MARK: - Read all

    /// Scan `<projectPath>/docs/artifacts/*.md`, parse each into an `Artifact`.
    /// Skips index.md/INDEX.md. Returns `[]` on any filesystem error or if the
    /// directory doesn't exist yet — never crashes on malformed/missing input.
    static func read(_ projectPath: String) -> [Artifact] {
        let dir = Self.dir(for: projectPath)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }

        return files
            .filter { $0.hasSuffix(".md") && $0.lowercased() != "index.md" }
            .sorted()
            .compactMap { filename -> Artifact? in
                let numericPrefix = String(filename.prefix(while: { $0.isNumber }))
                guard !numericPrefix.isEmpty else { return nil }
                let fullPath = "\(dir)/\(filename)"
                guard let raw = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                    return nil
                }
                return parseArtifact(id: numericPrefix, raw: raw, path: fullPath)
            }
    }

    // MARK: - Read filtered by task

    /// Return artifacts whose `task` field matches `taskId` numerically.
    /// Tolerates zero-padding: `task=42` and `task=0042` both match taskId "42".
    static func read(_ projectPath: String, forTask taskId: String) -> [Artifact] {
        read(projectPath).filter { artifact in
            guard let t = artifact.task else { return false }
            // Numeric comparison: strip leading zeros on both sides.
            if let ia = Int(t), let ib = Int(taskId) { return ia == ib }
            return t == taskId
        }
    }

    // MARK: - Private parsing

    private static func parseArtifact(id: String, raw: String, path: String) -> Artifact? {
        let fm = LoreReader.parseFrontmatter(raw)
        guard let title = fm["title"], !title.isEmpty else { return nil }

        let body = extractBody(from: raw)

        return Artifact(
            id: id,
            title: title,
            task: fm["task"].flatMap { $0.isEmpty ? nil : $0 },
            kind: fm["kind"].flatMap { $0.isEmpty ? nil : $0 },
            file: fm["file"].flatMap { $0.isEmpty ? nil : $0 },
            created: fm["created"].flatMap { $0.isEmpty ? nil : $0 },
            body: body,
            path: path
        )
    }

    /// Extract everything after the closing `---` frontmatter fence.
    private static func extractBody(from raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var fences = 0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("---") {
                fences += 1
                if fences == 2 {
                    let bodyLines = lines[(i + 1)...]
                    return bodyLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
