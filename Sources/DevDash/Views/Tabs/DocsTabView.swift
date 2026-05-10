import SwiftUI
import AppKit

struct DocsTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var content: AttributedString? = nil
    @State private var rawText: String = ""
    @State private var notFound = false
    @State private var loadedPath: String? = nil

    var body: some View {
        Group {
            if let project = store.project(for: store.selection) {
                docsContent(for: project)
                    .onAppear { loadIfNeeded(project: project) }
                    .onChange(of: project.path) { newPath in
                        loadedPath = nil
                        loadIfNeeded(project: store.projects.first { $0.path == newPath } ?? project)
                    }
            } else {
                Text("Select a project to read its docs")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func docsContent(for project: Project) -> some View {
        if notFound {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("No README.md found in \(project.name)")
                    .foregroundColor(.secondary)
                Button("Reveal project") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let attr = content {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(attr)
                        .textSelection(.enabled)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadIfNeeded(project: Project) {
        if loadedPath == project.path { return }
        loadedPath = project.path
        notFound = false
        content = nil

        Task.detached(priority: .userInitiated) {
            let candidates = ["README.md", "Readme.md", "readme.md", "README.markdown"]
            var loaded: String? = nil
            for name in candidates {
                let p = "\(project.path)/\(name)"
                if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
                   let s = String(data: data, encoding: .utf8) {
                    loaded = s
                    break
                }
            }

            await MainActor.run {
                guard let text = loaded else {
                    notFound = true
                    return
                }
                rawText = text
                content = parseMarkdown(text)
            }
        }
    }

    private func parseMarkdown(_ text: String) -> AttributedString {
        var out = AttributedString()
        let lines = text.components(separatedBy: .newlines)

        var inCodeBlock = false
        for line in lines {
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                out.append(AttributedString("\n"))
                continue
            }

            if inCodeBlock {
                var seg = AttributedString(line + "\n")
                seg.font = .system(size: 12).monospaced()
                seg.foregroundColor = .secondary
                out.append(seg)
                continue
            }

            if line.hasPrefix("# ") {
                var seg = AttributedString(String(line.dropFirst(2)))
                seg.font = .system(size: 28, weight: .bold)
                out.append(seg)
                out.append(AttributedString("\n\n"))
            } else if line.hasPrefix("## ") {
                var seg = AttributedString(String(line.dropFirst(3)))
                seg.font = .system(size: 22, weight: .semibold)
                out.append(seg)
                out.append(AttributedString("\n\n"))
            } else if line.hasPrefix("### ") {
                var seg = AttributedString(String(line.dropFirst(4)))
                seg.font = .system(size: 17, weight: .semibold)
                out.append(seg)
                out.append(AttributedString("\n\n"))
            } else if line.isEmpty {
                out.append(AttributedString("\n"))
            } else {
                if let parsed = try? AttributedString(markdown: line) {
                    out.append(parsed)
                } else {
                    out.append(AttributedString(line))
                }
                out.append(AttributedString("\n"))
            }
        }
        return out
    }
}
