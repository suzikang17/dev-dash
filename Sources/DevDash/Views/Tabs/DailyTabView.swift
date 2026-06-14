import SwiftUI

struct DailyTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var loreEntries: [DailyLoreEntry] = []
    @State private var claudeSessions: [SessionDigest] = []

    private var project: Project? { store.project(for: store.selection) }

    var body: some View {
        if let project = project {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Text(Date().formatted(date: .complete, time: .omitted))
                        .font(.title2.bold())
                        .padding(.bottom, 4)

                    if !claudeSessions.isEmpty {
                        DailySectionView(title: "Claude Sessions") {
                            ForEach(claudeSessions) { session in
                                DailyRow(
                                    label: session.title ?? session.firstUserMessage ?? "Session",
                                    detail: session.durationSeconds > 0
                                        ? formatDuration(session.durationSeconds) : nil
                                )
                            }
                        }
                    }

                    let grouped = Dictionary(grouping: loreEntries, by: \.loreType)
                    ForEach(grouped.keys.sorted(), id: \.self) { type in
                        DailySectionView(title: type.capitalized) {
                            ForEach(grouped[type] ?? []) { entry in
                                DailyRow(label: entry.title, detail: nil)
                            }
                        }
                    }

                    if loreEntries.isEmpty && claudeSessions.isEmpty {
                        Text("Nothing yet today.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                }
                .padding()
            }
            .onAppear { reload(project: project) }
            .onChange(of: project.path) { _, _ in reload(project: project) }
        } else {
            ContentUnavailableView("No project selected", systemImage: "calendar.day.timeline.left")
        }
    }

    private func reload(project: Project) {
        let todayStr = Self.todayStr
        let docsRoot = "\(project.path)/docs"
        let fmgr = FileManager.default

        // Scan lore docs created today
        var found: [DailyLoreEntry] = []
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
                    guard let created = fm["created"], created.hasPrefix(todayStr) else { continue }
                    found.append(DailyLoreEntry(
                        loreType: fm["lore_type"] ?? dirName,
                        title: fm["title"] ?? file.replacingOccurrences(of: ".md", with: ""),
                        file: file
                    ))
                }
            }
        }
        loreEntries = found

        // Claude sessions started today for this project
        claudeSessions = store.sessionDigests.values
            .filter { d in
                guard d.projectPath == project.path || d.projectPath.hasPrefix("\(project.path)/"),
                      let start = d.startedAt else { return false }
                return Self.dayFormatter.string(from: start) == todayStr
            }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    private func formatDuration(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }

    private static let todayStr: String = dayFormatter.string(from: Date())

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
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
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
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
                .fill(Color.secondary.opacity(0.4))
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

// Minimal YAML frontmatter parser — handles simple `key: value` lines only.
private func parseMdFrontmatter(_ content: String) -> [String: String] {
    var result: [String: String] = [:]
    var fences = 0
    for line in content.components(separatedBy: "\n") {
        if line.hasPrefix("---") { fences += 1; if fences == 2 { break }; continue }
        guard fences == 1, let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // Strip optional surrounding quotes
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        if !key.isEmpty { result[key] = value }
    }
    return result
}
