import Foundation

enum SessionScanner {
    static let claudeProjectsDir = "\(NSHomeDirectory())/.claude/projects"

    static func scan(limit: Int = 200) async -> [ClaudeSession] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: claudeProjectsDir) else { return [] }

        // Step 1 (cheap): enumerate every .jsonl file across every project,
        // collect (path, mtime). One stat call per file, no parsing.
        struct FileEntry {
            let dirName: String
            let projectPath: String
            let projectName: String
            let fileName: String
            let fullPath: String
            let mtime: Date
        }

        var allFiles: [FileEntry] = []
        for dir in dirs {
            let dirPath = "\(claudeProjectsDir)/\(dir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            let projectPath = decodeProjectDir(dir)
            let projectName = URL(fileURLWithPath: projectPath).lastPathComponent

            for f in files where f.hasSuffix(".jsonl") {
                let full = "\(dirPath)/\(f)"
                guard let attrs = try? fm.attributesOfItem(atPath: full),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                allFiles.append(FileEntry(
                    dirName: dir,
                    projectPath: projectPath,
                    projectName: projectName,
                    fileName: f,
                    fullPath: full,
                    mtime: mtime
                ))
            }
        }

        // Step 2: globally sort by mtime, then only read meta for the top `limit`
        // most recent. Reading meta is the expensive part (32KB per file).
        let topFiles = allFiles
            .sorted { $0.mtime > $1.mtime }
            .prefix(limit)

        let sessions = await withTaskGroup(of: ClaudeSession?.self) { group -> [ClaudeSession] in
            for entry in topFiles {
                group.addTask {
                    let sessionId = String(entry.fileName.dropLast(6))
                    let meta = readMeta(file: entry.fullPath)
                    return ClaudeSession(
                        id: sessionId,
                        projectName: entry.projectName,
                        projectPath: entry.projectPath,
                        lastActivity: meta.last ?? entry.mtime,
                        messageCount: meta.count,
                        firstUserMessage: meta.firstUserMsg
                    )
                }
            }
            var collected: [ClaudeSession] = []
            for await s in group { if let s = s { collected.append(s) } }
            return collected
        }

        return sessions.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    static func decodeProjectDir(_ encoded: String) -> String {
        guard encoded.hasPrefix("-") else {
            return encoded.replacingOccurrences(of: "-", with: "/")
        }
        let parts = String(encoded.dropFirst()).split(separator: "-").map(String.init)
        let fm = FileManager.default

        // Prefer deeper paths first
        if parts.count >= 2 {
            for i in stride(from: parts.count, through: 2, by: -1) {
                let parent = "/" + parts.prefix(i - 1).joined(separator: "/")
                let tailEncoded = parts.suffix(parts.count - (i - 1)).joined(separator: "-")

                if let entries = try? fm.contentsOfDirectory(atPath: parent) {
                    if let match = entries.first(where: { normalize($0) == tailEncoded }) {
                        return "\(parent)/\(match)"
                    }
                }
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: "-")
    }

    // Read only first line + mtime + estimate count from file size.
    // Avoids slurping multi-MB jsonl files just to count messages.
    private static func readMeta(file: String) -> (first: Date?, last: Date?, count: Int, firstUserMsg: String?) {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: file)
        let mtime = attrs?[.modificationDate] as? Date
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        var first: Date?
        var firstUserMsg: String?

        if let handle = FileHandle(forReadingAtPath: file) {
            defer { try? handle.close() }
            // Larger head to catch the first user message, which can be after some metadata
            let head = handle.readData(ofLength: 32768)
            if let text = String(data: head, encoding: .utf8) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                for line in text.split(separator: "\n") {
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if first == nil, let ts = json["timestamp"] as? String {
                        first = formatter.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
                    }
                    if firstUserMsg == nil, (json["type"] as? String) == "user",
                       let msg = json["message"] as? [String: Any] {
                        if let str = msg["content"] as? String {
                            firstUserMsg = str
                        } else if let arr = msg["content"] as? [[String: Any]] {
                            firstUserMsg = arr.compactMap { $0["text"] as? String }.first
                        }
                    }
                    if first != nil && firstUserMsg != nil { break }
                }
            }
        }

        let count = max(1, size / 800)
        return (first, mtime, count, firstUserMsg)
    }
}
