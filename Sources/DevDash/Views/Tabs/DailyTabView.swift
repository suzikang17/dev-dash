import SwiftUI

struct DailyTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var days: [DayGroup] = []

    private var project: Project? { store.project(for: store.selection) }

    var body: some View {
        if let project = project {
            Group {
                if days.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28, pinnedViews: .sectionHeaders) {
                            ForEach(days) { day in
                                Section {
                                    dayContent(day)
                                } header: {
                                    dayHeader(day)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .onAppear { reload(project: project) }
            .onChange(of: project.path) { _, _ in reload(project: project) }
            .onChange(of: store.sessionDigests.count) { _, _ in reload(project: project) }
        } else {
            ContentUnavailableView("No project selected", systemImage: "calendar.day.timeline.left")
        }
    }

    @ViewBuilder
    private func dayHeader(_ day: DayGroup) -> some View {
        Text(day.isToday ? "Today · \(day.formatted)" : day.formatted)
            .font(.headline)
            .foregroundColor(day.isToday ? .primary : .secondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
    }

    @ViewBuilder
    private func dayContent(_ day: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !day.sessions.isEmpty {
                DailySectionView(title: "Claude") {
                    ForEach(day.sessions) { session in
                        DailyRow(
                            label: session.title ?? session.firstUserMessage ?? "Session",
                            detail: session.durationSeconds > 0
                                ? formatDuration(session.durationSeconds) : nil
                        )
                    }
                }
            }
            let grouped = Dictionary(grouping: day.docs, by: \.loreType)
            ForEach(grouped.keys.sorted(), id: \.self) { type in
                DailySectionView(title: type.capitalized) {
                    ForEach(grouped[type] ?? []) { entry in
                        DailyRow(label: entry.title, detail: nil)
                    }
                }
            }
        }
    }

    private func reload(project: Project) {
        let docsRoot = "\(project.path)/docs"
        let projectPath = project.path
        let digests = store.sessionDigests

        Task.detached(priority: .userInitiated) {
            // Collect all docs with a date, keyed by YYYY-MM-DD
            var docsByDate: [String: [DailyLoreEntry]] = [:]
            let fmgr = FileManager.default
            if let typeDirs = try? fmgr.contentsOfDirectory(atPath: docsRoot) {
                for dirName in typeDirs {
                    guard dirName != ".lore" else { continue }
                    let dirPath = "\(docsRoot)/\(dirName)"
                    var isDir: ObjCBool = false
                    guard fmgr.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
                    guard let files = try? fmgr.contentsOfDirectory(atPath: dirPath) else { continue }
                    for file in files {
                        guard file.hasSuffix(".md"), file.lowercased() != "index.md" else { continue }
                        guard let content = try? String(contentsOfFile: "\(dirPath)/\(file)", encoding: .utf8) else { continue }
                        let fm = parseMdFrontmatter(content)
                        // Determine date: created field first, then filename prefix
                        let dateStr: String?
                        if let created = fm["created"], created.count >= 10 {
                            dateStr = String(created.prefix(10))
                        } else if file.count >= 10, file.prefix(10).allSatisfy({ $0.isNumber || $0 == "-" }) {
                            dateStr = String(file.prefix(10))
                        } else {
                            dateStr = nil
                        }
                        guard let date = dateStr else { continue }
                        let entry = DailyLoreEntry(
                            loreType: fm["lore_type"] ?? dirName,
                            title: fm["title"] ?? file.replacingOccurrences(of: ".md", with: ""),
                            file: file
                        )
                        docsByDate[date, default: []].append(entry)
                    }
                }
            }

            // Collect sessions keyed by YYYY-MM-DD
            var sessionsByDate: [String: [SessionDigest]] = [:]
            for digest in digests.values {
                guard digest.projectPath == projectPath || digest.projectPath.hasPrefix("\(projectPath)/"),
                      let start = digest.startedAt else { continue }
                let dateStr = Self.dayFormatter.string(from: start)
                sessionsByDate[dateStr, default: []].append(digest)
            }

            // Build sorted day groups (newest first)
            let allDates = Set(docsByDate.keys).union(sessionsByDate.keys)
            let todayStr = Self.dayFormatter.string(from: Date())
            let groups = allDates.sorted(by: >).map { dateStr in
                DayGroup(
                    dateStr: dateStr,
                    isToday: dateStr == todayStr,
                    formatted: Self.formatDate(dateStr),
                    docs: (docsByDate[dateStr] ?? []).sorted { $0.title < $1.title },
                    sessions: (sessionsByDate[dateStr] ?? []).sorted {
                        ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
                    }
                )
            }

            await MainActor.run { self.days = groups }
        }
    }

    private func formatDuration(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }

    private static func formatDate(_ dateStr: String) -> String {
        guard let date = dayFormatter.date(from: dateStr) else { return dateStr }
        return date.formatted(date: .complete, time: .omitted)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

private struct DayGroup: Identifiable {
    let dateStr: String
    var id: String { dateStr }
    let isToday: Bool
    let formatted: String
    let docs: [DailyLoreEntry]
    let sessions: [SessionDigest]
}

private struct DailyLoreEntry: Identifiable {
    let id = UUID()
    let loreType: String
    let title: String
    let file: String
}

private struct DailySectionView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content
        }
    }
}

private struct DailyRow: View {
    let label: String
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private func parseMdFrontmatter(_ content: String) -> [String: String] {
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
