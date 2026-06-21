import Foundation

/// File IO for a single day's note page (docs/notes/YYYY-MM-DD.md). Pure statics are
/// deterministic and selftested; `DailyPageController` (UI task) adds the debounced
/// @MainActor save wrapper on top.
enum DailyPageStore {
    static func fileURL(projectPath: String, date: String) -> URL {
        URL(fileURLWithPath: "\(projectPath)/docs/notes/\(date).md")
    }

    static func load(projectPath: String, date: String) -> [DayNode] {
        let url = fileURL(projectPath: projectPath, date: date)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return DayOutline.parse(stripFrontmatter(raw))
    }

    static func write(projectPath: String, date: String, nodes: [DayNode]) throws {
        let dir = "\(projectPath)/docs/notes"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = fileURL(projectPath: projectPath, date: date)
        let body = DayOutline.serialize(nodes)
        let frontmatter = existingFrontmatter(at: url) ?? "---\ntitle: \"\(date)\"\ncreated: \"\(date)\"\n---"
        let content = "\(frontmatter)\n\n\(body)"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func recentDates(projectPath: String, limit: Int) -> [String] {
        let dir = "\(projectPath)/docs/notes"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let re = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        var dates = Set(files.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }
            .filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil })
        dates.insert(todayString())
        return Array(dates.sorted(by: >).prefix(limit))
    }

    static func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - frontmatter

    /// The literal `---\n...\n---` block at the top of the file, or nil if none.
    private static func existingFrontmatter(at url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8), raw.hasPrefix("---") else { return nil }
        let lines = raw.components(separatedBy: "\n")
        var fences = 0, end = 0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("---") { fences += 1; if fences == 2 { end = i; break } }
        }
        guard fences == 2 else { return nil }
        return lines[0...end].joined(separator: "\n")
    }

    private static func stripFrontmatter(_ s: String) -> String {
        guard s.hasPrefix("---") else { return s }
        let lines = s.components(separatedBy: "\n")
        var fences = 0, start = 0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("---") { fences += 1; if fences == 2 { start = i + 1; break } }
        }
        return lines.dropFirst(start).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
