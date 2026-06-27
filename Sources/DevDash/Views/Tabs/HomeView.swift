import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.xl) {
                // Resolve each project's running port once up front, so the sort
                // comparator and the cards below do O(1) dict lookups instead of
                // re-deriving services per comparison (this runs every render).
                let active = store.projects.filter { (store.heatmaps[$0.path]?.totalCommits ?? 0) > 0 }
                let runningPorts: [String: Int] = Dictionary(
                    uniqueKeysWithValues: active.compactMap { p in
                        store.runningPort(for: p.path).map { (p.path, $0) }
                    }
                )
                let activeWithHeat = active.sorted { lhs, rhs in
                    let lRunning = runningPorts[lhs.path] != nil
                    let rRunning = runningPorts[rhs.path] != nil
                    if lRunning != rRunning { return lRunning }
                    let lc = store.heatmaps[lhs.path]?.totalCommits ?? 0
                    let rc = store.heatmaps[rhs.path]?.totalCommits ?? 0
                    return lc > rc
                }
                if !activeWithHeat.isEmpty {
                    Section(label: "Active Projects", systemImage: "square.grid.3x3") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: DSSpace.sm) {
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
                        .cardSurface()
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
                        .cardSurface()
                    }
                }

                if !store.infraServices.isEmpty {
                    Section(label: "Infrastructure", systemImage: "server.rack") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: DSSpace.md)], spacing: DSSpace.md) {
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
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack(spacing: DSSpace.xs) {
                Image(systemName: systemImage)
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
                Text(label.uppercased())
                    .font(DSFont.sectionHeader)
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
        HStack(spacing: DSSpace.md) {
            StatPill(label: "Running", value: store.devServices.count, hint: "live servers", color: DSColor.success)
            StatPill(label: "Projects", value: store.projects.count, hint: nil, color: .accentColor)
            StatPill(label: "Active", value: store.activeProjects.count, hint: "past 7 days", color: DSColor.warning)
            StatPill(label: "Sessions", value: store.sessions.count, hint: "recent claude", color: DSColor.assistant)
        }
    }
}

private struct StatPill: View {
    let label: String
    let value: Int
    let hint: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(label.uppercased())
                .font(DSFont.sectionHeader)
                .tracking(1)
                .foregroundColor(.secondary)
            Text(verbatim: String(value))
                .font(DSFont.display.monospacedDigit())
                .foregroundColor(color)
            Text(hint ?? " ")
                .font(DSFont.micro)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

private struct RunningServiceCard: View {
    let service: Service
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        Button {
            store.selection = .service(serviceID: service.id)
            store.previewDockOpen = true
        } label: {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                HStack(spacing: DSSpace.xs) {
                    PulsingDot()
                    Text(service.name)
                        .font(DSFont.title)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(verbatim: String(service.port))
                        .font(DSFont.monoDigits(.headline))
                        .foregroundColor(DSColor.success)
                }
                Text(service.framework)
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
                if !service.cwd.isEmpty {
                    Text(DevRoots.shortenPath(service.cwd))
                        .font(DSFont.mono(.caption2))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .padding(DSSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
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
            store.tabStore.detailTab = .info
            if runningPort != nil { store.previewDockOpen = true }
        } label: {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                HStack(spacing: DSSpace.xs) {
                    if runningPort != nil {
                        PulsingDot()
                    }
                    Text(project.name)
                        .font(DSFont.title)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let port = runningPort {
                        Text(verbatim: String(port))
                            .font(DSFont.monoDigits(.caption))
                            .foregroundColor(DSColor.success)
                    }
                }
                HStack(spacing: DSSpace.xs) {
                    Text(project.framework)
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                    if let days = project.daysSinceCommit {
                        Text("·").foregroundColor(.secondary).font(DSFont.micro)
                        Text(verbatim: "\(days)d ago")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(DSSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
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
            store.tabStore.detailTab = .info
            if runningPort != nil { store.previewDockOpen = true }
        } label: {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                HStack(spacing: DSSpace.xs) {
                    if runningPort != nil { PulsingDot() }
                    Text(project.name)
                        .font(DSFont.bodyEmphasized.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                HStack(spacing: 5) {
                    Text(project.framework)
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text("·").foregroundColor(.secondary).font(DSFont.micro)
                    Text(verbatim: "\(heatmap.totalCommits) commits")
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                CommitHeatmap(heatmap: heatmap)
            }
            .padding(DSSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(DSRadius.small)
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
            store.tabStore.detailTab = .info
        } label: {
            HStack(spacing: DSSpace.sm) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundColor(DSColor.success.opacity(0.7))
                Text(commit.projectName)
                    .font(DSFont.label.weight(.semibold))
                    .frame(width: 140, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(commit.subject)
                    .font(DSFont.label)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: commit.shortHash)
                    .font(DSFont.mono(.caption2))
                    .foregroundColor(.secondary)
                Text(timeAgo(commit.time))
                    .font(DSFont.monoDigits(.caption2))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, DSSpace.lg)
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
        HStack(spacing: DSSpace.sm) {
            Image(systemName: "server.rack")
                .foregroundColor(DSColor.assistant)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(DSFont.bodyEmphasized.weight(.semibold))
                Text(verbatim: "Port \(service.port)")
                    .font(DSFont.monoDigits(.caption2))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(DSSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

private struct HomeSessionRow: View {
    let session: ClaudeSession
    @EnvironmentObject var store: DashboardStore
    @State private var copied = false

    var body: some View {
        Button {
            store.openSessionId = session.id
        } label: {
            HStack(spacing: DSSpace.md) {
                Image(systemName: "bubble.left.fill")
                    .foregroundColor(DSColor.assistant)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DSSpace.xs) {
                        Text(session.projectName)
                            .font(DSFont.bodyEmphasized)
                            .foregroundColor(.primary)
                        if let title = store.digest(for: session.id)?.title {
                            Text("·").foregroundColor(.secondary).font(DSFont.micro)
                            Text(title)
                                .font(DSFont.label)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(timeAgo(session.lastActivity))
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let d = store.digest(for: session.id) {
                    Text(verbatim: "\(d.tokens.total.formatted()) tok")
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(.secondary)
                } else {
                    Text(verbatim: "\(session.messageCount) msgs")
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, DSSpace.lg)
            .padding(.vertical, DSSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("claude --resume \(session.id)", forType: .string)
            } label: { Label("Copy resume command", systemImage: "doc.on.clipboard") }
            Button {
                store.openSessionId = session.id
            } label: { Label("Open detail", systemImage: "rectangle.expand.vertical") }
        }
    }
}
