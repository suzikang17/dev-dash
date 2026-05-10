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
        .init(id: "artifacts",    label: "Artifacts",    source: .artifactsBrowser)
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
        case artifactsBrowser              // grouped view of every artifact folder
    }

    /// Folders the generator reads from. Each maps to a label used in the
    /// Artifacts browser. Order is render order.
    static let artifactFolders: [(rel: String, label: String, hint: String)] = [
        ("prd",        "PRDs",                 "Product requirements docs."),
        ("plans",      "Implementation Plans", "Milestones, timelines, risks."),
        ("status",     "Status Reports",       "Weekly snapshots."),
        ("decisions",  "Decisions",            "Append-only decision log."),
        ("concepts",   "Concept Explainers",   "How something works, for the team."),
        ("retros",     "Retrospectives",       "What went well, what didn't, what's next."),
        ("docs",       "Documents",            "Catch-all narrative docs.")
    ]

    @discardableResult
    static func generate(
        projectName: String,
        projectPath: String,
        meta: ProjectMeta,
        template: LaunchTemplate?,
        tasks: [TaskItem]
    ) -> String? {
        let folder = folderPath(for: projectPath)
        // Vendor JS (Alpine + components) into <project>/docs/devdash/.assets/.
        // Idempotent — only writes when bundled resource differs from disk.
        ProductDocAssets.writeAssets(to: folder)
        let sectionsFolder = "\(folder)/sections"
        try? FileManager.default.createDirectory(atPath: sectionsFolder, withIntermediateDirectories: true)
        // Migrate legacy folders from earlier builds → singular / shorter names.
        migrateLegacyFolder(from: "\(folder)/prds", to: "\(folder)/prd")
        migrateLegacyFolder(from: "\(folder)/documents", to: "\(folder)/docs")
        for (rel, _, _) in artifactFolders {
            try? FileManager.default.createDirectory(atPath: "\(folder)/\(rel)", withIntermediateDirectories: true)
        }

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
        <script defer src=".assets/devdash-components.js"></script>
        <script defer src=".assets/alpine.min.js"></script>
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
            // Refresh the queryable manifest each time the index page is
            // rebuilt — keeps .index.json in sync with what's on disk.
            DocIndexGenerator.generate(projectPath: projectPath)
            return path
        } catch {
            return nil
        }
    }

    // MARK: - Section reading

    private static func readSection(tab: DocTab, projectPath: String) -> String {
        switch tab.source {
        case .userHtml(let file):
            let path = "\(folderPath(for: projectPath))/sections/\(file)"
            let body: String = (try? String(contentsOfFile: path, encoding: .utf8))
                ?? "<p class=\"empty\">No content yet. Click here and start typing.</p>"
            // Wrap in an editable container so the bridge JS marks it contenteditable.
            return "<div data-section-file=\"sections/\(file)\">\(body)</div>"
        case .generatedHtml(let file):
            let path = "\(folderPath(for: projectPath))/sections/\(file)"
            if let body = try? String(contentsOfFile: path, encoding: .utf8) {
                return body
            }
            return "<p class=\"empty\">No content yet — derived from project state.</p>"
        case .userFolder(let rel):
            return readFolder(at: "\(folderPath(for: projectPath))/\(rel)", relRoot: rel, emptyMsg: emptyMsg(for: rel))
        case .artifactsBrowser:
            return renderArtifactsBrowser(projectPath: projectPath)
        }
    }

    /// One section per artifact folder, each as a collapsible group with
    /// the file list inside. Empty folders still render so users see what
    /// types exist.
    private static func renderArtifactsBrowser(projectPath: String) -> String {
        var out: [String] = []
        for (rel, label, hint) in artifactFolders {
            let folder = "\(folderPath(for: projectPath))/\(rel)"
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder))?
                .filter { $0.hasSuffix(".html") }.sorted() ?? []
            out.append("<details class=\"card\"\(files.isEmpty ? "" : " open")>")
            out.append("  <summary><strong>\(escapeHTML(label))</strong> <span class=\"meta\">\(escapeHTML(rel))/ · \(files.count)</span></summary>")
            out.append("  <p class=\"meta\" style=\"margin-top:6px\">\(escapeHTML(hint))</p>")
            if files.isEmpty {
                out.append("  <p class=\"empty\">None yet. Use the toolbar pencil menu → New \(escapeHTML(String(label.dropLast())))…</p>")
            } else {
                out.append("  <div class=\"file-list\">")
                for f in files {
                    let path = "\(folder)/\(f)"
                    let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                    let title = extractTitle(from: body) ?? (f as NSString).deletingPathExtension
                    let relFile = "\(rel)/\(f)"
                    out.append("""
                      <details class="card" style="margin-left:8px">
                        <summary><strong>\(escapeHTML(title))</strong> <span class="meta">\(escapeHTML(f))</span></summary>
                        <div class="embed" data-section-file="\(relFile)">\(body)</div>
                      </details>
                    """)
                }
                out.append("  </div>")
            }
            out.append("</details>")
        }
        return out.joined(separator: "\n")
    }

    private static func migrateLegacyFolder(from oldPath: String, to newPath: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldPath), !fm.fileExists(atPath: newPath) else { return }
        try? fm.moveItem(atPath: oldPath, toPath: newPath)
    }

    private static func emptyMsg(for rel: String) -> String {
        switch rel {
        case "prds":      return "No PRDs yet. Use “New PRD…” in the Product tab toolbar."
        case "documents": return "No documents yet. Use “New document…” in the Product tab toolbar."
        default:          return "Empty."
        }
    }

    private static func readFolder(at folder: String, relRoot: String, emptyMsg: String) -> String {
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
            let rel = "\(relRoot)/\(f)"
            out.append("""
              <details class="card" open>
                <summary><strong>\(escapeHTML(title))</strong> <span class="meta">\(escapeHTML(f))</span></summary>
                <div class="embed" data-section-file="\(rel)">\(body)</div>
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
        case .blocked:    return "<span class=\"pill blocked\">Blocked</span>"
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
            <div class="doc-head">
              <h2>\(escapeHTML(name))</h2>
              <span class="doc-status">One-pager · <code>sections/overview.html</code></span>
            </div>

            <div class="callout tldr">
              <h4 style="margin-top:0">TL;DR</h4>
              <p><em>One sentence the rest of the page is justifying.</em></p>
            </div>

            <div class="grid-2">
              <div class="card">
                <h3>What is it?</h3>
                <p><em>One sentence — what does this do?</em></p>
              </div>
              <div class="card">
                <h3>Who's it for?</h3>
                <p><em>Specific. Role + situation, not a persona poster.</em></p>
              </div>
              <div class="card">
                <h3>Why now?</h3>
                <p><em>What changed that makes this the right time?</em></p>
              </div>
              <div class="card">
                <h3>What it is <em>not</em></h3>
                <p><em>Out-of-scope. The features you're consciously skipping.</em></p>
              </div>
            </div>

            <div class="card">
              <h3>How will we know it's working?</h3>
              <p><em>Pick 1–3 signals. Activation, retention, revenue, qualitative.</em></p>
              <ul>
                <li><span class="tag">activation</span> <em>e.g. % of new users completing core flow</em></li>
                <li><span class="tag">retention</span> <em>e.g. WAU/MAU or day-7 return</em></li>
                <li><span class="tag">qualitative</span> <em>e.g. 3 unprompted "thank you"s in a week</em></li>
              </ul>
            </div>

            <h3>Risks &amp; assumptions</h3>
            <table>
              <thead><tr><th>Risk</th><th>Likelihood</th><th>Impact</th><th>Mitigation</th></tr></thead>
              <tbody>
                <tr><td><em>e.g. nobody wants this</em></td><td><span class="pill warn">Med</span></td><td><span class="pill risk">High</span></td><td><em>5 customer interviews before MVP</em></td></tr>
              </tbody>
            </table>
            """
        case .goals(let name):
            return """
            <div class="doc-head">
              <h2>\(escapeHTML(name)) — Goals &amp; KPIs</h2>
              <span class="doc-status"><code>sections/goals.html</code></span>
            </div>

            <h3>North-star metric</h3>
            <div class="kpi-grid">
              <div class="kpi">
                <div class="k-label">North-star</div>
                <div class="k-value">—</div>
                <div class="k-target">target: —</div>
                <div class="k-delta">vs. last week: —</div>
              </div>
            </div>

            <h3>Quarter goals</h3>
            <ul class="checklist">
              <li>☐ <em>Goal 1</em></li>
              <li>☐ <em>Goal 2</em></li>
              <li>☐ <em>Goal 3</em></li>
            </ul>
            \(ProductDocAssets.addBtn(label: "+ Add goal", html: "<li>☐ <em>New goal</em></li>"))

            <h3>Tracked KPIs</h3>
            <div class="kpi-grid kpi-tracked">
              <div class="kpi">
                <div class="k-label">Activation</div>
                <div class="k-value">—</div>
                <div class="k-target">target: —</div>
                <div class="k-delta">—</div>
              </div>
              <div class="kpi">
                <div class="k-label">D7 retention</div>
                <div class="k-value">—</div>
                <div class="k-target">target: —</div>
                <div class="k-delta">—</div>
              </div>
              <div class="kpi">
                <div class="k-label">Weekly active</div>
                <div class="k-value">—</div>
                <div class="k-target">target: —</div>
                <div class="k-delta">—</div>
              </div>
            </div>
            \(ProductDocAssets.addBtn(label: "+ Add KPI tile", html: "<div class=\"kpi\"><div class=\"k-label\">New KPI</div><div class=\"k-value\">—</div><div class=\"k-target\">target: —</div><div class=\"k-delta\">—</div></div>"))

            <h3>Detailed metrics</h3>
            <table>
              <thead><tr><th>Metric</th><th>Current</th><th>Target</th><th>Notes</th></tr></thead>
              <tbody>
                <tr><td><em>weekly active users</em></td><td>—</td><td>—</td><td>—</td></tr>
                <tr><td><em>activation rate</em></td><td>—</td><td>—</td><td>—</td></tr>
              </tbody>
            </table>
            \(ProductDocAssets.addBtn(label: "+ Add metric", html: "<tr><td><em>new metric</em></td><td>—</td><td>—</td><td>—</td></tr>"))
            """
        case .ideas:
            return """
            <div class="doc-head">
              <h2>Ideas</h2>
              <span class="doc-status">Parking lot · <code>sections/ideas.html</code></span>
            </div>

            <p class="meta">Promote to a task (Tasks tab) or a PRD (Product → New PRD) when an idea is ripe.</p>

            <div class="board">
              <div class="col" data-col="quick-wins">
                <h4>Quick wins <span class="meta">low effort, real value</span></h4>
                <div class="item"><span class="tag">eng</span> <em>Idea 1</em></div>
                <div class="item"><span class="tag">design</span> <em>Idea 2</em></div>
                <button data-action="dom-append-template" data-template="idea-card" data-target="[data-col=quick-wins]" class="add-btn" contenteditable="false">+ Idea</button>
              </div>
              <div class="col" data-col="big-bets">
                <h4>Big bets <span class="meta">larger investment</span></h4>
                <div class="item"><span class="tag">research</span> <em>Idea 3</em></div>
                <button data-action="dom-append-template" data-template="idea-card" data-target="[data-col=big-bets]" class="add-btn" contenteditable="false">+ Idea</button>
              </div>
              <div class="col" data-col="maybe-later">
                <h4>Maybe later <span class="meta">parked</span></h4>
                <div class="item"><span class="tag">marketing</span> <em>Idea 4</em></div>
                <button data-action="dom-append-template" data-template="idea-card" data-target="[data-col=maybe-later]" class="add-btn" contenteditable="false">+ Idea</button>
              </div>
            </div>
            """
        }
    }

    // MARK: - Document templates (richer artifacts spawned via "New …")

    enum DocType: String, CaseIterable, Identifiable {
        case prd, implementationPlan, statusReport, decisionLog, conceptExplainer, retrospective, triageBoard

        var id: String { rawValue }
        var label: String {
            switch self {
            case .prd:               return "PRD"
            case .implementationPlan: return "Implementation plan"
            case .statusReport:      return "Status report"
            case .decisionLog:       return "Decision log"
            case .conceptExplainer:  return "Concept explainer"
            case .retrospective:     return "Retrospective"
            case .triageBoard:       return "Triage board"
            }
        }
        var folder: String {
            switch self {
            case .prd:                return "prd"
            case .implementationPlan: return "plans"
            case .statusReport:       return "status"
            case .decisionLog:        return "decisions"
            case .conceptExplainer:   return "concepts"
            case .retrospective:      return "retros"
            case .triageBoard:        return "triage"
            }
        }
        var defaultSlug: String {
            switch self {
            case .prd:                return "prd-feature.html"
            case .implementationPlan: return "implementation-plan.html"
            case .statusReport:       return "status-\(Self.dateSlug()).html"
            case .decisionLog:        return "decision-log.html"
            case .conceptExplainer:   return "concept-explainer.html"
            case .retrospective:      return "retro-\(Self.dateSlug()).html"
            case .triageBoard:        return "triage-\(Self.dateSlug()).html"
            }
        }
        private static func dateSlug() -> String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }
    }

    /// Rich HTML starter for each doc type. Uses shell CSS classes so the
    /// artifact looks coherent inside the living doc viewer.
    static func template(_ type: DocType, projectName: String) -> String {
        switch type {
        case .prd:
            return """
            <div class="doc-head">
              <h2>PRD: <em>Feature name</em></h2>
              <span class="doc-status"><span class="pill warn">Draft</span> · \(escapeHTML(projectName))</span>
            </div>

            <div class="callout tldr">
              <h4 style="margin-top:0">TL;DR</h4>
              <p><em>One paragraph. What we're building, who it's for, why it matters.</em></p>
            </div>

            <h3>Problem</h3>
            <p><em>The user pain in their words. Quote actual conversations / tickets / data.</em></p>

            <h3>Goals</h3>
            <ul>
              <li><strong>Primary:</strong> <em>One concrete outcome.</em></li>
              <li><strong>Secondary:</strong> <em>Nice-to-have outcomes.</em></li>
              <li><strong>Non-goals:</strong> <em>What this won't address.</em></li>
            </ul>

            <h3>Proposed approach</h3>
            <p><em>How. High-level, not implementation detail.</em></p>

            <div class="grid-2">
              <div class="card">
                <h4>User-visible behavior</h4>
                <p><em>What changes for the user. Step through the new flow.</em></p>
              </div>
              <div class="card">
                <h4>System behavior</h4>
                <p><em>What changes under the hood. Sketch data flow if it's nontrivial.</em></p>
              </div>
            </div>

            <h3>Risks</h3>
            <table>
              <thead><tr><th>Risk</th><th>Severity</th><th>Mitigation</th></tr></thead>
              <tbody>
                <tr><td><em>e.g. perf regression on hot path</em></td><td><span class="pill risk">High</span></td><td><em>benchmark gate before rollout</em></td></tr>
              </tbody>
            </table>

            <h3>Open questions</h3>
            <ul>
              <li><em>Question 1 — who's deciding, by when?</em></li>
            </ul>

            <h3>Success metrics</h3>
            <div class="kpi-grid">
              <div class="kpi"><div class="k-label">Adoption</div><div class="k-value">—</div><div class="k-target">target: —</div></div>
              <div class="kpi"><div class="k-label">Quality signal</div><div class="k-value">—</div><div class="k-target">target: —</div></div>
            </div>
            """

        case .implementationPlan:
            return """
            <div class="doc-head">
              <h2>Implementation Plan</h2>
              <span class="doc-status">\(escapeHTML(projectName))</span>
            </div>

            <div class="callout tldr">
              <h4 style="margin-top:0">Overview</h4>
              <p><em>One paragraph: what we're building and the rough shape of the work.</em></p>
            </div>

            <h3>Milestones</h3>
            <ul class="timeline">
              <li class="done"><div class="t-meta">Week 0</div><div class="t-title">Discovery — landed</div><p><em>What we know now that we didn't before.</em></p></li>
              <li class="current"><div class="t-meta">Week 1</div><div class="t-title">Foundations</div><p><em>Schema, plumbing, the boring base layer.</em></p></li>
              <li><div class="t-meta">Week 2</div><div class="t-title">Core flow</div><p><em>End-to-end happy path.</em></p></li>
              <li><div class="t-meta">Week 3</div><div class="t-title">Polish &amp; ship</div><p><em>Edge cases, telemetry, rollout.</em></p></li>
            </ul>

            <h3>Data flow</h3>
            <div class="card">
              <pre><code>// Replace with an SVG / mermaid diagram. ASCII placeholder:
            [client] ──&gt; [api] ──&gt; [worker] ──&gt; [db]
                              │
                              └──&gt; [event bus]</code></pre>
            </div>

            <h3>Key code paths</h3>
            <pre><code>// Drop the load-bearing snippet here so reviewers can see the shape.
            function example() {
              // ...
            }</code></pre>

            <h3>Risks</h3>
            <table>
              <thead><tr><th>Risk</th><th>Likelihood</th><th>Impact</th><th>Plan if it bites</th></tr></thead>
              <tbody>
                <tr><td><em>third-party API rate limits</em></td><td><span class="pill warn">Med</span></td><td><span class="pill risk">High</span></td><td><em>local cache + retry</em></td></tr>
                <tr><td><em>migration on hot table</em></td><td><span class="pill">Low</span></td><td><span class="pill risk">High</span></td><td><em>shadow-write + verify before cutover</em></td></tr>
              </tbody>
            </table>

            <h3>Rollout</h3>
            <ul class="checklist">
              <li>☐ Behind a flag, off by default</li>
              <li>☐ 1% → 10% → 100% gated by error rate</li>
              <li>☐ Kill switch documented</li>
              <li>☐ Metrics dashboard linked</li>
            </ul>
            """

        case .statusReport:
            let date = formattedDate()
            return """
            <div class="doc-head">
              <h2>Status — \(date)</h2>
              <span class="doc-status">\(escapeHTML(projectName))</span>
            </div>

            <div class="callout tldr">
              <p><strong>Headline:</strong> <em>One sentence summary, the thing your boss reads.</em></p>
            </div>

            <h3>Velocity (last 4 weeks)</h3>
            <div class="card">
              <div class="bars">
                <div class="bar" style="height:30%"><span class="b-val">3</span><span class="b-label">W-3</span></div>
                <div class="bar" style="height:60%"><span class="b-val">6</span><span class="b-label">W-2</span></div>
                <div class="bar" style="height:50%"><span class="b-val">5</span><span class="b-label">W-1</span></div>
                <div class="bar" style="height:80%"><span class="b-val">8</span><span class="b-label">this</span></div>
              </div>
            </div>

            <div class="grid-2">
              <div class="card">
                <h4>✓ Shipped</h4>
                <ul><li><em>Thing 1</em></li><li><em>Thing 2</em></li></ul>
              </div>
              <div class="card">
                <h4>⏳ In progress</h4>
                <ul><li><em>Thing 3</em></li></ul>
              </div>
              <div class="card">
                <h4>⚠ Slipped</h4>
                <ul><li><em>Thing 4 — why &amp; new ETA</em></li></ul>
              </div>
              <div class="card">
                <h4>→ Next week</h4>
                <ul><li><em>Thing 5</em></li></ul>
              </div>
            </div>

            <h3>Risks &amp; asks</h3>
            <ul>
              <li><span class="pill warn">Risk</span> <em>Something that could derail the next milestone.</em></li>
              <li><span class="pill current">Ask</span> <em>What you need from leadership / others.</em></li>
            </ul>
            """

        case .decisionLog:
            return """
            <div class="doc-head">
              <h2>Decision Log</h2>
              <span class="doc-status">\(escapeHTML(projectName))</span>
            </div>

            <p class="meta">Append-only. Each decision: context, options, what we picked, why. Don't go back and rewrite history — add a new entry that reverses the call instead.</p>

            <div class="card">
              <div class="doc-head">
                <h3 style="margin:0">D-001 · <em>Decision title</em></h3>
                <span class="doc-status meta">\(formattedDate()) · <span class="pill done">Adopted</span></span>
              </div>
              <h4>Context</h4>
              <p><em>What forced the decision. Constraints, deadlines, prior art.</em></p>
              <h4>Options considered</h4>
              <table>
                <thead><tr><th>Option</th><th>Pros</th><th>Cons</th></tr></thead>
                <tbody>
                  <tr><td><strong>A.</strong> <em>name</em></td><td><em>…</em></td><td><em>…</em></td></tr>
                  <tr><td><strong>B.</strong> <em>name</em></td><td><em>…</em></td><td><em>…</em></td></tr>
                </tbody>
              </table>
              <h4>Decision</h4>
              <p><strong>Picked: A.</strong> <em>Why.</em></p>
              <h4>Consequences</h4>
              <p><em>What this commits us to / locks out / makes easier later.</em></p>
            </div>
            """

        case .conceptExplainer:
            return """
            <div class="doc-head">
              <h2>Concept: <em>Topic</em></h2>
              <span class="doc-status">\(escapeHTML(projectName))</span>
            </div>

            <div class="callout tldr">
              <h4 style="margin-top:0">TL;DR</h4>
              <p><em>One paragraph the rest of the page builds on.</em></p>
            </div>

            <h3>The mental model</h3>
            <div class="card">
              <p><em>The single image / metaphor / diagram that carries the rest. Inline SVG goes here.</em></p>
              <pre><code>// SVG / mermaid / diagram placeholder</code></pre>
            </div>

            <h3>Key terms</h3>
            <table>
              <thead><tr><th>Term</th><th>Definition</th></tr></thead>
              <tbody>
                <tr><td><strong><em>Term 1</em></strong></td><td><em>1-line definition.</em></td></tr>
                <tr><td><strong><em>Term 2</em></strong></td><td><em>1-line definition.</em></td></tr>
              </tbody>
            </table>

            <h3>How it actually works</h3>
            <p><em>Walk through the request path / lifecycle / state machine. Step by step.</em></p>
            <ol>
              <li><em>Step 1</em></li>
              <li><em>Step 2</em></li>
              <li><em>Step 3</em></li>
            </ol>

            <h3>Gotchas</h3>
            <div class="callout warn">
              <ul>
                <li><em>Surprising thing 1</em></li>
                <li><em>Surprising thing 2</em></li>
              </ul>
            </div>

            <h3>FAQ</h3>
            <details><summary><strong>Q: <em>frequently asked thing?</em></strong></summary><p><em>Answer.</em></p></details>
            <details><summary><strong>Q: <em>another?</em></strong></summary><p><em>Answer.</em></p></details>
            """

        case .triageBoard:
            return """
            <div class="doc-head">
              <h2>Triage Board</h2>
              <span class="doc-status meta">Drag tickets between columns. Auto-saves.</span>
            </div>

            <div class="triage-controls">
              <button class="add-btn" contenteditable="false" data-action="triage-add" data-col="now">+ Ticket</button>
              <button class="add-btn" contenteditable="false" data-action="triage-export-md">Copy as Markdown</button>
            </div>

            <div class="triage-cols">
              <div class="triage-col" data-col="now">
                <h4>Now <span class="meta tcount">0</span></h4>
                <div class="triage-list" data-droplist="now"></div>
              </div>
              <div class="triage-col" data-col="next">
                <h4>Next <span class="meta tcount">0</span></h4>
                <div class="triage-list" data-droplist="next"></div>
              </div>
              <div class="triage-col" data-col="later">
                <h4>Later <span class="meta tcount">0</span></h4>
                <div class="triage-list" data-droplist="later"></div>
              </div>
              <div class="triage-col" data-col="cut">
                <h4>Cut <span class="meta tcount">0</span></h4>
                <div class="triage-list" data-droplist="cut"></div>
              </div>
            </div>

            <p class="empty">Hint: click a tag on a ticket to filter. Click the title to edit.</p>
            """

        case .retrospective:
            return """
            <div class="doc-head">
              <h2>Retrospective — <em>milestone or sprint</em></h2>
              <span class="doc-status">\(escapeHTML(projectName)) · \(formattedDate())</span>
            </div>

            <div class="grid-2">
              <div class="card">
                <h4>👍 Went well</h4>
                <ul><li><em>Thing 1</em></li><li><em>Thing 2</em></li></ul>
              </div>
              <div class="card">
                <h4>👎 Didn't go well</h4>
                <ul><li><em>Thing 3</em></li><li><em>Thing 4</em></li></ul>
              </div>
              <div class="card">
                <h4>💡 Lessons</h4>
                <ul><li><em>What we learned.</em></li></ul>
              </div>
              <div class="card">
                <h4>→ Action items</h4>
                <ul class="checklist">
                  <li>☐ <em>Action 1 — owner, due date</em></li>
                </ul>
              </div>
            </div>

            <h3>Timeline</h3>
            <ul class="timeline">
              <li class="done"><div class="t-meta">Week 1</div><div class="t-title">Started</div><p><em>What we set out to do.</em></p></li>
              <li class="done"><div class="t-meta">Mid</div><div class="t-title">Course corrections</div><p><em>What changed and why.</em></p></li>
              <li class="done"><div class="t-meta">End</div><div class="t-title">Landed</div><p><em>What we shipped.</em></p></li>
            </ul>
            """
        }
    }

    private static func formattedDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: Date())
    }

    private static func scaffold(at path: String, with content: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Style + script (kept inline so the HTML is self-contained)

    private static let sharedStyles = """
    <style>
      :root { --bg: #0f1115; --fg: #e8e8ec; --muted: #9aa0a8; --accent: #5ac8fa;
              --border: #23262d; --card: #181a1f; --code: #1c1f26;
              --green: #2ecc71; --red: #ff6b6b; --orange: #ffa502; --purple: #b388ff; }
      @media (prefers-color-scheme: light) {
        :root { --bg: #ffffff; --fg: #1c1c1e; --muted: #6e6e73; --accent: #007aff;
                --border: #e5e5ea; --card: #f7f7f9; --code: #f1f3f5;
                --green: #2ecc71; --red: #ff3b30; --orange: #ff9500; --purple: #af52de; }
      }
      html, body { background: var(--bg); color: var(--fg); margin: 0; padding: 0;
                   font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", sans-serif;
                   line-height: 1.55; }
      .wrap { max-width: 960px; margin: 0 auto; padding: 24px 28px 80px; }
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

      /* Cards & callouts */
      .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
              padding: 14px 18px; margin: 12px 0; }
      .callout { padding: 12px 16px; border-radius: 8px; margin: 12px 0;
                 border-left: 3px solid var(--accent); background: var(--card); }
      .callout.tldr { border-left-color: var(--accent); }
      .callout.warn { border-left-color: var(--orange); }
      .callout.risk { border-left-color: var(--red); }

      /* Pills / badges */
      .pill { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px;
              background: var(--card); border: 1px solid var(--border); color: var(--muted);
              margin-right: 4px; }
      .pill.done    { color: var(--green); border-color: color-mix(in srgb, var(--green) 40%, transparent); }
      .pill.current { color: var(--accent); border-color: color-mix(in srgb, var(--accent) 40%, transparent); }
      .pill.pending { color: var(--muted); }
      .pill.warn    { color: var(--orange); border-color: color-mix(in srgb, var(--orange) 40%, transparent); }
      .pill.risk    { color: var(--red); border-color: color-mix(in srgb, var(--red) 40%, transparent); }
      .pill.idea    { color: var(--purple); border-color: color-mix(in srgb, var(--purple) 40%, transparent); }

      /* KPI dashboard */
      .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
                  gap: 12px; margin: 12px 0; }
      .kpi { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
             padding: 14px; }
      .kpi .k-label { font-size: 11px; color: var(--muted); text-transform: uppercase;
                      letter-spacing: 0.6px; font-weight: 600; }
      .kpi .k-value { font-size: 24px; font-weight: 700; margin: 6px 0 2px;
                      font-feature-settings: "tnum"; }
      .kpi .k-target { font-size: 11px; color: var(--muted); }
      .kpi .k-delta { font-size: 11px; font-weight: 600; }
      .kpi .k-delta.up { color: var(--green); }
      .kpi .k-delta.down { color: var(--red); }

      /* Timeline (vertical) */
      .timeline { list-style: none; padding-left: 0; margin: 14px 0;
                  border-left: 2px solid var(--border); }
      .timeline > li { position: relative; margin: 0; padding: 8px 0 14px 22px; }
      .timeline > li::before { content: ""; position: absolute; left: -6px; top: 14px;
                               width: 10px; height: 10px; border-radius: 50%;
                               background: var(--card); border: 2px solid var(--accent); }
      .timeline > li.done::before { background: var(--green); border-color: var(--green); }
      .timeline > li.current::before { background: var(--accent); border-color: var(--accent); }
      .timeline > li .t-meta { color: var(--muted); font-size: 11px; font-family: ui-monospace, "SF Mono", monospace; }
      .timeline > li .t-title { font-weight: 600; }

      /* Tagged board (idea backlog) */
      .board { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
               gap: 12px; margin: 12px 0; }
      .board .col { background: var(--card); border: 1px solid var(--border);
                    border-radius: 10px; padding: 12px; }
      .board .col h4 { margin-top: 0; }
      .board .col .item { padding: 8px 10px; border-radius: 6px; background: var(--bg);
                          border: 1px solid var(--border); font-size: 12px; margin-bottom: 6px; }

      /* Tag chips */
      .tag { display: inline-block; padding: 1px 6px; border-radius: 4px; font-size: 10px;
             background: color-mix(in srgb, var(--accent) 15%, transparent);
             color: var(--accent); margin-right: 4px; }

      /* PRD / Plan structure */
      .doc-head { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; margin-bottom: 8px; }
      .doc-head .doc-status { font-size: 11px; color: var(--muted); }
      .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
      @media (max-width: 720px) { .grid-2 { grid-template-columns: 1fr; } }

      /* Status / risk tables */
      .file-list { display: grid; gap: 8px; }
      .file-list .embed { margin-top: 10px; }
      .meta { color: var(--muted); font-size: 12px; }
      table { border-collapse: collapse; width: 100%; margin: 10px 0; font-size: 13px; }
      th, td { padding: 6px 10px; border-bottom: 1px solid var(--border); text-align: left;
               vertical-align: top; }
      th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase;
           letter-spacing: 0.5px; }
      .empty { color: var(--muted); font-style: italic; padding: 14px 0; }
      details > summary { cursor: pointer; padding: 6px 0; }

      /* Inline add buttons (data-action="dom-insert-template" etc.) */
      .add-btn { background: transparent; border: 1px dashed var(--border); color: var(--muted);
                 padding: 6px 12px; border-radius: 6px; font: inherit; font-size: 12px;
                 cursor: pointer; margin: 6px 0; }
      .add-btn:hover { color: var(--accent); border-color: var(--accent); }

      /* Inline remove (✕) buttons injected on .kpi / .item / .triage-card */
      .rm-btn { position: absolute; top: 4px; right: 4px; background: transparent;
                border: 0; color: var(--muted); font-size: 11px; line-height: 1;
                padding: 2px 5px; border-radius: 3px; cursor: pointer;
                opacity: 0; transition: opacity 0.12s, color 0.12s, background 0.12s; }
      .kpi:hover .rm-btn, .item:hover .rm-btn, .triage-card:hover .rm-btn { opacity: 1; }
      .rm-btn:hover { color: var(--red); background: color-mix(in srgb, var(--red) 12%, transparent); }

      /* Triage board */
      .triage-controls { display: flex; gap: 6px; margin: 12px 0; }
      .triage-cols { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px;
                     margin: 12px 0 24px; }
      .triage-col { background: var(--card); border: 1px solid var(--border);
                    border-radius: 10px; padding: 10px; min-height: 200px; }
      .triage-col h4 { margin-top: 0; display: flex; justify-content: space-between;
                       align-items: baseline; }
      .triage-list { min-height: 120px; }
      .triage-list.is-drop-target { background: color-mix(in srgb, var(--accent) 12%, transparent);
                                    border-radius: 6px; outline: 2px dashed var(--accent);
                                    outline-offset: -4px; }
      .triage-card { background: var(--bg); border: 1px solid var(--border); border-radius: 6px;
                     padding: 8px 10px; margin-bottom: 6px; cursor: grab; font-size: 12px; }
      .triage-card:active { cursor: grabbing; }
      .triage-card.dragging { opacity: 0.4; }
      .triage-card .t-title { font-weight: 500; }
      .triage-card .t-tags { margin-top: 4px; display: flex; gap: 4px; flex-wrap: wrap; }
      .triage-card .t-tags .tag { cursor: pointer; }
      .triage-card.is-filtered-out { display: none; }
      @media (max-width: 720px) {
        .triage-cols { grid-template-columns: 1fr 1fr; }
      }

      /* Bar chart (vanilla, no JS) */
      .bars { display: flex; align-items: flex-end; gap: 6px; height: 80px; padding: 8px 0; }
      .bars .bar { flex: 1; background: color-mix(in srgb, var(--accent) 60%, transparent);
                   border-radius: 3px 3px 0 0; min-height: 2px; position: relative; }
      .bars .bar .b-val { position: absolute; top: -16px; left: 0; right: 0; text-align: center;
                          font-size: 10px; color: var(--muted); }
      .bars .bar .b-label { position: absolute; bottom: -18px; left: 0; right: 0; text-align: center;
                            font-size: 10px; color: var(--muted); }
    </style>
    """

    private static let tabScript = """
    <script>
      (function() {
        // No URL fragment manipulation — file:// origin treats each fragment
        // as a unique origin and WKWebView blocks the navigation, which
        // looks like the page reverting to Overview.
        var btns = document.querySelectorAll('nav.tabs .tab');
        var panes = document.querySelectorAll('.tab-pane');
        btns.forEach(function(b) {
          b.addEventListener('click', function(e) {
            e.preventDefault();
            btns.forEach(function(x) { x.classList.remove('active'); });
            panes.forEach(function(p) { p.classList.remove('active'); });
            b.classList.add('active');
            var t = document.getElementById('tab-' + b.dataset.tab);
            if (t) t.classList.add('active');
          });
        });
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

