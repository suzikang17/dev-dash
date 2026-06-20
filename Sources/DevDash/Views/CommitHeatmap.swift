import SwiftUI

/// Compact GitHub-style heatmap. Rows = day-of-week, columns = weeks.
/// Cells size dynamically to fill available width.
struct CommitHeatmap: View {
    let heatmap: CommitHeatmapStore.Heatmap
    var spacing: CGFloat = 2
    var cell: CGFloat = 11

    private var maxCount: Int { heatmap.dayCounts.max() ?? 0 }

    private static let tooltipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    var body: some View {
        let weeks = max(1, heatmap.totalDays / 7)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let totalDays = heatmap.totalDays

        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<weeks, id: \.self) { col in
                        let idx = col * 7 + row
                        let inRange = idx < heatmap.dayCounts.count
                        let count = inRange ? heatmap.dayCounts[idx] : 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(inRange ? color(for: count) : Color.clear)
                            .frame(width: cell, height: cell)
                            .help(inRange ? tooltip(idx: idx, count: count, today: today, totalDays: totalDays, cal: cal) : "")
                    }
                }
            }
        }
        .fixedSize()
    }

    private func tooltip(idx: Int, count: Int, today: Date, totalDays: Int, cal: Calendar) -> String {
        let offset = totalDays - 1 - idx
        guard let day = cal.date(byAdding: .day, value: -offset, to: today) else {
            return count == 0 ? "No commits" : "\(count) commit\(count == 1 ? "" : "s")"
        }
        let dateStr = Self.tooltipFormatter.string(from: day)
        if count == 0 { return "\(dateStr) — no commits" }
        return "\(dateStr) — \(count) commit\(count == 1 ? "" : "s")"
    }

    private func color(for count: Int) -> Color {
        if count == 0 { return Color.secondary.opacity(0.18) }
        guard maxCount > 0 else { return DSColor.success.opacity(0.3) }
        let ratio = Double(count) / Double(maxCount)
        if ratio < 0.25 { return DSColor.success.opacity(0.32) }
        if ratio < 0.5  { return DSColor.success.opacity(0.55) }
        if ratio < 0.75 { return DSColor.success.opacity(0.78) }
        return DSColor.success.opacity(0.95)
    }
}
