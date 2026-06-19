import Foundation

/// Reads lore docs (devlogs, decisions, …) from `docs/<type>/`. Read-only — this
/// feature projects lore into a snapshot, it never writes lore.
enum LoreReader {
    /// Parse YAML-ish `--- … ---` frontmatter into a flat string map.
    /// (Canonical home; `DailyTabView` calls this too.)
    static func parseFrontmatter(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        var fences = 0
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("---") { fences += 1; if fences == 2 { break }; continue }
            guard fences == 1, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// The most recent doc of `type` under `<projectPath>/docs/<type>/`, or nil.
    static func latest(type: String, in projectPath: String) -> LoreRef? {
        let dir = "\(projectPath)/docs/\(type)"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

        var best: (dateStr: String, file: String, ref: LoreRef)?
        for file in files {
            guard file.hasSuffix(".md"), file.lowercased() != "index.md" else { continue }
            guard let content = try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)
            else { continue }
            let front = parseFrontmatter(content)

            // Accept a date prefix only if it actually parses as yyyy-MM-dd, so a
            // malformed value (e.g. "9999-99-99") can't out-sort real dates and
            // then render undated. The same parsed date feeds LoreRef so the
            // selection key and the rendered date can never diverge.
            var dateStr = ""
            if let raw = front["created"] ?? front["date"], raw.count >= 10,
               dateFormatter.date(from: String(raw.prefix(10))) != nil {
                dateStr = String(raw.prefix(10))
            } else if file.count >= 10, dateFormatter.date(from: String(file.prefix(10))) != nil {
                dateStr = String(file.prefix(10))
            }

            let title = front["title"] ?? file.replacingOccurrences(of: ".md", with: "")
            let ref = LoreRef(title: title, date: dateFormatter.date(from: dateStr))
            // Total, deterministic order: by date prefix (chronological for
            // yyyy-MM-dd, "" sorts first), then filename as a stable tiebreak so
            // same-date docs don't depend on directory iteration order.
            if best == nil || (dateStr, file) > (best!.dateStr, best!.file) {
                best = (dateStr, file, ref)
            }
        }
        return best?.ref
    }
}
