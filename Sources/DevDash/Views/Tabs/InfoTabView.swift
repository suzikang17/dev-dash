import SwiftUI
import AppKit

struct InfoTabView: View {
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        if let project = store.project(for: store.selection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(project.name)
                        .font(.largeTitle.bold())

                    Text(DevRoots.shortenPath(project.path))
                        .font(.system(size: 12).monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    InfoCard {
                        InfoRow(label: "Framework", value: project.framework, icon: "cube.box")
                        Divider()
                        InfoRow(label: "Stack", value: project.stack ?? "—", icon: "stack.3d")
                        Divider()
                        InfoRow(label: "Health", value: project.health.label, icon: "heart")
                        if let days = project.daysSinceCommit {
                            Divider()
                            InfoRow(label: "Last commit", value: "\(days) days ago", icon: "clock")
                        }
                        if let branch = project.branch {
                            Divider()
                            InfoRow(label: "Branch", value: branch, icon: "arrow.triangle.branch", monospaced: true)
                        }
                        if let url = project.githubURL {
                            Divider()
                            InfoRow(label: "GitHub", value: url.absoluteString, icon: "link", linkURL: url)
                        }
                        if let port = store.runningPort(for: project.path) {
                            Divider()
                            InfoRow(label: "Running on", value: "localhost:\(port)", icon: "play.circle.fill",
                                    linkURL: URL(string: "http://localhost:\(port)"))
                        }
                    }

                    HStack(spacing: 10) {
                        if store.runningPort(for: project.path) == nil {
                            Button {
                                Task { await store.startServer(for: project.path) }
                            } label: {
                                Label("Start dev server", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isStarting(project.path))
                        } else {
                            Button(role: .destructive) {
                                Task { await store.stopServer(for: project.path) }
                            } label: {
                                Label("Stop dev server", systemImage: "stop.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)

                        if let url = project.githubURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open GitHub", systemImage: "arrow.up.forward.square")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if let err = store.startError(project.path) {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }

                    ContextCard(project: project)

                    Spacer()
                }
                .padding(20)
            }
        } else {
            Text("Select a project to see info")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ContextCard: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        let path = project.path
        let projectSessions = store.sessions.filter {
            $0.projectPath == path || $0.projectPath.hasPrefix("\(path)/")
        }
        let openTodos = (store.tasksByProject.first { $0.projectPath == path }?.todos ?? [])
            .filter { !$0.done }.count

        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT ACTIVITY")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)

            if projectSessions.isEmpty && openTodos == 0 {
                Text("No recent activity logged for this project.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if openTodos > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").foregroundColor(.secondary)
                    Text(verbatim: "\(openTodos) open todo\(openTodos == 1 ? "" : "s")")
                }
                .font(.system(size: 12))
            }

            if !projectSessions.isEmpty {
                Divider()
                Text("RECENT CLAUDE SESSIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(projectSessions.prefix(5)) { s in
                        HStack(alignment: .top, spacing: 8) {
                            Text(timeAgo(s.lastActivity))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(s.firstUserMessage ?? "(no user message)")
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

private struct InfoCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    let icon: String
    var monospaced: Bool = false
    var linkURL: URL? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            if let url = linkURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(value)
                        .foregroundColor(.accentColor)
                        .font(monospaced ? .system(size: 13).monospaced() : .system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            } else {
                Text(value)
                    .font(monospaced ? .system(size: 13).monospaced() : .system(size: 13))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }
}
