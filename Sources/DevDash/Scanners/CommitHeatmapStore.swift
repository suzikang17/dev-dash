import Foundation

/// Builds GitHub-style daily commit-count buckets for a project.
enum CommitHeatmapStore {
    struct Heatmap: Equatable {
        /// `dayCounts[i]` is the count for `today - (totalDays - 1 - i)`.
        let dayCounts: [Int]
        let totalDays: Int
        let totalCommits: Int
    }

    /// Build a heatmap for the last `weeks` weeks (default 12 = ~84 days).
    static func build(projectPath: String, weeks: Int = 12) async -> Heatmap? {
        let totalDays = weeks * 7
        guard FileManager.default.fileExists(atPath: "\(projectPath)/.git") else { return nil }

        let raw = await ShellRunner.run(
            "/usr/bin/git",
            args: ["log", "--since=\(totalDays).days", "--format=%cs", "--no-merges"],
            cwd: projectPath,
            timeout: 4
        ) ?? ""

        var counts: [String: Int] = [:]
        for line in raw.split(separator: "\n") {
            let day = String(line)
            if !day.isEmpty { counts[day, default: 0] += 1 }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var bucket: [Int] = []
        var total = 0
        for i in stride(from: totalDays - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -i, to: today) else {
                bucket.append(0); continue
            }
            let key = formatter.string(from: day)
            let count = counts[key] ?? 0
            bucket.append(count)
            total += count
        }

        return Heatmap(dayCounts: bucket, totalDays: totalDays, totalCommits: total)
    }
}
