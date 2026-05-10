import Foundation

/// Persists the most-recent HealthRunResult per check at
/// `.devdash/health.json`. Keyed by checkId.
enum HealthStore {
    static func file(for projectPath: String) -> String {
        "\(projectPath)/.devdash/health.json"
    }

    static func read(_ projectPath: String) -> [String: HealthRunResult] {
        let path = file(for: projectPath)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? decoder.decode([String: HealthRunResult].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func write(_ projectPath: String, results: [String: HealthRunResult]) throws {
        let dir = "\(projectPath)/.devdash"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(results)
        try data.write(to: URL(fileURLWithPath: file(for: projectPath)), options: .atomic)
    }

    static func record(_ result: HealthRunResult, for projectPath: String) throws {
        var current = read(projectPath)
        current[result.checkId] = result
        try write(projectPath, results: current)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
