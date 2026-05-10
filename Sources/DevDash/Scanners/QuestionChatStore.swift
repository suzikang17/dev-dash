import Foundation
import CryptoKit

/// Per-(stage, question) chat transcripts persisted as JSONL at
/// `.devdash/question-chats/<stageId>-<questionHash>.jsonl`. JSONL keeps
/// appends cheap; we only ever read the whole file when opening the sheet.
enum QuestionChatStore {
    static func file(for projectPath: String, stageId: String, question: String) -> String {
        let dir = "\(projectPath)/.devdash/question-chats"
        let h = SHA256.hash(data: Data(question.utf8))
        let hex = h.compactMap { String(format: "%02x", $0) }.joined().prefix(12)
        let safeStage = stageId.replacingOccurrences(of: "/", with: "_")
        return "\(dir)/\(safeStage)-\(hex).jsonl"
    }

    static func read(_ projectPath: String, stageId: String, question: String) -> [QuestionChatMessage] {
        let path = file(for: projectPath, stageId: stageId, question: question)
        guard FileManager.default.fileExists(atPath: path),
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        var out: [QuestionChatMessage] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? decoder.decode(QuestionChatMessage.self, from: data) else { continue }
            out.append(msg)
        }
        return out
    }

    static func append(_ message: QuestionChatMessage, to projectPath: String, stageId: String, question: String) {
        let path = file(for: projectPath, stageId: stageId, question: question)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(message),
              let line = String(data: data, encoding: .utf8) else { return }
        let payload = line + "\n"
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                if let d = payload.data(using: .utf8) { try? handle.write(contentsOf: d) }
            }
        } else {
            try? payload.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func clear(_ projectPath: String, stageId: String, question: String) {
        let path = file(for: projectPath, stageId: stageId, question: question)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Replace the in-place content of the assistant's last message (used
    /// while streaming so we don't write a line per token).
    static func updateLastAssistant(_ projectPath: String, stageId: String, question: String, content: String, id: String) {
        let path = file(for: projectPath, stageId: stageId, question: question)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // Find last line with this id
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            guard let data = lines[i].data(using: .utf8),
                  var msg = try? decoder.decode(QuestionChatMessage.self, from: data) else { continue }
            if msg.id == id {
                msg.content = content
                if let newData = try? encoder.encode(msg),
                   let newLine = String(data: newData, encoding: .utf8) {
                    lines[i] = newLine
                }
                let combined = lines.joined(separator: "\n") + "\n"
                try? combined.write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
