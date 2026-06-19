import Foundation

enum LoreRunner {

    // MARK: - Claude binary

    static func claudePath() async -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            NSHomeDirectory() + "/.npm/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        if let found = await ShellRunner.run("/usr/bin/which", args: ["claude"]) {
            let t = found.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    // MARK: - lore binary

    /// Locate the `lore` CLI, mirroring `claudePath()`.
    static func lorePath() async -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/lore",
            "/usr/local/bin/lore",
            "/opt/homebrew/bin/lore",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        if let found = await ShellRunner.run("/usr/bin/which", args: ["lore"]) {
            let t = found.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// Whether lore has been initialized for a project (the `docs/.lore` marker dir exists).
    static func isInitialized(projectPath: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: "\(projectPath)/docs/.lore", isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Run `lore init docs` from the project root. Returns true if lore is initialized afterward.
    static func runInit(projectPath: String) async -> (ok: Bool, output: String?) {
        guard let lore = await lorePath() else { return (false, nil) }
        let out = await ShellRunner.run(lore, args: ["init", "docs"], cwd: projectPath, timeout: 60)
        return (isInitialized(projectPath: projectPath), out)
    }

    // MARK: - Schema prompt

    /// Extract the `prompt: |` block from a .lore/types/<type>.schema.yaml file.
    static func schemaPrompt(type: String, projectPath: String) -> String? {
        let path = "\(projectPath)/docs/.lore/types/\(type).schema.yaml"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\n")
        var inPrompt = false
        var parts: [String] = []
        for line in lines {
            if line.hasPrefix("prompt:") { inPrompt = true; continue }
            if inPrompt {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    parts.append(line.trimmingCharacters(in: .whitespaces))
                } else if line.isEmpty {
                    parts.append("")
                } else {
                    break
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Generation

    /// Call `claude -p "<systemPrompt>\n\n<userMessage>"` and return the response.
    static func generate(
        systemPrompt: String,
        userMessage: String,
        projectPath: String,
        timeout: Double = 120
    ) async -> String? {
        guard let claude = await claudePath() else { return nil }
        let combined = "\(systemPrompt)\n\n\(userMessage)"
        return await ShellRunner.run(claude, args: ["-p", combined], cwd: projectPath, timeout: timeout)
    }

    // MARK: - File helpers

    /// Next sequential numeric ID for files in a directory (zero-padded to `pad` digits).
    static func nextId(in dir: String, pad: Int = 4) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let max = files.compactMap { f -> Int? in
            guard f.hasSuffix(".md"), f != "index.md", f != "INDEX.md" else { return nil }
            return Int(f.prefix(pad))
        }.max() ?? 0
        return String(format: "%0\(pad)d", max + 1)
    }

    /// Simple slug from a title — lowercase, words joined with hyphens, max 55 chars.
    static func slug(from title: String) -> String {
        let slug = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return String(slug.prefix(55)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Frontmatter (shared with LoreTasksView)

    static func parseFM(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        guard raw.hasPrefix("---") else { return result }
        let lines = raw.components(separatedBy: "\n")
        var fences = 0; var i = 0
        while i < lines.count {
            let line = lines[i]; i += 1
            if line.hasPrefix("---") { fences += 1; if fences == 2 { break }; continue }
            guard fences == 1, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value == ">-" || value == ">" || value == "|-" || value == "|" {
                let fold = value.hasPrefix(">")
                var parts: [String] = []
                while i < lines.count {
                    let next = lines[i]
                    if next.hasPrefix("---") { break }
                    if next.hasPrefix(" ") || next.hasPrefix("\t") { parts.append(next.trimmingCharacters(in: .whitespaces)); i += 1 }
                    else if next.isEmpty { i += 1 } else { break }
                }
                value = fold ? parts.joined(separator: " ") : parts.joined(separator: "\n")
            } else if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
