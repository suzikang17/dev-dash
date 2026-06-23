import SwiftUI
import AppKit
import DevDashCore

struct ChangesTabView: View {
    @EnvironmentObject var store: DashboardStore

    @State private var unstaged: [ChangedFile] = []
    @State private var staged: [ChangedFile] = []
    @State private var commits: [GitCommit] = []

    // Working-tree single-file selection
    @State private var selection: DiffSelection? = nil
    @State private var diff: FileDiff? = nil
    @State private var loadingDiff = false

    // Commit detail (stacked all-files view)
    @State private var selectedCommit: GitCommit? = nil
    @State private var commitSections: [FileDiffSection] = []
    @State private var loadingCommit = false

    @State private var revertTarget: ChangedFile? = nil
    @State private var errorMessage: String? = nil

    struct DiffSelection: Equatable {
        let file: String
        let source: FileDiffSource
        let untracked: Bool
    }

    var body: some View {
        if let project = store.project(for: store.selection) {
            HSplitView {
                sidebar(projectPath: project.path)
                    .frame(minWidth: 200, idealWidth: 280, maxWidth: 460)
                    .background(DSColor.cardBg)
                diffPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
            }
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
            .task(id: project.path) { await refresh(project.path) }
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

    // MARK: Sidebar

    @ViewBuilder
    private func sidebar(projectPath: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                fileGroup(title: "Unstaged", files: unstaged, projectPath: projectPath,
                          source: .unstaged, isStaged: false)
                fileGroup(title: "Staged", files: staged, projectPath: projectPath,
                          source: .staged, isStaged: true)
                Divider().padding(.vertical, DSSpace.xs)
                historyGroup(projectPath: projectPath)
            }
            .padding(DSSpace.sm)
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
            selectedCommit = nil
            selection = DiffSelection(file: file.path, source: source, untracked: file.isUntracked)
            Task { await loadDiff(projectPath) }
        }
    }

    @ViewBuilder
    private func historyGroup(projectPath: String) -> some View {
        SectionHeader("History")
        ForEach(commits) { commit in
            let isSel = selectedCommit?.sha == commit.sha
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
            .onTapGesture { Task { await selectCommit(commit, projectPath: projectPath) } }
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
        if loadingCommit || loadingDiff {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selectedCommit {
            CommitDetailView(commit: selectedCommit, sections: commitSections)
                .id(selectedCommit.sha)
        } else if let diff, let selection {
            VStack(spacing: 0) {
                HStack {
                    Text(selection.file).font(DSFont.mono(.caption)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                Divider()
                SideBySideDiffView(diff: diff, language: language(for: selection.file))
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

    private func selectCommit(_ commit: GitCommit, projectPath: String) async {
        await MainActor.run {
            selection = nil
            diff = nil
            selectedCommit = commit
            commitSections = []
            loadingCommit = true
        }
        let raw = await GitDiffScanner.commitFullDiff(path: projectPath, sha: commit.sha) ?? ""
        let sections = UnifiedDiffParser.parseMultiFile(raw)
        await MainActor.run {
            // Ignore if the user moved on to another commit while this loaded.
            guard selectedCommit?.sha == commit.sha else { return }
            commitSections = sections
            loadingCommit = false
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

// MARK: - Commit detail (stacked all-files diff in one scroll)

private struct CommitDetailView: View {
    let commit: GitCommit
    let sections: [FileDiffSection]

    @State private var collapsed: Set<String> = []

    private var totalAdds: Int { sections.reduce(0) { $0 + $1.diff.additions } }
    private var totalDels: Int { sections.reduce(0) { $0 + $1.diff.deletions } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    if sections.count > 1 { jumpBar(proxy: proxy) }
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            // Big files start collapsed so opening a large commit stays snappy.
            collapsed = Set(sections.filter { $0.diff.rows.count > 600 }.map(\.path))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(commit.subject).font(DSFont.title)
            HStack(spacing: DSSpace.sm) {
                Text(commit.shortSha).font(DSFont.mono(.caption2)).foregroundColor(DSColor.gitMeta)
                Text("\(commit.author) · \(commit.relativeDate)")
                    .font(DSFont.micro).foregroundColor(.secondary)
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

    private func jumpBar(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpace.xs) {
                ForEach(sections) { section in
                    Button {
                        withAnimation { proxy.scrollTo(section.id, anchor: .top) }
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
