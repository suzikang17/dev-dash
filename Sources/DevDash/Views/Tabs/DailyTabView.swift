import SwiftUI

struct DailyTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var days: [DayGroup] = []
    @State private var allDocs: [DailyLoreEntry] = []
    @State private var selectedEntry: DailyLoreEntry?
    @State private var selectedSession: SessionDigest?
    @State private var mode: ViewMode = .daily

    private enum ViewMode { case daily, browse }

    private var project: Project? { store.project(for: store.selection) }

    var body: some View {
        if let project = project {
            HSplitView {
                timeline(project: project)
                    .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
                // always present so HSplitView keeps timeline left-pinned
                ZStack {
                    if let entry = selectedEntry {
                        NotePanel(entry: entry, onClose: { selectedEntry = nil })
                    } else if let session = selectedSession {
                        SessionPanel(digest: session, onClose: { selectedSession = nil })
                            .environmentObject(store)
                    }
                    // invisible placeholder keeps the pane alive when nothing is selected
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { reload(project: project) }
            .onChange(of: project.path) { _, _ in selectedEntry = nil; selectedSession = nil; reload(project: project) }
            .onChange(of: store.sessionDigests.count) { _, _ in reload(project: project) }
        } else {
            ContentUnavailableView("No project selected", systemImage: "calendar.day.timeline.left")
        }
    }

    @ViewBuilder
    private func timeline(project: Project) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("Daily").tag(ViewMode.daily)
                Text("Browse").tag(ViewMode.browse)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if days.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mode == .daily {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24, pinnedViews: .sectionHeaders) {
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
            } else {
                browseContent()
            }
        }
    }

    @ViewBuilder
    private func browseContent() -> some View {
        let grouped = allDocs
            .reduce(into: [String: [DailyLoreEntry]]()) { $0[$1.loreType, default: []].append($1) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(grouped.keys.sorted(), id: \.self) { type in
                    DailySectionView(title: type.capitalized) {
                        let sorted = (grouped[type] ?? []).sorted { $0.dateStr > $1.dateStr }
                        ForEach(sorted) { entry in
                            DailyRow(
                                label: entry.title,
                                detail: entry.dateStr,
                                isSelected: selectedEntry?.id == entry.id,
                                action: { selectedSession = nil; selectedEntry = entry }
                            )
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func dayHeader(_ day: DayGroup) -> some View {
        Text(day.isToday ? "Today · \(day.formatted)" : day.formatted)
            .font(.headline)
            .foregroundColor(day.isToday ? .primary : .secondary)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
    }

    @ViewBuilder
    private func dayContent(_ day: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !day.sessions.isEmpty {
                DailySectionView(title: "Claude") {
                    ForEach(day.sessions) { session in
                        DailyRow(
                            label: session.title ?? session.firstUserMessage ?? "Session",
                            detail: session.durationSeconds > 0 ? formatDuration(session.durationSeconds) : nil,
                            isSelected: selectedSession?.id == session.id,
                            action: { selectedEntry = nil; selectedSession = session }
                        )
                    }
                }
            }
            let grouped = Dictionary(grouping: day.docs, by: \.loreType)
            ForEach(grouped.keys.sorted(), id: \.self) { type in
                DailySectionView(title: type.capitalized) {
                    ForEach(grouped[type] ?? []) { entry in
                        DailyRow(
                            label: entry.title,
                            detail: nil,
                            isSelected: selectedEntry?.id == entry.id,
                            action: { selectedEntry = entry }
                        )
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
            var docsByDate: [String: [DailyLoreEntry]] = [:]
            var allDocsList: [DailyLoreEntry] = []
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
                        let filePath = "\(dirPath)/\(file)"
                        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
                        let fm = parseMdFrontmatter(content)
                        let dateStr: String?
                        let rawDate = fm["created"] ?? fm["date"]
                        if let d = rawDate, d.count >= 10 {
                            dateStr = String(d.prefix(10))
                        } else if file.count >= 10, file.prefix(10).allSatisfy({ $0.isNumber || $0 == "-" }) {
                            dateStr = String(file.prefix(10))
                        } else {
                            dateStr = nil
                        }
                        let entry = DailyLoreEntry(
                            loreType: fm["lore_type"] ?? dirName,
                            title: fm["title"] ?? file.replacingOccurrences(of: ".md", with: ""),
                            file: file,
                            path: filePath,
                            dateStr: dateStr ?? ""
                        )
                        allDocsList.append(entry)
                        if let date = dateStr {
                            docsByDate[date, default: []].append(entry)
                        }
                    }
                }
            }

            var sessionsByDate: [String: [SessionDigest]] = [:]
            for digest in digests.values {
                guard digest.projectPath == projectPath || digest.projectPath.hasPrefix("\(projectPath)/"),
                      let start = digest.startedAt else { continue }
                let dateStr = Self.dayFormatter.string(from: start)
                sessionsByDate[dateStr, default: []].append(digest)
            }

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
            await MainActor.run { self.days = groups; self.allDocs = allDocsList }
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

// MARK: - Session side panel

private struct SessionPanel: View {
    @EnvironmentObject var store: DashboardStore
    let digest: SessionDigest
    let onClose: () -> Void
    @State private var transcript: SessionTranscript?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(digest.title ?? digest.firstUserMessage ?? "Claude session")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let start = digest.startedAt {
                            Text(start.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if digest.durationSeconds > 0 {
                            Text(formatDuration(digest.durationSeconds))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text("\(digest.userMessageCount) msgs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let t = transcript {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(t.turns.filter { hasVisibleContent($0) }) { turn in
                            TurnRow(turn: turn)
                        }
                    }
                    .padding()
                }
            } else {
                ContentUnavailableView("Transcript unavailable", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 340)
        .task(id: digest.id) {
            loading = true
            transcript = await store.transcriptForDigest(digest)
            loading = false
        }
    }

    private func hasVisibleContent(_ turn: SessionTranscript.Turn) -> Bool {
        guard turn.role == .user || turn.role == .assistant else { return false }
        return turn.blocks.contains {
            switch $0 {
            case .text(let s): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking(let s): return !s.isEmpty
            case .toolUse: return true
            case .toolResult(_, let isError): return isError
            case .attachment: return false
            }
        }
    }

    private func formatDuration(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }
}

private struct TurnRow: View {
    let turn: SessionTranscript.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(turn.role == .user ? "You" : "Claude",
                  systemImage: turn.role == .user ? "person.fill" : "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundColor(turn.role == .user ? .primary : .purple)
            ForEach(Array(turn.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .padding(10)
        .background(turn.role == .user
            ? Color.primary.opacity(0.04)
            : Color.purple.opacity(0.04))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func blockView(_ block: SessionTranscript.Block) -> some View {
        switch block {
        case .text(let s):
            if let attributed = try? AttributedString(markdown: s,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            } else {
                Text(s)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            }
        case .thinking(let s):
            Text(s)
                .font(.system(size: 11))
                .italic()
                .foregroundColor(.secondary)
                .lineLimit(3)
        case .toolUse(let name, let summary, _):
            Label(summary.isEmpty ? name : "\(name): \(summary)", systemImage: "wrench.and.screwdriver")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
        case .toolResult(let text, let isError):
            if isError {
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.8))
                    .lineLimit(2)
            }
        case .attachment:
            EmptyView()
        }
    }
}

// MARK: - Note side panel

private struct NotePanel: View {
    let entry: DailyLoreEntry
    let onClose: () -> Void
    @State private var rawContent: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(entry.loreType)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            MarkdownWebView(markdown: bodyContent)
        }
        .frame(minWidth: 320)
        .onAppear { loadContent() }
        .onChange(of: entry.path) { _, _ in loadContent() }
    }

    private var bodyContent: String { stripFrontmatter(rawContent) }

    private func loadContent() {
        rawContent = (try? String(contentsOfFile: entry.path, encoding: .utf8)) ?? ""
    }

    private func stripFrontmatter(_ s: String) -> String {
        guard s.hasPrefix("---") else { return s }
        let lines = s.components(separatedBy: "\n")
        var fences = 0
        var start = 0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("---") {
                fences += 1
                if fences == 2 { start = i + 1; break }
            }
        }
        return lines.dropFirst(start).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}

// MARK: - Shared components

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
    let path: String
    let dateStr: String
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
    let isSelected: Bool
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .accentColor : .primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
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
