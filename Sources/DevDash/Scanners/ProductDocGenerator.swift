import Foundation

/// Renders the project's living product document as a tabbed HTML page at
/// `docs/devdash/index.html`. Pulls content from sibling markdown files
/// (one-pager.md, goals.md, ideas.md, prds/*.md, etc.) and from JSON state
/// (current roadmap, initiatives derived from top-level tasks).
///
/// Stub markdown files are scaffolded on first generation so each tab has
/// a starting point. The HTML wraps everything with vanilla JS tab nav so
/// it works in any browser without a build step.
enum ProductDocGenerator {
    static let folderRel = "docs/devdash"
    static let indexName = "index.html"
    static let header = "<!-- managed by devdash — content comes from sibling .md files; this file is regenerated -->"

    static func folderPath(for projectPath: String) -> String {
        "\(projectPath)/\(folderRel)"
    }

    static func indexPath(for projectPath: String) -> String {
        "\(folderPath(for: projectPath))/\(indexName)"
    }

    /// Tabs the living doc surfaces. Order is the rendered tab order.
    static let tabs: [DocTab] = [
        .init(id: "overview",     label: "Overview",     source: .onePagerMd),
        .init(id: "roadmap",      label: "Roadmap",      source: .roadmapMd),
        .init(id: "initiatives",  label: "Initiatives",  source: .initiativesGenerated),
        .init(id: "goals",        label: "Goals & KPIs", source: .goalsMd),
        .init(id: "ideas",        label: "Ideas",        source: .ideasMd),
        .init(id: "prds",         label: "PRDs",         source: .prdsFolder),
        .init(id: "documents",    label: "Documents",    source: .documentsFolder)
    ]

    struct DocTab {
        let id: String
        let label: String
        let source: TabSource
    }

    enum TabSource {
        case onePagerMd
        case roadmapMd
        case initiativesGenerated
        case goalsMd
        case ideasMd
        case prdsFolder
        case documentsFolder
    }

    @discardableResult
    static func generate(
        projectName: String,
        projectPath: String,
        meta: ProjectMeta,
        template: LaunchTemplate?,
        tasks: [TaskItem]
    ) -> String? {
        let folder = folderPath(for: projectPath)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(folder)/prds", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(folder)/documents", withIntermediateDirectories: true)

        // Scaffold stub markdown files where missing.
        scaffold(at: "\(folder)/one-pager.md", with: stub(.onePager(projectName: projectName)))
        scaffold(at: "\(folder)/goals.md", with: stub(.goals(projectName: projectName)))
        scaffold(at: "\(folder)/ideas.md", with: stub(.ideas))

        // Render each tab.
        var sections: [String] = []
        for tab in tabs {
            let body = renderTab(tab, projectPath: projectPath, projectName: projectName,
                                 meta: meta, template: template, tasks: tasks)
            let active = (tab.id == "overview") ? " active" : ""
            sections.append("""
              <section id="tab-\(tab.id)" class="tab-pane\(active)">
                \(body)
              </section>
            """)
        }

        let nav = tabs.map { t in
            let active = t.id == "overview" ? " active" : ""
            return "<button class=\"tab\(active)\" data-tab=\"\(t.id)\">\(escapeHTML(t.label))</button>"
        }.joined(separator: "\n      ")

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        \(header)
        <meta charset="utf-8">
        <title>\(escapeHTML(projectName)) — Product</title>
        <style>
          :root { --bg: #0f1115; --fg: #e8e8ec; --muted: #9aa0a8; --accent: #5ac8fa;
                  --border: #23262d; --card: #181a1f; --code: #1c1f26; }
          @media (prefers-color-scheme: light) {
            :root { --bg: #ffffff; --fg: #1c1c1e; --muted: #6e6e73; --accent: #007aff;
                    --border: #e5e5ea; --card: #f7f7f9; --code: #f1f3f5; }
          }
          html, body { background: var(--bg); color: var(--fg); margin: 0; padding: 0;
                       font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", sans-serif;
                       line-height: 1.55; }
          .wrap { max-width: 920px; margin: 0 auto; padding: 24px 28px 80px; }
          h1 { font-size: 22px; margin: 0 0 4px; }
          .crumbs { color: var(--muted); font-size: 12px; margin-bottom: 18px; }
          nav.tabs { display: flex; gap: 6px; flex-wrap: wrap; border-bottom: 1px solid var(--border);
                     margin-bottom: 22px; padding-bottom: 0; position: sticky; top: 0; background: var(--bg);
                     z-index: 5; padding-top: 4px; }
          nav.tabs .tab { background: transparent; color: var(--muted); border: 0;
                          padding: 8px 12px; font: inherit; cursor: pointer; border-radius: 6px 6px 0 0;
                          border-bottom: 2px solid transparent; }
          nav.tabs .tab:hover { color: var(--fg); }
          nav.tabs .tab.active { color: var(--accent); border-bottom-color: var(--accent); font-weight: 600; }
          .tab-pane { display: none; }
          .tab-pane.active { display: block; }
          h2 { font-size: 18px; margin-top: 32px; margin-bottom: 8px; }
          h3 { font-size: 15px; margin-top: 22px; margin-bottom: 6px; }
          p { margin: 8px 0; }
          a { color: var(--accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
          code, pre { background: var(--code); border-radius: 4px; }
          code { padding: 1px 5px; font-size: 12px; }
          pre { padding: 10px 12px; overflow-x: auto; font-size: 12px; }
          ul { padding-left: 22px; }
          li { margin: 3px 0; }
          blockquote { border-left: 3px solid var(--border); padding: 4px 12px; color: var(--muted);
                       margin: 6px 0; }
          .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
                  padding: 14px 18px; margin: 12px 0; }
          .pill { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px;
                  background: var(--card); border: 1px solid var(--border); color: var(--muted); }
          .pill.done { color: #2ecc71; border-color: rgba(46,204,113,0.4); }
          .pill.current { color: var(--accent); border-color: rgba(90,200,250,0.4); }
          .pill.pending { color: var(--muted); }
          .file-list { display: grid; gap: 8px; }
          .file-link { display: flex; justify-content: space-between; align-items: center;
                       padding: 10px 14px; background: var(--card); border: 1px solid var(--border);
                       border-radius: 8px; }
          .meta { color: var(--muted); font-size: 12px; }
          table { border-collapse: collapse; width: 100%; margin: 10px 0; font-size: 13px; }
          th, td { padding: 6px 10px; border-bottom: 1px solid var(--border); text-align: left; }
          th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase;
               letter-spacing: 0.5px; }
          .empty { color: var(--muted); font-style: italic; padding: 14px 0; }
        </style>
        </head>
        <body>
          <div class="wrap">
            <h1>\(escapeHTML(projectName))</h1>
            <div class="crumbs">
              \(template.map { "Methodology: <strong>\(escapeHTML($0.name))</strong>" } ?? "No template applied")
              \(meta.currentStageId.flatMap { stageId in
                template?.stages.first { $0.id == stageId }.map {
                  " · Stage: <strong>\(escapeHTML($0.title))</strong>"
                }
              } ?? "")
            </div>
            <nav class="tabs">
              \(nav)
            </nav>
        \(sections.joined(separator: "\n"))
          </div>
          <script>
            (function() {
              var btns = document.querySelectorAll('nav.tabs .tab');
              var panes = document.querySelectorAll('.tab-pane');
              btns.forEach(function(b) {
                b.addEventListener('click', function() {
                  btns.forEach(function(x) { x.classList.remove('active'); });
                  panes.forEach(function(p) { p.classList.remove('active'); });
                  b.classList.add('active');
                  var t = document.getElementById('tab-' + b.dataset.tab);
                  if (t) t.classList.add('active');
                  if (history && history.replaceState) {
                    history.replaceState(null, '', '#' + b.dataset.tab);
                  }
                });
              });
              // Open from hash if present
              var hash = (location.hash || '').replace('#', '');
              if (hash) {
                var b = document.querySelector('nav.tabs .tab[data-tab="' + hash + '"]');
                if (b) b.click();
              }
            })();
          </script>
        </body>
        </html>
        """

        let path = indexPath(for: projectPath)
        do {
            try html.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    // MARK: - Tab content

    private static func renderTab(
        _ tab: DocTab,
        projectPath: String,
        projectName: String,
        meta: ProjectMeta,
        template: LaunchTemplate?,
        tasks: [TaskItem]
    ) -> String {
        switch tab.source {
        case .onePagerMd:
            return renderMarkdownFile("\(folderPath(for: projectPath))/one-pager.md")

        case .roadmapMd:
            // Reuse RoadmapGenerator rendering; if no template, show a helpful prompt.
            guard let template = template else {
                return "<p class=\"empty\">No template applied. Apply one in the Tasks tab to start tracking.</p>"
            }
            let md = RoadmapGenerator.render(projectName: projectName, meta: meta, template: template, tasks: tasks)
            return Markdown.toHTML(md)

        case .initiativesGenerated:
            return renderInitiatives(tasks: tasks)

        case .goalsMd:
            return renderMarkdownFile("\(folderPath(for: projectPath))/goals.md")

        case .ideasMd:
            return renderMarkdownFile("\(folderPath(for: projectPath))/ideas.md")

        case .prdsFolder:
            return renderFolderListing("\(folderPath(for: projectPath))/prds",
                                       emptyMsg: "No PRDs yet. Add markdown files to docs/devdash/prds/.")

        case .documentsFolder:
            return renderFolderListing("\(folderPath(for: projectPath))/documents",
                                       emptyMsg: "No documents yet. Drop architecture notes, decision logs, etc. into docs/devdash/documents/.")
        }
    }

    private static func renderMarkdownFile(_ path: String) -> String {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "<p class=\"empty\">No content yet. Edit \(escapeHTML((path as NSString).lastPathComponent)) to fill this section.</p>"
        }
        return Markdown.toHTML(raw)
    }

    private static func renderFolderListing(_ folder: String, emptyMsg: String) -> String {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folder) else {
            return "<p class=\"empty\">\(escapeHTML(emptyMsg))</p>"
        }
        let mdFiles = files.filter { $0.hasSuffix(".md") }.sorted()
        if mdFiles.isEmpty {
            return "<p class=\"empty\">\(escapeHTML(emptyMsg))</p>"
        }
        var sections: [String] = []
        sections.append("<div class=\"file-list\">")
        for f in mdFiles {
            let path = "\(folder)/\(f)"
            let title = extractTitle(of: path) ?? (f as NSString).deletingPathExtension
            sections.append("""
              <details class="card">
                <summary><strong>\(escapeHTML(title))</strong> <span class="meta">\(escapeHTML(f))</span></summary>
                <div style="margin-top:10px">\(renderMarkdownFile(path))</div>
              </details>
            """)
        }
        sections.append("</div>")
        return sections.joined(separator: "\n")
    }

    private static func renderInitiatives(tasks: [TaskItem]) -> String {
        let initiatives = tasks.filter { t in
            t.parentId == nil && tasks.contains(where: { $0.parentId == t.id })
        }
        if initiatives.isEmpty {
            return "<p class=\"empty\">No initiatives yet. Top-level tasks with children become initiatives — group related tasks under a parent in the Tasks tab.</p>"
        }
        var out: [String] = []
        for init_ in initiatives {
            let children = tasks.filter { $0.parentId == init_.id }
            let doneCount = children.filter { $0.status == .done }.count
            out.append("<div class=\"card\">")
            out.append("<h3>\(escapeHTML(init_.title))</h3>")
            out.append("<p class=\"meta\">\(doneCount)/\(children.count) tasks complete · \(escapeHTML(init_.category.label))</p>")
            if let notes = init_.notes, !notes.isEmpty {
                out.append("<p>\(escapeHTML(notes))</p>")
            }
            out.append("<table>")
            out.append("<thead><tr><th>Status</th><th>Task</th><th>Category</th></tr></thead><tbody>")
            for c in children {
                let badge: String
                switch c.status {
                case .done:       badge = "<span class=\"pill done\">Done</span>"
                case .inProgress: badge = "<span class=\"pill current\">In progress</span>"
                case .skipped:    badge = "<span class=\"pill\">Skipped</span>"
                case .open:       badge = "<span class=\"pill pending\">Open</span>"
                }
                out.append("<tr><td>\(badge)</td><td>\(escapeHTML(c.title))</td><td class=\"meta\">\(escapeHTML(c.category.label))</td></tr>")
            }
            out.append("</tbody></table>")
            out.append("</div>")
        }
        return out.joined(separator: "\n")
    }

    private static func extractTitle(of path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Stubs

    private enum Stub {
        case onePager(projectName: String)
        case goals(projectName: String)
        case ideas
    }

    private static func stub(_ kind: Stub) -> String {
        switch kind {
        case .onePager(let name):
            return """
            # \(name) — One-pager

            ## What is it?
            _One sentence: what does this project do?_

            ## Who's it for?
            _Specific. Role + situation._

            ## Why now?
            _What's changed that makes this the right time?_

            ## What it is *not*
            _Out-of-scope. The features you're consciously not building._

            ## How will we know it's working?
            _Activation / retention / revenue / qualitative signal._
            """
        case .goals(let name):
            return """
            # \(name) — Goals & KPIs

            ## North-star metric
            _The one number that tells you the project is healthy._

            ## Quarter goals
            - _Goal 1_
            - _Goal 2_
            - _Goal 3_

            ## Tracked KPIs
            | Metric | Current | Target | Notes |
            | --- | --- | --- | --- |
            | _e.g. weekly active users_ | _?_ | _?_ | _?_ |
            """
        case .ideas:
            return """
            # Ideas

            _Parking lot for things you don't want to lose track of but aren't ready to commit to. Promote to a task or PRD when an idea is ripe._

            ## Maybe later
            - _Idea 1_
            - _Idea 2_
            """
        }
    }

    private static func scaffold(at path: String, with content: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Escape

    private static func escapeHTML(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }
}
