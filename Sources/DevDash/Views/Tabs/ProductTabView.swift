import SwiftUI
import AppKit

/// Renders the living product document — a single HTML page with internal
/// tabs (Overview / Roadmap / Initiatives / Goals / Ideas / PRDs / Docs)
/// at `docs/devdash/index.html`. Generated from JSON state + sibling .md
/// files; viewed via WKWebView.
struct ProductTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var lastRegenAt: Date?

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
                Button("Edit one-pager") { openMd("\(project.path)/docs/devdash/one-pager.md") }
                Button("Edit goals & KPIs") { openMd("\(project.path)/docs/devdash/goals.md") }
                Button("Edit ideas") { openMd("\(project.path)/docs/devdash/ideas.md") }
                Divider()
                Button("New PRD…") { newDoc(at: "\(project.path)/docs/devdash/prds", suggested: "prd-feature.md") }
                Button("New document…") { newDoc(at: "\(project.path)/docs/devdash/documents", suggested: "doc.md") }
            } label: {
                Image(systemName: "pencil.and.outline")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
            .help("Edit sections")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func content(project: Project) -> some View {
        let path = ProductDocGenerator.indexPath(for: project.path)
        if FileManager.default.fileExists(atPath: path) {
            FileWebView(fileURL: URL(fileURLWithPath: path))
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Generating…").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    private func openMd(_ path: String) {
        store.pendingFilePath = path
        store.detailTab = .files
    }

    private func newDoc(at folder: String, suggested: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = "\(folder)/\(suggested)"
        if !FileManager.default.fileExists(atPath: target) {
            let stub = "# \((suggested as NSString).deletingPathExtension)\n\n_Drafted by DevDash. Edit me._\n"
            try? stub.write(toFile: target, atomically: true, encoding: .utf8)
        }
        openMd(target)
    }
}
