import Foundation

/// Scans `docs/devdash/` for artifact HTML files, extracts the
/// `<!-- devdash:meta ... -->` front matter from each, and writes
/// `.index.json` — a single queryable manifest of every artifact in
/// the project. AI agents and the in-doc UI can read this instead of
/// scanning every file.
enum DocIndexGenerator {
    struct ArtifactMeta: Codable, Hashable {
        let path: String         // relative to docs/devdash
        let type: String         // from front matter, defaults to folder name
        let title: String
        let status: String?
        let owner: String?
        let tags: [String]
        let created: String?     // ISO date string from front matter (best effort)
        let modified: Date
        let wordCount: Int
    }

    struct Manifest: Codable {
        let generatedAt: Date
        let artifacts: [ArtifactMeta]
    }

    /// Walk every artifact folder, parse front matter, write manifest.
    @discardableResult
    static func generate(projectPath: String) -> URL? {
        let docsRoot = "\(projectPath)/\(ProductDocGenerator.folderRel)"
        guard FileManager.default.fileExists(atPath: docsRoot) else { return nil }

        var artifacts: [ArtifactMeta] = []
        let folders = ProductDocGenerator.artifactFolders.map { $0.rel } + ["sections"]
        for rel in folders {
            let dir = "\(docsRoot)/\(rel)"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".html") {
                let path = "\(dir)/\(f)"
                guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let meta = parseFrontMatter(body)
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
                let title = extractTitle(from: body) ?? (f as NSString).deletingPathExtension
                artifacts.append(ArtifactMeta(
                    path: "\(rel)/\(f)",
                    type: meta["type"] ?? rel,
                    title: title,
                    status: meta["status"],
                    owner: meta["owner"],
                    tags: parseTagList(meta["tags"]),
                    created: meta["created"],
                    modified: mtime,
                    wordCount: countWords(body)
                ))
            }
        }

        artifacts.sort { $0.modified > $1.modified }
        let manifest = Manifest(generatedAt: Date(), artifacts: artifacts)
        let target = URL(fileURLWithPath: "\(docsRoot)/.index.json")
        guard let data = try? encoder.encode(manifest) else { return nil }
        try? data.write(to: target, options: .atomic)
        return target
    }

    /// Parse the `<!-- devdash:meta\nkey: value\n... -->` block at the top
    /// of an HTML file. Returns flat string→string. Tags handled by caller.
    static func parseFrontMatter(_ html: String) -> [String: String] {
        guard let openRange = html.range(of: "<!--", options: [.literal]) else { return [:] }
        let head = html[openRange.upperBound...]
        guard let closeRange = head.range(of: "-->", options: [.literal]) else { return [:] }
        let block = String(head[..<closeRange.lowerBound])
        // Must contain the marker at the top of the comment
        guard block.range(of: "devdash:meta") != nil else { return [:] }

        var dict: [String: String] = [:]
        for line in block.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("devdash:meta") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { dict[key] = value }
        }
        return dict
    }

    private static func parseTagList(_ raw: String?) -> [String] {
        guard let raw = raw else { return [] }
        var s = raw
        if s.hasPrefix("[") && s.hasSuffix("]") {
            s = String(s.dropFirst().dropLast())
        }
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func extractTitle(from html: String) -> String? {
        for tag in ["h1", "h2"] {
            if let r1 = html.range(of: "<\(tag)>"),
               let r2 = html.range(of: "</\(tag)>", range: r1.upperBound..<html.endIndex) {
                let inner = String(html[r1.upperBound..<r2.lowerBound])
                return inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func countWords(_ html: String) -> Int {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let comments = stripped.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        return comments.split { !$0.isLetter && !$0.isNumber }.count
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
