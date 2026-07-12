import Foundation

// MARK: - Models

/// One lore markdown doc, as listed in the Docs tab sidebar.
struct LoreDoc: Identifiable, Hashable {
    let path: String            // relative to docs/ — "devlog/2026-07-04-foo.md"
    let dir: String             // plural folder — "devlog", "decisions", …
    let title: String
    let date: String?           // raw YYYY-MM-DD (frontmatter `date` ?? `created`)
    let status: String?
    let front: [String: String] // full frontmatter (chips in the reading header)

    var id: String { path }

    /// Numeric id prefix of the filename ("0004-foo.md" → "0004"), if any.
    var numericID: String? {
        let base = (path as NSString).lastPathComponent
        let digits = base.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : String(digits)
    }
}

/// A doc type (folder) and its docs, newest first.
struct LoreDocGroup: Identifiable, Hashable {
    let dir: String
    let label: String
    let docs: [LoreDoc]
    var id: String { dir }
}

// MARK: - Scanner

/// Enumerates every lore doc folder under `<project>/docs/` for the Docs tab.
/// Generic on purpose: any `docs/<dir>/*.md` participates (skipping `index.md`
/// and dot-dirs), so repos with custom lore types show up without code changes.
enum LoreDocsScanner {

    /// Display labels for the known dirs (matches LoreSection where one exists;
    /// unknown dirs fall back to a capitalized folder name).
    private static let labels: [String: String] = [
        "devlog": "Devlog", "decisions": "Decisions", "tickets": "Tickets",
        "tasks": "Tasks", "policies": "Policies", "ideas": "Ideas",
        "notes": "Knowledge", "artifacts": "Artifacts", "kpis": "KPIs",
        "overview": "Overview",
    ]

    /// Sidebar ordering — narrative types first, plumbing last; unknown dirs
    /// after the known ones, alphabetically.
    private static let order: [String] = [
        "devlog", "decisions", "tickets", "tasks", "policies",
        "ideas", "notes", "artifacts", "kpis", "overview",
    ]

    static func label(for dir: String) -> String {
        if let l = labels[dir] { return l }
        // Nested section dirs ("self/goals-2026") read as "Self · Goals-2026".
        return dir.components(separatedBy: "/")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " · ")
    }

    /// Where a project's lore docs live. Project-profile repos nest them under
    /// `docs/`; wiki-profile repos (`.lore/` at the top level — e.g. ~/dev/wiki,
    /// ~/Documents/wiki) keep the type dirs at the root itself.
    static func docsRoot(projectPath: String) -> String {
        FileManager.default.fileExists(atPath: "\(projectPath)/.lore/config.yaml")
            ? projectPath
            : projectPath + "/docs"
    }

    /// All doc groups for a project, ready for the sidebar. Blocking file I/O —
    /// call off the main actor.
    static func scan(projectPath: String) -> [LoreDocGroup] {
        let fm = FileManager.default
        let docsPath = docsRoot(projectPath: projectPath)
        guard let entries = try? fm.contentsOfDirectory(atPath: docsPath) else { return [] }
        var groups: [LoreDocGroup] = []
        for dir in entries {
            guard !dir.hasPrefix(".") else { continue }
            var isDir: ObjCBool = false
            let dirPath = "\(docsPath)/\(dir)"
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            var docs: [LoreDoc] = collectDocs(dirPath: dirPath, dir: dir)
            if docs.isEmpty {
                // A section dir (e.g. self/) holding subdirs of docs: emit each
                // subdir as its own group, one level deep only.
                for sub in ((try? fm.contentsOfDirectory(atPath: dirPath)) ?? []).sorted() {
                    guard !sub.hasPrefix(".") else { continue }
                    var subIsDir: ObjCBool = false
                    let subPath = "\(dirPath)/\(sub)"
                    guard fm.fileExists(atPath: subPath, isDirectory: &subIsDir), subIsDir.boolValue else { continue }
                    var subDocs = collectDocs(dirPath: subPath, dir: "\(dir)/\(sub)")
                    guard !subDocs.isEmpty else { continue }
                    subDocs.sort {
                        let (a, b) = ($0.date ?? "", $1.date ?? "")
                        return a == b ? $0.path > $1.path : a > b
                    }
                    groups.append(LoreDocGroup(dir: "\(dir)/\(sub)", label: label(for: "\(dir)/\(sub)"), docs: subDocs))
                }
                continue
            }
            // Newest first: by date, then filename (id prefixes sort naturally).
            docs.sort {
                let (a, b) = ($0.date ?? "", $1.date ?? "")
                return a == b ? $0.path > $1.path : a > b
            }
            groups.append(LoreDocGroup(dir: dir, label: label(for: dir), docs: docs))
        }
        func rank(_ dir: String) -> Int { order.firstIndex(of: dir) ?? order.count }
        groups.sort { rank($0.dir) == rank($1.dir) ? $0.dir < $1.dir : rank($0.dir) < rank($1.dir) }
        return groups
    }

    private static func collectDocs(dirPath: String, dir: String) -> [LoreDoc] {
        let fm = FileManager.default
        var docs: [LoreDoc] = []
        for file in ((try? fm.contentsOfDirectory(atPath: dirPath)) ?? []).sorted() {
            guard file.hasSuffix(".md"), file.lowercased() != "index.md" else { continue }
            guard let raw = try? String(contentsOfFile: "\(dirPath)/\(file)", encoding: .utf8) else { continue }
            let front = LoreReader.parseFrontmatter(raw)
            docs.append(LoreDoc(
                path: "\(dir)/\(file)",
                dir: dir,
                title: front["title"] ?? file.replacingOccurrences(of: ".md", with: ""),
                date: front["date"] ?? front["created"],
                status: front["status"],
                front: front))
        }
        return docs
    }

    /// Load one doc's frontmatter + markdown body. Blocking file I/O — call off
    /// the main actor. `relPath` is relative to `docs/` (a `LoreDoc.path`).
    static func load(projectPath: String, relPath: String) -> (front: [String: String], body: String)? {
        guard let raw = try? String(contentsOfFile: "\(docsRoot(projectPath: projectPath))/\(relPath)", encoding: .utf8)
        else { return nil }
        return (LoreReader.parseFrontmatter(raw), LoreLinkIndex.bodyOf(raw))
    }
}
