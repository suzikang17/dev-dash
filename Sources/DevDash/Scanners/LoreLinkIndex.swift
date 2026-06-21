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
    private static let inlineCodeRE = try! NSRegularExpression(pattern: #"`[^`]*`"#)

    /// Build the graph for a project over the given lore section dirs.
    static func build(projectPath: String, dirs: [String]) -> Graph {
        let fm = FileManager.default
        // Pass 1: gather every doc → (path, title, body) and the token index.
        var docs: [(path: String, title: String, type: String, body: String)] = []
        var resolve: [String: Target] = [:]
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
                docs.append((path, title, dir, bodyOf(raw)))
            }
        }
        // Pass 2: scan bodies for [[token]] → backlinks. De-dup (target, source)
        // in O(1) so multiple links from one doc count once.
        var backlinks: [String: [Backlink]] = [:]
        var seen = Set<String>()
        for doc in docs {
            for token in wikilinks(in: doc.body) {
                guard let t = resolve[token.lowercased()], t.path != doc.path else { continue }
                if seen.insert("\(t.path)|\(doc.path)").inserted {
                    backlinks[t.path, default: []].append(
                        Backlink(fromPath: doc.path, fromTitle: doc.title, fromType: doc.type))
                }
            }
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
