import SwiftUI
import AppKit

enum SidebarTab: String, CaseIterable, Identifiable {
    case running, projects, infra
    var id: String { rawValue }
    var label: String {
        switch self {
        case .running: return "Running"
        case .projects: return "Projects"
        case .infra: return "Infra"
        }
    }
    var systemImage: String {
        switch self {
        case .running: return "play.circle.fill"
        case .projects: return "folder.fill"
        case .infra: return "server.rack"
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var search = ""
    @State private var sidebarTab: SidebarTab = .running

    var filteredProjects: [Project] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.projects }
        return store.projects.filter { $0.name.lowercased().contains(q) }
    }

    var filteredServices: [Service] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.devServices }
        return store.devServices.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        // Evaluate the filtered lists and running-port map once per render.
        // These were recomputed on every access (filteredServices was read 3×,
        // runningPort was called per row), all on the main thread.
        let projects = filteredProjects
        let services = filteredServices
        let runningPorts: [String: Int] = Dictionary(
            uniqueKeysWithValues: store.projects.compactMap { p in
                store.runningPort(for: p.path).map { (p.path, $0) }
            }
        )
        // Group running services under their owning project so a project with
        // several processes (e.g. cliphy's web + server) shows as one entry with
        // the processes nested, instead of N flat rows. Computed once per render.
        let runningGroups = Self.groupRunning(services, projects: store.projects)
        return VStack(spacing: 0) {
            Picker("Section", selection: $sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Image(systemName: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            List(selection: $store.selection) {
                switch sidebarTab {
                case .running:
                    let pinned = store.projects.filter { store.isPinned($0.path) }
                    if !pinned.isEmpty {
                        Section {
                            ForEach(pinned) { proj in
                                SidebarProjectRow(project: proj, runningPort: runningPorts[proj.path])
                                    .tag(Selection.project(path: proj.path))
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text("PINNED")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(1.2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(verbatim: String(pinned.count))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    if !services.isEmpty {
                        Section {
                            ForEach(runningGroups) { group in
                                if group.services.count >= 2, let proj = group.project {
                                    SidebarRunningGroupHeader(project: proj, services: group.services)
                                        .tag(Selection.project(path: proj.path))
                                    ForEach(group.services) { svc in
                                        SidebarServiceRow(service: svc, nested: true)
                                            .tag(Selection.service(serviceID: svc.id))
                                    }
                                } else {
                                    ForEach(group.services) { svc in
                                        SidebarServiceRow(service: svc)
                                            .tag(Selection.service(serviceID: svc.id))
                                    }
                                }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text("RUNNING")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(1.2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(verbatim: String(services.count))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    if services.isEmpty && pinned.isEmpty {
                        Text("Nothing here yet — pin a project from its context menu")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                            .padding(.vertical, 12)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                case .projects:
                    let grouped = Dictionary(grouping: projects) {
                        DevRoots.rootGroup(for: $0.path)
                    }
                    let groupKeys = grouped.keys.sorted()
                    ForEach(groupKeys, id: \.self) { key in
                        Section {
                            ForEach(grouped[key] ?? []) { proj in
                                SidebarProjectRow(project: proj, runningPort: runningPorts[proj.path])
                                    .tag(Selection.project(path: proj.path))
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text(verbatim: "~/\(key)")
                                    .font(.system(size: 10, weight: .semibold).monospaced())
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(verbatim: String(grouped[key]?.count ?? 0))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                case .infra:
                    if store.infraServices.isEmpty {
                        Text("No infra detected")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(store.infraServices) { svc in
                            SidebarServiceRow(service: svc)
                                .tag(Selection.service(serviceID: svc.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        Button {
                            store.selection = .home
                        } label: {
                            Image(systemName: store.selection == .home ? "house.fill" : "house")
                                .foregroundColor(store.selection == .home ? .accentColor : .secondary)
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("0", modifiers: .command)
                        .help("Home (⌘0)")

                        Divider().frame(height: 14)

                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        TextField("Search…", text: $search)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !search.isEmpty {
                            Button {
                                search = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
    }

    /// A project and the running dev services beneath it, for the RUNNING list.
    struct RunningGroup: Identifiable {
        let id: String              // owning project path, or "svc:<id>" if unmatched
        let project: Project?
        let services: [Service]     // sorted by port
    }

    /// Partition running dev services by the project that owns them (longest
    /// matching project-path prefix). Group order follows first appearance in
    /// the incoming `services` list so the layout stays stable across renders.
    static func groupRunning(_ services: [Service], projects: [Project]) -> [RunningGroup] {
        func owner(of svc: Service) -> Project? {
            projects
                .filter { svc.cwd == $0.path || svc.cwd.hasPrefix("\($0.path)/") }
                .max { $0.path.count < $1.path.count }
        }
        var order: [String] = []
        var byKey: [String: (project: Project?, services: [Service])] = [:]
        for svc in services {
            let proj = owner(of: svc)
            let key = proj?.path ?? "svc:\(svc.id)"
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = (proj, [])
            }
            byKey[key]?.services.append(svc)
        }
        return order.map { key in
            let entry = byKey[key]!
            return RunningGroup(
                id: key,
                project: entry.project,
                services: entry.services.sorted { $0.port < $1.port }
            )
        }
    }
}

private struct SidebarHeader: View {
    let title: String
    let count: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
            Spacer()
            Text(verbatim: String(count))
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Header row for a project running 2+ processes. Surfaces the processes' ports
/// (instead of the git branch) and selects the project when tapped.
private struct SidebarRunningGroupHeader: View {
    let project: Project
    let services: [Service]
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(services.map { String($0.port) }.joined(separator: " · "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.green)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .contextMenu {
            ForEach(services, id: \.id) { svc in
                Button {
                    if let url = URL(string: "http://localhost:\(svc.port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: { Label("Open :\(svc.port) in browser", systemImage: "arrow.up.forward.app") }
            }
            Divider()
            Button(role: .destructive) {
                Task { await store.stopServer(for: project.path) }
            } label: { Label("Stop all servers", systemImage: "stop.fill") }
        }
    }
}

/// One running process. When `nested` it sits under a project group header, so
/// it shows just the short process name (e.g. "server") and drops the branch —
/// the project + ports already live on the header above it.
private struct SidebarServiceRow: View {
    let service: Service
    var nested: Bool = false
    @EnvironmentObject var store: DashboardStore

    /// The trailing component of a "project › process" name, used when nested.
    private var shortName: String {
        service.name
            .components(separatedBy: "›")
            .last?
            .trimmingCharacters(in: .whitespaces) ?? service.name
    }

    var body: some View {
        HStack(spacing: 8) {
            if !service.isInfra {
                PulsingDot()
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundColor(.green)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(nested ? shortName : service.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if !nested, let proj = store.project(for: .service(serviceID: service.id)) {
                        GitRefLabel(path: proj.path, branch: proj.branch)
                    }
                    Text(service.framework)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .lineLimit(1)
            }
            Spacer()
            Text(verbatim: String(service.port))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 5)
        .padding(.leading, nested ? 18 : 2)
        .padding(.trailing, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !service.isInfra {
                Button(role: .destructive) {
                    Task { await store.stopServer(pid: service.pid) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.red)
            }
        }
        .contextMenu {
            if !service.isInfra {
                Button {
                    if let url = URL(string: "http://localhost:\(service.port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: { Label("Open in browser", systemImage: "arrow.up.forward.app") }

                Divider()

                Button(role: .destructive) {
                    Task { await store.stopServer(pid: service.pid) }
                } label: { Label("Stop server", systemImage: "stop.fill") }
            }
        }
    }
}

private struct SidebarProjectRow: View {
    let project: Project
    let runningPort: Int?
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        HStack(spacing: 8) {
            if runningPort != nil {
                PulsingDot()
            } else {
                Image(systemName: healthIcon)
                    .font(.system(size: 9))
                    .foregroundColor(healthColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if store.isPinned(project.path) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    GitRefLabel(path: project.path, branch: project.branch)
                    Text(project.framework)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if let days = project.daysSinceCommit {
                        Text("·").foregroundColor(.secondary).font(.system(size: 10))
                        Text("\(days)d")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                .lineLimit(1)
            }
            Spacer()
            if let port = runningPort {
                Text(verbatim: String(port))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                store.togglePin(project.path)
            } label: {
                Label(store.isPinned(project.path) ? "Unpin" : "Pin",
                      systemImage: store.isPinned(project.path) ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                store.togglePin(project.path)
            } label: {
                Label(store.isPinned(project.path) ? "Unpin from Running" : "Pin to Running",
                      systemImage: store.isPinned(project.path) ? "pin.slash" : "pin")
            }
            if runningPort == nil {
                Button {
                    Task { await store.startServer(for: project.path) }
                } label: {
                    Label("Start dev server", systemImage: "play.fill")
                }
            }
            Divider()
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            if let url = project.githubURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open GitHub", systemImage: "arrow.up.forward.square")
                }
            }
        }
    }

    private var healthColor: Color {
        switch project.health {
        case .active: return .green
        case .moderate: return .yellow
        case .stale: return .orange
        case .archived: return .gray
        case .noGit: return .secondary
        }
    }

    private var healthIcon: String {
        switch project.health {
        case .active: return "circle.fill"
        case .moderate: return "circle.fill"
        case .stale: return "circle.fill"
        case .archived: return "circle"
        case .noGit: return "questionmark.circle"
        }
    }
}

/// Shows either a worktree indicator (⊞ name) or a branch indicator (⎇ branch)
/// followed by a "·" separator, or nothing if there's no git info yet.
private struct GitRefLabel: View {
    let path: String
    let branch: String?
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        let worktrees = store.gitStatuses[path]?.worktrees ?? []
        let thisTree = worktrees.first(where: { $0.path == path })
        let isWorktree = worktrees.count > 1 && thisTree?.isMain == false

        if isWorktree, let name = thisTree?.displayName {
            HStack(spacing: 3) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 8))
                    .foregroundColor(.purple)
                Text(name)
                    .font(.system(size: 10).monospaced())
                    .foregroundColor(.purple)
                Text("·").font(.system(size: 10)).foregroundColor(.secondary)
            }
        } else if let b = branch ?? store.gitStatuses[path]?.branch {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                Text(b)
                    .font(.system(size: 10).monospaced())
                    .foregroundColor(.secondary)
                Text("·").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
}
