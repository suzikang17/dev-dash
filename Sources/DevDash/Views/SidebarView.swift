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
    @State private var showNewGroupSheet = false
    @State private var newGroupName = ""
    @State private var pendingGroupProjectPath: String? = nil

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
                            HStack(spacing: DSSpace.xs) {
                                Image(systemName: "pin.fill")
                                    .font(DSFont.micro)
                                    .foregroundColor(.secondary)
                                Text("PINNED")
                                    .font(DSFont.micro.weight(.semibold))
                                    .tracking(1.2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(verbatim: String(pinned.count))
                                    .font(DSFont.monoDigits(.caption2))
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
                            HStack(spacing: DSSpace.xs) {
                                Image(systemName: "play.circle.fill")
                                    .font(DSFont.micro)
                                    .foregroundColor(.secondary)
                                Text("RUNNING")
                                    .font(DSFont.micro.weight(.semibold))
                                    .tracking(1.2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(verbatim: String(services.count))
                                    .font(DSFont.monoDigits(.caption2))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    if services.isEmpty && pinned.isEmpty {
                        Text("Nothing here yet — pin a project from its context menu")
                            .foregroundColor(.secondary)
                            .font(DSFont.label)
                            .padding(.vertical, DSSpace.md)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                case .projects:
                    // Determine which project paths are in any group.
                    let groupedPaths = Set(store.projectGroups.flatMap { $0.projectPaths })

                    // --- Group sections (Linear-bound) first ---
                    ForEach(store.projectGroups.sorted(by: { $0.createdAt < $1.createdAt })) { grp in
                        let members = grp.projectPaths.compactMap { path in
                            projects.first { $0.path == path }
                        }
                        let visibleMembers: [Project] = {
                            let q = search.trimmingCharacters(in: .whitespaces).lowercased()
                            guard !q.isEmpty else { return members }
                            return members.filter { $0.name.lowercased().contains(q) }
                        }()
                        if !visibleMembers.isEmpty || search.trimmingCharacters(in: .whitespaces).isEmpty {
                            CollapsibleGroupSection(
                                group: grp,
                                members: visibleMembers,
                                runningPorts: runningPorts
                            )
                        }
                    }

                    // --- Ungrouped repos under their dev-root folder headers ---
                    let ungrouped = projects.filter { !groupedPaths.contains($0.path) }
                    // Compute worktree groups from the ungrouped set; child worktrees
                    // are removed from the flat list and nested under their parent.
                    let wtGroups = Self.groupWorktrees(ungrouped, gitStatuses: store.gitStatuses)
                    // Only parent rows participate in the folder-header bucketing;
                    // children are rendered inline under their parent by WorktreeGroupRow.
                    let topLevel = wtGroups.map { $0.parent }
                    let folderGrouped = Dictionary(grouping: topLevel) {
                        DevRoots.rootGroup(for: $0.path)
                    }
                    // Lookup: parent path → WorktreeGroup, only for groups that actually
                    // have children. Parents with no children render as plain SidebarProjectRows.
                    let wtByParent = Dictionary(
                        uniqueKeysWithValues: wtGroups.filter { !$0.children.isEmpty }.map { ($0.parent.path, $0) }
                    )
                    let folderKeys = folderGrouped.keys.sorted()
                    ForEach(folderKeys, id: \.self) { key in
                        Section {
                            ForEach(folderGrouped[key] ?? []) { proj in
                                if let wtGroup = wtByParent[proj.path] {
                                    // Main checkout of a repo with extra worktrees in the list —
                                    // render collapsible group. WorktreeGroupRow only shows a
                                    // disclosure chevron when children.count > 0 (guaranteed here).
                                    WorktreeGroupRow(
                                        wtGroup: wtGroup,
                                        runningPorts: runningPorts,
                                        onNewGroup: {
                                            pendingGroupProjectPath = proj.path
                                            showNewGroupSheet = true
                                        }
                                    )
                                } else {
                                    SidebarProjectRow(
                                        project: proj,
                                        runningPort: runningPorts[proj.path],
                                        onNewGroup: {
                                            pendingGroupProjectPath = proj.path
                                            showNewGroupSheet = true
                                        },
                                        onAddToGroup: { _ in }
                                    )
                                    .tag(Selection.project(path: proj.path))
                                }
                            }
                        } header: {
                            // Count = parents + their nested children so the badge reflects
                            // the true number of repos under this folder root.
                            let folderParents = folderGrouped[key] ?? []
                            let totalCount = folderParents.reduce(0) { acc, proj in
                                acc + 1 + (wtByParent[proj.path]?.children.count ?? 0)
                            }
                            HStack(spacing: DSSpace.xs) {
                                Image(systemName: "folder")
                                    .font(DSFont.micro)
                                    .foregroundColor(.secondary)
                                Text(verbatim: "~/\(key)")
                                    .font(DSFont.mono(.caption2).weight(.semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(verbatim: String(totalCount))
                                    .font(DSFont.monoDigits(.caption2))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                case .infra:
                    if store.infraServices.isEmpty {
                        Text("No infra detected")
                            .foregroundColor(.secondary)
                            .font(DSFont.label)
                            .padding(.vertical, DSSpace.md)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(store.infraServices) { svc in
                            SidebarServiceRow(service: svc)
                                .tag(Selection.service(serviceID: svc.id))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .sheet(isPresented: $showNewGroupSheet) {
                NewGroupSheet(
                    projectPath: pendingGroupProjectPath,
                    onCreated: { pendingGroupProjectPath = nil }
                )
                .environmentObject(store)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: DSSpace.sm) {
                        Button {
                            store.selection = .home
                        } label: {
                            Image(systemName: store.selection == .home ? "house.fill" : "house")
                                .foregroundColor(store.selection == .home ? .accentColor : .secondary)
                                .font(DSFont.body)
                        }
                        .buttonStyle(.plain)
                        .dsHitTarget()
                        .keyboardShortcut("0", modifiers: .command)
                        .help("Home (⌘0)")
                        .accessibilityLabel("Home")

                        Button {
                            store.selection = .simulator
                        } label: {
                            Image(systemName: store.selection == .simulator ? "iphone.gen3" : "iphone")
                                .foregroundColor(store.selection == .simulator ? .accentColor : .secondary)
                                .font(DSFont.body)
                        }
                        .buttonStyle(.plain)
                        .dsHitTarget()
                        .help("Simulator")
                        .accessibilityLabel("Simulator")

                        Divider().frame(height: 14)

                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(DSFont.micro)
                        TextField("Search…", text: $search)
                            .textFieldStyle(.plain)
                            .font(DSFont.label)
                        if !search.isEmpty {
                            Button {
                                search = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(DSFont.micro)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, DSSpace.sm)
                    .padding(.vertical, DSSpace.sm)
                    .background(.bar)

                    Divider()
                    HStack(spacing: DSSpace.sm) {
                        if store.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            TimeAgoLabel()
                        }
                        Spacer()
                        Button {
                            store.previewDockOpen.toggle()
                        } label: {
                            Image(systemName: store.previewDockOpen ? "sidebar.right" : "sidebar.squares.right")
                                .foregroundColor(store.previewDockOpen ? .accentColor : .secondary)
                                .font(DSFont.body)
                        }
                        .buttonStyle(.plain)
                        .dsHitTarget()
                        .disabled(store.project(for: store.selection) == nil)
                        .help("Toggle Preview dock (⌘P)")
                        .accessibilityLabel("Toggle Preview dock")

                        Button {
                            store.terminalOpen.toggle()
                        } label: {
                            Image(systemName: "terminal")
                                .foregroundColor(.secondary)
                                .font(DSFont.body)
                        }
                        .buttonStyle(.plain)
                        .dsHitTarget()
                        .keyboardShortcut("`", modifiers: .command)
                        .disabled(store.project(for: store.selection) == nil)
                        .help("Toggle terminal (⌘`)")
                        .accessibilityLabel("Toggle terminal")

                        Button {
                            Task { await store.refreshAll(); await store.refreshTodos() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.secondary)
                                .font(DSFont.body)
                        }
                        .buttonStyle(.plain)
                        .dsHitTarget()
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Refresh (⌘R)")
                        .accessibilityLabel("Refresh")
                    }
                    .padding(.horizontal, DSSpace.sm)
                    .padding(.vertical, DSSpace.xs)
                    .background(.bar)
                }
            }
        }
    }

    // MARK: - Worktree grouping

    /// A repo's main checkout plus any sibling worktrees that also appear in the
    /// project list. Purely presentational — no mutation of store data.
    struct WorktreeGroup: Identifiable {
        /// The main checkout (isMain == true), or the best stand-in when the
        /// actual main checkout isn't in the scanned project list.
        let parent: Project
        /// Non-main worktree projects belonging to the same repo, in their
        /// original list order.
        let children: [Project]
        var id: String { parent.path }
    }

    /// Build worktree groups from `projects` + `gitStatuses`.
    ///
    /// Algorithm:
    /// 1. For each project, resolve its repo's main-checkout path from
    ///    `gitStatuses[project.path].worktrees.first(where:{ $0.isMain })?.path`.
    ///    Projects with no gitStatus (standalone, no git) map to their own path.
    /// 2. Group all projects by that main path.
    /// 3. For each group with >1 member, designate the main project as parent
    ///    and the rest as children. Single-member groups are standalone (no nesting).
    /// 4. Return one `WorktreeGroup` per repo. Input order is preserved for parent
    ///    selection and child ordering so the list is stable across renders.
    static func groupWorktrees(
        _ projects: [Project],
        gitStatuses: [String: GitStatus]
    ) -> [WorktreeGroup] {
        // Map each project to the path of its repo's main checkout.
        func mainPath(for project: Project) -> String {
            gitStatuses[project.path]?
                .worktrees
                .first(where: { $0.isMain })?
                .path ?? project.path
        }

        // Collect groups preserving first-seen order of the main path.
        var order: [String] = []
        var byMain: [String: [Project]] = [:]
        for proj in projects {
            let key = mainPath(for: proj)
            if byMain[key] == nil { order.append(key) }
            byMain[key, default: []].append(proj)
        }

        return order.compactMap { key -> WorktreeGroup? in
            guard let members = byMain[key], !members.isEmpty else { return nil }
            if members.count == 1 {
                // No sibling worktrees in the list — render flat.
                return WorktreeGroup(parent: members[0], children: [])
            }
            // Pick the main checkout as parent; fall back to first member if the
            // actual main path isn't in our project list.
            let parent = members.first(where: { $0.path == key }) ?? members[0]
            let children = members.filter { $0.path != parent.path }
            return WorktreeGroup(parent: parent, children: children)
        }
    }

    // MARK: - Running group helpers

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
        HStack(spacing: DSSpace.xs) {
            Image(systemName: systemImage)
                .font(DSFont.micro)
                .foregroundColor(.secondary)
            Text(title.uppercased())
                .font(DSFont.sectionHeader)
                .tracking(0.6)
            Spacer()
            Text(verbatim: String(count))
                .font(DSFont.monoDigits(.caption2))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, DSSpace.xs)
    }
}

/// Header row for a project running 2+ processes. Surfaces the processes' ports
/// (instead of the git branch) and selects the project when tapped.
private struct SidebarRunningGroupHeader: View {
    let project: Project
    let services: [Service]
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        HStack(spacing: DSSpace.sm) {
            PulsingDot()
            Text(project.name)
                .font(DSFont.body.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(services.map { String($0.port) }.joined(separator: " · "))
                .font(DSFont.mono(.caption2))
                .foregroundColor(DSColor.success)
                .lineLimit(1)
        }
        .padding(.vertical, DSSpace.xs)
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
        HStack(spacing: DSSpace.sm) {
            if !service.isInfra {
                PulsingDot()
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundColor(DSColor.success)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(nested ? shortName : service.name)
                    .font(DSFont.bodyEmphasized)
                    .lineLimit(1)
                HStack(spacing: DSSpace.xs) {
                    if !nested, let proj = store.project(for: .service(serviceID: service.id)) {
                        GitRefLabel(path: proj.path, branch: proj.branch)
                    }
                    Text(service.framework)
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                }
                .lineLimit(1)
            }
            Spacer()
            Text(verbatim: String(service.port))
                .font(DSFont.mono(.caption2))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, DSSpace.xs)
        .padding(.leading, nested ? 18 : 2)
        .padding(.trailing, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !service.isInfra {
                Button(role: .destructive) {
                    Task { await store.stopServer(pid: service.pid) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(DSColor.danger)
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
    /// Callbacks injected by the parent sidebar so the row can trigger sheets
    /// without holding its own @State (which would be reset on list rebuilds).
    var onNewGroup: (() -> Void)? = nil
    var onAddToGroup: ((String) -> Void)? = nil

    /// True when an external Claude Code session is actively working in this project.
    private var hasLiveSession: Bool {
        store.liveSessions.values.contains {
            $0.status == .active && (
                $0.projectPath == project.path
                || $0.cwd == project.path
                || $0.cwd.hasPrefix("\(project.path)/")
            )
        }
    }

    var body: some View {
        HStack(spacing: DSSpace.sm) {
            if runningPort != nil {
                PulsingDot()
            } else {
                Image(systemName: healthIcon)
                    .font(.system(size: 9))
                    .foregroundColor(healthColor)
                    .healthAura(healthColor, active: project.health == .stale)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DSSpace.xs) {
                    Text(project.name)
                        .font(DSFont.bodyEmphasized)
                        .lineLimit(1)
                    if store.isPinned(project.path) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                    // Subtle live-session indicator
                    if hasLiveSession {
                        Circle()
                            .fill(DSColor.success)
                            .frame(width: 6, height: 6)
                            .help("Active Claude session")
                    }
                    // Worktree count indicator (⊞ N)
                    let activeWorktreeCount = store.tasksV2(for: project.path)
                        .filter { $0.worktree != nil }.count
                    if activeWorktreeCount > 0 {
                        HStack(spacing: 2) {
                            Text("⊞")
                                .font(.system(size: 8))
                                .foregroundColor(DSColor.info)
                            Text("\(activeWorktreeCount)")
                                .font(DSFont.monoDigits(.caption2))
                                .foregroundColor(DSColor.info)
                        }
                        .help("\(activeWorktreeCount) active worktree\(activeWorktreeCount == 1 ? "" : "s")")
                    }
                }
                HStack(spacing: DSSpace.xs) {
                    GitRefLabel(path: project.path, branch: project.branch)
                    Text(project.framework)
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                    if let days = project.daysSinceCommit {
                        Text("·").foregroundColor(.secondary).font(DSFont.micro)
                        Text("\(days)d")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                    }
                }
                .lineLimit(1)
            }
            Spacer()
            if let port = runningPort {
                Text(verbatim: String(port))
                    .font(DSFont.mono(.caption2))
                    .foregroundColor(DSColor.success)
            }
        }
        .padding(.vertical, DSSpace.xs)
        .padding(.horizontal, 2)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                store.togglePin(project.path)
            } label: {
                Label(store.isPinned(project.path) ? "Unpin" : "Pin",
                      systemImage: store.isPinned(project.path) ? "pin.slash.fill" : "pin.fill")
            }
            .tint(DSColor.warning)
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
            // Group membership
            let currentGroup = store.group(for: project.path)
            if let g = currentGroup {
                Button {
                    store.removeProjectFromGroup(projectPath: project.path)
                } label: {
                    Label("Remove from \"\(g.name)\"", systemImage: "rectangle.badge.minus")
                }
            }
            Menu("Add to Linear group") {
                ForEach(store.projectGroups.sorted(by: { $0.name < $1.name })) { g in
                    if g.id != currentGroup?.id {
                        Button(g.name) {
                            onAddToGroup?(g.id)
                            store.addProjectToGroup(projectPath: project.path, groupId: g.id)
                        }
                    }
                }
                Divider()
                Button("New group…") { onNewGroup?() }
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
        case .active: return DSColor.success
        case .moderate: return .yellow
        case .stale: return DSColor.warning
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
                    .foregroundColor(DSColor.gitMeta)
                Text(name)
                    .font(DSFont.mono(.caption2))
                    .foregroundColor(DSColor.gitMeta)
                Text("·").font(DSFont.micro).foregroundColor(.secondary)
            }
        } else if let b = branch ?? store.gitStatuses[path]?.branch {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                Text(b)
                    .font(DSFont.mono(.caption2))
                    .foregroundColor(.secondary)
                Text("·").font(DSFont.micro).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - UserDefaults key helper for group collapse state

private func groupCollapseKey(_ id: String) -> String { "devdash.groupCollapsed.\(id)" }

// MARK: - Collapsible group section

/// A sidebar section for one ProjectGroup. Persists collapse state in UserDefaults.
private struct CollapsibleGroupSection: View {
    let group: ProjectGroup
    let members: [Project]
    let runningPorts: [String: Int]

    @EnvironmentObject var store: DashboardStore
    @State private var collapsed: Bool

    init(group: ProjectGroup, members: [Project], runningPorts: [String: Int]) {
        self.group = group
        self.members = members
        self.runningPorts = runningPorts
        let key = groupCollapseKey(group.id)
        _collapsed = State(initialValue: UserDefaults.standard.bool(forKey: key))
    }

    var body: some View {
        Section {
            if !collapsed {
                ForEach(members) { proj in
                    SidebarProjectRow(
                        project: proj,
                        runningPort: runningPorts[proj.path],
                        onNewGroup: nil,
                        onAddToGroup: { groupId in
                            store.addProjectToGroup(projectPath: proj.path, groupId: groupId)
                        }
                    )
                    .tag(Selection.project(path: proj.path))
                }
            }
        } header: {
            groupHeader
        }
    }

    private var groupHeader: some View {
        Button {
            collapsed.toggle()
            UserDefaults.standard.set(collapsed, forKey: groupCollapseKey(group.id))
        } label: {
            HStack(spacing: DSSpace.xs) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Image(systemName: "rhombus")
                    .font(DSFont.micro)
                    .foregroundColor(DSColor.info)
                Text(group.name)
                    .font(DSFont.mono(.caption2).weight(.semibold))
                    .foregroundColor(.primary)
                if let teamName = group.linearTeamName {
                    Text("·")
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                    Text(teamName)
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(verbatim: String(members.count))
                    .font(DSFont.monoDigits(.caption2))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Worktree group row

/// Renders a repo's main checkout as a collapsible parent with its worktree
/// children indented beneath it. Mirrors the `CollapsibleGroupSection` idiom.
/// Collapse state is persisted per main-checkout path via raw UserDefaults
/// (same pattern as CollapsibleGroupSection — read once in init, written on toggle).
private struct WorktreeGroupRow: View {
    let wtGroup: SidebarView.WorktreeGroup
    let runningPorts: [String: Int]
    var onNewGroup: (() -> Void)? = nil

    @EnvironmentObject var store: DashboardStore
    @State private var collapsed: Bool

    init(wtGroup: SidebarView.WorktreeGroup, runningPorts: [String: Int], onNewGroup: (() -> Void)? = nil) {
        self.wtGroup = wtGroup
        self.runningPorts = runningPorts
        self.onNewGroup = onNewGroup
        let key = "devdash.worktreeCollapsed.\(wtGroup.parent.path)"
        // Default to expanded (false = not collapsed).
        _collapsed = State(initialValue: UserDefaults.standard.object(forKey: key) != nil
            ? UserDefaults.standard.bool(forKey: key)
            : false)
    }

    var body: some View {
        // Parent row — always visible, tappable for selection.
        SidebarProjectRow(
            project: wtGroup.parent,
            runningPort: runningPorts[wtGroup.parent.path],
            onNewGroup: onNewGroup,
            onAddToGroup: { _ in }
        )
        .tag(Selection.project(path: wtGroup.parent.path))
        .overlay(alignment: .leading) {
            // Disclosure chevron inset to left edge so it doesn't cover the row content.
            Button {
                collapsed.toggle()
                UserDefaults.standard.set(collapsed,
                    forKey: "devdash.worktreeCollapsed.\(wtGroup.parent.path)")
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .offset(x: -16)
        }

        if !collapsed {
            ForEach(wtGroup.children) { child in
                SidebarProjectRow(
                    project: child,
                    runningPort: runningPorts[child.path],
                    onNewGroup: nil,
                    onAddToGroup: { _ in }
                )
                .tag(Selection.project(path: child.path))
                .padding(.leading, 18)
            }
        }
    }
}

// MARK: - New group sheet

struct NewGroupSheet: View {
    var projectPath: String?
    var onCreated: (() -> Void)?

    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.lg) {
            Text("New Linear Group")
                .font(DSFont.title)

            Text("Create a group to share a Linear binding across multiple repos.")
                .font(DSFont.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Group name…", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }

            if let path = projectPath {
                Text("Repo \"\(URL(fileURLWithPath: path).lastPathComponent)\" will be added to this group.")
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpace.xl)
        .frame(width: 400)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let g = store.createGroup(name: trimmed)
        if let path = projectPath {
            store.addProjectToGroup(projectPath: path, groupId: g.id)
        }
        onCreated?()
        dismiss()
    }
}
