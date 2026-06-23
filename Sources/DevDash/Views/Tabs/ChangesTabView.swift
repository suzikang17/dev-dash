import SwiftUI
import AppKit
import DevDashCore

struct ChangesTabView: View {
    @EnvironmentObject var store: DashboardStore

    @State private var unstaged: [ChangedFile] = []
    @State private var staged: [ChangedFile] = []
    @State private var commits: [GitCommit] = []
    @State private var expandedSha: String? = nil
    @State private var commitFiles: [ChangedFile] = []

    @State private var selection: DiffSelection? = nil
    @State private var diff: FileDiff? = nil
    @State private var loadingDiff = false
    @State private var revertTarget: ChangedFile? = nil

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
                    Task { await GitDiffScanner.unstage(path: projectPath, file: file.path); await refresh(projectPath) }
                }
            } else {
                rowButton("plus.circle", help: "Stage") {
                    Task { await GitDiffScanner.stage(path: projectPath, file: file.path); await refresh(projectPath) }
                }
                rowButton("arrow.uturn.backward", help: "Discard") { revertTarget = file }
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
        .contentShape(Rectangle())
        .onTapGesture {
            selection = DiffSelection(file: file.path, source: source, untracked: file.isUntracked)
            Task { await loadDiff(projectPath) }
        }
    }

    @ViewBuilder
    private func historyGroup(projectPath: String) -> some View {
        SectionHeader("History")
        ForEach(commits) { commit in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: expandedSha == commit.sha ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Text(commit.shortSha).font(DSFont.mono(.caption2)).foregroundColor(DSColor.gitMeta)
                    Text(commit.subject).font(DSFont.label).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(commit.relativeDate).font(DSFont.micro).foregroundColor(.secondary)
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .contentShape(Rectangle())
                .onTapGesture { Task { await toggleCommit(commit, projectPath: projectPath) } }

                if expandedSha == commit.sha {
                    ForEach(commitFiles) { file in
                        let isSel = selection?.file == file.path && selection?.source == .commit(commit.sha)
                        HStack(spacing: 6) {
                            Text(file.stagedStatus.map(String.init) ?? "M")
                                .font(DSFont.monoDigits(.caption2)).foregroundColor(.secondary).frame(width: 14)
                            Text(file.name).font(DSFont.label).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2).padding(.leading, 22).padding(.trailing, 6)
                        .background(isSel ? Color.accentColor.opacity(0.15) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = DiffSelection(file: file.path, source: .commit(commit.sha), untracked: false)
                            Task { await loadDiff(projectPath) }
                        }
                    }
                }
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
        if loadingDiff {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("Select a file to view its diff")
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

    private func toggleCommit(_ commit: GitCommit, projectPath: String) async {
        if expandedSha == commit.sha {
            await MainActor.run { expandedSha = nil; commitFiles = [] }
            return
        }
        let files = await GitDiffScanner.commitFiles(path: projectPath, sha: commit.sha)
        await MainActor.run { expandedSha = commit.sha; commitFiles = files }
    }

    private func doRevert(_ projectPath: String, _ file: ChangedFile) async {
        _ = await GitDiffScanner.revert(path: projectPath, file: file.path, untracked: file.isUntracked)
        await MainActor.run { revertTarget = nil }
        await refresh(projectPath)
    }
}
