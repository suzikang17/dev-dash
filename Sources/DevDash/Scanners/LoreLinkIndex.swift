import Foundation

/// The lore knowledge-graph layer: resolves `[[wikilinks]]` and computes backlinks
/// across every lore doc type in a project — mirroring lore-core's buildLinkIndex/
/// computeBacklinks (the lore CLI doesn't expose them). Tokens are a doc's title
/// or filename base (lowercased); links live in markdown bodies as `[[token]]`.
enum LoreLinkIndex {
    struct Target: Hashable { let path: String; let title: String }   // path = "dir/file.md"
    struct Backlink: Hashable { let fromPath: String; let fromTitle: String; let fromType: String }

    struct Graph {
        /// lowercased token (title or filename base) → target
        let resolve: [String: Target]
        /// target path → docs that reference it
        let backlinks: [String: [Backlink]]
    }

    private static let wikiRE = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)

    /// Build the graph for a project over the given lore section dirs.
    static func build(projectPath: String, dirs: [String]) -> Graph {
        let fm = FileManager.default
        // Pass 1: gather every doc → (path, title, body) and the token index.
        var docs: [(path: String, title: String, type: String, body: String)] = []
        var resolve: [String: Target] = [:]
        for dir in dirs {
            let dirPath = "\(projectPath)/docs/\(dir)"
            for file in (try? fm.contentsOfDirectory(atPath: dirPath)) ?? [] {
                guard file.hasSuffix(".md"), file.lowercased() != "index.md" else { continue }
                guard let raw = try? String(contentsOfFile: "\(dirPath)/\(file)", encoding: .utf8) else { continue }
                let front = LoreReader.parseFrontmatter(raw)
                let title = front["title"] ?? file.replacingOccurrences(of: ".md", with: "")
                let path = "\(dir)/\(file)"
                let target = Target(path: path, title: title)
                let titleKey = title.trimmingCharacters(in: .whitespaces).lowercased()
                if !titleKey.isEmpty, resolve[titleKey] == nil { resolve[titleKey] = target }
                let fileKey = file.replacingOccurrences(of: ".md", with: "").lowercased()
                if resolve[fileKey] == nil { resolve[fileKey] = target }
                docs.append((path, title, dir, bodyOf(raw)))
            }
        }
        // Pass 2: scan bodies for [[token]] → backlinks.
        var backlinks: [String: [Backlink]] = [:]
        for doc in docs {
            for token in wikilinks(in: doc.body) {
                guard let t = resolve[token.lowercased()] else { continue }
                guard t.path != doc.path else { continue }   // ignore self-links
                let bl = Backlink(fromPath: doc.path, fromTitle: doc.title, fromType: doc.type)
                if !(backlinks[t.path]?.contains(bl) ?? false) { backlinks[t.path, default: []].append(bl) }
            }
        }
        return Graph(resolve: resolve, backlinks: backlinks)
    }

    /// `[[token]]` occurrences in a body, skipping fenced code blocks.
    static func wikilinks(in body: String) -> [String] {
        var tokens: [String] = []
        var inFence = false
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let ns = line as NSString
            for m in wikiRE.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                tokens.append(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces))
            }
        }
        return tokens
    }

    /// Body markdown after the leading `--- … ---` frontmatter (exact-fence rule).
    private static func bodyOf(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              lines[..<open].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return s }
        return lines[(close + 1)...].joined(separator: "\n")
    }
}
