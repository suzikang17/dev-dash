import Foundation

/// Renders the project's living product document at `docs/devdash/index.html`.
/// Section content lives as standalone .html files (sections/*.html, prds/*.html,
/// documents/*.html) and gets composed into the tabbed shell. HTML is the
/// authoring format — no markdown round-trip.
///
/// Stub HTML files are scaffolded on first generation so each tab has a
/// starting point. Generated sections (roadmap, initiatives) are written as
/// HTML directly into `sections/*.html` and overwritten each regen.
enum ProductDocGenerator {
    static let folderRel = "docs/devdash"
    static let indexName = "index.html"
    static let header = "<!-- managed by devdash — content comes from sibling .html files; this file is regenerated -->"

    static func folderPath(for projectPath: String) -> String {
        "\(projectPath)/\(folderRel)"
    }

    static func indexPath(for projectPath: String) -> String {
        "\(folderPath(for: projectPath))/\(indexName)"
    }

    static let tabs: [DocTab] = [
        .init(id: "overview",     label: "Overview",     source: .userHtml(file: "overview.html")),
        .init(id: "roadmap",      label: "Roadmap",      source: .generatedHtml(file: "roadmap.html")),
        .init(id: "initiatives",  label: "Initiatives",  source: .generatedHtml(file: "initiatives.html")),
        .init(id: "goals",        label: "Goals & KPIs", source: .userHtml(file: "goals.html")),
        .init(id: "ideas",        label: "Ideas",        source: .userHtml(file: "ideas.html")),
        .init(id: "prds",         label: "PRDs",         source: .userFolder(rel: "prds")),
        .init(id: "documents",    label: "Documents",    source: .userFolder(rel: "documents"))
    ]

    struct DocTab {
        let id: String
        let label: String
        let source: TabSource
    }

    enum TabSource {
        case userHtml(file: String)        // sections/<file>; user-authored
        case generatedHtml(file: String)   // sections/<file>; we own it
        case userFolder(rel: String)       // collection of .html files
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
        let sectionsFolder = "\(folder)/sections"
        try? FileManager.default.createDirectory(atPath: sectionsFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(folder)/prds", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(folder)/documents", withIntermediateDirectories: true)

        // User-authored stubs — only scaffold when missing.
        scaffold(at: "\(sectionsFolder)/overview.html", with: stub(.overview(projectName: projectName)))
        scaffold(at: "\(sectionsFolder)/goals.html",    with: stub(.goals(projectName: projectName)))
        scaffold(at: "\(sectionsFolder)/ideas.html",    with: stub(.ideas))

        // Generated sections — overwritten every regen.
        let roadmapHtml = renderRoadmap(meta: meta, template: template, tasks: tasks)
        try? roadmapHtml.write(toFile: "\(sectionsFolder)/roadmap.html", atomically: true, encoding: .utf8)

        let initiativesHtml = renderInitiatives(tasks: tasks)
        try? initiativesHtml.write(toFile: "\(sectionsFolder)/initiatives.html", atomically: true, encoding: .utf8)

        // Compose the full page.
        var sections: [String] = []
        for tab in tabs {
            let body = readSection(tab: tab, projectPath: projectPath)
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

        let crumbs: String = {
            var parts: [String] = []
            if let template = template {
                parts.append("Methodology: <strong>\(escapeHTML(template.name))</strong>")
            } else {
                parts.append("No template applied")
            }
            if let stageId = meta.currentStageId,
               let stage = template?.stages.first(where: { $0.id == stageId }) {
                parts.append("Stage: <strong>\(escapeHTML(stage.title))</strong>")
            }
            return parts.joined(separator: " · ")
        }()

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        \(header)
        <meta charset="utf-8">
        <title>\(escapeHTML(projectName)) — Product</title>
        \(sharedStyles)
        </head>
        <body>
          <div class="wrap">
            <h1>\(escapeHTML(projectName))</h1>
            <div class="crumbs">\(crumbs)</div>
            <nav class="tabs">
              \(nav)
            </nav>
        \(sections.joined(separator: "\n"))
          </div>
          \(tabScript)
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

    // MARK: - Section reading

    private static func readSection(tab: DocTab, projectPath: String) -> String {
        switch tab.source {
        case .userHtml(let file), .generatedHtml(let file):
            let path = "\(folderPath(for: projectPath))/sections/\(file)"
            if let body = try? String(contentsOfFile: path, encoding: .utf8) {
                return body
            }
            return "<p class=\"empty\">No content yet. Edit <code>sections/\(escapeHTML(file))</code>.</p>"
        case .userFolder(let rel):
            return readFolder(at: "\(folderPath(for: projectPath))/\(rel)", emptyMsg: emptyMsg(for: rel))
        }
    }

    private static func emptyMsg(for rel: String) -> String {
        switch rel {
        case "prds":      return "No PRDs yet. Use “New PRD…” in the Product tab toolbar."
        case "documents": return "No documents yet. Use “New document…” in the Product tab toolbar."
        default:          return "Empty."
        }
    }

    private static func readFolder(at folder: String, emptyMsg: String) -> String {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folder) else {
            return "<p class=\"empty\">\(escapeHTML(emptyMsg))</p>"
        }
        let htmlFiles = files.filter { $0.hasSuffix(".html") }.sorted()
        if htmlFiles.isEmpty {
            return "<p class=\"empty\">\(escapeHTML(emptyMsg))</p>"
        }
        var out: [String] = ["<div class=\"file-list\">"]
        for f in htmlFiles {
            let path = "\(folder)/\(f)"
            let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let title = extractTitle(from: body) ?? (f as NSString).deletingPathExtension
            out.append("""
              <details class="card">
                <summary><strong>\(escapeHTML(title))</strong> <span class="meta">\(escapeHTML(f))</span></summary>
                <div class="embed">\(body)</div>
              </details>
            """)
        }
        out.append("</div>")
        return out.joined(separator: "\n")
    }

    private static func extractTitle(from html: String) -> String? {
        // Look for first <h1>…</h1> or <h2>…</h2> tag — best-effort.
        for tag in ["h1", "h2"] {
            if let r1 = html.range(of: "<\(tag)>"),
               let r2 = html.range(of: "</\(tag)>", range: r1.upperBound..<html.endIndex) {
                let inner = String(html[r1.upperBound..<r2.lowerBound])
                return inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    // MARK: - Generated sections (HTML)

    private static func renderRoadmap(
        meta: ProjectMeta,
        template: LaunchTemplate?,
        tasks: [TaskItem]
    ) -> String {
        guard let template = template else {
            return "<p class=\"empty\">No template applied. Apply one in the Tasks tab to start tracking.</p>"
        }
        var out: [String] = []
        out.append("<h2>\(escapeHTML(template.name))</h2>")
        if !template.methodology.isEmpty {
            out.append("<blockquote>\(escapeHTML(template.methodology))</blockquote>")
        }

        out.append("<h3>Progress</h3>")
        out.append("<ul class=\"progress\">")
        let currentIdx = template.stages.firstIndex { $0.id == meta.currentStageId }
        for (i, s) in template.stages.enumerated() {
            let status: String
            let cls: String
            if let cur = currentIdx, i < cur { status = "Done"; cls = "done" }
            else if i == currentIdx { status = "Current"; cls = "current" }
            else { status = "Pending"; cls = "pending" }
            let exitChecked = s.exitCriteria.filter {
                meta.checkedExitCriteria.contains("\(s.id):\($0)")
            }.count
            out.append("<li><span class=\"pill \(cls)\">\(status)</span> <strong>\(escapeHTML(s.title))</strong> <span class=\"meta\">\(exitChecked)/\(s.exitCriteria.count) exit criteria</span></li>")
        }
        out.append("</ul>")

        for s in template.stages {
            let status: String
            if let cur = currentIdx, let myIdx = template.stages.firstIndex(where: { $0.id == s.id }) {
                if myIdx < cur { status = "done" }
                else if myIdx == cur { status = "current" }
                else { status = "pending" }
            } else { status = "pending" }

            out.append("<div class=\"card\">")
            out.append("<h3>\(escapeHTML(s.title)) <span class=\"pill \(status)\">\(status.capitalized)</span></h3>")
            out.append("<p>\(escapeHTML(s.purpose))</p>")
            if !s.methodology.isEmpty {
                out.append("<blockquote>\(escapeHTML(s.methodology))</blockquote>")
            }

            // Q&A
            if !s.guidingQuestions.isEmpty {
                let answers = meta.stageAnswers[s.id] ?? [:]
                let answered = s.guidingQuestions.filter { (answers[$0] ?? "").isEmpty == false }.count
                out.append("<h4>Questions <span class=\"meta\">(\(answered)/\(s.guidingQuestions.count) answered)</span></h4>")
                for q in s.guidingQuestions {
                    out.append("<p><strong>\(escapeHTML(q))</strong></p>")
                    let a = (answers[q] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if a.isEmpty {
                        out.append("<blockquote class=\"unanswered\">unanswered</blockquote>")
                    } else {
                        out.append("<blockquote>\(escapeHTML(a).replacingOccurrences(of: "\n", with: "<br>"))</blockquote>")
                    }
                }
            }

            // Exit criteria
            if !s.exitCriteria.isEmpty {
                out.append("<h4>Exit criteria</h4>")
                out.append("<ul class=\"checklist\">")
                for c in s.exitCriteria {
                    let checked = meta.checkedExitCriteria.contains("\(s.id):\(c)")
                    out.append("<li>\(checked ? "☑︎" : "☐") \(escapeHTML(c))</li>")
                }
                out.append("</ul>")
            }

            // Tasks for this stage
            let stageTasks = tasks.filter { $0.stage == s.id }
            if !stageTasks.isEmpty {
                out.append("<h4>Tasks</h4>")
                out.append("<table>")
                out.append("<thead><tr><th>Status</th><th>Task</th><th>Category</th></tr></thead><tbody>")
                for t in stageTasks {
                    out.append("<tr><td>\(taskBadge(t.status))</td><td>\(escapeHTML(t.title))</td><td class=\"meta\">\(escapeHTML(t.category.label))</td></tr>")
                }
                out.append("</tbody></table>")
            }
            out.append("</div>")
        }
        return out.joined(separator: "\n")
    }

    private static func renderInitiatives(tasks: [TaskItem]) -> String {
        let initiatives = tasks.filter { t in
            t.parentId == nil && tasks.contains(where: { $0.parentId == t.id })
        }
        if initiatives.isEmpty {
            return "<p class=\"empty\">No initiatives yet. Top-level tasks with children become initiatives — group related tasks under a parent in the Tasks tab.</p>"
        }
        var out: [String] = []
        for i in initiatives {
            let children = tasks.filter { $0.parentId == i.id }
            let doneCount = children.filter { $0.status == .done }.count
            out.append("<div class=\"card\">")
            out.append("<h3>\(escapeHTML(i.title))</h3>")
            out.append("<p class=\"meta\">\(doneCount)/\(children.count) tasks complete · \(escapeHTML(i.category.label))</p>")
            if let notes = i.notes, !notes.isEmpty {
                out.append("<p>\(escapeHTML(notes))</p>")
            }
            out.append("<table>")
            out.append("<thead><tr><th>Status</th><th>Task</th><th>Category</th></tr></thead><tbody>")
            for c in children {
                out.append("<tr><td>\(taskBadge(c.status))</td><td>\(escapeHTML(c.title))</td><td class=\"meta\">\(escapeHTML(c.category.label))</td></tr>")
            }
            out.append("</tbody></table>")
            out.append("</div>")
        }
        return out.joined(separator: "\n")
    }

    private static func taskBadge(_ status: TaskStatus) -> String {
        switch status {
        case .done:       return "<span class=\"pill done\">Done</span>"
        case .inProgress: return "<span class=\"pill current\">In progress</span>"
        case .skipped:    return "<span class=\"pill\">Skipped</span>"
        case .open:       return "<span class=\"pill pending\">Open</span>"
        }
    }

    // MARK: - HTML stubs

    private enum Stub {
        case overview(projectName: String)
        case goals(projectName: String)
        case ideas
    }

    private static func stub(_ kind: Stub) -> String {
        switch kind {
        case .overview(let name):
            return """
            <h2>\(escapeHTML(name))</h2>
            <p class="meta">One-pager. Edit me at <code>sections/overview.html</code>.</p>

            <div class="card">
              <h3>What is it?</h3>
              <p><em>One sentence: what does this project do?</em></p>
            </div>

            <div class="card">
              <h3>Who's it for?</h3>
              <p><em>Specific. Role + situation.</em></p>
            </div>

            <div class="card">
              <h3>Why now?</h3>
              <p><em>What's changed that makes this the right time?</em></p>
            </div>

            <div class="card">
              <h3>What it is <em>not</em></h3>
              <p><em>Out-of-scope. The features you're consciously not building.</em></p>
            </div>

            <div class="card">
              <h3>How will we know it's working?</h3>
              <p><em>Activation / retention / revenue / qualitative signal.</em></p>
            </div>
            """
        case .goals(let name):
            return """
            <h2>\(escapeHTML(name)) — Goals & KPIs</h2>
            <p class="meta">Edit me at <code>sections/goals.html</code>.</p>

            <div class="card">
              <h3>North-star metric</h3>
              <p><em>The one number that tells you the project is healthy.</em></p>
            </div>

            <div class="card">
              <h3>Quarter goals</h3>
              <ul>
                <li><em>Goal 1</em></li>
                <li><em>Goal 2</em></li>
                <li><em>Goal 3</em></li>
              </ul>
            </div>

            <div class="card">
              <h3>Tracked KPIs</h3>
              <table>
                <thead>
                  <tr><th>Metric</th><th>Current</th><th>Target</th><th>Notes</th></tr>
                </thead>
                <tbody>
                  <tr><td><em>e.g. weekly active users</em></td><td>—</td><td>—</td><td>—</td></tr>
                </tbody>
              </table>
            </div>
            """
        case .ideas:
            return """
            <h2>Ideas</h2>
            <p class="meta">Parking lot. Promote to a task or PRD when ripe. Edit me at <code>sections/ideas.html</code>.</p>

            <div class="card">
              <h3>Maybe later</h3>
              <ul>
                <li><em>Idea 1</em></li>
                <li><em>Idea 2</em></li>
              </ul>
            </div>
            """
        }
    }

    private static func scaffold(at path: String, with content: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Style + script (kept inline so the HTML is self-contained)

    private static let sharedStyles = """
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
                 margin-bottom: 22px; position: sticky; top: 0; background: var(--bg);
                 z-index: 5; padding-top: 4px; }
      nav.tabs .tab { background: transparent; color: var(--muted); border: 0;
                      padding: 8px 12px; font: inherit; cursor: pointer; border-radius: 6px 6px 0 0;
                      border-bottom: 2px solid transparent; }
      nav.tabs .tab:hover { color: var(--fg); }
      nav.tabs .tab.active { color: var(--accent); border-bottom-color: var(--accent); font-weight: 600; }
      .tab-pane { display: none; }
      .tab-pane.active { display: block; }
      h2 { font-size: 18px; margin-top: 22px; margin-bottom: 8px; }
      h3 { font-size: 15px; margin-top: 18px; margin-bottom: 6px; }
      h4 { font-size: 13px; margin-top: 14px; margin-bottom: 4px; color: var(--muted);
           text-transform: uppercase; letter-spacing: 0.5px; font-weight: 600; }
      p { margin: 8px 0; }
      a { color: var(--accent); text-decoration: none; }
      a:hover { text-decoration: underline; }
      code, pre { background: var(--code); border-radius: 4px; }
      code { padding: 1px 5px; font-size: 12px; }
      pre { padding: 10px 12px; overflow-x: auto; font-size: 12px; }
      ul { padding-left: 22px; }
      li { margin: 3px 0; }
      ul.progress { padding-left: 0; list-style: none; }
      ul.progress li { padding: 4px 0; }
      ul.checklist { padding-left: 0; list-style: none; }
      ul.checklist li { padding: 2px 0; font-family: ui-monospace, "SF Mono", monospace; font-size: 13px; }
      blockquote { border-left: 3px solid var(--border); padding: 4px 12px; color: var(--muted);
                   margin: 6px 0; font-style: italic; }
      blockquote.unanswered { color: var(--muted); opacity: 0.6; }
      .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
              padding: 14px 18px; margin: 12px 0; }
      .pill { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px;
              background: var(--card); border: 1px solid var(--border); color: var(--muted);
              margin-right: 4px; }
      .pill.done { color: #2ecc71; border-color: rgba(46,204,113,0.4); }
      .pill.current { color: var(--accent); border-color: rgba(90,200,250,0.4); }
      .pill.pending { color: var(--muted); }
      .file-list { display: grid; gap: 8px; }
      .file-list .embed { margin-top: 10px; }
      .meta { color: var(--muted); font-size: 12px; }
      table { border-collapse: collapse; width: 100%; margin: 10px 0; font-size: 13px; }
      th, td { padding: 6px 10px; border-bottom: 1px solid var(--border); text-align: left; }
      th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase;
           letter-spacing: 0.5px; }
      .empty { color: var(--muted); font-style: italic; padding: 14px 0; }
      details > summary { cursor: pointer; padding: 6px 0; }
    </style>
    """

    private static let tabScript = """
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
        var hash = (location.hash || '').replace('#', '');
        if (hash) {
          var b = document.querySelector('nav.tabs .tab[data-tab="' + hash + '"]');
          if (b) b.click();
        }
      })();
    </script>
    """

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
