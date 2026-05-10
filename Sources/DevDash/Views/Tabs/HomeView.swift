import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let activeWithHeat = store.projects
                    .filter { (store.heatmaps[$0.path]?.totalCommits ?? 0) > 0 }
                    .sorted { lhs, rhs in
                        let lRunning = store.runningPort(for: lhs.path) != nil
                        let rRunning = store.runningPort(for: rhs.path) != nil
                        if lRunning != rRunning { return lRunning }
                        let lc = store.heatmaps[lhs.path]?.totalCommits ?? 0
                        let rc = store.heatmaps[rhs.path]?.totalCommits ?? 0
                        return lc > rc
                    }
                if !activeWithHeat.isEmpty {
                    Section(label: "Active Projects", systemImage: "square.grid.3x3") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 10) {
                                ForEach(activeWithHeat.prefix(40)) { proj in
                                    if let map = store.heatmaps[proj.path] {
                                        HeatmapCard(
                                            project: proj,
                                            heatmap: map,
                                            runningPort: store.runningPort(for: proj.path)
                                        )
                                        .frame(width: 220)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                StatsRow()

                if !store.recentCommits.isEmpty {
                    Section(label: "Recent Activity", systemImage: "clock.arrow.circlepath") {
                        VStack(spacing: 0) {
                            let visible = Array(store.recentCommits.prefix(15))
                            ForEach(visible) { commit in
                                CommitRow(commit: commit)
                                if commit.id != visible.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                    }
                }

                if !store.sessions.isEmpty {
                    Section(label: "Recent Claude Sessions", systemImage: "bubble.left.and.bubble.right") {
                        VStack(spacing: 0) {
                            ForEach(store.sessions.prefix(5)) { session in
                                HomeSessionRow(session: session)
                                if session.id != store.sessions.prefix(5).last?.id {
                                    Divider()
                                }
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                    }
                }

                if !store.infraServices.isEmpty {
                    Section(label: "Infrastructure", systemImage: "server.rack") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                            ForEach(store.infraServices) { svc in
                                InfraServiceCard(service: svc)
                            }
                        }
                    }
                }

                Color.clear.frame(height: 24)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Section<Content: View>: View {
    let label: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
            }
            content()
        }
    }
}

private struct StatsRow: View {
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        HStack(spacing: 12) {
            StatPill(label: "Running", value: store.devServices.count, hint: "live servers", color: .green)
            StatPill(label: "Projects", value: store.projects.count, hint: nil, color: .accentColor)
            StatPill(label: "Active", value: store.activeProjects.count, hint: "past 7 days", color: .orange)
            StatPill(label: "Sessions", value: store.sessions.count, hint: "recent claude", color: .purple)
        }
    }
}

private struct StatPill: View {
    let label: String
    let value: Int
    let hint: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1)
                .foregroundColor(.secondary)
            Text(verbatim: String(value))
                .font(.system(size: 26, weight: .bold).monospacedDigit())
                .foregroundColor(color)
            Text(hint ?? " ")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

private struct RunningServiceCard: View {
    let service: Service
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        Button {
            store.selection = .service(serviceID: service.id)
            store.detailTab = .preview
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PulsingDot()
                    Text(service.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(verbatim: String(service.port))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundColor(.green)
                }
                Text(service.framework)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if !service.cwd.isEmpty {
                    Text(DevRoots.shortenPath(service.cwd))
                        .font(.system(size: 10).monospaced())
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { await store.stopServer(pid: service.pid) }
            } label: { Label("Stop server", systemImage: "stop.fill") }
        }
    }
}

private struct RecentProjectCard: View {
    let project: Project
    let runningPort: Int?
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        Button {
            store.selection = .project(path: project.path)
            store.detailTab = runningPort != nil ? .preview : .info
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if runningPort != nil {
                        PulsingDot()
                    }
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let port = runningPort {
                        Text(verbatim: String(port))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundColor(.green)
                    }
                }
                HStack(spacing: 6) {
                    Text(project.framework)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if let days = project.daysSinceCommit {
                        Text("·").foregroundColor(.secondary).font(.system(size: 11))
                        Text(verbatim: "\(days)d ago")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

private struct HeatmapCard: View {
    let project: Project
    let heatmap: CommitHeatmapStore.Heatmap
    let runningPort: Int?
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        let runningServices = store.services(for: project.path)

        Button {
            store.selection = .project(path: project.path)
            store.detailTab = runningPort != nil ? .preview : .info
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if runningPort != nil { PulsingDot() }
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                HStack(spacing: 5) {
                    Text(project.framework)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text("·").foregroundColor(.secondary).font(.system(size: 10))
                    Text(verbatim: "\(heatmap.totalCommits) commits")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                CommitHeatmap(heatmap: heatmap)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !runningServices.isEmpty {
                ForEach(runningServices, id: \.id) { svc in
                    Button {
                        if let url = URL(string: "http://localhost:\(svc.port)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Open :\(svc.port) in browser", systemImage: "arrow.up.forward.app")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    Task { await store.stopServer(for: project.path) }
                } label: { Label("Stop all servers", systemImage: "stop.fill") }
            }
        }
    }
}

private struct CommitRow: View {
    let commit: RecentCommit
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        Button {
            store.selection = .project(path: commit.projectPath)
            store.detailTab = .info
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundColor(.green.opacity(0.7))
                Text(commit.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 140, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(commit.subject)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: commit.shortHash)
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(.secondary)
                Text(timeAgo(commit.time))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct InfraServiceCard: View {
    let service: Service

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: "Port \(service.port)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

private struct HomeSessionRow: View {
    let session: ClaudeSession
    @EnvironmentObject var store: DashboardStore
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.fill")
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName)
                    .font(.system(size: 13, weight: .medium))
                Text(timeAgo(session.lastActivity))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(verbatim: "\(session.messageCount) msgs")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("claude --resume \(session.id)", forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Resume", systemImage: copied ? "checkmark" : "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
