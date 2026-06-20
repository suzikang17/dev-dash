import SwiftUI
import AppKit

/// Renders the living product document — a single HTML page with internal
/// tabs (Overview / Roadmap / Initiatives / Goals / Ideas / PRDs / Docs)
/// at `docs/devdash/index.html`. Generated from JSON state + sibling .md
/// files; viewed via WKWebView.
struct ProductTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var lastRegenAt: Date?
    @State private var reloadToken: Int = 0
    @State private var showLinkedSidebar: Bool = false
    /// Whether the generated index.html exists. Cached so `content` doesn't hit
    /// disk (`fileExists`) on every render; updated whenever `regen` runs.
    @State private var docExists: Bool = false

    var body: some View {
        if let project = store.project(for: store.selection) {
            VStack(spacing: 0) {
                toolbar(project: project)
                Divider()
                content(project: project)
            }
            .onAppear { regen(project: project) }
            .onChange(of: project.path) { _, _ in regen(project: project) }
        } else {
            Text("Select a project to view its living document")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func toolbar(project: Project) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .foregroundColor(.accentColor)
            Text("Living document")
                .font(.system(size: 13, weight: .semibold))
            Text("docs/devdash/index.html")
                .font(.system(size: 11).monospaced())
                .foregroundColor(.secondary)
            Spacer()
            if let at = lastRegenAt {
                Text("Regenerated \(timeAgo(at))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Button {
                regen(project: project)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Regenerate the living doc")
            Button {
                let path = ProductDocGenerator.indexPath(for: project.path)
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in default browser")
            Menu {
                Section("Edit shell sections") {
                    Button("Edit overview") { openFile("\(project.path)/docs/devdash/sections/overview.html") }
                    Button("Edit goals & KPIs") { openFile("\(project.path)/docs/devdash/sections/goals.html") }
                    Button("Edit ideas") { openFile("\(project.path)/docs/devdash/sections/ideas.html") }
                }
                Divider()
                Section("New artifact") {
                    ForEach(ProductDocGenerator.DocType.allCases) { dt in
                        Button(dt.label) { spawnTemplate(dt, project: project) }
                    }
                    Divider()
                    Button("Blank document…") {
                        newBlankDoc(at: "\(project.path)/docs/devdash/documents", suggested: "doc.html", project: project)
                    }
                }
            } label: {
                Image(systemName: "pencil.and.outline")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
            .help("Edit sections / scaffold a new HTML artifact")
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showLinkedSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .symbolVariant(showLinkedSidebar ? .fill : .none)
            }
            .buttonStyle(.borderless)
            .help(showLinkedSidebar ? "Hide linked tasks" : "Show linked tasks")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func content(project: Project) -> some View {
        let path = ProductDocGenerator.indexPath(for: project.path)
        let docsRoot = URL(fileURLWithPath: ProductDocGenerator.folderPath(for: project.path))
        HStack(spacing: 0) {
            Group {
                if docExists {
                    ProductWebView(
                        url: URL(fileURLWithPath: path),
                        docsRoot: docsRoot,
                        reloadToken: reloadToken,
                        onSave: { rel, html in
                            saveSection(projectPath: project.path, rel: rel, html: html)
                        },
                        onSaveAlpine: { rel, state in
                            saveAlpineSection(projectPath: project.path, rel: rel, state: state)
                        },
                        onSaveLore: { absPath, markdown in
                            saveLoreDoc(absPath: absPath, markdownBody: markdown)
                        },
                        onAction: { payload in
                            handleAction(project: project, payload: payload)
                        },
                        onSearchItems: { [weak store] query in
                            guard let store = store else { return [] }
                            let tasks = store.tasksV2(for: project.path)
                            let q = query.lowercased()
                            return tasks
                                .filter { q.isEmpty || $0.title.lowercased().contains(q) }
                                .prefix(8)
                                .map { t in
                                    ["id": t.id, "title": t.title,
                                     "type": "task", "status": t.status.rawValue]
                                }
                        },
                        onCreateTask: { [weak store] title, linkedDocPath in
                            guard let store = store else { return [:] }
                            guard let task = try? TaskStore.add(
                                projectPath: project.path,
                                title: title,
                                source: .local,
                                linkedDocPath: linkedDocPath
                            ) else { return [:] }
                            store.projectTasks[project.path] = TaskStore.read(project.path)
                            store.regenerateRoadmap(for: project.path)
                            return ["id": task.id, "title": task.title, "status": task.status.rawValue]
                        }
                    )
                    .onAppear { store.activeDocPath = path }
                    .onChange(of: path) { _, p in store.activeDocPath = p }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Generating…").foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showLinkedSidebar {
                Divider()
                LinkedTasksSidebarView(
                    projectPath: project.path,
                    docPath: store.activeDocPath ?? path
                )
                .environmentObject(store)
            }
        }
    }

    /// Bridge handler: write the edited HTML back to its source file.
    /// Doesn't trigger a regen — that would clobber the cursor mid-edit.
    /// Refreshes the queryable manifest so cross-doc filters stay current.
    private func saveSection(projectPath: String, rel: String, html: String) {
        let target = "\(projectPath)/docs/devdash/\(rel)"
        let dir = (target as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? html.write(toFile: target, atomically: true, encoding: .utf8)
        DocIndexGenerator.generate(projectPath: projectPath)
    }

    /// SPIKE: write an inline-edited lore doc back to its `.md`, losslessly.
    /// Preserves the file's existing frontmatter and replaces only the body with
    /// the edited markdown, then best-effort re-indexes via the lore CLI. This is
    /// the write path of "lore as the living doc's engine".
    @discardableResult
    private func saveLoreDoc(absPath: String, markdownBody: String) -> String {
        guard let existing = try? String(contentsOfFile: absPath, encoding: .utf8) else {
            return Markdown.bodyHTML(markdownBody)
        }
        // Preserve the leading `--- … ---` frontmatter verbatim; swap only the body.
        // Detect fences by EXACT trimmed "---" (tolerate a leading blank/BOM line),
        // and if frontmatter opens but never closes, refuse to write rather than
        // silently drop it (which would corrupt the doc).
        let lines = existing.components(separatedBy: "\n")
        var frontmatter = ""
        if let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
           lines[..<open].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            guard let close = lines[(open + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "---"
            }) else {
                return Markdown.bodyHTML(markdownBody)   // unterminated frontmatter — abort
            }
            frontmatter = lines[0...close].joined(separator: "\n")
        }
        let body = markdownBody.hasSuffix("\n") ? markdownBody : markdownBody + "\n"
        let content = frontmatter.isEmpty ? body : frontmatter + "\n" + body
        try? content.write(toFile: absPath, atomically: true, encoding: .utf8)

        // Re-index through lore. Map the plural folder (docs/decisions) to the
        // singular lore type (decision) — the spike passed the plural folder name,
        // which lore rejects with "unknown type", so reindex silently never ran.
        let dir = ((absPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let loreType = LoreSection.byDir(dir)?.loreType ?? dir
        if let projectRoot = absPath.range(of: "/docs/").map({ String(absPath[..<$0.lowerBound]) }) {
            let bin = Self.loreBinary
            Task.detached(priority: .utility) {
                _ = await ShellRunner.run(bin, args: ["reindex", loreType], cwd: projectRoot)
            }
        }
        // Hand the freshly-rendered body HTML back so the card's formatted view
        // updates the moment we save (no full regen needed).
        return Markdown.bodyHTML(markdownBody)
    }

    /// Resolve the lore binary — PATH inside the app host process isn't reliable.
    private static let loreBinary: String = {
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/lore").path
        return FileManager.default.isExecutableFile(atPath: local) ? local : "lore"
    }()

    /// Bridge handler for Alpine-managed sections (currently triage). The browser
    /// sends just the JSON state — we regex-replace the contents of the
    /// <script id="triage-state">…</script> block in the file. If the file or
    /// block is missing, regenerate the entire artifact from the triage template
    /// scaffold and embed the new state.
    private func saveAlpineSection(projectPath: String, rel: String, state: String) {
        let target = "\(projectPath)/docs/devdash/\(rel)"
        let dir = (target as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
        if !existing.isEmpty,
           let updated = replaceTriageStateBlock(in: existing, with: state) {
            try? updated.write(toFile: target, atomically: true, encoding: .utf8)
            DocIndexGenerator.generate(projectPath: projectPath)
            return
        }

        // Fallback: file is missing or block is malformed — regenerate from the template
        // and patch the state in.
        let projectName = (projectPath as NSString).lastPathComponent
        let scaffold = ProductDocGenerator.template(.triageBoard, projectName: projectName)
        if let withState = replaceTriageStateBlock(in: scaffold, with: state) {
            try? withState.write(toFile: target, atomically: true, encoding: .utf8)
            DocIndexGenerator.generate(projectPath: projectPath)
        }
    }

    /// Non-greedy regex replace of the contents of <script ... id="triage-state" ...>...</script>.
    /// Returns nil if the block isn't found.
    private func replaceTriageStateBlock(in html: String, with state: String) -> String? {
        let pattern = #"(<script[^>]*id="triage-state"[^>]*>)([\s\S]*?)(</script>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard regex.firstMatch(in: html, options: [], range: range) != nil else { return nil }
        // Pretty-print the JSON for readability on disk.
        let pretty = prettyJSON(state) ?? state
        let replacement = "$1\n\(pretty)\n$3"
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: replacement)
    }

    private func prettyJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: pretty, encoding: .utf8) else { return nil }
        return str
    }

    /// Bridge handler: route data-action clicks to native side-effects.
    private func handleAction(project: Project, payload: [String: Any]) {
        guard let action = payload["action"] as? String else { return }
        switch action {
        case "open-file":
            if let path = payload["path"] as? String {
                openFile(path)
            }
        case "open-task":
            store.detailTab = .tasks
        case "regenerate":
            store.regenerateRoadmap(for: project.path)
            lastRegenAt = Date()
        case "promote-idea":
            if let title = payload["title"] as? String {
                store.addTask(projectPath: project.path, title: title)
            }
        default:
            break
        }
    }

    private func regen(project: Project) {
        let template = store.template(for: project.path)
        let meta = store.meta(for: project.path)
        let tasks = store.tasksV2(for: project.path)
        _ = ProductDocGenerator.generate(
            projectName: project.name,
            projectPath: project.path,
            meta: meta,
            template: template,
            tasks: tasks,
            status: store.projectStatus(for: project.path)
        )
        lastRegenAt = Date()
        reloadToken &+= 1   // force WKWebView reload so latest HTML + JS land
        docExists = FileManager.default.fileExists(atPath: ProductDocGenerator.indexPath(for: project.path))
    }

    private func openFile(_ path: String) {
        store.pendingFilePath = path
        store.detailTab = .files
    }

    /// Scaffold a rich HTML artifact from a template type, then open it.
    private func spawnTemplate(_ type: ProductDocGenerator.DocType, project: Project) {
        let folder = "\(project.path)/docs/devdash/\(type.folder)"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = uniquePath(folder: folder, slug: type.defaultSlug)
        let html = ProductDocGenerator.template(type, projectName: project.name)
        try? html.write(toFile: target, atomically: true, encoding: .utf8)
        // Re-render so the embedded folder card lists it immediately.
        store.regenerateRoadmap(for: project.path)
        openFile(target)
    }

    private func newBlankDoc(at folder: String, suggested: String, project: Project) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = uniquePath(folder: folder, slug: suggested)
        let title = (suggested as NSString).deletingPathExtension
        let stub = """
        <div class="doc-head">
          <h2>\(title)</h2>
          <span class="doc-status meta">Edit me at <code>\(target)</code></span>
        </div>

        <div class="card">
          <p>Write your content here.</p>
        </div>
        """
        try? stub.write(toFile: target, atomically: true, encoding: .utf8)
        store.regenerateRoadmap(for: project.path)
        openFile(target)
    }

    /// Return a path that doesn't collide with existing files in the folder
    /// by appending -2, -3, … if needed.
    private func uniquePath(folder: String, slug: String) -> String {
        let target = "\(folder)/\(slug)"
        if !FileManager.default.fileExists(atPath: target) { return target }
        let base = (slug as NSString).deletingPathExtension
        let ext  = (slug as NSString).pathExtension
        for i in 2...100 {
            let candidate = "\(folder)/\(base)-\(i).\(ext)"
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return target  // fall back; will overwrite
    }
}
