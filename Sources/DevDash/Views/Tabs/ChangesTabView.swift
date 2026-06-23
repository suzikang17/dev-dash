import SwiftUI
import AppKit
import DevDashCore

struct ChangesTabView: View {
    @EnvironmentObject var store: DashboardStore

    enum ViewMode: String, CaseIterable, Identifiable {
        case changes, prs, sessions
        var id: String { rawValue }
        var label: String {
            switch self { case .changes: return "Changes"; case .prs: return "PRs"; case .sessions: return "Sessions" }
        }
    }
    @State private var viewMode: ViewMode = .changes

    @State private var unstaged: [ChangedFile] = []
    @State private var staged: [ChangedFile] = []
    @State private var commits: [GitCommit] = []
    @State private var prs: [PRSummary] = []
    @State private var sessions: [SessionDigest] = []
    @State private var loadingList = false

    // Working-tree single-file selection
    @State private var selection: DiffSelection? = nil
    @State private var diff: FileDiff? = nil
    @State private var loadingDiff = false

    // Stacked all-files view (commit / PR / session)
    @State private var stacked: StackedSelection? = nil
    @State private var stackedSections: [FileDiffSection] = []
    @State private var loadingStacked = false

    @State private var revertTarget: ChangedFile? = nil
    @State private var errorMessage: String? = nil

    struct StackedSelection: Equatable {
        let key: String
        let title: String
        let subtitle: String
    }

    // Persisted, resizable sidebar width (sane default; clamped on drag).
    @AppStorage("devdash.changesSidebarWidth") private var sidebarWidth: Double = 300
    @State private var dragStartWidth: Double? = nil

    // Vim-style navigation
    enum Pane: Hashable { case sidebar, diff }
    @FocusState private var focus: Pane?
    @State private var cursor: Int = 0          // index into navItems
    @State private var pendingG = false         // first 'g' of a 'gg'
    @State private var diffRowID: Int? = nil    // scroll position in single-file diff
    @State private var diffLineCursor = 0
    @State private var commitSectionID: String? = nil  // scroll position in commit detail
    @State private var sectionCursor = 0

    enum NavItem: Equatable {
        case file(path: String, source: FileDiffSource, untracked: Bool, name: String)
        case commit(GitCommit)
        case pr(PRSummary)
        case session(SessionDigest)
    }

    private var navItems: [NavItem] {
        switch viewMode {
        case .changes:
            return unstaged.map { .file(path: $0.path, source: .unstaged, untracked: $0.isUntracked, name: $0.name) }
                + staged.map { .file(path: $0.path, source: .staged, untracked: $0.isUntracked, name: $0.name) }
                + commits.map { .commit($0) }
        case .prs:
            return prs.map { .pr($0) }
        case .sessions:
            return sessions.map { .session($0) }
        }
    }

    struct DiffSelection: Equatable {
        let file: String
        let source: FileDiffSource
        let untracked: Bool
    }

    var body: some View {
        if let project = store.project(for: store.selection) {
            HStack(spacing: 0) {
                sidebar(projectPath: project.path)
                    .frame(width: sidebarWidth)
                    .background(DSColor.cardBg)
                    .focusable()
                    .focused($focus, equals: .sidebar)
                    .onKeyPress { handleSidebarKey($0, project.path) }
                resizeHandle
                diffPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                    .focusable()
                    .focused($focus, equals: .diff)
                    .onKeyPress { handleDiffKey($0) }
            }
            .overlay(alignment: .bottomTrailing) { focusHint }
            .overlay(alignment: .top) {
                if let errorMessage {
                    HStack(spacing: DSSpace.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(DSColor.danger)
                        Text(errorMessage)
                            .font(DSFont.label)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Button {
                            self.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(DSSpace.sm)
                    .background(DSColor.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: DSRadius.medium))
                    .padding(DSSpace.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: errorMessage)
            .task(id: project.path) {
                await refresh(project.path)
                focus = .sidebar
            }
            .alert("Discard changes to \(revertTarget?.name ?? "")?",
                   isPresented: Binding(get: { revertTarget != nil },
                                        set: { if !$0 { revertTarget = nil } })) {
                Button("Discard", role: .destructive) {
                    if let t = revertTarget { Task { await doRevert(project.path, t) } }
                }
                Button("Cancel", role: .cancel) { revertTarget = nil }
            } message: {
                Text("This permanently discards the file's uncommitted changes.")
            }
        } else {
            Text("Select a project to view changes")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Resizable divider

    private var resizeHandle: some View {
        Rectangle()
            .fill(DSColor.hairline)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStartWidth ?? sidebarWidth
                        if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                        sidebarWidth = min(500, max(200, start + value.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    private var focusHint: some View {
        Text(focus == .diff ? "diff · j/k scroll · h sidebar" : "list · j/k move · l/⏎ diff")
            .font(DSFont.micro).foregroundColor(.secondary)
            .padding(.horizontal, DSSpace.sm).padding(.vertical, 3)
            .background(DSColor.cardBg.opacity(0.9), in: Capsule())
            .padding(DSSpace.sm)
    }

    // MARK: Vim navigation

    private func handleSidebarKey(_ press: KeyPress, _ projectPath: String) -> KeyPress.Result {
        if press.modifiers.contains(.control) {
            switch press.key.character {
            case "d": moveCursor(10, projectPath); return .handled
            case "u": moveCursor(-10, projectPath); return .handled
            default: break
            }
        }
        switch press.key.character {
        case "\r", "\t": focus = .diff; return .handled
        default: break
        }
        switch press.characters {
        case "j": moveCursor(1, projectPath); pendingG = false; return .handled
        case "k": moveCursor(-1, projectPath); pendingG = false; return .handled
        case "l": focus = .diff; pendingG = false; return .handled
        case "G": setCursor(navItems.count - 1, projectPath); pendingG = false; return .handled
        case "g":
            if pendingG { setCursor(0, projectPath); pendingG = false } else { pendingG = true }
            return .handled
        default:
            pendingG = false
            return .ignored
        }
    }

    private func handleDiffKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key.character {
        case "\t", "\u{1b}": focus = .sidebar; pendingG = false; return .handled
        default: break
        }
        if press.characters == "h" { focus = .sidebar; pendingG = false; return .handled }

        let ctrl = press.modifiers.contains(.control)
        if stacked != nil {
            let count = stackedSections.count
            guard count > 0 else { return .handled }
            if ctrl, press.key.character == "d" { moveSection(1); return .handled }
            if ctrl, press.key.character == "u" { moveSection(-1); return .handled }
            switch press.characters {
            case "j": moveSection(1); pendingG = false; return .handled
            case "k": moveSection(-1); pendingG = false; return .handled
            case "G": setSection(count - 1); pendingG = false; return .handled
            case "g":
                if pendingG { setSection(0); pendingG = false } else { pendingG = true }
                return .handled
            default: pendingG = false; return .ignored
            }
        } else {
            let count = diff?.rows.count ?? 0
            guard count > 0 else { return .handled }
            if ctrl, press.key.character == "d" { moveLine(15); return .handled }
            if ctrl, press.key.character == "u" { moveLine(-15); return .handled }
            switch press.characters {
            case "j": moveLine(1); pendingG = false; return .handled
            case "k": moveLine(-1); pendingG = false; return .handled
            case "G": setLine(count - 1); pendingG = false; return .handled
            case "g":
                if pendingG { setLine(0); pendingG = false } else { pendingG = true }
                return .handled
            default: pendingG = false; return .ignored
            }
        }
    }

    private func moveCursor(_ delta: Int, _ projectPath: String) {
        setCursor(cursor + delta, projectPath)
    }

    private func setCursor(_ idx: Int, _ projectPath: String) {
        let items = navItems
        guard !items.isEmpty else { return }
        let n = max(0, min(items.count - 1, idx))
        cursor = n
        activate(items[n], projectPath)
    }

    private func activate(_ item: NavItem, _ projectPath: String) {
        switch item {
        case let .file(path, source, untracked, _):
            stacked = nil
            diffRowID = nil; diffLineCursor = 0
            selection = DiffSelection(file: path, source: source, untracked: untracked)
            Task { await loadDiff(projectPath) }
        case let .commit(c):
            loadStacked(key: "commit:\(c.sha)", title: c.subject,
                        subtitle: "\(c.shortSha) · \(c.author) · \(c.relativeDate)", projectPath: projectPath) {
                let raw = await GitDiffScanner.commitFullDiff(path: projectPath, sha: c.sha) ?? ""
                return UnifiedDiffParser.parseMultiFile(raw)
            }
        case let .pr(pr):
            loadStacked(key: "pr:\(pr.number)", title: "#\(pr.number) \(pr.title)",
                        subtitle: "\(pr.state.lowercased()) · \(pr.author) · \(pr.headRefName)", projectPath: projectPath) {
                let raw = await GitDiffScanner.prDiff(path: projectPath, number: pr.number) ?? ""
                return UnifiedDiffParser.parseMultiFile(raw)
            }
        case let .session(s):
            let written = s.filesTouched.filter { $0.writes > 0 }
                .map { rel($0.path, projectPath) }
            loadStacked(key: "session:\(s.id)", title: s.title ?? (s.firstUserMessage ?? "Session"),
                        subtitle: "\(written.count) file\(written.count == 1 ? "" : "s") written · \(s.id.prefix(8))",
                        projectPath: projectPath) {
                let raw = await GitDiffScanner.sessionDiff(path: projectPath, files: written, since: s.startedAt) ?? ""
                return UnifiedDiffParser.parseMultiFile(raw)
            }
        }
    }

    /// Repo-relative path (strip a leading projectPath prefix if present).
    private func rel(_ path: String, _ projectPath: String) -> String {
        if path.hasPrefix(projectPath + "/") { return String(path.dropFirst(projectPath.count + 1)) }
        return path
    }

    private func loadStacked(key: String, title: String, subtitle: String, projectPath: String,
                             _ load: @escaping () async -> [FileDiffSection]) {
        selection = nil
        diff = nil
        commitSectionID = nil; sectionCursor = 0
        stacked = StackedSelection(key: key, title: title, subtitle: subtitle)
        stackedSections = []
        loadingStacked = true
        Task {
            let sections = await load()
            await MainActor.run {
                guard stacked?.key == key else { return }   // user moved on
                stackedSections = sections
                loadingStacked = false
            }
        }
    }

    private func moveLine(_ delta: Int) { setLine(diffLineCursor + delta) }
    private func setLine(_ idx: Int) {
        let count = diff?.rows.count ?? 0
        guard count > 0 else { return }
        diffLineCursor = max(0, min(count - 1, idx))
        diffRowID = diffLineCursor
    }

    private func moveSection(_ delta: Int) { setSection(sectionCursor + delta) }
    private func setSection(_ idx: Int) {
        guard !stackedSections.isEmpty else { return }
        sectionCursor = max(0, min(stackedSections.count - 1, idx))
        commitSectionID = stackedSections[sectionCursor].id
    }

    // MARK: Sidebar

    @ViewBuilder
    private func sidebar(projectPath: String) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $viewMode) {
                ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(DSSpace.sm)
            .onChange(of: viewMode) { _, newMode in
                clearSelection()
                cursor = 0
                Task { await loadList(for: newMode, projectPath: projectPath) }
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch viewMode {
                    case .changes:
                        fileGroup(title: "Unstaged", files: unstaged, projectPath: projectPath,
                                  source: .unstaged, isStaged: false)
                        fileGroup(title: "Staged", files: staged, projectPath: projectPath,
                                  source: .staged, isStaged: true)
                        Divider().padding(.vertical, DSSpace.xs)
                        historyGroup(projectPath: projectPath)
                    case .prs:
                        prsGroup(projectPath: projectPath)
                    case .sessions:
                        sessionsGroup(projectPath: projectPath)
                    }
                }
                .padding(DSSpace.sm)
            }
        }
    }

    @ViewBuilder
    private func prsGroup(projectPath: String) -> some View {
        if loadingList {
            ProgressView().padding(DSSpace.md).frame(maxWidth: .infinity)
        } else if prs.isEmpty {
            Text("No PRs (or gh not authenticated)")
                .font(DSFont.label).foregroundColor(.secondary).padding(DSSpace.md)
        } else {
            ForEach(prs) { pr in
                let isSel = stacked?.key == "pr:\(pr.number)"
                HStack(spacing: 6) {
                    Text("#\(pr.number)").font(DSFont.monoDigits(.caption2)).foregroundColor(prStateColor(pr.state))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pr.title).font(DSFont.label).lineLimit(1).truncationMode(.tail)
                        Text("\(pr.state.lowercased()) · \(pr.author)")
                            .font(DSFont.micro).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(isSel ? Color.accentColor.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                .contentShape(Rectangle())
                .onTapGesture {
                    focus = .sidebar
                    if let i = navItems.firstIndex(of: .pr(pr)) { cursor = i }
                    activate(.pr(pr), projectPath)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionsGroup(projectPath: String) -> some View {
        if sessions.isEmpty {
            Text("No Claude Code sessions for this project")
                .font(DSFont.label).foregroundColor(.secondary).padding(DSSpace.md)
        } else {
            ForEach(sessions) { s in
                let isSel = stacked?.key == "session:\(s.id)"
                let written = s.filesTouched.filter { $0.writes > 0 }.count
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundColor(DSColor.assistant)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title ?? s.firstUserMessage ?? "Session")
                            .font(DSFont.label).lineLimit(1).truncationMode(.tail)
                        Text("\(written) changed · \(relTime(s.startedAt))")
                            .font(DSFont.micro).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(isSel ? Color.accentColor.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                .contentShape(Rectangle())
                .onTapGesture {
                    focus = .sidebar
                    if let i = navItems.firstIndex(of: .session(s)) { cursor = i }
                    activate(.session(s), projectPath)
                }
            }
        }
    }

    private func prStateColor(_ s: String) -> Color {
        switch s.uppercased() {
        case "OPEN": return DSColor.success
        case "MERGED": return DSColor.assistant
        case "CLOSED": return DSColor.danger
        default: return .secondary
        }
    }

    private func relTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func clearSelection() {
        selection = nil; diff = nil
        stacked = nil; stackedSections = []
    }

    private func loadList(for mode: ViewMode, projectPath: String) async {
        switch mode {
        case .changes:
            await refresh(projectPath)
        case .prs:
            await MainActor.run { loadingList = true }
            let list = await GitDiffScanner.pullRequests(path: projectPath)
            await MainActor.run { prs = list; loadingList = false; cursor = 0 }
        case .sessions:
            store.refreshSessionDigests()
            await MainActor.run {
                sessions = store.sessionDigests.values
                    .filter { $0.projectPath == projectPath }
                    .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
                cursor = 0
            }
        }
    }

    @ViewBuilder
    private func fileGroup(title: String, files: [ChangedFile], projectPath: String,
                           source: FileDiffSource, isStaged: Bool) -> some View {
        if !files.isEmpty {
            SectionHeader("\(title) (\(files.count))")
                .padding(.top, DSSpace.xs)
            ForEach(files) { file in
                fileRow(file, projectPath: projectPath, source: source, isStaged: isStaged)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: ChangedFile, projectPath: String,
                         source: FileDiffSource, isStaged: Bool) -> some View {
        let isSelected = selection?.file == file.path && selection?.source == source
        HStack(spacing: 6) {
            Text(statusBadge(file, isStaged: isStaged))
                .font(DSFont.monoDigits(.caption2))
                .foregroundColor(badgeColor(file, isStaged: isStaged))
                .frame(width: 14)
            Text(file.name)
                .font(DSFont.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isStaged {
                rowButton("minus.circle", help: "Unstage") {
                    Task { await doMutation(projectPath, file, verb: "unstage") {
                        await GitDiffScanner.unstage(path: projectPath, file: file.path)
                    } }
                }
            } else {
                rowButton("plus.circle", help: "Stage") {
                    Task { await doMutation(projectPath, file, verb: "stage") {
                        await GitDiffScanner.stage(path: projectPath, file: file.path)
                    } }
                }
                rowButton("arrow.uturn.backward", help: "Discard") { revertTarget = file }
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
        .contentShape(Rectangle())
        .onTapGesture {
            focus = .sidebar
            let item = NavItem.file(path: file.path, source: source, untracked: file.isUntracked, name: file.name)
            if let i = navItems.firstIndex(of: item) { cursor = i }
            activate(item, projectPath)
        }
    }

    @ViewBuilder
    private func historyGroup(projectPath: String) -> some View {
        SectionHeader("History")
        ForEach(commits) { commit in
            let isSel = stacked?.key == "commit:\(commit.sha)"
            HStack(spacing: 6) {
                Text(commit.shortSha).font(DSFont.mono(.caption2)).foregroundColor(DSColor.gitMeta)
                Text(commit.subject).font(DSFont.label).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(commit.relativeDate).font(DSFont.micro).foregroundColor(.secondary)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(isSel ? Color.accentColor.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
            .contentShape(Rectangle())
            .onTapGesture {
                focus = .sidebar
                if let i = navItems.firstIndex(of: .commit(commit)) { cursor = i }
                activate(.commit(commit), projectPath)
            }
        }
    }

    private func rowButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 11)) }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help(help)
    }

    private func statusBadge(_ file: ChangedFile, isStaged: Bool) -> String {
        if file.isUntracked { return "?" }
        let c = isStaged ? file.stagedStatus : file.unstagedStatus
        return c.map(String.init) ?? "•"
    }

    private func badgeColor(_ file: ChangedFile, isStaged: Bool) -> Color {
        if file.isUntracked { return DSColor.success }
        let c = isStaged ? file.stagedStatus : file.unstagedStatus
        switch c {
        case "A": return DSColor.success
        case "D": return DSColor.danger
        case "M": return DSColor.warning
        default:  return .secondary
        }
    }

    // MARK: Diff pane

    @ViewBuilder
    private var diffPane: some View {
        if loadingStacked || loadingDiff {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let stacked {
            StackedDiffView(title: stacked.title, subtitle: stacked.subtitle,
                            sections: stackedSections, scrollID: $commitSectionID)
                .id(stacked.key)
        } else if let diff, let selection {
            VStack(spacing: 0) {
                HStack {
                    Text(selection.file).font(DSFont.mono(.caption)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                Divider()
                SideBySideDiffView(diff: diff, language: language(for: selection.file),
                                   scrollID: $diffRowID)
            }
        } else {
            Text("Select a file or commit to view its diff")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func language(for file: String) -> SyntaxHighlighter.Language {
        SyntaxHighlighter.Language.detect(from: (file as NSString).pathExtension)
    }

    // MARK: Loading

    private func refresh(_ projectPath: String) async {
        let all = await GitDiffScanner.changedFiles(path: projectPath)
        let log = await GitDiffScanner.commits(path: projectPath)
        await MainActor.run {
            unstaged = all.filter { $0.unstagedStatus != nil || $0.isUntracked }
            staged = all.filter { $0.stagedStatus != nil }
            commits = log
            cursor = max(0, min(cursor, navItems.count - 1))
        }
    }

    private func loadDiff(_ projectPath: String) async {
        guard let sel = selection else { return }
        await MainActor.run { loadingDiff = true }
        let raw = await GitDiffScanner.fileDiff(path: projectPath, file: sel.file,
                                                source: sel.source, untracked: sel.untracked) ?? ""
        let parsed = UnifiedDiffParser.parse(raw)
        await MainActor.run {
            diff = parsed
            loadingDiff = false
        }
    }

    private func doRevert(_ projectPath: String, _ file: ChangedFile) async {
        await MainActor.run { revertTarget = nil }
        await doMutation(projectPath, file, verb: "discard changes to") {
            await GitDiffScanner.revert(path: projectPath, file: file.path, untracked: file.isUntracked)
        }
    }

    /// Run a git mutation, surface failures in the error banner, then refresh.
    private func doMutation(_ projectPath: String, _ file: ChangedFile, verb: String,
                            _ op: @escaping () async -> Bool) async {
        let ok = await op()
        await MainActor.run {
            errorMessage = ok ? nil : "Failed to \(verb) \(file.name)."
        }
        await refresh(projectPath)
    }
}

// MARK: - Stacked all-files diff in one scroll (commits, PRs, sessions)

private struct StackedDiffView: View {
    let title: String
    let subtitle: String
    let sections: [FileDiffSection]
    var scrollID: Binding<String?> = .constant(nil)

    @State private var collapsed: Set<String> = []

    private var totalAdds: Int { sections.reduce(0) { $0 + $1.diff.additions } }
    private var totalDels: Int { sections.reduce(0) { $0 + $1.diff.deletions } }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if sections.count > 1 { jumpBar }
                ForEach(sections) { section in
                    fileSection(section)
                        .id(section.id)
                }
                if sections.isEmpty {
                    Text("No file changes in this commit")
                        .font(DSFont.label).foregroundColor(.secondary)
                        .padding(DSSpace.lg)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: scrollID, anchor: .top)
        .onAppear {
            // Big files start collapsed so opening a large commit stays snappy.
            collapsed = Set(sections.filter { $0.diff.rows.count > 600 }.map(\.path))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(title).font(DSFont.title)
            HStack(spacing: DSSpace.sm) {
                Text(subtitle).font(DSFont.micro).foregroundColor(.secondary).lineLimit(1)
                Text("\(sections.count) file\(sections.count == 1 ? "" : "s")")
                    .font(DSFont.micro).foregroundColor(.secondary)
                Text("+\(totalAdds)").font(DSFont.monoDigits(.caption2)).foregroundColor(DSColor.success)
                Text("−\(totalDels)").font(DSFont.monoDigits(.caption2)).foregroundColor(DSColor.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpace.md)
        .background(DSColor.cardBg)
    }

    private var jumpBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpace.xs) {
                ForEach(sections) { section in
                    Button {
                        withAnimation { scrollID.wrappedValue = section.id }
                    } label: {
                        Text(basename(section.path))
                            .font(DSFont.micro)
                            .lineLimit(1)
                            .padding(.horizontal, DSSpace.sm).padding(.vertical, 3)
                            .background(DSColor.hairline, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
        }
    }

    @ViewBuilder
    private func fileSection(_ section: FileDiffSection) -> some View {
        let isCollapsed = collapsed.contains(section.path)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isCollapsed { collapsed.remove(section.path) } else { collapsed.insert(section.path) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Text(statusBadge(section.diff)).font(DSFont.monoDigits(.caption2))
                        .foregroundColor(badgeColor(section.diff)).frame(width: 12)
                    Text(section.path).font(DSFont.mono(.caption2)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("+\(section.diff.additions)").font(DSFont.monoDigits(.caption2)).foregroundColor(DSColor.success)
                    Text("−\(section.diff.deletions)").font(DSFont.monoDigits(.caption2)).foregroundColor(DSColor.danger)
                }
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(DSColor.cardBg.opacity(0.5))

            if !isCollapsed {
                DiffRowsView(diff: section.diff, language: language(for: section.path))
                    .padding(.vertical, DSSpace.xs)
            }
            Divider()
        }
    }

    private func language(for file: String) -> SyntaxHighlighter.Language {
        SyntaxHighlighter.Language.detect(from: (file as NSString).pathExtension)
    }

    private func basename(_ path: String) -> String { (path as NSString).lastPathComponent }

    private func statusBadge(_ diff: FileDiff) -> String {
        if diff.isBinary { return "B" }
        if diff.deletions == 0 && diff.additions > 0 { return "A" }
        if diff.additions == 0 && diff.deletions > 0 { return "D" }
        return "M"
    }

    private func badgeColor(_ diff: FileDiff) -> Color {
        switch statusBadge(diff) {
        case "A": return DSColor.success
        case "D": return DSColor.danger
        default:  return DSColor.warning
        }
    }
}
