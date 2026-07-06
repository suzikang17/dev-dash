import SwiftUI
import WebKit

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
        .task(id: "\(selectedPath ?? "")#\(reloadToken)") { await render(project.path) }
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
            watcher = NotesFileWatcher(dirs: g.map { "\(projectPath)/docs/\($0.dir)" }) {
                Task { await reload(projectPath, resetSelection: false) }
            }
        }
    }

    private func render(_ projectPath: String) async {
        guard let rel = selectedPath, let graph else { docHTML = nil; return }
        let doc = groups.flatMap(\.docs).first { $0.path == rel }
        let backlinks = graph.backlinks[rel] ?? []
        let html = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let loaded = LoreDocsScanner.load(projectPath: projectPath, relPath: rel) else { return nil }
            return LoreDocHTML.page(relPath: rel, doc: doc, front: loaded.front,
                                    body: loaded.body, graph: graph, backlinks: backlinks)
        }.value
        guard selectedPath == rel else { return }   // selection moved on mid-render
        docHTML = html
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredGroups) { group in
                            sectionHeader(group)
                            // Searching auto-expands so hits are never hidden.
                            if !search.isEmpty || !collapsedDirs.contains(group.dir) {
                                ForEach(group.docs) { doc in docRow(doc) }
                            }
                        }
                    }
                    .padding(DSSpace.sm)
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

    private func sectionHeader(_ group: LoreDocGroup) -> some View {
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
    }

    private func docRow(_ doc: LoreDoc) -> some View {
        let selected = doc.path == selectedPath
        return Button {
            selectedPath = doc.path
        } label: {
            VStack(alignment: .leading, spacing: 2) {
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
            if let html = docHTML {
                DocWebView(html: html) { target in
                    selectedPath = target
                    // Expand the target's group so the selection is visible.
                    if let dir = target.components(separatedBy: "/").first {
                        collapsedDirs.remove(dir)
                    }
                }
            } else {
                Text(loaded ? "Select a doc to read" : "Loading…")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func readerToolbar(project: Project, rel: String) -> some View {
        let fileURL = URL(fileURLWithPath: "\(project.path)/docs/\(rel)")
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
        let bodyHTML = Markdown.bodyHTML(linkify(body, graph: graph))

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

    /// Pre-convert `[[wikilinks]]` to markdown links (`[title](lore://open/<path>)`)
    /// so `Markdown.bodyHTML` renders them as anchors the webview can intercept.
    /// Fence- and inline-code-aware, mirroring `LoreLinkIndex.wikilinks` — a
    /// literal `[[x]]` in code stays literal. Also prettifies task checkboxes.
    private static func linkify(_ body: String, graph: LoreLinkIndex.Graph) -> String {
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

    /// `lore://open/<encoded>` — parens/spaces must be encoded or the markdown
    /// link regex (`[^\)]+`) truncates the URL.
    private static func loreHref(_ relPath: String) -> String {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._/")
        return "lore://open/" + (relPath.addingPercentEncoding(withAllowedCharacters: cs) ?? relPath)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.onOpenDoc = onOpenDoc
        // Only reload when the page actually changed — updateNSView also fires
        // for unrelated state changes, and reloading resets scroll position.
        let hash = html.hashValue
        if context.coordinator.lastHTMLHash != hash {
            context.coordinator.lastHTMLHash = hash
            wv.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onOpenDoc: ((String) -> Void)?
        var lastHTMLHash: Int = 0

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "lore" {
                let prefix = "lore://open/"
                let abs = url.absoluteString
                if abs.hasPrefix(prefix), let rel = String(abs.dropFirst(prefix.count)).removingPercentEncoding {
                    let open = onOpenDoc
                    DispatchQueue.main.async { open?(rel) }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
