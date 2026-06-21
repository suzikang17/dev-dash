import Foundation

/// The lore knowledge-graph layer: resolves `[[wikilinks]]` and computes backlinks
/// across every lore doc type in a project (the lore CLI doesn't expose its own
/// graph). Tokens are a doc's title or filename base (lowercased); links live in
/// markdown bodies as `[[token]]`.
///
/// Backlink sources are: (a) body `[[wikilinks]]` (like lore-core), and (b) the
/// `parent` frontmatter key specifically (task→parent). This is NOT the full
/// schema-driven `reference`-field walk lore-core does — dev-dash has no
/// `type: reference` fields, and `parent` is the only reference edge it needs.
enum LoreLinkIndex {
    struct Target: Hashable { let path: String; let title: String }   // path = "dir/file.md"
    struct Backlink: Hashable {
        let fromPath: String; let fromTitle: String; let fromType: String
        let via: String   // "body" (a [[wikilink]]) or "parent" (a reference field)
    }

    struct Graph {
        /// lowercased token (title or filename base) → target
        let resolve: [String: Target]
        /// target path → docs that reference it
        let backlinks: [String: [Backlink]]
    }

    private static let wikiRE = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)
    private static let inlineCodeRE = try! NSRegularExpression(pattern: #"`[^`]*`"#)

    /// Every lore doc dir that participates in the graph: the living-doc sections
    /// PLUS `tasks` (which render in LoreTasksView, not a LoreSection). Use this
    /// everywhere the graph is built so links/backlinks span every surface.
    static var allDirs: [String] { LoreSection.all.map(\.dir) + ["tasks"] }

    /// Build the graph for a project over the given lore section dirs.
    static func build(projectPath: String, dirs: [String]) -> Graph {
        let fm = FileManager.default
        // Pass 1: gather every doc → (path, title, body, parent) + the token index
        // + a per-dir id index (for resolving reference fields like task `parent`).
        var docs: [(path: String, title: String, type: String, body: String, parent: String?)] = []
        var resolve: [String: Target] = [:]
        var idIndex: [String: [String: String]] = [:]   // dir → numeric id → path
        for dir in dirs {
            let dirPath = "\(projectPath)/docs/\(dir)"
            // Sort so "first wins" on a title/filename collision is deterministic
            // (matches lore-core, which indexes a sorted doc list).
            for file in ((try? fm.contentsOfDirectory(atPath: dirPath)) ?? []).sorted() {
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
                // Normalize the numeric id (0001 and 1 both → "1") so a hand-typed
                // `parent: 1` resolves to `0001-*.md`. First-wins, like `resolve`.
                if let n = Int(file.prefix(while: { $0.isNumber })),
                   idIndex[dir, default: [:]][String(n)] == nil {
                    idIndex[dir, default: [:]][String(n)] = path
                }
                docs.append((path, title, dir, bodyOf(raw), front["parent"]))
            }
        }
        // Pass 2: scan bodies for [[token]] → backlinks. De-dup (target, source)
        // in O(1) so multiple links from one doc count once.
        var backlinks: [String: [Backlink]] = [:]
        var seen = Set<String>()
        func add(target: String, from doc: (path: String, title: String, type: String, body: String, parent: String?), via: String) {
            // De-dup per (target, source) regardless of via: a source lists once.
            guard target != doc.path, seen.insert("\(target)|\(doc.path)").inserted else { return }
            backlinks[target, default: []].append(
                Backlink(fromPath: doc.path, fromTitle: doc.title, fromType: doc.type, via: via))
        }
        for doc in docs {
            for token in wikilinks(in: doc.body) {
                if let t = resolve[token.lowercased()] { add(target: t.path, from: doc, via: "body") }
            }
        }
        // Pass 3: reference-frontmatter backlinks (task `parent: 0003` → the parent
        // task), resolving the normalized numeric id within the doc's own type.
        for doc in docs {
            guard let parent = doc.parent,
                  let n = Int(parent.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })),
                  let parentPath = idIndex[doc.type]?[String(n)] else { continue }
            add(target: parentPath, from: doc, via: "parent")
        }
        return Graph(resolve: resolve, backlinks: backlinks)
    }

    /// Every lore doc (title + dir) — backs the `[[` autocomplete.
    static func allDocs(projectPath: String, dirs: [String]) -> [(title: String, dir: String, path: String)] {
        let fm = FileManager.default
        var out: [(title: String, dir: String, path: String)] = []
        for dir in dirs {
            let dirPath = "\(projectPath)/docs/\(dir)"
            for file in ((try? fm.contentsOfDirectory(atPath: dirPath)) ?? []).sorted() {
                guard file.hasSuffix(".md"), file.lowercased() != "index.md" else { continue }
                guard let raw = try? String(contentsOfFile: "\(dirPath)/\(file)", encoding: .utf8) else { continue }
                let title = LoreReader.parseFrontmatter(raw)["title"] ?? file.replacingOccurrences(of: ".md", with: "")
                out.append((title: title, dir: dir, path: "\(dir)/\(file)"))
            }
        }
        return out
    }

    /// `[[token]]` occurrences in a body, skipping fenced AND inline code so the
    /// graph matches what the renderer linkifies (literal `[[x]]` in code stays literal).
    static func wikilinks(in body: String) -> [String] {
        var tokens: [String] = []
        var inFence = false
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            // Blank out inline `code` spans before matching.
            let stripped = inlineCodeRE.stringByReplacingMatches(
                in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: " ")
            let ns = stripped as NSString
            for m in wikiRE.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
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
