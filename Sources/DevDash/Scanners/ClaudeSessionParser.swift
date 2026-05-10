import Foundation

/// Parses ~/.claude/projects/<dir>/<sessionId>.jsonl into structured data.
/// Cheap digests (counts, files, commands, tokens) are cached to disk;
/// full transcripts are parsed on demand for the detail view.
enum ClaudeSessionParser {

    // MARK: - Cache layout

    private static let cacheDirName = ".devdash/sessions"

    private static func cacheFile(for sessionId: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(cacheDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sessionId).json")
    }

    /// Returns a cached digest if its parsedAt is at or after the JSONL mtime.
    static func cachedDigest(sessionId: String, jsonlPath: String) -> SessionDigest? {
        let cache = cacheFile(for: sessionId)
        guard let data = try? Data(contentsOf: cache),
              let digest = try? JSONDecoder.iso.decode(SessionDigest.self, from: data) else {
            return nil
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
              let mtime = attrs[.modificationDate] as? Date else {
            return digest
        }
        return digest.parsedAt >= mtime ? digest : nil
    }

    static func writeCache(_ digest: SessionDigest) {
        let url = cacheFile(for: digest.id)
        if let data = try? JSONEncoder.iso.encode(digest) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Digest parsing (single pass, line-by-line)

    static func parseDigest(jsonlPath: String, sessionId: String, projectPath: String, projectName: String) -> SessionDigest? {
        guard let stream = LineReader(path: jsonlPath) else { return nil }
        defer { stream.close() }

        var startedAt: Date?
        var endedAt: Date?
        var title: String?
        var firstUserMsg: String?
        var userCount = 0
        var assistantCount = 0
        var toolCalls: [String: Int] = [:]
        var fileTouches: [String: (reads: Int, writes: Int)] = [:]
        var commands: [SessionDigest.CommandRun] = []
        var tokens = SessionDigest.TokenUsage()

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String?) -> Date? {
            guard let s = s else { return nil }
            return iso.date(from: s) ?? isoNoFrac.date(from: s)
        }

        while let line = stream.nextLine() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = json["type"] as? String

            if let ts = parseDate(json["timestamp"] as? String) {
                if startedAt == nil { startedAt = ts }
                endedAt = ts
            }

            switch type {
            case "ai-title":
                if let t = json["aiTitle"] as? String, !t.isEmpty { title = t }

            case "user":
                userCount += 1
                if firstUserMsg == nil, let msg = json["message"] as? [String: Any] {
                    firstUserMsg = extractUserText(msg)
                }
                // User messages may carry tool_result blocks (replies to assistant tool_use)
                if let msg = json["message"] as? [String: Any],
                   let content = msg["content"] as? [[String: Any]] {
                    // Tool results don't change file/command counts here; counted via assistant tool_use
                    _ = content
                }

            case "assistant":
                assistantCount += 1
                guard let msg = json["message"] as? [String: Any] else { continue }
                if let usage = msg["usage"] as? [String: Any] {
                    tokens.input += (usage["input_tokens"] as? Int) ?? 0
                    tokens.output += (usage["output_tokens"] as? Int) ?? 0
                    tokens.cacheCreate += (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    tokens.cacheRead += (usage["cache_read_input_tokens"] as? Int) ?? 0
                }
                if let content = msg["content"] as? [[String: Any]] {
                    for blk in content {
                        guard (blk["type"] as? String) == "tool_use" else { continue }
                        let name = (blk["name"] as? String) ?? "?"
                        toolCalls[name, default: 0] += 1
                        let input = (blk["input"] as? [String: Any]) ?? [:]
                        switch name {
                        case "Read", "NotebookRead":
                            if let p = input["file_path"] as? String {
                                var t = fileTouches[p] ?? (0, 0)
                                t.reads += 1
                                fileTouches[p] = t
                            }
                        case "Write", "Edit", "NotebookEdit":
                            if let p = input["file_path"] as? String {
                                var t = fileTouches[p] ?? (0, 0)
                                t.writes += 1
                                fileTouches[p] = t
                            }
                        case "Bash":
                            if let cmd = input["command"] as? String {
                                commands.append(.init(command: cmd, timestamp: parseDate(json["timestamp"] as? String)))
                            }
                        default:
                            break
                        }
                    }
                }

            default:
                break
            }
        }

        let duration: Int = {
            guard let s = startedAt, let e = endedAt else { return 0 }
            return max(0, Int(e.timeIntervalSince(s)))
        }()

        let files = fileTouches
            .map { SessionDigest.FileTouch(path: $0.key, reads: $0.value.reads, writes: $0.value.writes) }
            .sorted { $0.total > $1.total }

        return SessionDigest(
            id: sessionId,
            projectPath: projectPath,
            projectName: projectName,
            title: title,
            firstUserMessage: firstUserMsg,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            userMessageCount: userCount,
            assistantMessageCount: assistantCount,
            toolCallsByName: toolCalls,
            filesTouched: files,
            commandsRun: commands,
            tokens: tokens,
            parsedAt: Date()
        )
    }

    // MARK: - Transcript parsing (full, on demand)

    static func parseTranscript(jsonlPath: String, sessionId: String, projectPath: String, projectName: String) -> SessionTranscript? {
        guard let stream = LineReader(path: jsonlPath) else { return nil }
        defer { stream.close() }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String?) -> Date? {
            guard let s = s else { return nil }
            return iso.date(from: s) ?? isoNoFrac.date(from: s)
        }

        var turns: [SessionTranscript.Turn] = []

        while let line = stream.nextLine() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = (json["type"] as? String) ?? ""
            let uuid = (json["uuid"] as? String) ?? UUID().uuidString
            let ts = parseDate(json["timestamp"] as? String)

            switch type {
            case "user":
                guard let msg = json["message"] as? [String: Any] else { continue }
                let blocks = userBlocks(from: msg)
                if blocks.isEmpty { continue }
                turns.append(.init(id: uuid, role: .user, timestamp: ts, blocks: blocks, tokens: nil))

            case "assistant":
                guard let msg = json["message"] as? [String: Any] else { continue }
                let blocks = assistantBlocks(from: msg)
                let usage = msg["usage"] as? [String: Any]
                let tokens: SessionDigest.TokenUsage? = usage.map {
                    SessionDigest.TokenUsage(
                        input: ($0["input_tokens"] as? Int) ?? 0,
                        output: ($0["output_tokens"] as? Int) ?? 0,
                        cacheCreate: ($0["cache_creation_input_tokens"] as? Int) ?? 0,
                        cacheRead: ($0["cache_read_input_tokens"] as? Int) ?? 0
                    )
                }
                turns.append(.init(id: uuid, role: .assistant, timestamp: ts, blocks: blocks, tokens: tokens))

            case "attachment":
                if let att = json["attachment"] as? [String: Any] {
                    let name = (att["hookName"] as? String) ?? (att["type"] as? String) ?? "attachment"
                    let content = (att["content"] as? String) ?? ""
                    if !content.isEmpty {
                        turns.append(.init(
                            id: uuid, role: .attachment, timestamp: ts,
                            blocks: [.attachment(name: name, content: content)],
                            tokens: nil
                        ))
                    }
                }

            default:
                continue
            }
        }

        return SessionTranscript(id: sessionId, projectPath: projectPath, projectName: projectName, turns: turns)
    }

    // MARK: - Helpers

    private static func extractUserText(_ msg: [String: Any]) -> String? {
        if let s = msg["content"] as? String { return s }
        if let arr = msg["content"] as? [[String: Any]] {
            for blk in arr {
                if (blk["type"] as? String) == "text", let t = blk["text"] as? String {
                    return t
                }
            }
        }
        return nil
    }

    private static func userBlocks(from msg: [String: Any]) -> [SessionTranscript.Block] {
        if let s = msg["content"] as? String, !s.isEmpty {
            return [.text(s)]
        }
        guard let arr = msg["content"] as? [[String: Any]] else { return [] }
        var out: [SessionTranscript.Block] = []
        for blk in arr {
            switch blk["type"] as? String {
            case "text":
                if let t = blk["text"] as? String, !t.isEmpty { out.append(.text(t)) }
            case "tool_result":
                let isErr = (blk["is_error"] as? Bool) ?? false
                let text: String = {
                    if let s = blk["content"] as? String { return s }
                    if let arr = blk["content"] as? [[String: Any]] {
                        return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    }
                    return ""
                }()
                if !text.isEmpty { out.append(.toolResult(text: text, isError: isErr)) }
            default:
                break
            }
        }
        return out
    }

    private static func assistantBlocks(from msg: [String: Any]) -> [SessionTranscript.Block] {
        guard let arr = msg["content"] as? [[String: Any]] else { return [] }
        var out: [SessionTranscript.Block] = []
        for blk in arr {
            switch blk["type"] as? String {
            case "text":
                if let t = blk["text"] as? String, !t.isEmpty { out.append(.text(t)) }
            case "thinking":
                if let t = blk["thinking"] as? String, !t.isEmpty { out.append(.thinking(t)) }
            case "tool_use":
                let name = (blk["name"] as? String) ?? "?"
                let input = (blk["input"] as? [String: Any]) ?? [:]
                let summary = inputSummary(name: name, input: input)
                let pretty = (try? JSONSerialization.data(
                    withJSONObject: input, options: [.prettyPrinted, .sortedKeys]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                out.append(.toolUse(name: name, summary: summary, fullInput: pretty))
            default:
                break
            }
        }
        return out
    }

    private static func inputSummary(name: String, input: [String: Any]) -> String {
        switch name {
        case "Read", "Write", "Edit", "NotebookEdit", "NotebookRead":
            return (input["file_path"] as? String) ?? ""
        case "Bash":
            return (input["command"] as? String) ?? ""
        case "Grep":
            let p = (input["pattern"] as? String) ?? ""
            let path = (input["path"] as? String).map { " in \($0)" } ?? ""
            return "\(p)\(path)"
        case "Glob":
            return (input["pattern"] as? String) ?? ""
        case "WebFetch":
            return (input["url"] as? String) ?? ""
        case "WebSearch":
            return (input["query"] as? String) ?? ""
        case "Task":
            return (input["description"] as? String) ?? ""
        default:
            // Fallback: first string value
            return input.values.compactMap { $0 as? String }.first ?? ""
        }
    }
}

/// Streaming line reader so we don't load multi-MB JSONLs into memory.
private final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private let chunkSize = 64 * 1024

    init?(path: String) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = h
    }

    func close() { try? handle.close() }

    func nextLine() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: nl)
                buffer.removeSubrange(0...nl)
                return String(data: lineData, encoding: .utf8)
            }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let s = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                return s
            }
            buffer.append(chunk)
        }
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
