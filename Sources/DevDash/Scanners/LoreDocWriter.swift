import Foundation

enum LoreDocWriter {
    struct ExtractionResult: Equatable {
        let mutatedNodes: [DayNode]
        let docTitle: String
        let docBody: String
        let backlink: String
    }

    /// Pure: extract a bullet's subtree into doc content, leaving a backlink in the outline.
    static func extract(nodeId: UUID, type: SupertagType, from nodes: [DayNode]) -> ExtractionResult? {
        guard let found = find(nodeId, in: nodes) else { return nil }
        let title = found.text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let body = DayOutline.serialize(found.children)   // children de-indent to depth 0
        let backlink = "[[\(title)]]"
        let mutated = replace(nodeId, in: nodes) { var m = $0; m.text = backlink; m.children = []; return m }
        return ExtractionResult(mutatedNodes: mutated, docTitle: title, docBody: body, backlink: backlink)
    }

    /// Pure: full markdown file content for a new typed doc (deterministic, no AI).
    static func docContent(type: SupertagType, title: String, bodyMarkdown: String, today: String) -> String {
        var fm = "---\ntitle: \"\(escape(title))\"\n"
        fm += "created: \"\(today)\"\n"
        for pair in type.frontmatterFields {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fm += "\(parts[0]): \(parts[1])\n" }
        }
        if !type.bodyIsFree { fm += "date: \"\(today)\"\n" }   // sections schemas require a date
        fm += "---\n\n# \(title)\n\n"

        if type.bodyIsFree {
            return fm + (bodyMarkdown.isEmpty ? "" : bodyMarkdown + "\n")
        }
        // sections schema: scaffold required H2s; put body under the first.
        var out = fm
        for (i, section) in type.requiredSections.enumerated() {
            out += "## \(section)\n\n"
            if i == 0 && !bodyMarkdown.isEmpty { out += bodyMarkdown + "\n\n" }
        }
        return out
    }

    /// IO: write the doc file + reindex. Returns success.
    static func commit(projectPath: String, type: SupertagType, result: ExtractionResult) async -> Bool {
        let dir = "\(projectPath)/docs/\(type.dir)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = LoreRunner.nextId(in: dir)
        let slug = LoreRunner.slug(from: result.docTitle)
        let file = "\(dir)/\(id)-\(slug).md"
        let today = DailyPageStore.todayString()
        let content = docContent(type: type, title: result.docTitle, bodyMarkdown: result.docBody, today: today)
        do { try content.write(toFile: file, atomically: true, encoding: .utf8) }
        catch { return false }
        if let bin = await loreBinary() {
            _ = await ShellRunner.run(bin, args: ["reindex", type.loreType], cwd: projectPath)
        }
        return true
    }

    // MARK: - helpers

    private static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }

    private static func find(_ id: UUID, in nodes: [DayNode]) -> DayNode? {
        for n in nodes {
            if n.id == id { return n }
            if let hit = find(id, in: n.children) { return hit }
        }
        return nil
    }

    private static func replace(_ id: UUID, in nodes: [DayNode], _ f: (DayNode) -> DayNode) -> [DayNode] {
        nodes.map { n in
            if n.id == id { return f(n) }
            var m = n; m.children = replace(id, in: n.children, f); return m
        }
    }

    private static func loreBinary() async -> String? {
        for p in ["/usr/local/bin/lore", "/opt/homebrew/bin/lore", "\(NSHomeDirectory())/.local/bin/lore"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        if let found = await ShellRunner.run("/usr/bin/which", args: ["lore"]) {
            let t = found.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }
}
