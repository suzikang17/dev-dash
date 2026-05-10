import SwiftUI
import AppKit

struct FilesTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var rootNode: FileNode?
    @State private var selectedPath: String?
    @State private var loadingTreePath: String?

    var body: some View {
        if let project = store.project(for: store.selection) {
            VStack(spacing: 0) {
                if let running = store.runningTask(for: project.path), !running.liveFiles.isEmpty {
                    LiveFilesSection(task: running)
                }
                HSplitView {
                    treePane(project: project)
                        .frame(minWidth: 200, idealWidth: 280, maxWidth: 480)
                        .background(Color(NSColor.controlBackgroundColor))
                    contentPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.textBackgroundColor))
                }
                .onAppear {
                    loadTree(for: project.path)
                    consumePendingFile()
                }
                .onChange(of: project.path) { _, newPath in loadTree(for: newPath) }
                .onChange(of: store.pendingFilePath) { _, _ in consumePendingFile() }
            }
        } else {
            Text("Select a project to browse its files")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func consumePendingFile() {
        guard let path = store.pendingFilePath else { return }
        selectedPath = path
        store.pendingFilePath = nil
    }

    private func loadTree(for path: String) {
        if loadingTreePath == path { return }
        loadingTreePath = path
        rootNode = nil
        selectedPath = nil
        Task.detached {
            let node = FileTreeScanner.loadTree(root: path)
            await MainActor.run {
                if loadingTreePath == path {
                    rootNode = node
                }
            }
        }
    }

    @ViewBuilder
    private func treePane(project: Project) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.secondary)
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()

            if let root = rootNode, let kids = root.children {
                List(selection: Binding(
                    get: { selectedPath },
                    set: { selectedPath = $0 }
                )) {
                    OutlineGroup(kids, children: \.children) { node in
                        HStack(spacing: 6) {
                            Image(systemName: FileTreeScanner.icon(for: node.name, isDirectory: node.isDirectory))
                                .foregroundColor(node.isDirectory ? .accentColor : .secondary)
                                .font(.system(size: 12))
                                .frame(width: 14)
                            Text(node.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                        .tag(node.path)
                    }
                }
                .listStyle(.sidebar)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var contentPane: some View {
        if let path = selectedPath {
            FileContentView(path: path)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("Pick a file from the tree")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FileContentView: View {
    let path: String
    @State private var content: FileTreeScanner.FileContent?
    @State private var loadedPath: String?
    @State private var renderMode: RenderMode = .nvim
    @State private var editing = false
    @State private var draft: String = ""
    @State private var saveError: String?

    enum RenderMode: String, CaseIterable, Identifiable {
        case nvim, source, rendered
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nvim: return "nvim"
            case .source: return "Source"
            case .rendered: return "Preview"
            }
        }
    }

    private var originalText: String? {
        if case .text(let t)? = content { return t }
        return nil
    }
    private var isDirty: Bool { editing && draft != (originalText ?? "") }
    private var canEdit: Bool {
        if case .text? = content { return true }
        return false
    }

    private var ext: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
    private var isHtml: Bool { ["html", "htm", "svg"].contains(ext) }
    private var isMarkdown: Bool { ["md", "markdown", "mdx"].contains(ext) }
    private var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff"].contains(ext) }
    private var hasRenderer: Bool { isHtml || isMarkdown || isImage }
    private var useRendered: Bool { renderMode == .rendered }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: FileTreeScanner.icon(for: URL(fileURLWithPath: path).lastPathComponent, isDirectory: false))
                    .foregroundColor(.secondary)
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                Text(DevRoots.shortenPath(path))
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if isDirty {
                    Text("Modified")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                }
                Spacer()

                if !editing {
                    Picker("View", selection: $renderMode) {
                        ForEach(RenderMode.allCases) { mode in
                            // Hide Preview unless the file actually has a renderer
                            if mode != .rendered || hasRenderer {
                                Text(mode.label).tag(mode)
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: hasRenderer ? 260 : 200)
                }

                if renderMode == .nvim {
                    // nvim is modal — no edit toggle needed, vim handles save/quit itself
                    EmptyView()
                } else if editing {
                    Button("Cancel") {
                        editing = false
                        draft = ""
                        saveError = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        save()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
                } else if canEdit {
                    Button {
                        if let t = originalText {
                            draft = t
                            editing = true
                            saveError = nil
                        }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit (⌘E)")
                    .keyboardShortcut("e", modifiers: .command)
                }

                Menu {
                    Button("Open in nvim") { ExternalEditor.openInTerminal(path: path, command: "nvim") }
                    Button("Open in vim")  { ExternalEditor.openInTerminal(path: path, command: "vim") }
                    Divider()
                    Button("Open in Cursor")  { ExternalEditor.openWith(path: path, app: "Cursor") }
                    Button("Open in VS Code") { ExternalEditor.openWith(path: path, app: "Visual Studio Code") }
                    Button("Open in Zed")     { ExternalEditor.openWith(path: path, app: "Zed") }
                    Divider()
                    Button("Open in default app") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
                .help("Open externally")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            if let err = saveError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(err).font(.system(size: 12)).foregroundColor(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
            }

            Divider()

            if editing {
                CodeEditor(
                    text: $draft,
                    language: SyntaxHighlighter.Language.detect(from: ext)
                )
                .background(Color(NSColor.textBackgroundColor))
            } else if renderMode == .nvim {
                if let term = EmbeddedTerminal.neovim(filePath: path, readOnly: true) {
                    term
                        .background(Color.black)
                        .id(path)
                } else {
                    placeholder("nvim not found", subtitle: "Install via brew install neovim")
                }
            } else {
                renderedView
            }
        }
        .onAppear { load() }
        .onChange(of: path) { _, _ in
            editing = false
            draft = ""
            saveError = nil
            load()
        }
    }

    private func save() {
        do {
            try draft.write(toFile: path, atomically: true, encoding: .utf8)
            // Reload so `content` reflects the saved file
            content = .text(draft)
            editing = false
            draft = ""
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var renderedView: some View {
        if useRendered, isImage {
            if let img = NSImage(contentsOfFile: path) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                }
                .background(Color(NSColor.windowBackgroundColor))
            } else {
                placeholder("Couldn't load image", subtitle: path)
            }
        } else if useRendered, isHtml {
            FileWebView(fileURL: URL(fileURLWithPath: path))
        } else if useRendered, isMarkdown, case .text(let raw)? = content {
            FileWebView(
                html: Markdown.toHTML(raw),
                baseURL: URL(fileURLWithPath: path).deletingLastPathComponent()
            )
        } else {
            switch content {
            case .text(let text):
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case .binary(let size):
                placeholder("Binary file", subtitle: byteCountFormatted(size))
            case .tooLarge(let size):
                placeholder("File too large", subtitle: "\(byteCountFormatted(size)) — open in another app")
            case .unreadable(let msg):
                placeholder("Couldn't read file", subtitle: msg)
            case .none:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func load() {
        if loadedPath == path { return }
        loadedPath = path
        content = nil
        Task.detached {
            let result = FileTreeScanner.readFile(at: path)
            await MainActor.run {
                if loadedPath == path { content = result }
            }
        }
    }

    @ViewBuilder
    private func placeholder(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(subtitle).foregroundColor(.secondary).font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func byteCountFormatted(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

private struct LiveFilesSection: View {
    let task: ClaudeTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Label("Live · \(task.currentPhase ?? "Running")", systemImage: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.blue)
                Spacer()
                Text(verbatim: "\(task.liveFiles.count) files")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.blue.opacity(0.08))

            ForEach(Array(task.liveFiles.suffix(20))) { event in
                HStack(spacing: 8) {
                    Image(systemName: event.operation.systemImage)
                        .font(.system(size: 10))
                        .foregroundColor(event.operation == .read ? .secondary : .orange)
                        .frame(width: 14)
                    Text(URL(fileURLWithPath: event.path).lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Text(event.operation.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
                Divider()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.3), lineWidth: 0.5))
        .padding(10)
    }
}
