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
    /// Single-flights lore create/delete so rapid clicks can't race the lore CLI's
    /// sequential-id allocation (which would clobber freshly-created docs).
    @State private var loreMutating = false
    /// loreType of the currently-visible lore section (reported by the webview),
    /// so the native ⌘⌥N new-doc shortcut knows where to create. nil = not on a
    /// lore section.
    @State private var activeLoreType: String?

    var body: some View {
        if let project = store.project(for: store.selection) {
            VStack(spacing: 0) {
                toolbar(project: project)
                Divider()
                content(project: project)
            }
            .onAppear { regen(project: project) }
            .onChange(of: project.path) { _, _ in regen(project: project) }
            .onChange(of: store.docRegenToken) { _, _ in reloadToken &+= 1 }
            .background {
                // Native ⌘⌥N → new doc in the active lore section. Native (not
                // webview) so it fires even when the document isn't first responder.
                Button("") {
                    if let lt = activeLoreType { createLoreDoc(project: project, loreType: lt) }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .frame(width: 0, height: 0)
                .opacity(0)
            }
        } else {
            Text("Select a project to view its living document")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func toolbar(project: Project) -> some View {
        HStack(spacing: DSSpace.sm) {
            Image(systemName: "doc.richtext")
                .foregroundColor(.accentColor)
            Text("Living document")
                .font(DSFont.body.weight(.semibold))
            Text("docs/devdash/index.html")
                .font(DSFont.mono(.caption2))
                .foregroundColor(.secondary)
            Spacer()
            if let at = lastRegenAt {
                Text("Regenerated \(timeAgo(at))")
                    .font(DSFont.monoDigits(.caption2))
                    .foregroundColor(.secondary)
            }
            Button {
                regen(project: project)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Regenerate the living doc")
            .accessibilityLabel("Regenerate the living doc")
            Button {
                let path = ProductDocGenerator.indexPath(for: project.path)
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in default browser")
            .accessibilityLabel("Open in default browser")
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
            .accessibilityLabel("Edit sections / scaffold a new HTML artifact")
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showLinkedSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .symbolVariant(showLinkedSidebar ? .fill : .none)
            }
            .buttonStyle(.borderless)
            .help(showLinkedSidebar ? "Hide linked tasks" : "Show linked tasks")
            .accessibilityLabel(showLinkedSidebar ? "Hide linked tasks" : "Show linked tasks")
        }
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.sm)
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
                            saveLoreDoc(projectPath: project.path, absPath: absPath, markdownBody: markdown)
                        },
                        onSaveKPI: { absPath, fields in
                            saveKPIFields(projectPath: project.path, absPath: absPath, fields: fields)
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
                    VStack(spacing: DSSpace.sm) {
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
    private func saveSection(projectPath: String, rel: String, html: String) {
        let docsRoot = "\(projectPath)/docs/devdash"
        guard let target = containedPath("\(docsRoot)/\(rel)", within: docsRoot) else { return }
        let dir = (target as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? html.write(toFile: target, atomically: true, encoding: .utf8)
    }

    /// Reject page-supplied paths that escape `root`. The living-doc WKWebView is
    /// editable and its HTML can be injected, so bridge writes/deletes must not
    /// trust the paths it hands back (path traversal → arbitrary file write).
    private func containedPath(_ candidate: String, within root: String) -> String? {
        let resolved = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        return (resolved == base || resolved.hasPrefix(base + "/")) ? resolved : nil
    }

    /// SPIKE: write an inline-edited lore doc back to its `.md`, losslessly.
    /// Preserves the file's existing frontmatter and replaces only the body with
    /// the edited markdown, then best-effort re-indexes via the lore CLI. This is
    /// the write path of "lore as the living doc's engine".
    @discardableResult
    private func saveLoreDoc(projectPath: String, absPath rawPath: String, markdownBody: String) -> (html: String, warning: String?) {
        // Containment: the page hands back the target path — never write outside docs/.
        guard let absPath = containedPath(rawPath, within: "\(projectPath)/docs") else {
            return (Markdown.bodyHTML(markdownBody), "not saved: path is outside docs/")
        }
        guard let existing = try? String(contentsOfFile: absPath, encoding: .utf8) else {
            return (Markdown.bodyHTML(markdownBody), nil)
        }
        // Normalize away a BOM + CRLF before fence detection — otherwise the first
        // line reads "\u{FEFF}---" or "---\r", the exact-match fence check misses,
        // and the frontmatter is silently dropped on write (data loss).
        let normalized = existing
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Preserve the leading `--- … ---` frontmatter verbatim; swap only the body.
        let lines = normalized.components(separatedBy: "\n")
        var frontmatter = ""
        if let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
           lines[..<open].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            guard let close = lines[(open + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "---"
            }) else {
                // Frontmatter opens but never closes — refuse to write (would corrupt)
                // AND surface it, so the green "saved" flash doesn't imply a phantom save.
                return (Markdown.bodyHTML(markdownBody), "not saved: frontmatter fences (---) are malformed")
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

        // Validation feedback. An inline edit only touches the BODY (frontmatter is
        // preserved above), so the only thing it can break is a `sections`-schema
        // doc missing a required H2 — and `lore validate` checks frontmatter only,
        // not sections. So we check required H2s in Swift. Never blocks the save.
        var warning: String?
        if let section = LoreSection.byDir(dir), !section.bodyIsFree {
            let missing = section.requiredSections.filter { !markdownBody.contains("## \($0)") }
            if !missing.isEmpty { warning = "missing section: " + missing.joined(separator: ", ") }
        }
        // Hand back the freshly-rendered body HTML (live re-render) + any warning.
        return (Markdown.bodyHTML(markdownBody), warning)
    }

    /// Resolve the lore binary — PATH inside the app host process isn't reliable.
    private static let loreBinary: String = {
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/lore").path
        return FileManager.default.isExecutableFile(atPath: local) ? local : "lore"
    }()

    /// Write KPI frontmatter fields (current/target/unit) back to the doc, keeping
    /// the rest of the frontmatter + body intact, then reindex. Numbers written
    /// bare, unit quoted; an empty/invalid value removes the key. Same path-
    /// containment + CRLF/BOM safety as saveLoreDoc.
    private func saveKPIFields(projectPath: String, absPath rawPath: String, fields: [String: String]) {
        guard let absPath = containedPath(rawPath, within: "\(projectPath)/docs"),
              let existing = try? String(contentsOfFile: absPath, encoding: .utf8) else { return }
        let normalized = existing
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              lines[..<open].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return }   // KPI docs always have frontmatter — bail rather than corrupt

        var fm = Array(lines[(open + 1)..<close])
        func encode(_ key: String, _ value: String) -> String? {
            let v = value.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { return nil }
            if key == "current" || key == "target" {
                return Double(v) != nil ? "\(key): \(v)" : nil   // only persist valid numbers
            }
            return "\(key): \"\(v.replacingOccurrences(of: "\"", with: "'"))\""
        }
        for key in ["current", "target", "unit"] {
            guard let raw = fields[key] else { continue }
            let encoded = encode(key, raw)
            if let idx = fm.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }) {
                if let e = encoded { fm[idx] = e } else { fm.remove(at: idx) }
            } else if let e = encoded {
                fm.append(e)
            }
        }
        let pre = lines[0..<open].joined(separator: "\n")
        let body = (close + 1) < lines.count ? lines[(close + 1)...].joined(separator: "\n") : ""
        var out = pre.isEmpty ? "" : pre + "\n"
        out += "---\n" + fm.joined(separator: "\n") + "\n---\n" + body
        if !out.hasSuffix("\n") { out += "\n" }
        try? out.write(toFile: absPath, atomically: true, encoding: .utf8)

        if let projectRoot = absPath.range(of: "/docs/").map({ String(absPath[..<$0.lowerBound]) }) {
            let bin = Self.loreBinary
            Task.detached(priority: .utility) {
                _ = await ShellRunner.run(bin, args: ["reindex", "kpi"], cwd: projectRoot)
            }
        }
    }

    /// Bridge handler for Alpine-managed sections (currently triage). The browser
    /// sends just the JSON state — we regex-replace the contents of the
    /// <script id="triage-state">…</script> block in the file. If the file or
    /// block is missing, regenerate the entire artifact from the triage template
    /// scaffold and embed the new state.
    private func saveAlpineSection(projectPath: String, rel: String, state: String) {
        let docsRoot = "\(projectPath)/docs/devdash"
        guard let target = containedPath("\(docsRoot)/\(rel)", within: docsRoot) else { return }
        let dir = (target as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
        if !existing.isEmpty,
           let updated = replaceTriageStateBlock(in: existing, with: state) {
            try? updated.write(toFile: target, atomically: true, encoding: .utf8)
            return
        }

        // Fallback: file is missing or block is malformed — regenerate from the template
        // and patch the state in.
        let projectName = (projectPath as NSString).lastPathComponent
        let scaffold = ProductDocGenerator.template(.triageBoard, projectName: projectName)
        if let withState = replaceTriageStateBlock(in: scaffold, with: state) {
            try? withState.write(toFile: target, atomically: true, encoding: .utf8)
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
            store.tabStore.detailTab = .tasks
        case "regenerate":
            store.regenerateRoadmap(for: project.path)
            lastRegenAt = Date()
        case "promote-idea":
            if let title = payload["title"] as? String {
                store.addTask(projectPath: project.path, title: title)
            }
        case "lore-new":
            if let loreType = payload["loreType"] as? String {
                createLoreDoc(project: project, loreType: loreType)
            }
        case "lore-delete":
            if let file = payload["loreFile"] as? String {
                deleteLoreDoc(project: project, absPath: file)
            }
        case "lore-section-active":
            let t = payload["loreType"] as? String
            activeLoreType = (t?.isEmpty ?? true) ? nil : t
        default:
            break
        }
    }

    /// Author a new lore doc from the living document. `lore add` alone omits
    /// required fields (the doc would fail validation), so we pass them via
    /// `--field`: per-type `newDocFields` plus `date` for `sections` schemas.
    private func createLoreDoc(project: Project, loreType: String) {
        guard !loreMutating else { return }
        guard let section = LoreSection.all.first(where: { $0.loreType == loreType }) else { return }
        loreMutating = true
        let dir = "\(project.path)/docs/\(section.dir)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var args = ["add", loreType, "--title", "Untitled"]
        for f in section.newDocFields { args += ["--field", f] }
        if !section.bodyIsFree {
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            args += ["--field", "date=\(fmt.string(from: Date()))"]
        }
        let bin = Self.loreBinary
        Task {
            _ = await ShellRunner.run(bin, args: args, cwd: project.path)
            _ = await ShellRunner.run(bin, args: ["reindex", loreType], cwd: project.path)
            await MainActor.run { regen(project: project); loreMutating = false }
        }
    }

    /// Delete a lore doc from the living document, then reindex + regen.
    private func deleteLoreDoc(project: Project, absPath rawPath: String) {
        guard !loreMutating else { return }
        guard let absPath = containedPath(rawPath, within: "\(project.path)/docs") else { return }
        loreMutating = true
        try? FileManager.default.removeItem(atPath: absPath)
        let dir = ((absPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let loreType = LoreSection.byDir(dir)?.loreType ?? dir
        let bin = Self.loreBinary
        Task {
            _ = await ShellRunner.run(bin, args: ["reindex", loreType], cwd: project.path)
            await MainActor.run { regen(project: project); loreMutating = false }
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
        store.tabStore.detailTab = .files
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
