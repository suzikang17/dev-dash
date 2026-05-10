import Foundation

/// Per-project provider store at `.devdash/providers.json`. The stored list
/// is the source of truth — auto-detection only adds providers that aren't
/// already there (by name), never overwrites user-edited fields.
enum ProviderStore {
    static func file(for projectPath: String) -> String {
        "\(projectPath)/.devdash/providers.json"
    }

    static func read(_ projectPath: String) -> [Provider] {
        let path = file(for: projectPath)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let providers = try? decoder.decode([Provider].self, from: data) else {
            return []
        }
        return providers
    }

    static func write(_ projectPath: String, providers: [Provider]) throws {
        let dir = "\(projectPath)/.devdash"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(providers)
        try data.write(to: URL(fileURLWithPath: file(for: projectPath)), options: .atomic)
    }

    /// Run detection and merge with stored providers. Existing entries
    /// (matched by name, case-insensitive) are kept untouched so user edits
    /// to monthly cost / notes / URL persist across rescans.
    @discardableResult
    static func refresh(_ projectPath: String) -> [Provider] {
        let stored = read(projectPath)
        let detected = ProviderDetector.detect(in: projectPath)

        let storedNames = Set(stored.map { $0.name.lowercased() })
        let newOnes = detected.filter { !storedNames.contains($0.name.lowercased()) }

        let merged = stored + newOnes
        if !newOnes.isEmpty {
            try? write(projectPath, providers: merged)
        }
        return merged
    }

    static func add(
        projectPath: String,
        name: String,
        category: ProviderCategory,
        dashboardURL: URL? = nil,
        monthlyEstimateUSD: Double? = nil,
        notes: String? = nil
    ) throws -> Provider {
        var providers = read(projectPath)
        let provider = Provider(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            detectedFrom: .manual,
            dashboardURL: dashboardURL,
            monthlyEstimateUSD: monthlyEstimateUSD,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            addedAt: Date()
        )
        providers.append(provider)
        try write(projectPath, providers: providers)
        return provider
    }

    static func update(_ projectPath: String, _ updated: Provider) throws {
        var providers = read(projectPath)
        guard let idx = providers.firstIndex(where: { $0.id == updated.id }) else { return }
        providers[idx] = updated
        try write(projectPath, providers: providers)
    }

    static func delete(_ projectPath: String, id: String) throws {
        let providers = read(projectPath).filter { $0.id != id }
        try write(projectPath, providers: providers)
    }

    /// Sum of monthlyEstimateUSD across all providers; nil if none have a value.
    static func totalMonthlyCost(_ providers: [Provider]) -> Double? {
        let costs = providers.compactMap { $0.monthlyEstimateUSD }
        return costs.isEmpty ? nil : costs.reduce(0, +)
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
