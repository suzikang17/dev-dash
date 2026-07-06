import SwiftUI
import AppKit
import DevDashCore

struct ChangesTabView: View {
    @EnvironmentObject var store: DashboardStore
    // Canvas panels pinned to another project inject this override (see PanelContentView).
    @Environment(\.panelSelection) private var panelSelection

    enum ViewMode: String, CaseIterable, Identifiable {
        case changes, prs, sessions, files, deploys
        var id: String { rawValue }
        var label: String {
            switch self {
            case .changes: return "Changes"; case .prs: return "PRs"
            case .sessions: return "Sessions"; case .files: return "Files"
            case .deploys: return "Deploys"
            }
        }
    }
    @State private var viewMode: ViewMode = .changes

    @State private var unstaged: [ChangedFile] = []
    @State private var staged: [ChangedFile] = []
    @State private var commits: [GitCommit] = []
    @State private var prs: [PRSummary] = []
    @State private var sessions: [SessionDigest] = []

    // Files (Filetree) mode — browse + view any file in the project.
    @State private var fileTreeRoot: FileNode? = nil
    @State private var fileTreeLoadedPath: String? = nil
    @State private var selectedFilePath: String? = nil
    @State private var fileContent: FileTreeScanner.FileContent? = nil
    @State private var fileViewerText: String = ""
    @State private var loadingList = false

    // Working-tree single-file selection
    @State private var selection: DiffSelection? = nil
    @State private var diff: FileDiff? = nil
    @State private var loadingDiff = false

    // Stacked all-files view (commit / PR / session)
    @State private var stacked: StackedSelection? = nil
    @State private var stackedSections: [FileDiffSection] = []
    @State private var prDetail: PRDetail? = nil   // metadata for the selected PR
    @State private var prPreview: VercelDeployment? = nil  // Vercel preview for the PR's branch
    @State private var mergeTarget: PRDetail? = nil  // PR awaiting merge confirmation
    @State private var merging = false
    @State private var mergeMessage: String? = nil   // merge result to surface

    // Deploys (Vercel) mode
    @State private var deploysResult: VercelScanner.FetchResult? = nil
    @State private var deployments: [VercelDeployment] = []
    @State private var selectedDeploymentId: String? = nil
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
            return sortedPRs.map { .pr($0) }
        case .sessions:
            return sessions.map { .session($0) }
        case .files:
            return []   // Files mode uses tree selection, not flat keyboard nav
        case .deploys:
            return []   // Deploys mode uses its own row selection
        }
    }

    /// Open PRs first, then merged/closed — each group ordered by recency
    /// (most recent activity first; missing timestamps fall back to PR number).
    private var sortedPRs: [PRSummary] {
        func byRecency(_ a: PRSummary, _ b: PRSummary) -> Bool {
            switch (a.updatedAt, b.updatedAt) {
            case let (x?, y?) where x != y: return x > y
            default: return a.number > b.number
            }
        }
        let open = prs.filter { $0.isOpen }.sorted(by: byRecency)
        let closed = prs.filter { !$0.isOpen }.sorted(by: byRecency)
        return open + closed
    }

    struct DiffSelection: Equatable {
        let file: String
        let source: FileDiffSource
        let untracked: Bool
    }

    var body: some View {
        if let project = store.project(for: panelSelection ?? store.selection) {
            HStack(spacing: 0) {
                sidebar(projectPath: project.path)
                    .frame(width: sidebarWidth)
                    .background(DSColor.cardBg)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focus, equals: .sidebar)
                    .onKeyPress { handleSidebarKey($0, project.path) }
                resizeHandle
                Group {
                    if viewMode == .files { filesContentPane }
                    else if viewMode == .deploys { deploysDetailPane }
                    else { diffPane }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
                    .focusable()
                    .focusEffectDisabled()
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
                // Reset Files/Deploys state so a project switch never shows stale data.
                selectedFilePath = nil; fileContent = nil
                fileTreeRoot = nil; fileTreeLoadedPath = nil
                deploysResult = nil; deployments = []; selectedDeploymentId = nil
                await refresh(project.path)
                if viewMode == .files { await loadFileTree(project.path) }
                if viewMode == .deploys { await loadDeployments(project.path) }
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
            .confirmationDialog(
                "Merge PR #\(mergeTarget?.number ?? 0)?",
                isPresented: Binding(get: { mergeTarget != nil },
                                     set: { if !$0 { mergeTarget = nil } }),
                titleVisibility: .visible
            ) {
                ForEach(GitDiffScanner.PRMergeMethod.allCases) { method in
                    Button(method.label) {
                        if let t = mergeTarget {
                            merging = true   // close the double-trigger window synchronously
                            Task { await runMerge(t, method, project.path) }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { mergeTarget = nil }
            } message: {
                if let t = mergeTarget {
                    Text("Merges #\(t.number) “\(t.title)” into \(t.baseRefName) on GitHub. This can't be undone from here.")
                }
            }
            .alert("Merge", isPresented: Binding(get: { mergeMessage != nil },
                                                 set: { if !$0 { mergeMessage = nil } })) {
                Button("OK", role: .cancel) { mergeMessage = nil }
            } message: {
                Text(mergeMessage ?? "")
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
            // Load richer metadata in parallel; ignore if the user moved on.
            Task {
                let d = await GitDiffScanner.prDetail(path: projectPath, number: pr.number)
                await MainActor.run {
                    guard stacked?.key == "pr:\(pr.number)" else { return }
                    prDetail = d
                }
            }
            // Vercel preview deployment for this PR's branch (best-effort).
            Task {
                let preview = await VercelScanner.latestPreview(projectPath: projectPath, branch: pr.headRefName)
                await MainActor.run {
                    guard stacked?.key == "pr:\(pr.number)" else { return }
                    prPreview = preview
                }
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
        prDetail = nil; prPreview = nil
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
                    case .files:
                        fileTreeGroup(projectPath: projectPath)
                    case .deploys:
                        deploysGroup(projectPath: projectPath)
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
            let open = sortedPRs.filter { $0.isOpen }
            let closed = sortedPRs.filter { !$0.isOpen }
            if !open.isEmpty {
                prSectionHeader("Open", count: open.count)
                ForEach(open) { prRow($0, projectPath: projectPath) }
            }
            if !closed.isEmpty {
                prSectionHeader("Closed", count: closed.count)
                ForEach(closed) { prRow($0, projectPath: projectPath) }
            }
        }
    }

    private func prSectionHeader(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)")
            .font(DSFont.micro).foregroundColor(.secondary)
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func prRow(_ pr: PRSummary, projectPath: String) -> some View {
        let isSel = stacked?.key == "pr:\(pr.number)"
        let rel = relTime(pr.updatedAt)
        HStack(spacing: 6) {
            Text("#\(pr.number)").font(DSFont.monoDigits(.caption2)).foregroundColor(prStateColor(pr.state))
            VStack(alignment: .leading, spacing: 1) {
                Text(pr.title).font(DSFont.label).lineLimit(1).truncationMode(.tail)
                Text("\(pr.state.lowercased()) · \(pr.author)\(rel.isEmpty ? "" : " · \(rel)")")
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
        .contextMenu {
            Button("Open in Browser") { Task { await GitDiffScanner.openPRWeb(path: projectPath, number: pr.number) } }
            Button("Copy Branch") { copyText(pr.headRefName) }
            Button("Copy #\(pr.number)") { copyText("#\(pr.number)") }
        }
    }

    /// Metadata card shown above a selected PR's diff: state, author, recency,
    /// base ← head, line counts, labels, and the description body.
    @ViewBuilder
    private func prDetailHeader(_ d: PRDetail) -> some View {
        let rel = relTime(d.mergedAt ?? d.updatedAt)
        let relLabel = d.mergedAt != nil ? "merged \(rel)" : "updated \(rel)"
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack(spacing: 6) {
                Circle().fill(prStateColor(d.state)).frame(width: 7, height: 7)
                Text(d.state.lowercased()).font(DSFont.label).foregroundColor(prStateColor(d.state))
                Text("· \(d.author)").font(DSFont.micro).foregroundColor(.secondary)
                if !rel.isEmpty { Text("· \(relLabel)").font(DSFont.micro).foregroundColor(.secondary) }
                Spacer(minLength: 0)
                Text("+\(d.additions)").font(DSFont.monoDigits(.caption2)).foregroundColor(DSColor.success)
                Text("−\(d.deletions)").font(DSFont.monoDigits(.caption2)).foregroundColor(DSColor.danger)
            }
            HStack(spacing: 5) {
                Text(d.baseRefName).font(DSFont.mono(.caption2))
                Image(systemName: "arrow.left").font(.system(size: 9)).foregroundColor(.secondary)
                Text(d.headRefName).font(DSFont.mono(.caption2)).foregroundColor(.secondary)
                if !d.labels.isEmpty {
                    Text("· \(d.labels.joined(separator: ", "))")
                        .font(DSFont.micro).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            // Vercel preview deployment for this PR's branch, when available.
            if let preview = prPreview {
                HStack(spacing: 5) {
                    Image(systemName: "triangle.fill").font(.system(size: 8)).foregroundColor(.secondary)
                    Text("Preview").font(DSFont.micro).foregroundColor(.secondary)
                    VercelStateBadge(state: preview.state)
                    if let url = preview.deploymentURL {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Text(url.host ?? "open")
                                .font(DSFont.mono(.caption2)).foregroundColor(.accentColor)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help("Open preview deployment")
                    }
                    Spacer(minLength: 0)
                }
            }
            // Prominent action row: secondary Open, primary green Merge (open PRs).
            HStack(spacing: DSSpace.sm) {
                Spacer(minLength: 0)
                Button { openPR(d) } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open PR #\(d.number) in browser")
                if d.state.uppercased() == "OPEN" {
                    Button { mergeTarget = d } label: {
                        if merging {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Merge", systemImage: "arrow.triangle.merge")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DSColor.success)
                    .controlSize(.small)
                    .disabled(merging)
                    .help("Merge PR #\(d.number)")
                    .accessibilityLabel("Merge PR #\(d.number)")
                }
            }
            .padding(.top, 2)
            if !d.body.isEmpty {
                ScrollView {
                    Text(d.body)
                        .font(DSFont.label).foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .contextMenu {
                    Button("Copy Session ID") { copyText(s.id) }
                    Button("Copy Title") { copyText(s.title ?? s.firstUserMessage ?? "Session") }
                }
            }
        }
    }

    private func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func revealInFinder(_ absolutePath: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
    }

    /// Open the PR's GitHub page. Uses the URL from `gh pr view`; no subprocess.
    private func openPR(_ d: PRDetail) {
        guard let url = URL(string: d.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Merge a PR via `gh`, then refresh its state. Result (success or error
    /// output) is surfaced in the Merge alert.
    private func runMerge(_ pr: PRDetail, _ method: GitDiffScanner.PRMergeMethod, _ projectPath: String) async {
        await MainActor.run { merging = true; mergeTarget = nil }
        let result = await GitDiffScanner.mergePR(path: projectPath, number: pr.number, method: method)
        // Refresh regardless of the reported result: a client-side timeout may
        // have merged server-side anyway, so always reconcile the shown state.
        await loadList(for: .prs, projectPath: projectPath)
        let updated = await GitDiffScanner.prDetail(path: projectPath, number: pr.number)
        await MainActor.run {
            if stacked?.key == "pr:\(pr.number)" { prDetail = updated }
            merging = false
            mergeMessage = result.message
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
        prDetail = nil; prPreview = nil
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
        case .files:
            await loadFileTree(projectPath)
        case .deploys:
            await loadDeployments(projectPath)
        }
    }

    // MARK: - Deploys (Vercel) mode

    private func loadDeployments(_ projectPath: String) async {
        await MainActor.run { deploysResult = nil; loadingList = true }
        let result = await VercelScanner.deployments(projectPath: projectPath, limit: 30)
        await MainActor.run {
            // The fetch is slow (network); ignore it if the user switched projects.
            guard store.project(for: panelSelection ?? store.selection)?.path == projectPath else { return }
            deploysResult = result
            if case let .ok(list) = result { deployments = list } else { deployments = [] }
            selectedDeploymentId = deployments.first?.id
            loadingList = false
        }
    }

    private var selectedDeployment: VercelDeployment? {
        deployments.first { $0.id == selectedDeploymentId }
    }

    // MARK: - Files (Filetree) mode

    /// Build the project's file tree once per project; cheap to re-enter the tab.
    private func loadFileTree(_ projectPath: String) async {
        if fileTreeLoadedPath == projectPath, fileTreeRoot != nil { return }
        await MainActor.run { fileTreeRoot = nil }
        let root = await Task.detached { FileTreeScanner.loadTree(root: projectPath) }.value
        await MainActor.run {
            fileTreeRoot = root
            fileTreeLoadedPath = projectPath
        }
    }

    /// Read a file's contents for the viewer pane.
    private func selectFile(_ path: String) {
        selectedFilePath = path
        fileContent = nil
        Task {
            let content = await Task.detached { FileTreeScanner.readFile(at: path) }.value
            await MainActor.run {
                guard selectedFilePath == path else { return }   // user moved on
                fileContent = content
                if case let .text(t) = content { fileViewerText = t } else { fileViewerText = "" }
            }
        }
    }

    @ViewBuilder
    private func fileTreeGroup(projectPath: String) -> some View {
        if let root = fileTreeRoot, let kids = root.children {
            if kids.isEmpty {
                Text("No files").font(DSFont.label).foregroundColor(.secondary).padding(DSSpace.md)
            } else {
                OutlineGroup(kids, children: \.children) { node in
                    fileTreeRow(node)
                }
            }
        } else {
            ProgressView().padding(DSSpace.md).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func fileTreeRow(_ node: FileNode) -> some View {
        let isSel = !node.isDirectory && selectedFilePath == node.path
        HStack(spacing: 6) {
            Image(systemName: FileTreeScanner.icon(for: node.name, isDirectory: node.isDirectory))
                .font(DSFont.label)
                .foregroundColor(node.isDirectory ? .accentColor : .secondary)
                .frame(width: 16)
            Text(node.name).font(DSFont.label).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(isSel ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
        .contentShape(Rectangle())
        .onTapGesture { if !node.isDirectory { selectFile(node.path) } }
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
        .contextMenu {
            if isStaged {
                Button("Unstage") {
                    Task { await doMutation(projectPath, file, verb: "unstage") {
                        await GitDiffScanner.unstage(path: projectPath, file: file.path)
                    } }
                }
            } else {
                Button("Stage") {
                    Task { await doMutation(projectPath, file, verb: "stage") {
                        await GitDiffScanner.stage(path: projectPath, file: file.path)
                    } }
                }
                Button("Discard Changes…", role: .destructive) { revertTarget = file }
            }
            Divider()
            Button("Reveal in Finder") { revealInFinder("\(projectPath)/\(file.path)") }
            Button("Open File") { store.openFile("\(projectPath)/\(file.path)") }
            Button("Copy Path") { copyText(file.path) }
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
            .contextMenu {
                Button("Copy SHA") { copyText(commit.sha) }
                Button("Copy Message") { copyText(commit.subject) }
                Button("Open on GitHub") { Task { await GitDiffScanner.browseCommit(path: projectPath, sha: commit.sha) } }
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

    // MARK: Files content pane

    @ViewBuilder
    private var filesContentPane: some View {
        if let path = selectedFilePath {
            VStack(spacing: 0) {
                HStack(spacing: DSSpace.sm) {
                    Image(systemName: FileTreeScanner.icon(for: URL(fileURLWithPath: path).lastPathComponent, isDirectory: false))
                        .foregroundColor(.secondary)
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(DSFont.label.weight(.medium))
                    Text(DevRoots.shortenPath(path)).font(DSFont.mono(.caption))
                        .foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { store.openFile(path) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.borderless).help("Open in default app")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless).help("Reveal in Finder")
                }
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                Divider()
                fileBody(path: path)
            }
        } else {
            VStack(spacing: DSSpace.sm) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 32)).foregroundColor(.secondary)
                Text("Select a file to view").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func fileBody(path: String) -> some View {
        switch fileContent {
        case .text:
            CodeEditor(text: $fileViewerText, language: language(for: path), isEditable: false)
        case let .binary(size):
            fileMessage("Binary file", detail: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        case let .tooLarge(size):
            fileMessage("File too large to preview", detail: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        case let .unreadable(msg):
            fileMessage("Can't read file", detail: msg)
        case nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileMessage(_ title: String, detail: String) -> some View {
        VStack(spacing: DSSpace.sm) {
            Image(systemName: "doc").font(.system(size: 32)).foregroundColor(.secondary)
            Text(title).font(DSFont.label)
            if !detail.isEmpty { Text(detail).font(DSFont.micro).foregroundColor(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Deploys (Vercel) pane

    @ViewBuilder
    private func deploysGroup(projectPath: String) -> some View {
        HStack(spacing: 4) {
            Text("Deployments").font(DSFont.micro).foregroundColor(.secondary)
            Spacer()
            if loadingList { ProgressView().controlSize(.mini) }
            Button { Task { await loadDeployments(projectPath) } } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless).controlSize(.small)
            .disabled(loadingList)
            .help("Refresh deployments")
            .accessibilityLabel("Refresh deployments")
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        switch deploysResult {
        case nil:
            ProgressView().padding(DSSpace.md).frame(maxWidth: .infinity)
        case .notAuthenticated:
            deploysHint("Not connected", "Run vercel login in a terminal, then switch tabs to refresh.")
        case .notLinked:
            deploysHint("Project not linked", "Run vercel link in this project, then switch tabs to refresh.")
        case .failed(let msg):
            deploysHint("Couldn’t load", msg)
        case .ok:
            if deployments.isEmpty {
                deploysHint("No deployments", "This project has no Vercel deployments yet.")
            } else {
                ForEach(deployments) { deployRow($0) }
            }
        }
    }

    @ViewBuilder
    private func deployRow(_ d: VercelDeployment) -> some View {
        let isSel = selectedDeploymentId == d.id
        HStack(spacing: 6) {
            Circle().fill(vercelStateColor(d.state)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.branch ?? (d.isProduction ? "production" : d.url))
                    .font(DSFont.label).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(d.state.lowercased()).font(DSFont.micro).foregroundColor(vercelStateColor(d.state))
                    Text("· \(d.isProduction ? "prod" : "preview")").font(DSFont.micro).foregroundColor(.secondary)
                    if let at = d.createdAt {
                        Text("· \(relTime(at))").font(DSFont.micro).foregroundColor(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(isSel ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
        .contentShape(Rectangle())
        .onTapGesture { selectedDeploymentId = d.id }
        .contextMenu {
            if let url = d.deploymentURL { Button("Visit Deployment") { NSWorkspace.shared.open(url) } }
            if let inspector = d.inspectorUrl, let iu = URL(string: inspector) {
                Button("Open in Vercel") { NSWorkspace.shared.open(iu) }
            }
        }
    }

    private func deploysHint(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DSFont.label).foregroundColor(.secondary)
            Text(detail).font(DSFont.micro).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpace.md)
    }

    @ViewBuilder
    private var deploysDetailPane: some View {
        if let d = selectedDeployment {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                HStack(spacing: 8) {
                    VercelStateBadge(state: d.state)
                    VercelTargetTag(isProduction: d.isProduction)
                    if let at = d.createdAt {
                        Text(relTime(at)).font(DSFont.micro).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if let branch = d.branch {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundColor(.secondary)
                        Text(branch).font(DSFont.mono(.caption))
                    }
                }
                if let msg = d.commitMessage, !msg.isEmpty {
                    Text(msg).font(DSFont.label).foregroundColor(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                if let url = d.deploymentURL {
                    Text(url.absoluteString).font(DSFont.mono(.caption)).foregroundColor(.accentColor)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                HStack(spacing: DSSpace.sm) {
                    if let url = d.deploymentURL {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label("Visit", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    if let inspector = d.inspectorUrl, let iu = URL(string: inspector) {
                        Button { NSWorkspace.shared.open(iu) } label: {
                            Label("Open in Vercel", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    if let sha = d.commitSha {
                        Button { copyText(sha) } label: {
                            Label("Copy SHA", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Spacer()
            }
            .padding(DSSpace.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: DSSpace.sm) {
                Image(systemName: "triangle").font(.system(size: 32)).foregroundColor(.secondary)
                Text("Select a deployment").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Diff pane

    @ViewBuilder
    private var diffPane: some View {
        if loadingStacked || loadingDiff {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let stacked {
            VStack(spacing: 0) {
                if let d = prDetail, "pr:\(d.number)" == stacked.key {
                    prDetailHeader(d)
                    Divider()
                }
                StackedDiffView(title: stacked.title, subtitle: stacked.subtitle,
                                sections: stackedSections, scrollID: $commitSectionID)
            }
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
