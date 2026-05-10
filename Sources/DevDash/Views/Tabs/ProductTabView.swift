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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func content(project: Project) -> some View {
        let path = ProductDocGenerator.indexPath(for: project.path)
        let docsRoot = URL(fileURLWithPath: ProductDocGenerator.folderPath(for: project.path))
        if FileManager.default.fileExists(atPath: path) {
            ProductWebView(
                url: URL(fileURLWithPath: path),
                docsRoot: docsRoot,
                reloadToken: reloadToken,
                onSave: { rel, html in
                    saveSection(projectPath: project.path, rel: rel, html: html)
                },
                onAction: { payload in
                    handleAction(project: project, payload: payload)
                }
            )
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Generating…").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Bridge handler: write the edited HTML back to its source file.
    /// Doesn't trigger a regen — that would clobber the cursor mid-edit.
    private func saveSection(projectPath: String, rel: String, html: String) {
        let target = "\(projectPath)/docs/devdash/\(rel)"
        let dir = (target as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? html.write(toFile: target, atomically: true, encoding: .utf8)
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
            tasks: tasks
        )
        lastRegenAt = Date()
        reloadToken &+= 1   // force WKWebView reload so latest HTML + JS land
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
