import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - DocsTabView

/// The lore docs reader: a type-grouped, searchable sidebar over every
/// `docs/<dir>/*.md` in the project, and an editorial reading pane (WKWebView)
/// with clickable `[[wikilinks]]` and a backlinks footer.
struct DocsTabView: View {
    @EnvironmentObject var store: DashboardStore
    // Canvas panels pinned to another project inject this override (see PanelContentView).
    @Environment(\.panelSelection) private var panelSelection

    @State private var groups: [LoreDocGroup] = []
    @State private var graph: LoreLinkIndex.Graph?
    @State private var selectedPath: String?
    @State private var search = ""
    @State private var collapsedDirs: Set<String> = []
    @State private var docHTML: String?
    @State private var loaded = false
    @State private var reloadToken = 0
    @State private var watcher: NotesFileWatcher?
    @State private var filePreview: FilePreviewTarget?
    @State private var claudeSheet = false
    @State private var claudeSelection: String = ""
    @State private var claudeInstruction: String = ""
    @State private var docWebViewRef: WKWebView?
    @State private var visibleCollectionDoc: String?
    @AppStorage("devdash.collectionSort") private var collectionSort = "recent"
    @State private var editMode = false  // "recent" | "alpha"

    var body: some View {
        if let project = store.project(for: panelSelection ?? store.selection) {
            content(project: project)
        } else {
            Text("Select a project to browse its docs")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(project: Project) -> some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 264)
                .background(DSColor.cardBg)
            Divider()
            reader(project: project)
        }
        .task(id: project.path) { await reload(project.path, resetSelection: true) }
        .task(id: "\(selectedPath ?? "")#\(reloadToken)#\(collectionSort)") { await render(project.path) }
        .sheet(isPresented: $claudeSheet) {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                Text("Edit with Claude")
                    .font(DSFont.title)
                if let rel = selectedPath {
                    Text(rel).font(DSFont.mono(.caption2)).foregroundStyle(.secondary)
                }
                if !claudeSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SELECTED PASSAGE").font(DSFont.micro.weight(.semibold)).foregroundStyle(.secondary)
                        ScrollView {
                            Text(claudeSelection)
                                .font(DSFont.mono(.caption2))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 90)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                }
                Text("INSTRUCTION").font(DSFont.micro.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $claudeInstruction)
                    .font(DSFont.body)
                    .frame(minHeight: 80, maxHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                HStack {
                    Spacer()
                    Button("Cancel") { claudeSheet = false }.keyboardShortcut(.cancelAction)
                    Button("Open Claude session") {
                        if let rel = selectedPath,
                           let project = store.project(for: panelSelection ?? store.selection) {
                            store.openClaudeForDoc(
                                projectPath: project.path, relPath: rel,
                                selection: claudeSelection, instruction: claudeInstruction)
                        }
                        claudeSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(claudeInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DSSpace.xl)
            .frame(width: 520)
        }
        .sheet(item: $filePreview) { target in
            let root = LoreDocsScanner.docsRoot(projectPath: project.path)
            let url = URL(fileURLWithPath: "\(root)/\(target.rel)")
            VStack(spacing: 0) {
                HStack {
                    Text(target.rel).font(DSFont.mono(.caption)).lineLimit(1)
                    Spacer()
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open in default app", systemImage: "arrow.up.forward.app") }
                    Button("Close") { filePreview = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(10)
                Divider()
                FileWebView(fileURL: url)
            }
            .frame(minWidth: 900, minHeight: 640)
        }
    }

    // MARK: Loading (all file I/O off the main actor — perf guardrail)

    private func reload(_ projectPath: String, resetSelection: Bool) async {
        let (g, gr) = await Task.detached(priority: .userInitiated) { () -> ([LoreDocGroup], LoreLinkIndex.Graph) in
            let groups = LoreDocsScanner.scan(projectPath: projectPath)
            let graph = LoreLinkIndex.build(projectPath: projectPath, dirs: groups.map(\.dir))
            return (groups, graph)
        }.value
        // Watcher-triggered reloads are unstructured Tasks — a slow scan for the
        // previous project must not land after a project switch.
        guard store.project(for: panelSelection ?? store.selection)?.path == projectPath else { return }
        groups = g
        graph = gr
        loaded = true
        let allPaths = Set(g.flatMap { $0.docs.map(\.path) })
        if resetSelection || !(selectedPath.map(allPaths.contains) ?? false) {
            selectedPath = g.first?.docs.first?.path
        }
        reloadToken &+= 1
        // Arm the watcher once per project (not per reload — its own change events
        // trigger reloads, and rearming every time would churn dispatch sources).
        // External writes — typically the lore CLI from an agent session — then
        // refresh the view live. Dirs created after this scan aren't watched until
        // the project is revisited.
        if resetSelection || watcher == nil {
            watcher = NotesFileWatcher(dirs: g.map { "\(LoreDocsScanner.docsRoot(projectPath: projectPath))/\($0.dir)" }) {
                Task { await reload(projectPath, resetSelection: false) }
            }
        }
    }

    /// Anything that isn't lore markdown renders as a raw file, not via the
    /// markdown pipeline.
    static func isAsset(_ rel: String) -> Bool { !rel.lowercased().hasSuffix(".md") }

    private func render(_ projectPath: String) async {
        guard let rel = selectedPath, !Self.isAsset(rel), let graph else { docHTML = nil; return }
        let doc = groups.flatMap(\.docs).first { $0.path == rel }
        let backlinks = graph.backlinks[rel] ?? []
        // Collection view: an anchor doc (e.g. the reading interest) renders as
        // a front cover followed by every item in its nested collection, in one
        // continuously scrollable page with scrollspy anchors.
        if let cover = doc, let sub = Self.anchoredSubgroup(for: cover, in: groups) {
            let items = Self.sortedCollection(sub.docs.filter { !$0.isFile }, by: collectionSort)
            let sort = collectionSort
            let html = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let coverLoaded = LoreDocsScanner.load(projectPath: projectPath, relPath: rel) else { return nil }
                let loadedItems: [(LoreDoc, [String: String], String)] = items.compactMap { d in
                    LoreDocsScanner.load(projectPath: projectPath, relPath: d.path).map { (d, $0.front, $0.body) }
                }
                return LoreDocHTML.collectionPage(coverRel: rel, coverDoc: cover,
                                                  coverFront: coverLoaded.front, coverBody: coverLoaded.body,
                                                  items: loadedItems, graph: graph,
                                                  backlinks: backlinks, sortLabel: sort)
            }.value
            guard selectedPath == rel, collectionSort == sort else { return }
            docHTML = html
            return
        }
        let html = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let loaded = LoreDocsScanner.load(projectPath: projectPath, relPath: rel) else { return nil }
            return LoreDocHTML.page(relPath: rel, doc: doc, front: loaded.front,
                                    body: loaded.body, graph: graph, backlinks: backlinks)
        }.value
        guard selectedPath == rel else { return }   // selection moved on mid-render
        docHTML = html
    }

    static func sortedCollection(_ docs: [LoreDoc], by sort: String) -> [LoreDoc] {
        sort == "alpha"
            ? docs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            : docs   // groups already sort newest-first
    }

    // MARK: Sidebar

    private var filteredGroups: [LoreDocGroup] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return groups }
        let q = search
        return groups.compactMap { g in
            let hits = g.docs.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q)
            }
            return hits.isEmpty ? nil : LoreDocGroup(dir: g.dir, label: g.label, docs: hits)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, DSSpace.sm)
                .padding(.vertical, DSSpace.sm)
            Divider()
            if loaded && groups.isEmpty {
                emptySidebarHint
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Self.topLevelGroups(filteredGroups)) { group in
                            sectionHeader(group)
                            // Searching auto-expands so hits are never hidden.
                            if !search.isEmpty || !collapsedDirs.contains(group.dir) {
                                ForEach(group.docs) { doc in
                                    docRow(doc)
                                    // A type dir anchored to this doc nests beneath it
                                    // (books under the reading interest).
                                    if let sub = Self.anchoredSubgroup(for: doc, in: filteredGroups) {
                                        subgroupHeader(sub)
                                        if !search.isEmpty || !collapsedDirs.contains(sub.dir) {
                                            let ordered = Self.sortedCollection(sub.docs, by: collectionSort)
                                            ForEach(Array(ordered.enumerated()), id: \.element.id) { idx, d in
                                                if d.isFile {
                                                    docRow(d).padding(.leading, 26).id(d.path)
                                                } else {
                                                    collectionRow(d, index: idx, anchorDoc: doc)
                                                        .id(d.path)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(DSSpace.sm)
                }
                .onChange(of: visibleCollectionDoc) { _, newValue in
                    if let path = newValue {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(path, anchor: .center) }
                    }
                }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: "magnifyingglass")
                .font(DSFont.label)
                .foregroundStyle(.secondary)
            TextField("Search docs", text: $search)
                .textFieldStyle(.plain)
                .font(DSFont.body)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DSFont.label)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DSSpace.sm)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DSRadius.small).fill(Color.primary.opacity(0.05)))
    }

    /// Type dirs rendered nested beneath a specific doc row instead of as
    /// top-level groups (storage stays flat — presentation only).
    /// child dir → the doc path it anchors under.
    static let nestAnchor: [String: String] = [
        "books": "interests/reading-and-books.md",
        "recipes": "interests/cooking.md",
    ]

    static func topLevelGroups(_ groups: [LoreDocGroup]) -> [LoreDocGroup] {
        let anchored = Set(nestAnchor.keys).intersection(groups.map(\.dir))
        // Only suppress a child group when its anchor doc is actually present.
        let anchorDocs = Set(groups.flatMap { $0.docs.map(\.path) })
        return groups.filter { g in
            guard anchored.contains(g.dir), let anchor = nestAnchor[g.dir] else { return true }
            return !anchorDocs.contains(anchor)
        }
    }

    static func anchoredSubgroup(for doc: LoreDoc, in groups: [LoreDocGroup]) -> LoreDocGroup? {
        guard let dir = nestAnchor.first(where: { $0.value == doc.path })?.key else { return nil }
        guard let g = groups.first(where: { $0.dir == dir }) else { return nil }
        // Items tagged `inactive` stay out of the collection (sidebar rows +
        // combined scroll); they remain reachable through the type's index table.
        let active = g.docs.filter { d in
            !(d.front["tags"] ?? "").components(separatedBy: ",")
                .contains { $0.trimmingCharacters(in: .whitespaces) == "inactive" }
        }
        return LoreDocGroup(dir: g.dir, label: g.label, docs: active)
    }

    /// A collection item row: when its cover page is open, clicking scrolls the
    /// combined view to the item (no reload); otherwise it opens the item's own
    /// page. The scrollspy-tracked row gets an accent tint.
    private func collectionRow(_ d: LoreDoc, index: Int, anchorDoc: LoreDoc) -> some View {
        let tracked = visibleCollectionDoc == d.path && selectedPath == anchorDoc.path
        return Button {
            if selectedPath == anchorDoc.path, let wv = docWebViewRef {
                wv.evaluateJavaScript(
                    "document.querySelector('section[data-path=\"" + d.path + "\"]')?.scrollIntoView({behavior:'smooth',block:'start'})",
                    completionHandler: nil)
            } else {
                selectedPath = d.path
            }
        } label: {
            docRowLabel(d)
                .padding(.leading, 26)
                .background(tracked ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)) : nil)
        }
        .buttonStyle(.plain)
    }

    private func subgroupHeader(_ group: LoreDocGroup) -> some View {
        subgroupHeaderBody(group)
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { handleFileDrop($0, into: group.dir) }
    }

    private func subgroupHeaderBody(_ group: LoreDocGroup) -> some View {
        Button {
            if collapsedDirs.contains(group.dir) { collapsedDirs.remove(group.dir) }
            else { collapsedDirs.insert(group.dir) }
        } label: {
            HStack(spacing: DSSpace.xs) {
                Image(systemName: collapsedDirs.contains(group.dir) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
                Circle()
                    .fill(DocTypeStyle.color(group.dir))
                    .frame(width: 6, height: 6)
                Text(group.label)
                    .font(DSFont.micro.weight(.semibold))
                    .tracking(0.8)
                    .foregroundColor(.secondary)
                Text(verbatim: String(group.docs.count))
                    .font(DSFont.monoDigits(.caption2))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 2) {
                    Button { collectionSort = "recent" } label: {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundColor(collectionSort == "recent" ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain).help("Sort by recent")
                    Button { collectionSort = "alpha" } label: {
                        Image(systemName: "textformat.abc")
                            .font(.system(size: 9))
                            .foregroundColor(collectionSort == "alpha" ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain).help("Sort alphabetically")
                }
            }
            .padding(.leading, 14)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Copy externally dropped files into a group's folder — every group doubles
    /// as a swipe-file bin. The dir watcher picks the copies up and reloads.
    private func handleFileDrop(_ providers: [NSItemProvider], into dir: String) -> Bool {
        guard let project = store.project(for: panelSelection ?? store.selection) else { return false }
        let root = LoreDocsScanner.docsRoot(projectPath: project.path)
        let destDir = dir == "." ? root : "\(root)/\(dir)"
        var any = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            any = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let dest = "\(destDir)/\(url.lastPathComponent)"
                guard !FileManager.default.fileExists(atPath: dest) else { return }
                try? FileManager.default.copyItem(atPath: url.path, toPath: dest)
            }
        }
        return any
    }

    private func sectionHeader(_ group: LoreDocGroup, nested: Bool = false) -> some View {
        Button {
            if collapsedDirs.contains(group.dir) { collapsedDirs.remove(group.dir) }
            else { collapsedDirs.insert(group.dir) }
        } label: {
            HStack(spacing: DSSpace.xs) {
                Circle()
                    .fill(DocTypeStyle.color(group.dir))
                    .frame(width: 7, height: 7)
                Text(group.label.uppercased())
                    .font(DSFont.sectionHeader)
                    .foregroundStyle(.secondary)
                Text("\(group.docs.count)")
                    .font(DSFont.micro)
                    .foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsedDirs.contains(group.dir) && search.isEmpty ? 0 : 90))
            }
            .padding(.horizontal, DSSpace.sm)
            .padding(.top, DSSpace.md)
            .padding(.bottom, DSSpace.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, nested ? 14 : 0)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { handleFileDrop($0, into: group.dir) }
    }

    private func docRowLabel(_ doc: LoreDoc) -> some View {
        let selected = doc.path == selectedPath
        return VStack(alignment: .leading, spacing: 2) {
            Text(doc.title)
                .font(selected ? DSFont.bodyEmphasized : DSFont.body)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: DSSpace.xs) {
                if let date = doc.date { Text(DocTypeStyle.prettyDate(date)) }
                if let status = doc.status {
                    Text(status)
                        .foregroundStyle(DocTypeStyle.statusColor(status))
                }
            }
            .font(DSFont.micro)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DSSpace.sm)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// SF symbol for a non-md asset row, by extension.
    static func assetIcon(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm":                        return "globe"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": return "photo"
        case "pdf":                                return "doc.richtext"
        case "csv", "tsv":                         return "tablecells"
        case "mov", "mp4":                         return "film"
        default:                                   return "doc"
        }
    }

    private func docRow(_ doc: LoreDoc) -> some View {
        let selected = doc.path == selectedPath
        return Button {
            selectedPath = doc.path
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DSSpace.xs) {
                    if doc.isFile {
                        Image(systemName: Self.assetIcon(doc.path))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(doc.title)
                        .font(selected ? DSFont.bodyEmphasized : DSFont.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: DSSpace.xs) {
                    if let date = doc.date { Text(DocTypeStyle.prettyDate(date)) }
                    if let status = doc.status {
                        Text(status)
                            .foregroundStyle(DocTypeStyle.statusColor(status))
                    }
                }
                .font(DSFont.micro)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DSSpace.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.small)
                    .fill(selected ? DocTypeStyle.color(doc.dir).opacity(0.14) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptySidebarHint: some View {
        VStack(spacing: DSSpace.sm) {
            Image(systemName: "books.vertical")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No lore docs")
                .font(DSFont.bodyEmphasized)
            Text("This project has no docs/ markdown yet — run `lore init` to set up a knowledge base.")
                .font(DSFont.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(DSSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Reading pane

    private func reader(project: Project) -> some View {
        VStack(spacing: 0) {
            if let rel = selectedPath {
                readerToolbar(project: project, rel: rel)
                Divider()
            }
            if let rel = selectedPath, Self.isAsset(rel) {
                // Non-md assets (html prototypes, images, pdfs) render raw.
                FileWebView(fileURL: URL(fileURLWithPath: "\(LoreDocsScanner.docsRoot(projectPath: project.path))/\(rel)"))
                    .id(rel)
            } else if editMode, let rel = selectedPath {
                DocEditPane(
                    path: "\(LoreDocsScanner.docsRoot(projectPath: project.path))/\(rel)",
                    projectPath: project.path,
                    onOpenDoc: { target in selectedPath = target })
                    .id(rel)
            } else if let html = docHTML {
                DocWebView(html: html, onOpenDoc: { target in
                    selectedPath = target
                    // Expand the target's group so the selection is visible.
                    if let dir = target.components(separatedBy: "/").first {
                        collapsedDirs.remove(dir)
                    }
                }, onOpenFile: { rel in
                    filePreview = FilePreviewTarget(rel: rel)
                }, onWebView: { docWebViewRef = $0 },
                   onVisibleSection: { visibleCollectionDoc = $0 })
            } else {
                Text(loaded ? "Select a doc to read" : "Loading…")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func readerToolbar(project: Project, rel: String) -> some View {
        let fileURL = URL(fileURLWithPath: "\(LoreDocsScanner.docsRoot(projectPath: project.path))/\(rel)")
        return HStack(spacing: DSSpace.sm) {
            Text(rel)
                .font(DSFont.mono(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            Button {
                NSWorkspace.shared.open(fileURL)
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("Open in default editor")
            if !Self.isAsset(rel) {
                Button {
                    editMode.toggle()
                    if !editMode { reloadToken += 1 }   // re-render the reader with fresh content
                } label: { Image(systemName: editMode ? "eye" : "pencil.line") }
                    .buttonStyle(.borderless)
                    .help(editMode ? "Done editing (back to reading view)" : "Edit in place (bullets edit as an outline)")
                Button {
                    claudeSelection = ""
                    claudeInstruction = ""
                    if let wv = docWebViewRef {
                        wv.evaluateJavaScript("window.getSelection().toString()") { result, _ in
                            claudeSelection = (result as? String) ?? ""
                            claudeSheet = true
                        }
                    } else {
                        claudeSheet = true
                    }
                } label: { Image(systemName: "sparkle") }
                    .buttonStyle(.borderless)
                    .help("Edit with Claude (uses your text selection if any)")
            }
            if project.framework == "Wiki" {
                Menu {
                    Button("Check-in") { store.openCoachSession(projectPath: project.path, mode: "check-in") }
                    Button("Goal design") { store.openCoachSession(projectPath: project.path, mode: "goal design") }
                    Button("Gut-check") { store.openCoachSession(projectPath: project.path, mode: "decision gut-check") }
                    Button("Season review") { store.openCoachSession(projectPath: project.path, mode: "season review") }
                } label: { Image(systemName: "figure.mind.and.body") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Coach session in the terminal drawer (evidence over advice)")
            }
        }
        .padding(.horizontal, DSSpace.md)
        .frame(height: 32)
        .background(.bar)
    }
}

// MARK: - Type styling (shared by sidebar + HTML)

enum DocTypeStyle {
    static func color(_ dir: String) -> Color {
        switch dir {
        case "devlog":    return .teal
        case "decisions": return .purple
        case "tickets":   return .orange
        case "tasks":     return .blue
        case "policies":  return .red
        case "ideas":     return .yellow
        case "notes":     return .green
        case "artifacts": return .gray
        case "kpis":      return .pink
        case "overview":  return .indigo
        default:          return .secondary
        }
    }

    /// Accent hex for the HTML page (kept in sync with `color(_:)` by eye — the
    /// CSS needs literal values it can `color-mix` into tints).
    static func hex(_ dir: String) -> String {
        switch dir {
        case "devlog":    return "#2AA8A0"
        case "decisions": return "#9569D8"
        case "tickets":   return "#E0862E"
        case "tasks":     return "#4A8FE7"
        case "policies":  return "#D65C5C"
        case "ideas":     return "#C9A227"
        case "notes":     return "#4CAF7A"
        case "artifacts": return "#8A8F98"
        case "kpis":      return "#D65C9E"
        case "overview":  return "#6B7BD6"
        default:          return "#8A8F98"
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "done", "accepted", "closed", "shipped": return DSColor.success
        case "open", "raw", "draft":                  return DSColor.warning
        case "active", "in_progress", "in-progress":  return .blue
        case "blocked", "rejected":                   return DSColor.danger
        default:                                      return .secondary
        }
    }

    /// CSS class for the status pill in the doc header.
    static func statusClass(_ status: String) -> String {
        switch status.lowercased() {
        case "done", "accepted", "closed", "shipped": return "st-done"
        case "open", "raw", "draft":                  return "st-open"
        case "active", "in_progress", "in-progress":  return "st-active"
        case "blocked", "rejected":                   return "st-blocked"
        default:                                      return "st-neutral"
        }
    }

    // Static formatters only — never allocate one in a per-file loop (guardrail).
    private static let ymd: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()
    private static let long: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM d, yyyy"
        return df
    }()

    static func prettyDate(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard let d = ymd.date(from: String(clean.prefix(10))) else { return clean }
        return long.string(from: d)
    }
}

// MARK: - LoreDocHTML

/// Builds the reading-pane page: styled frontmatter header + `Markdown.bodyHTML`
/// body (wikilinks pre-linkified to `lore://` URLs) + a backlinks footer.
enum LoreDocHTML {
    private static let wikiRE = try! NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)

    static func page(relPath: String, doc: LoreDoc?, front: [String: String], body: String,
                     graph: LoreLinkIndex.Graph, backlinks: [LoreLinkIndex.Backlink]) -> String {
        let dir = relPath.components(separatedBy: "/").first ?? ""
        let accent = DocTypeStyle.hex(dir)
        let title = front["title"].map(esc) ?? esc((relPath as NSString).lastPathComponent)
        let bodyHTML = applyTimeline(Markdown.bodyHTML(linkify(body, relPath: relPath, graph: graph)))

        var kicker = "<span class=\"type-pill\">\(esc(LoreDocsScanner.label(for: dir)))</span>"
        if let id = doc?.numericID { kicker += "<span class=\"doc-id\">#\(esc(id))</span>" }

        var meta: [String] = []
        if let date = front["date"] ?? front["created"] {
            meta.append("<span class=\"m\">\(esc(DocTypeStyle.prettyDate(date)))</span>")
        }
        if let day = front["day"] { meta.append("<span class=\"m\">Day \(esc(day))</span>") }
        if let status = front["status"] {
            meta.append("<span class=\"status \(DocTypeStyle.statusClass(status))\">\(esc(status))</span>")
        }
        for key in ["owner", "phase", "applies_to"] {
            if let v = front[key] { meta.append("<span class=\"m\">\(esc(key)): \(esc(v))</span>") }
        }
        // Tags render as legend-style dot chips (life-map look).
        if let tags = front["tags"] {
            for tag in tags.components(separatedBy: ",") {
                let t = tag.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                meta.append("<span class=\"tag\"><span class=\"tag-dot\" style=\"background:\(tagColor(t))\"></span>\(esc(t))</span>")
            }
        }

        var backlinksHTML = ""
        if !backlinks.isEmpty {
            let items = backlinks
                .sorted { $0.fromTitle < $1.fromTitle }
                .map { bl in
                    "<a class=\"backlink\" href=\"\(loreHref(bl.fromPath))\">" +
                    "<span class=\"bl-type\" style=\"color:\(DocTypeStyle.hex(bl.fromType))\">\(esc(LoreDocsScanner.label(for: bl.fromType)))</span>" +
                    "<span class=\"bl-title\">\(esc(bl.fromTitle))</span></a>"
                }
                .joined()
            backlinksHTML = "<div class=\"backlinks\"><div class=\"backlinks-title\">Linked from</div><div class=\"backlink-list\">\(items)</div></div>"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(stylesheet(accent: accent))</style>
        </head>
        <body>
        <div class="page">
          <header class="doc-header">
            <div class="kicker">\(kicker)</div>
            <h1 class="doc-title">\(title)</h1>
            \(meta.isEmpty ? "" : "<div class=\"meta\">\(meta.joined())</div>")
          </header>
          <main class="doc-body">
          \(bodyHTML)
          </main>
          \(backlinksHTML)
        </div>
        </body>
        </html>
        """
    }

    /// Deterministic legend color for a tag — hue from a stable hash.
    private static func tagColor(_ tag: String) -> String {
        let hue = tag.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360
        return "hsl(\(hue), 42%, 52%)"
    }

    private static let timelineParaRE = try! NSRegularExpression(
        pattern: #"<p><strong>((?:19|20)\d\d)</strong>\s*([\s\S]*?)</p>"#)

    /// Runs of ≥3 consecutive paragraphs opening with a bold 4-digit year
    /// (the annual-review / life-arc shape) render as a vertical timeline —
    /// year gutter, accent dot, connecting line. Pure HTML post-pass; pages
    /// without the shape are untouched.
    static func applyTimeline(_ html: String) -> String {
        let ns = html as NSString
        let matches = timelineParaRE.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 3 else { return html }
        // Group into runs of consecutive matches (only whitespace between them).
        var runs: [[NSTextCheckingResult]] = []
        var current: [NSTextCheckingResult] = []
        for m in matches {
            if let last = current.last {
                let gapLoc = last.range.location + last.range.length
                let gap = ns.substring(with: NSRange(location: gapLoc, length: m.range.location - gapLoc))
                if gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current.append(m)
                } else {
                    runs.append(current); current = [m]
                }
            } else {
                current = [m]
            }
        }
        runs.append(current)
        let qualifying = runs.filter { $0.count >= 3 }
        guard !qualifying.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for run in qualifying {
            let start = run.first!.range.location
            let end = run.last!.range.location + run.last!.range.length
            result += ns.substring(with: NSRange(location: cursor, length: start - cursor))
            var entries = ""
            for m in run {
                let year = ns.substring(with: m.range(at: 1))
                let text = ns.substring(with: m.range(at: 2))
                entries += "<div class=\"tl-entry\"><div class=\"tl-year\">\(year)</div>"
                    + "<div class=\"tl-dot\"></div><div class=\"tl-text\">\(text)</div></div>"
            }
            result += "<div class=\"timeline\">\(entries)</div>"
            cursor = end
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Pre-convert `[[wikilinks]]` to markdown links (`[title](lore://open/<path>)`)
    /// so `Markdown.bodyHTML` renders them as anchors the webview can intercept.
    /// Fence- and inline-code-aware, mirroring `LoreLinkIndex.wikilinks` — a
    /// literal `[[x]]` in code stays literal. Also prettifies task checkboxes.
    /// Resolve a relative link target against the current doc's directory,
    /// normalizing `..` segments. Returns a docsRoot-relative path.
    private static func resolveRel(_ target: String, from relPath: String) -> String {
        var parts = relPath.components(separatedBy: "/").dropLast().map { String($0) }
        for seg in target.components(separatedBy: "/") {
            if seg == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if seg != "." && !seg.isEmpty { parts.append(seg) }
        }
        return parts.joined(separator: "/")
    }

    private static let mdLinkRE = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)

    /// Rewrite relative markdown links so they stay inside the app: `.md`
    /// targets route to the docs pane (lore://open), everything else to the
    /// in-app file viewer (lore://file). Absolute URLs are left alone.
    private static func rewriteRelativeLinks(_ s: String, relPath: String) -> String {
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in mdLinkRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let target = ns.substring(with: m.range(at: 1))
            if target.hasPrefix("lore://") || target.contains("://") || target.hasPrefix("#")
                || target.hasPrefix("mailto:") || target.hasPrefix("/") {
                result += ns.substring(with: m.range)
            } else {
                let clean = target.components(separatedBy: "#").first ?? target
                let resolved = resolveRel(clean, from: relPath)
                if clean.lowercased().hasSuffix(".md") {
                    result += "](\(loreHref(resolved)))"
                } else {
                    result += "](\(fileHref(resolved)))"
                }
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func linkify(_ body: String, relPath: String, graph: LoreLinkIndex.Graph) -> String {
        var out: [String] = []
        var inFence = false
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle(); out.append(line); continue
            }
            if inFence { out.append(line); continue }
            // Split on backticks; odd segments are inline code — leave untouched.
            let segments = line.components(separatedBy: "`")
            let rebuilt = segments.enumerated().map { i, seg -> String in
                guard i % 2 == 0 else { return seg }
                var s = replaceWiki(seg, graph: graph)
                s = rewriteRelativeLinks(s, relPath: relPath)
                if let r = s.range(of: "- [ ] ") { s = s.replacingCharacters(in: r, with: "- ☐ ") }
                if let r = s.range(of: "- [x] ") { s = s.replacingCharacters(in: r, with: "- ☑ ") }
                return s
            }
            out.append(rebuilt.joined(separator: "`"))
        }
        return out.joined(separator: "\n")
    }

    private static func replaceWiki(_ s: String, graph: LoreLinkIndex.Graph) -> String {
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in wikiRE.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let token = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if let target = graph.resolve[token.lowercased()] {
                // Square brackets in a title would terminate the markdown link
                // early (the minimal converter has no escape syntax) — soften them.
                let text = target.title
                    .replacingOccurrences(of: "[", with: "(")
                    .replacingOccurrences(of: "]", with: ")")
                result += "[\(text)](\(loreHref(target.path)))"
            } else {
                result += ns.substring(with: m.range)   // unresolved — keep literal
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// A front-cover doc followed by its collection, one scrollable page.
    /// Each item gets a stable anchor (`sec-<n>`) and an IntersectionObserver
    /// posts the topmost visible item to Swift (`scrollspy` handler) so the
    /// sidebar can track the reader's position.
    static func collectionPage(coverRel: String, coverDoc: LoreDoc?, coverFront: [String: String],
                               coverBody: String, items: [(LoreDoc, [String: String], String)],
                               graph: LoreLinkIndex.Graph, backlinks: [LoreLinkIndex.Backlink],
                               sortLabel: String) -> String {
        let base = page(relPath: coverRel, doc: coverDoc, front: coverFront,
                        body: coverBody, graph: graph, backlinks: [])
        var sections = ""
        for (idx, item) in items.enumerated() {
            let (d, front, body) = item
            // Drop a leading `# Title` — the section header renders the title.
            var trimmedBody = body
            let lines = trimmedBody.components(separatedBy: "\n")
            if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               first.hasPrefix("# ") {
                if let idx0 = lines.firstIndex(of: first) {
                    trimmedBody = lines[(idx0 + 1)...].joined(separator: "\n")
                }
            }
            let bodyHTML = Markdown.bodyHTML(linkify(trimmedBody, relPath: d.path, graph: graph))
            var chips = ""
            if let status = front["status"] { chips += "<span class=\"chip\">\(esc(status))</span>" }
            if let author = front["author"], !author.isEmpty { chips += "<span class=\"chip mut\">\(esc(author))</span>" }
            if let fin = front["finished"], !fin.isEmpty { chips += "<span class=\"chip mut\">finished \(esc(fin))</span>" }
            sections += """
            <section class="coll-item" id="sec-\(idx)" data-path="\(esc(d.path))">
              <h2 class="coll-title">\(esc(d.title))</h2>
              <div class="coll-chips">\(chips)</div>
              \(bodyHTML)
            </section>
            """
        }
        let collCSS = """
        <style>
        .coll-item { border-top: 1px solid color-mix(in srgb, currentColor 12%, transparent);
                     padding: 1.6em 0 0.8em; margin-top: 1.6em; }
        .coll-title { margin: 0 0 0.2em; }
        .coll-chips { margin-bottom: 0.7em; }
        .coll-chips .chip { display:inline-block; font-size:10.5px; letter-spacing:.6px;
            text-transform:uppercase; padding:1px 8px; border-radius:9px; margin-right:6px;
            background: color-mix(in srgb, currentColor 8%, transparent); }
        .coll-chips .chip.mut { text-transform:none; letter-spacing:0; }
        </style>
        """
        let spyJS = """
        <script>
        const obs = new IntersectionObserver((entries) => {
          const vis = entries.filter(e => e.isIntersecting)
            .sort((a,b) => a.boundingClientRect.top - b.boundingClientRect.top);
          if (vis.length && window.webkit?.messageHandlers?.scrollspy) {
            window.webkit.messageHandlers.scrollspy.postMessage(vis[0].target.dataset.path);
          }
        }, { rootMargin: "0px 0px -70% 0px" });
        document.querySelectorAll(".coll-item").forEach(s => obs.observe(s));
        </script>
        """
        var out = base
        if out.contains("</main>") {
            out = out.replacingOccurrences(of: "</main>", with: sections + "</main>")
            out = out.replacingOccurrences(of: "</body>", with: collCSS + spyJS + "</body>")
        } else {
            out = out.replacingOccurrences(of: "</body>", with: collCSS + "<div class=\"doc-body\">" + sections + "</div>" + spyJS + "</body>")
        }
        return out
    }

    /// `lore://open/<encoded>` — parens/spaces must be encoded or the markdown
    /// link regex (`[^\)]+`) truncates the URL.
    private static func loreHref(_ relPath: String) -> String {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._/")
        return "lore://open/" + (relPath.addingPercentEncoding(withAllowedCharacters: cs) ?? relPath)
    }

    private static func fileHref(_ relPath: String) -> String {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._/")
        return "lore://file/" + (relPath.addingPercentEncoding(withAllowedCharacters: cs) ?? relPath)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func stylesheet(accent: String) -> String {
        """
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            font-size: 15px;
            line-height: 1.75;
            color: #26262a;
            background: #fdfdfc;
            -webkit-font-smoothing: antialiased;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #e6e6e9; background: #1d1e21; }
        }
        ::selection { background: color-mix(in srgb, \(accent) 25%, transparent); }
        .page { max-width: 760px; margin: 0 auto; padding: 44px 48px 96px; }

        /* ---- header ---- */
        .doc-header {
            padding-bottom: 22px;
            margin-bottom: 30px;
            border-bottom: 1px solid color-mix(in srgb, currentColor 12%, transparent);
        }
        .kicker { display: flex; align-items: center; gap: 10px; }
        .type-pill {
            font-size: 10.5px; font-weight: 650; letter-spacing: 0.09em; text-transform: uppercase;
            color: \(accent);
            background: color-mix(in srgb, \(accent) 13%, transparent);
            padding: 3px 10px; border-radius: 999px;
        }
        .doc-id { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 11.5px; opacity: 0.45; }
        .doc-title {
            font-family: ui-serif, "New York", Georgia, serif;
            font-size: 31px; font-weight: 600; line-height: 1.18; letter-spacing: -0.015em;
            margin: 12px 0 10px;
        }
        .meta { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 16px; font-size: 12.5px; opacity: 0.72; }
        .status {
            font-size: 11px; font-weight: 600; padding: 1.5px 9px; border-radius: 999px;
            text-transform: lowercase;
        }
        .st-done    { color: #2f9e5f; background: color-mix(in srgb, #2f9e5f 14%, transparent); }
        .st-open    { color: #c07a1a; background: color-mix(in srgb, #c07a1a 14%, transparent); }
        .st-active  { color: #3f7fd6; background: color-mix(in srgb, #3f7fd6 14%, transparent); }
        .st-blocked { color: #cf4d4d; background: color-mix(in srgb, #cf4d4d 14%, transparent); }
        .st-neutral { color: color-mix(in srgb, currentColor 70%, transparent); background: color-mix(in srgb, currentColor 9%, transparent); }
        .tag { display: inline-flex; align-items: center; gap: 5px; font-size: 12px; }
        .tag-dot { width: 7px; height: 7px; border-radius: 50%; display: inline-block; }

        /* ---- body ---- */
        .doc-body h1, .doc-body h2, .doc-body h3, .doc-body h4 {
            font-family: ui-serif, "New York", Georgia, serif;
            font-weight: 600; line-height: 1.25; letter-spacing: -0.01em;
            margin: 1.9em 0 0.55em;
        }
        .doc-body h1 { font-size: 24px; }
        .doc-body h2 {
            font-size: 20.5px;
            padding-bottom: 0.25em;
            border-bottom: 1px solid color-mix(in srgb, currentColor 9%, transparent);
        }
        .doc-body h3 { font-size: 17px; }
        .doc-body p { margin: 0.55em 0 1em; }
        .doc-body > p:first-child { font-size: 16px; }   /* TL;DR lede reads slightly larger */
        .doc-body a { color: \(accent); text-decoration: none; border-bottom: 1px solid color-mix(in srgb, \(accent) 35%, transparent); }
        .doc-body a:hover { border-bottom-color: \(accent); }
        .doc-body a[href^="lore:"] {
            border-bottom-style: dotted;
            background: color-mix(in srgb, \(accent) 7%, transparent);
            border-radius: 3px; padding: 0 2px;
        }
        .doc-body code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.86em;
            background: color-mix(in srgb, currentColor 8%, transparent);
            padding: 0.13em 0.38em; border-radius: 4px;
        }
        .doc-body pre {
            background: color-mix(in srgb, currentColor 6%, transparent);
            border: 1px solid color-mix(in srgb, currentColor 8%, transparent);
            padding: 14px 16px; border-radius: 10px;
            overflow-x: auto; font-size: 12.5px; line-height: 1.55;
        }
        .doc-body pre code { background: transparent; padding: 0; font-size: 12.5px; }
        .doc-body blockquote {
            margin: 0.8em 0; padding: 0.5em 1.1em;
            border-left: 3px solid \(accent);
            background: color-mix(in srgb, \(accent) 5%, transparent);
            border-radius: 0 8px 8px 0;
            color: color-mix(in srgb, currentColor 82%, transparent);
        }
        /* The page's first quote reads as a hero pull-quote (life-map look). */
        .doc-body > blockquote:first-of-type {
            font-family: ui-serif, "New York", Georgia, serif;
            font-style: italic; font-size: 18.5px; line-height: 1.55;
            background: transparent;
            border-left-width: 4px;
            padding: 0.2em 1.2em;
            color: color-mix(in srgb, \(accent) 72%, currentColor);
        }

        /* ---- timeline (runs of bold-year paragraphs) ---- */
        .timeline { margin: 1.4em 0 1.8em; }
        .tl-entry {
            display: grid; grid-template-columns: 52px 16px 1fr;
            gap: 0 12px; position: relative; padding-bottom: 1.15em;
        }
        .tl-year {
            font-family: ui-serif, "New York", Georgia, serif;
            font-size: 16px; font-weight: 650; text-align: right;
            line-height: 1.5; opacity: 0.85;
        }
        .tl-dot { position: relative; }
        .tl-dot::before {
            content: ""; position: absolute; left: 4px; top: 8px;
            width: 8px; height: 8px; border-radius: 50%;
            background: \(accent);
        }
        .tl-dot::after {
            content: ""; position: absolute; left: 7.5px; top: 22px; bottom: -4px;
            width: 1px; background: color-mix(in srgb, currentColor 16%, transparent);
        }
        .tl-entry:last-child { padding-bottom: 0.2em; }
        .tl-entry:last-child .tl-dot::after { display: none; }
        .tl-text { line-height: 1.7; }
        .doc-body table {
            border-collapse: collapse; width: 100%; margin: 0.7em 0 1.1em;
            font-size: 13px;
        }
        .doc-body th, .doc-body td {
            text-align: left; padding: 6px 12px;
            border-bottom: 1px solid color-mix(in srgb, currentColor 12%, transparent);
        }
        .doc-body th {
            font-weight: 600; font-size: 11.5px; letter-spacing: 0.4px;
            text-transform: uppercase;
            color: color-mix(in srgb, currentColor 60%, transparent);
            border-bottom: 2px solid color-mix(in srgb, \(accent) 45%, transparent);
        }
        .doc-body tr:hover td { background: color-mix(in srgb, currentColor 3%, transparent); }
        .doc-body ul, .doc-body ol { padding-left: 1.4em; margin: 0.45em 0 1em; }
        .doc-body li { margin: 0.22em 0; }
        .doc-body hr { border: none; border-top: 1px solid color-mix(in srgb, currentColor 12%, transparent); margin: 2.2em 0; }
        .doc-body strong { font-weight: 650; }

        /* ---- backlinks ---- */
        .backlinks {
            margin-top: 56px; padding-top: 18px;
            border-top: 1px solid color-mix(in srgb, currentColor 12%, transparent);
        }
        .backlinks-title {
            font-size: 10.5px; font-weight: 650; letter-spacing: 0.09em; text-transform: uppercase;
            opacity: 0.55; margin-bottom: 12px;
        }
        .backlink-list { display: flex; flex-direction: column; gap: 6px; }
        .backlink {
            display: flex; align-items: baseline; gap: 10px;
            padding: 8px 12px; border-radius: 8px;
            background: color-mix(in srgb, currentColor 4%, transparent);
            color: inherit; text-decoration: none;
        }
        .backlink:hover { background: color-mix(in srgb, currentColor 8%, transparent); }
        .bl-type { font-size: 10px; font-weight: 650; letter-spacing: 0.07em; text-transform: uppercase; flex-shrink: 0; }
        .bl-title { font-size: 13.5px; }
        """
    }
}

// MARK: - DocWebView

/// WKWebView for the reading pane. Intercepts `lore://open/<path>` (wikilinks,
/// backlinks) into in-app navigation and sends real URLs to the default browser.
private struct DocWebView: NSViewRepresentable {
    let html: String
    let onOpenDoc: (String) -> Void
    var onOpenFile: ((String) -> Void)? = nil
    var onWebView: ((WKWebView) -> Void)? = nil
    var onVisibleSection: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "scrollspy")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        DispatchQueue.main.async { onWebView?(wv) }
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.onOpenDoc = onOpenDoc
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.onVisibleSection = onVisibleSection
        // Only reload when the page actually changed — updateNSView also fires
        // for unrelated state changes, and reloading resets scroll position.
        let hash = html.hashValue
        if context.coordinator.lastHTMLHash != hash {
            context.coordinator.lastHTMLHash = hash
            wv.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "scrollspy", let path = message.body as? String else { return }
            let cb = onVisibleSection
            DispatchQueue.main.async { cb?(path) }
        }

        var onOpenDoc: ((String) -> Void)?
        var onOpenFile: ((String) -> Void)?
        var onVisibleSection: ((String) -> Void)?
        var lastHTMLHash: Int = 0

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "lore" {
                let abs = url.absoluteString
                if abs.hasPrefix("lore://open/"),
                   let rel = String(abs.dropFirst("lore://open/".count)).removingPercentEncoding {
                    let open = onOpenDoc
                    DispatchQueue.main.async { open?(rel) }
                } else if abs.hasPrefix("lore://file/"),
                          let rel = String(abs.dropFirst("lore://file/".count)).removingPercentEncoding {
                    let openFile = onOpenFile
                    DispatchQueue.main.async { openFile?(rel) }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}


/// A non-markdown file linked from a doc (html, image, pdf) — shown in-app.
struct FilePreviewTarget: Identifiable {
    let rel: String
    var id: String { rel }
}

// MARK: - In-place doc editing

/// Live editing for a wiki/lore doc. Pure-bullet bodies open as the Roam-style
/// outliner (OutlinerView); anything with headings/paragraphs/tables opens as a
/// raw markdown editor — DayOutline.parse is lossy on mixed content, so the
/// outliner is only offered when a parse→serialize roundtrip is safe.
/// Debounced autosave (0.6s) + flush on close/switch; frontmatter preserved.
struct DocEditPane: View {
    let path: String
    let projectPath: String
    var onOpenDoc: (String) -> Void = { _ in }

    @State private var frontmatter = ""
    @State private var nodes: [DayNode] = []
    @State private var rawText = ""
    @State private var useOutline = false
    @State private var loadedBody: String?
    @State private var loadedPath: String?
    @State private var saveWork: DispatchWorkItem?
    @FocusState private var rawFocused: Bool

    var body: some View {
        Group {
            if useOutline {
                ScrollView {
                    OutlinerView(nodes: $nodes, projectPath: projectPath,
                                 onOpenDoc: onOpenDoc, autofocus: true)
                        .padding(DSSpace.lg)
                }
                .onChange(of: nodes) { _, _ in scheduleSave() }
            } else {
                TextEditor(text: $rawText)
                    .font(DSFont.mono(.body))
                    .scrollContentBackground(.hidden)
                    .padding(DSSpace.md)
                    .focused($rawFocused)
                    .onChange(of: rawText) { _, _ in scheduleSave() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            load()
            // Land the user in a blinking cursor, matching the outliner's
            // autofocus. The delay lets the TextEditor attach to the window
            // first — focusing in the same tick silently no-ops.
            if !useOutline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { rawFocused = true }
            }
        }
        .onDisappear { flushNow() }
    }

    private static func splitFrontmatter(_ raw: String) -> (fm: String, body: String) {
        guard raw.hasPrefix("---\n"),
              let end = raw.range(of: "\n---", range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex)
        else { return ("", raw) }
        let fm = String(raw[..<end.upperBound])
        var body = String(raw[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return (fm, body)
    }

    /// Outline-safe = every non-empty line is a `- ` list item (any indent).
    private static func isPureOutline(_ body: String) -> Bool {
        let lines = body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return true }
        return lines.allSatisfy { $0.drop(while: { $0 == " " }).hasPrefix("- ") }
    }

    private func load() {
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let parts = Self.splitFrontmatter(raw)
        frontmatter = parts.fm
        let body = parts.body.trimmingCharacters(in: .newlines)
        useOutline = Self.isPureOutline(body)
        if useOutline {
            var parsed = DayOutline.parse(body)
            if parsed.isEmpty { parsed = [DayNode(text: "")] }
            nodes = parsed
            loadedBody = DayOutline.serialize(parsed)
        } else {
            rawText = body
            loadedBody = body
        }
        loadedPath = path
    }

    private var currentBody: String { useOutline ? DayOutline.serialize(nodes) : rawText }

    private func scheduleSave() {
        guard loadedPath == path else { return }
        let body = currentBody
        guard body != loadedBody else { return }
        loadedBody = body
        saveWork?.cancel()
        let fm = frontmatter, target = path
        let item = DispatchWorkItem {
            let text = fm.isEmpty ? body : fm + "\n\n" + body + "\n"
            try? text.write(toFile: target, atomically: true, encoding: .utf8)
        }
        saveWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func flushNow() {
        guard let work = saveWork, let target = loadedPath else { return }
        work.cancel()
        saveWork = nil
        let fm = frontmatter, body = currentBody
        let text = fm.isEmpty ? body : fm + "\n\n" + body + "\n"
        try? text.write(toFile: target, atomically: true, encoding: .utf8)
    }
}
