import Foundation
import SwiftUI
import AppKit

/// App-wide appearance. Persisted across launches under `devdash.theme`.
enum AppTheme: String, CaseIterable {
    case dark, light

    var colorScheme: ColorScheme { self == .light ? .light : .dark }
    var label: String { self == .light ? "Light" : "Dark" }
    var icon: String { self == .light ? "sun.max.fill" : "moon.fill" }
    /// The theme to switch to when toggling.
    var toggled: AppTheme { self == .light ? .dark : .light }
}

/// Where the embedded terminal renders. Persisted under `devdash.terminal.placement`.
/// (The right-`side` placement was removed — the right edge is now the Preview dock.)
enum TerminalPlacement: String, CaseIterable {
    case bottom, floating

    var label: String {
        switch self {
        case .bottom: return "Bottom"
        case .floating: return "Floating"
        }
    }
    var icon: String {
        switch self {
        case .bottom: return "rectangle.bottomthird.inset.filled"
        case .floating: return "macwindow"
        }
    }
    var next: TerminalPlacement {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

@MainActor
final class DashboardStore: ObservableObject {
    @Published var services: [Service] = [] {
        didSet {
            _devServices = services.filter { !$0.isInfra }
            _infraServices = services.filter { $0.isInfra }
        }
    }
    /// Cached partitions of `services`, recomputed only when `services` changes
    /// (not on every access). `devServices`/`infraServices` are read inside view
    /// bodies and sort comparators, so re-filtering on each call was costly.
    private var _devServices: [Service] = []
    private var _infraServices: [Service] = []
    @Published var projects: [Project] = [] {
        didSet {
            terminals.reconcile(activePaths: Set(projects.map { $0.path }))
            armTaskWatcher()
        }
    }
    @Published var sessions: [ClaudeSession] = []
    @Published var tasksByProject: [ProjectTasks] = []
    @Published var lastUpdated: Date = .distantPast
    @Published var isLoading = false
    @Published var isLoadingIssues = false
    @Published var healthFilter: HealthFilter = .all
    @Published var selection: Selection? {
        didSet {
            tabStore.selectionChanged(toKey: projectKey(for: selection))
            recordNavigation()
            if let sel = selection {
                UserDefaults.standard.set(sel.key, forKey: "devdash.lastSelection")
            }
        }
    }

    // MARK: - Back/forward navigation

    private var navHistory: [Selection] = []
    private var navIndex: Int = -1
    private var isNavigating = false

    private func recordNavigation() {
        guard !isNavigating, let sel = selection else { return }
        if navIndex >= 0, navIndex < navHistory.count, navHistory[navIndex] == sel { return }
        if navIndex < navHistory.count - 1 {
            navHistory.removeSubrange((navIndex + 1)...)
        }
        navHistory.append(sel)
        if navHistory.count > 50 {
            navHistory.removeFirst(navHistory.count - 50)
        }
        navIndex = navHistory.count - 1
    }

    var canGoBack: Bool { navIndex > 0 }
    var canGoForward: Bool { navIndex >= 0 && navIndex < navHistory.count - 1 }

    func goBack() {
        guard canGoBack else { return }
        navIndex -= 1
        isNavigating = true
        selection = navHistory[navIndex]
        isNavigating = false
    }

    func goForward() {
        guard canGoForward else { return }
        navIndex += 1
        isNavigating = true
        selection = navHistory[navIndex]
        isNavigating = false
    }
    /// Active detail tab + per-project tab memory, split into its own small
    /// store so switching tabs doesn't republish this (large) store and
    /// re-render the sidebar. See `TabStore`.
    let tabStore = TabStore()
    /// Per-project freeform canvas layouts + mode, split out like `TabStore` so
    /// panel drags don't republish this store. See `CanvasStore`.
    let canvasStore = CanvasStore()
    /// Notification feed + banner gating, split out like `TabStore` so unread
    /// badge updates don't republish this store. See `NotificationStore`.
    let notificationStore = NotificationStore()
    @Published var pinnedProjects: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "devdash.pinnedProjects") ?? []
    )
    @Published var sessionDigests: [String: SessionDigest] = [:]
    @Published var openSessionId: String? = nil
    /// Open a file in the user's default app. The Files tab that used to render
    /// files in-app was replaced by the Changes (diff) tab, so cross-tab "open
    /// this file" actions hand off to the OS instead.
    func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    /// Open a TaskDetailSheet for this task. Set to nil to dismiss.
    @Published var openTaskId: String? = nil
    @Published var openTaskProjectPath: String? = nil
    /// Observer for banner-click navigation requests forwarded by AppDelegate.
    private var navigateObserver: NSObjectProtocol?
    /// Last `gh pr view` poll per "<projectPath>#<taskId>" (5-min throttle).
    private var prMergePollLast: [String: Date] = [:]
    @Published var isSettingsVisible: Bool = false
    /// Folders scanned for projects (Settings → Project folders). Mirrors the
    /// persisted `DevRoots.roots`; mutate via `addDevRoot`/`removeDevRoot`/`resetDevRoots`
    /// so the change is saved and a rescan is kicked off.
    @Published var devRoots: [String] = DevRoots.roots
    @Published var appTheme: AppTheme =
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "devdash.theme") ?? "") ?? .dark {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "devdash.theme")
            terminals.applyTheme(appTheme)
        }
    }
    @Published var activeDocPath: String? = nil

    // MARK: - Living-doc appearance (Settings → Document)

    /// Accent hue for the generated living doc. Drives the whole OKLCH palette;
    /// persisted and regenerates open docs on change.
    @Published var docAccent: DocAccent =
        DocAccent(rawValue: UserDefaults.standard.string(forKey: "devdash.docAccent") ?? "") ?? .amber {
        didSet {
            UserDefaults.standard.set(docAccent.rawValue, forKey: "devdash.docAccent")
            regenerateAllDocs()
        }
    }
    /// Named font pairing for the living doc. `.custom` uses the override families below.
    @Published var docFontPreset: DocFontPreset =
        DocFontPreset(rawValue: UserDefaults.standard.string(forKey: "devdash.docFontPreset") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(docFontPreset.rawValue, forKey: "devdash.docFontPreset")
            regenerateAllDocs()
        }
    }
    @Published var docFontDisplay: String =
        UserDefaults.standard.string(forKey: "devdash.docFont.display") ?? "" {
        didSet { UserDefaults.standard.set(docFontDisplay, forKey: "devdash.docFont.display"); regenerateAllDocs() }
    }
    @Published var docFontBody: String =
        UserDefaults.standard.string(forKey: "devdash.docFont.body") ?? "" {
        didSet { UserDefaults.standard.set(docFontBody, forKey: "devdash.docFont.body"); regenerateAllDocs() }
    }
    @Published var docFontMono: String =
        UserDefaults.standard.string(forKey: "devdash.docFont.mono") ?? "" {
        didSet { UserDefaults.standard.set(docFontMono, forKey: "devdash.docFont.mono"); regenerateAllDocs() }
    }
    /// Bumped on every doc regen so ProductWebView knows to reload the file.
    @Published var docRegenToken: Int = 0

    /// Cross-component bridge: set by the ⌘K command bar to ask LoreTasksView
    /// (which owns the inline suggestion checklist state) to start a breakdown
    /// for this ticket. The view consumes it and resets to nil.
    @Published var pendingBreakdownTicketId: String? = nil

    /// Duplicate lore-id collisions per project (path → messages), detected by
    /// `LoreIdAudit` during scans. Non-empty = two files share a numeric id
    /// (usually parallel worktree branches both minting max+1, then merging).
    @Published var projectIdCollisions: [String: [String]] = [:]

    /// Resolved font stacks for the generator. For `.custom`, each user-picked
    /// family is wrapped with a graceful fallback chain; empty fields inherit it.
    var resolvedDocFonts: DocFontSet {
        guard docFontPreset == .custom else { return docFontPreset.fontSet }
        func stack(_ family: String, fallback: String) -> String {
            let f = family.trimmingCharacters(in: .whitespaces)
            return f.isEmpty ? fallback : "\"\(f)\", \(fallback)"
        }
        return DocFontSet(
            display: stack(docFontDisplay, fallback: DocFontPreset.systemStack),
            body: stack(docFontBody, fallback: DocFontPreset.systemStack),
            mono: stack(docFontMono, fallback: DocFontPreset.monoStack))
    }

    private var docRegenTask: Task<Void, Never>?

    /// Regenerate living docs after a global appearance change. Debounced and off
    /// the synchronous didSet path so a burst of preference toggles coalesces into
    /// a single pass instead of stalling the main thread on every change.
    func regenerateAllDocs() {
        docRegenTask?.cancel()
        docRegenTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                for project in self.projects { self.regenerateRoadmap(for: project.path) }
                self.docRegenToken &+= 1
            }
        }
    }

    func toggleTheme() { appTheme = appTheme.toggled }
    private var digestTask: Task<Void, Never>?

    @Published var projectMeta: [String: ProjectMeta] = [:]   // path → meta
    @Published var projectTasks: [String: [TaskItem]] = [:]   // path → tasks
    @Published var projectTickets: [String: [Ticket]] = [:]   // path → tickets
    @Published var projectPolicies: [String: [Policy]] = [:]   // path → policies
    @Published var projectGroups: [ProjectGroup] = []         // all groups (global)
    @Published var groupLinearTasks: [String: [TaskItem]] = [:] // groupId → Linear tasks
    @Published var projectProviders: [String: [Provider]] = [:]   // path → providers
    @Published var projectHealth: [String: [String: HealthRunResult]] = [:]   // path → checkId → result
    @Published var runningHealthChecks: Set<String> = []   // "<path>:<checkId>"
    @Published var gitStatuses: [String: GitStatus] = [:]
    @Published var gitOpInProgress: Set<String> = []

    // Embedded terminal (VS Code–style, one live shell per project).
    @Published var terminalOpen: Bool = UserDefaults.standard.bool(forKey: "devdash.terminal.open") {
        didSet { UserDefaults.standard.set(terminalOpen, forKey: "devdash.terminal.open") }
    }
    @Published var terminalPlacement: TerminalPlacement =
        TerminalPlacement(rawValue: UserDefaults.standard.string(forKey: "devdash.terminal.placement") ?? "") ?? .bottom {
        didSet { UserDefaults.standard.set(terminalPlacement.rawValue, forKey: "devdash.terminal.placement") }
    }

    // Preview dock (right-side, resizable; hosts the project's Preview surface).
    @Published var previewDockOpen: Bool = UserDefaults.standard.bool(forKey: "devdash.previewDock.open") {
        didSet { UserDefaults.standard.set(previewDockOpen, forKey: "devdash.previewDock.open") }
    }
    @Published var terminalFontSize: Double =
        UserDefaults.standard.object(forKey: "devdash.terminal.fontSize") as? Double ?? 13 {
        didSet {
            UserDefaults.standard.set(terminalFontSize, forKey: "devdash.terminal.fontSize")
            terminals.setFontSize(terminalFontSize)
        }
    }
    @Published var terminalFontFamily: TerminalFontFamily =
        TerminalFontFamily(rawValue: UserDefaults.standard.string(forKey: "devdash.terminal.fontFamily") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(terminalFontFamily.rawValue, forKey: "devdash.terminal.fontFamily")
            terminals.setFontFamily(terminalFontFamily)
        }
    }
    @Published var terminalCursorStyle: TerminalCursorStyle =
        TerminalCursorStyle(rawValue: UserDefaults.standard.string(forKey: "devdash.terminal.cursorStyle") ?? "") ?? .block {
        didSet {
            UserDefaults.standard.set(terminalCursorStyle.rawValue, forKey: "devdash.terminal.cursorStyle")
            terminals.setCursorStyle(terminalCursorStyle)
        }
    }
    @Published var terminalScrollback: Int =
        UserDefaults.standard.object(forKey: "devdash.terminal.scrollback") as? Int ?? 10000 {
        didSet {
            UserDefaults.standard.set(terminalScrollback, forKey: "devdash.terminal.scrollback")
            terminals.setScrollback(terminalScrollback)
        }
    }
    let terminals = TerminalSessionStore(appearance: .current())

    // MARK: - Task + artifact file watcher
    private var taskWatcher: NotesFileWatcher?
    /// projectPath → (taskId → TaskItem) snapshot used for change diffing.
    private var taskSnapshot: [String: [String: TaskItem]] = [:]
    /// projectPath → Set<artifactId> snapshot used for new-artifact diffing.
    private var artifactSnapshot: [String: Set<String>] = [:]
    /// projectPath → (ticketId → rollup status) snapshot for ticket-status diffing.
    private var ticketStatusSnapshot: [String: [String: TaskStatus]] = [:]
    /// Bumped whenever the watcher fires so TaskDetailSheet can re-read artifacts.
    @Published var artifactsRefreshToken: Int = 0
    /// The dir set the current watcher was armed with; used to avoid tearing
    /// down and rebuilding FDs/DispatchSources on every refresh tick when the
    /// project list hasn't actually changed.
    private var taskWatcherDirs: Set<String> = []

    /// Public entry point for the app startup path. Idempotent — safe to call
    /// before projects are loaded (watcher is a no-op until projects populate).
    func armTaskWatcherIfNeeded() { armTaskWatcher() }

    /// (Re-)arm the watcher over every project's docs/tasks, docs/tickets, and docs/artifacts directories.
    /// Called from `projects.didSet` so it stays current when projects change.
    /// No-ops when the desired dir set is identical to the currently armed set.
    /// NotesFileWatcher skips dirs that don't exist yet (open() returns -1 → fd < 0).
    private func armTaskWatcher() {
        var desired = Set(projects.map { "\($0.path)/docs/tasks" })
        for project in projects {
            desired.insert("\(project.path)/docs/artifacts")
            desired.insert("\(project.path)/docs/tickets")
        }
        guard desired != taskWatcherDirs else { return }
        taskWatcher?.stop()
        taskWatcher = nil
        taskWatcherDirs = desired
        guard !desired.isEmpty else { return }
        taskWatcher = NotesFileWatcher(dirs: Array(desired), onChangedDirs: { [weak self] changedDirs in
            // Debounced; callback arrives on main. Map "<project>/docs/<type>"
            // back to project paths and reload ONLY the affected projects — a
            // single Claude write in one repo used to re-parse every project's
            // tasks/tickets/artifacts on the main thread.
            let projectPaths = Set(changedDirs.map { dir -> String in
                let docs = (dir as NSString).deletingLastPathComponent   // strip "/<type>"
                return (docs as NSString).deletingLastPathComponent      // strip "/docs"
            })
            self?.reloadTasksAndNotify(only: projectPaths)
        })
    }

    /// Rollup status for a ticket from its child tasks — the notification-side
    /// twin of LoreTasksView.ticketRollupStatus (which renders from lore items).
    /// nil when the ticket has no tasks (caller falls back to stored status).
    nonisolated static func ticketRollupStatus(ticketId: String, tasks: [TaskItem]) -> TaskStatus? {
        let ticketTasks = tasks.filter { TaskStore.numEq($0.ticket ?? "", ticketId) }
        guard !ticketTasks.isEmpty else { return nil }
        if ticketTasks.allSatisfy({ $0.status == .done || $0.status == .skipped }) { return .done }
        if ticketTasks.contains(where: { $0.status == .blocked }) { return .blocked }
        if ticketTasks.contains(where: { ($0.status == .open && $0.owner == .ai) || $0.status == .inProgress }) {
            return .inProgress
        }
        return .open
    }

    /// Reload tasks and artifacts, diff vs snapshots, and fire notifications for
    /// meaningful changes. First call per project seeds silently. Ticket rollup
    /// status changes are diffed and notified here too.
    /// `only`: restrict to these project paths (nil = all projects).
    func reloadTasksAndNotify(only: Set<String>? = nil) {
        var didChangeArtifacts = false
        for project in projects {
            let path = project.path
            if let only, !only.contains(path) { continue }

            // Re-audit id collisions — external writes (branch merges, agent
            // `lore add`) are exactly when duplicate ids appear.
            let collisions = LoreIdAudit.audit(projectPath: path)
            if projectIdCollisions[path] ?? [] != collisions {
                projectIdCollisions[path] = collisions.isEmpty ? nil : collisions
            }

            // — Tickets (diff rollup status below; first load per project seeds silently) —
            let freshTickets = TicketStore.read(path)
            projectTickets[path] = freshTickets.isEmpty ? nil : freshTickets

            // — Policies (silent reload) —
            reloadPolicies(for: path)

            // — Tasks —
            let fresh = TaskStore.read(path)
            let freshMap = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })

            if let snap = taskSnapshot[path] {
                // Diff: only notify when we have a prior snapshot (not first load).
                // Banner gating (per-kind + master) lives inside NotificationStore.post;
                // the in-app feed records regardless.
                for (id, task) in freshMap {
                    if snap[id] == nil {
                        // New task
                        if task.pr != nil {
                            notificationStore.post(.prReviewTask, title: "PR review task created",
                                                   body: task.title,
                                                   projectPath: path, tab: .tasks, taskId: id)
                        } else {
                            notificationStore.post(.taskCreated, title: "New task", body: task.title,
                                                   projectPath: path, tab: .tasks, taskId: id)
                        }
                    } else if snap[id]?.status != .done && task.status == .done {
                        // Task moved to done
                        notificationStore.post(.taskDone, title: "Task done", body: task.title,
                                               projectPath: path, tab: .tasks, taskId: id)
                    }
                }
            }
            // Always update snapshot and projectTasks.
            taskSnapshot[path] = freshMap
            projectTasks[path] = fresh.isEmpty ? nil : fresh

            // — Ticket rollup status diff —
            var freshTicketStatuses: [String: TaskStatus] = [:]
            for ticket in freshTickets {
                freshTicketStatuses[ticket.id] =
                    Self.ticketRollupStatus(ticketId: ticket.id, tasks: fresh) ?? ticket.status
            }
            if let snap = ticketStatusSnapshot[path] {
                // Diff: only notify when we have a prior snapshot (not first load).
                for ticket in freshTickets {
                    guard let old = snap[ticket.id],
                          let new = freshTicketStatuses[ticket.id], old != new else { continue }
                    notificationStore.post(.ticketStatusChanged,
                        title: "Ticket \(new == .done ? "complete" : new.rawValue): \(ticket.title)",
                        body: "\(old.rawValue) → \(new.rawValue)",
                        projectPath: path, tab: .tasks)
                }
            }
            ticketStatusSnapshot[path] = freshTicketStatuses

            // — Artifacts —
            let freshArtifacts = ArtifactStore.read(path)
            let freshIds = Set(freshArtifacts.map { $0.id })

            if let snapIds = artifactSnapshot[path] {
                // Diff: only notify when we have a prior snapshot (not first load).
                // LOAD-BEARING: this `if let` (nil snapshot = silent) is the entire
                // anti-spam guarantee for launch AND late-added projects. Do NOT refactor
                // into a seed-then-diff that would notify on every existing artifact.
                for artifact in freshArtifacts where !snapIds.contains(artifact.id) {
                    notificationStore.post(.artifactAdded, title: "Artifact added",
                                           body: artifact.title,
                                           projectPath: path, tab: .tasks)
                }
            }
            // Always update artifact snapshot and bump token if anything changed.
            if artifactSnapshot[path] != freshIds {
                artifactSnapshot[path] = freshIds
                didChangeArtifacts = true
            }
        }
        if didChangeArtifacts { artifactsRefreshToken &+= 1 }
    }

    /// Diff-notify for a single project (used by the SessionEnd path).
    /// Routes through the scoped reload so tickets/policies/artifacts written
    /// during the session are picked up too, not just tasks.
    private func reloadTasksAndNotifyForProject(_ projectPath: String) {
        reloadTasksAndNotify(only: [projectPath])
    }

    /// Seed `taskSnapshot` and `artifactSnapshot` from disk WITHOUT notifying.
    /// Call once after `loadProjectMetaAndTasks` populates projectTasks on main so
    /// that tasks and artifacts already on disk at launch never trigger notifications.
    func seedTaskSnapshots() {
        for (path, tasks) in projectTasks {
            taskSnapshot[path] = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        }
        // Seed artifact snapshots for every known project path (artifacts may exist
        // even if there are no tasks, so iterate projects directly).
        for project in projects {
            let ids = Set(ArtifactStore.read(project.path).map { $0.id })
            artifactSnapshot[project.path] = ids
        }
    }

    /// Silently refresh the snapshot for `projectPath` after an in-app mutation
    /// so external file-watcher callbacks don't double-report the app's own changes.
    private func refreshTaskSnapshot(for projectPath: String) {
        let tasks = TaskStore.read(projectPath)
        taskSnapshot[projectPath] = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }

    // Resize geometry (persisted; plain vars — containers own @State and write back).
    var terminalHeight: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "devdash.terminal.height") as? Double ?? 280) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "devdash.terminal.height") }
    }
    var terminalWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "devdash.terminal.width") as? Double ?? 420) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "devdash.terminal.width") }
    }
    var previewDockWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "devdash.previewDock.width") as? Double ?? 480) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "devdash.previewDock.width") }
    }
    var terminalFloatingFrame: CGRect {
        get {
            let d = UserDefaults.standard
            let w = d.object(forKey: "devdash.terminal.float.w") as? Double ?? 560
            let h = d.object(forKey: "devdash.terminal.float.h") as? Double ?? 360
            let x = d.object(forKey: "devdash.terminal.float.x") as? Double ?? 80
            let y = d.object(forKey: "devdash.terminal.float.y") as? Double ?? 80
            return CGRect(x: x, y: y, width: w, height: h)
        }
        set {
            let d = UserDefaults.standard
            d.set(Double(newValue.origin.x), forKey: "devdash.terminal.float.x")
            d.set(Double(newValue.origin.y), forKey: "devdash.terminal.float.y")
            d.set(Double(newValue.width), forKey: "devdash.terminal.float.w")
            d.set(Double(newValue.height), forKey: "devdash.terminal.float.h")
        }
    }

    func zoomTerminal(_ delta: Double) {
        terminalFontSize = min(28, max(8, terminalFontSize + delta))
    }
    func resetTerminalZoom() { terminalFontSize = 13 }

    func isPinned(_ projectPath: String) -> Bool {
        pinnedProjects.contains(projectPath)
    }

    func togglePin(_ projectPath: String) {
        if pinnedProjects.contains(projectPath) {
            pinnedProjects.remove(projectPath)
        } else {
            pinnedProjects.insert(projectPath)
        }
        UserDefaults.standard.set(Array(pinnedProjects), forKey: "devdash.pinnedProjects")
    }

    private func projectKey(for selection: Selection?) -> String? {
        guard let sel = selection else { return nil }
        switch sel {
        case .home, .simulator: return nil
        case .project(let path): return path
        case .service(let id):
            // Map service to its project so a service↔project switch shares tab memory
            guard let svc = services.first(where: { $0.id == id }) else { return nil }
            return projects.first { svc.cwd == $0.path || svc.cwd.hasPrefix("\($0.path)/") }?.path
        }
    }

    /// Shared click-to-navigate: system banner clicks (via .devdashNavigate)
    /// and in-app notification rows both land here.
    func navigate(projectPath: String?, tabRaw: String?, taskId: String?) {
        guard let projectPath else { return }
        // Order matters: selection first (its didSet may restore a remembered
        // tab via tabStore.selectionChanged), THEN the explicit tab override.
        selection = .project(path: projectPath)
        if let tabRaw, let tab = DetailTab(rawValue: tabRaw) {
            tabStore.detailTab = tab
        }
        if let taskId {
            openTaskProjectPath = projectPath
            openTaskId = taskId
        }
    }

    /// Call once at startup (from App.task, alongside startEventServer).
    func armNavigationObserver() {
        guard navigateObserver == nil else { return }
        navigateObserver = NotificationCenter.default.addObserver(
            forName: .devdashNavigate, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            Task { @MainActor in
                self?.navigate(projectPath: info["projectPath"],
                               tabRaw: info["tab"], taskId: info["taskId"])
            }
        }
    }

    func restoreLastSelection() {
        guard let key = UserDefaults.standard.string(forKey: "devdash.lastSelection") else { return }
        let resolved: Selection?
        if key == "home" {
            resolved = .home
        } else if key.hasPrefix("project:") {
            let path = String(key.dropFirst("project:".count))
            resolved = projects.first { $0.path == path }.map { _ in .project(path: path) }
        } else if key.hasPrefix("service:") {
            let id = String(key.dropFirst("service:".count))
            resolved = services.first { $0.id == id }.map { _ in .service(serviceID: id) }
        } else {
            resolved = nil
        }
        if let resolved { selection = resolved }
    }
    /// Dev-server management state lives in its own store so high-frequency log
    /// streaming doesn't re-render every view bound to DashboardStore. Injected
    /// separately as an `@EnvironmentObject` (see App.swift); the action methods
    /// (`startServer`/`stopServer`) stay here and write through to it.
    let serverStore = ServerStore()

    // MARK: - Hook event server

    let eventServer = EventServer()
    /// Resolved port the event server is listening on; 0 until the listener binds.
    /// @Published so SettingsView reacts when the server becomes ready.
    @Published var eventServerPort: Int = 0
    /// Live external Claude Code sessions keyed by sessionId.
    @Published var liveSessions: [String: LiveSession] = [:]
    /// In-memory feed of every received hook event, newest first. Capped at 300.
    @Published var recentEvents: [ClaudeIntegrationEvent] = []
    /// Transient banner shown when a SessionStart event arrives; auto-clears after ~6 s.
    @Published var lastHookBanner: String? = nil
    /// Auto-generate a devlog when a session ends (default off — spawns Claude).
    @Published var autoDevlogOnSessionEnd: Bool =
        UserDefaults.standard.bool(forKey: "devdash.autoDevlogOnSessionEnd") {
        didSet { UserDefaults.standard.set(autoDevlogOnSessionEnd, forKey: "devdash.autoDevlogOnSessionEnd") }
    }
    /// Fire native macOS notifications when Claude creates a PR task, completes a task,
    /// or finishes a meaningful session. Default on; uses register(defaults:) so first-
    /// launch reads true without an explicit write.
    @Published var enableNotifications: Bool = {
        UserDefaults.standard.register(defaults: ["devdash.enableNotifications": true])
        return UserDefaults.standard.bool(forKey: "devdash.enableNotifications")
    }() {
        didSet { UserDefaults.standard.set(enableNotifications, forKey: "devdash.enableNotifications") }
    }
    /// Inject open tasks + latest devlog into Claude sessions via hook stdout (default on — no AI spawn, fast).
    /// Uses register(defaults:) so an unset key still reads true on first launch.
    @Published var injectProjectContext: Bool = {
        UserDefaults.standard.register(defaults: ["devdash.injectProjectContext": true])
        return UserDefaults.standard.bool(forKey: "devdash.injectProjectContext")
    }() {
        didSet { UserDefaults.standard.set(injectProjectContext, forKey: "devdash.injectProjectContext") }
    }
    /// Run launched tasks in an isolated git worktree + branch under .worktrees/ (default on).
    @Published var launchInWorktree: Bool = {
        UserDefaults.standard.register(defaults: ["devdash.launchInWorktree": true])
        return UserDefaults.standard.bool(forKey: "devdash.launchInWorktree")
    }() {
        didSet { UserDefaults.standard.set(launchInWorktree, forKey: "devdash.launchInWorktree") }
    }
    /// Per-project overrides for the two global Claude integration behaviors.
    /// Keyed by project path. A missing key means the project inherits the global default.
    /// Persisted as JSON under "devdash.projectHookConfigs".
    @Published var projectHookConfigs: [String: ProjectHookConfig] = {
        guard let data = UserDefaults.standard.data(forKey: "devdash.projectHookConfigs"),
              let decoded = try? JSONDecoder().decode([String: ProjectHookConfig].self, from: data)
        else { return [:] }
        return decoded
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(projectHookConfigs) {
                UserDefaults.standard.set(data, forKey: "devdash.projectHookConfigs")
            }
        }
    }

    /// Persisted intent set: projects the user has explicitly installed dev-dash hooks for.
    /// Decoupled from settings.json content so "zero events enabled" remains a legal installed
    /// state (the empty→re-enable round-trip survives without losing install intent).
    /// Persisted as a JSON array of path strings under "devdash.installedHookProjects".
    @Published var installedHookProjects: Set<String> = {
        guard let data = UserDefaults.standard.data(forKey: "devdash.installedHookProjects"),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(Array(installedHookProjects)) {
                UserDefaults.standard.set(data, forKey: "devdash.installedHookProjects")
            }
        }
    }

    /// Global default set of enabled hook events. Projects without a per-project
    /// enabledEvents override inherit this set. Defaults to all six events.
    /// Persisted as a JSON array of event name strings under "devdash.defaultEnabledEvents".
    @Published var defaultEnabledEvents: Set<String> = {
        let allEvents = Set(HookInstaller.hookSpecs.map { $0.event })
        guard let data = UserDefaults.standard.data(forKey: "devdash.defaultEnabledEvents"),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return allEvents }
        return Set(decoded)
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(Array(defaultEnabledEvents)) {
                UserDefaults.standard.set(data, forKey: "devdash.defaultEnabledEvents")
            }
            // Re-reconcile every installed project that has no per-project override,
            // so inheriting projects stay in sync with the new global default.
            // Best-effort (try?) — must NOT write defaultEnabledEvents to avoid loops.
            let newDefault = defaultEnabledEvents
            for project in projects {
                let path = project.path
                guard projectHookConfigs[path]?.enabledEvents == nil,
                      hooksInstalled(for: path)
                else { continue }
                try? HookInstaller.installProjectHooks(projectPath: path, events: newDefault)
            }
        }
    }

    /// Effective enabled-event set for a project: project override if set, else global default.
    func effectiveEnabledEvents(for path: String?) -> Set<String> {
        guard let path else { return defaultEnabledEvents }
        return projectHookConfigs[path]?.enabledEvents ?? defaultEnabledEvents
    }

    /// Effective "inject context" setting for a project — project override if set, else global default.
    func effectiveInjectContext(for path: String?) -> Bool {
        guard let path else { return injectProjectContext }
        return projectHookConfigs[path]?.injectContext ?? injectProjectContext
    }

    /// Effective "auto devlog" setting for a project — project override if set, else global default.
    func effectiveAutoDevlog(for path: String?) -> Bool {
        guard let path else { return autoDevlogOnSessionEnd }
        return projectHookConfigs[path]?.autoDevlog ?? autoDevlogOnSessionEnd
    }

    /// Set or clear the inject-context override for a project.
    /// Passing nil clears the override (reverts to global default). Prunes the key when empty.
    func setInjectContextOverride(_ value: Bool?, for path: String) {
        var cfg = projectHookConfigs[path] ?? ProjectHookConfig()
        cfg.injectContext = value
        projectHookConfigs[path] = cfg.isEmpty ? nil : cfg
    }

    /// Set or clear the auto-devlog override for a project.
    /// Passing nil clears the override (reverts to global default). Prunes the key when empty.
    func setAutoDevlogOverride(_ value: Bool?, for path: String) {
        var cfg = projectHookConfigs[path] ?? ProjectHookConfig()
        cfg.autoDevlog = value
        projectHookConfigs[path] = cfg.isEmpty ? nil : cfg
    }

    /// Set or clear the enabled-events override for a project.
    /// Passing nil reverts to inheriting the global default. Prunes the config key when fully empty.
    /// If the project is currently managed (intent OR content), re-runs install immediately to sync
    /// settings.json. Captures managed state BEFORE mutating so the empty→re-enable round-trip works:
    /// disabling all events sets managed=true and reconciles (removing entries), intent is preserved;
    /// re-enabling an event sees managed=true via intent and reconciles again (re-adding entries).
    /// One-time: add the "Notification" hook event to previously-saved event
    /// sets (global default + per-project overrides predate this event and
    /// would silently never install it). didSet on defaultEnabledEvents
    /// re-reconciles installed projects.
    func migrateNotificationHookEventOnce() {
        let flag = "devdash.migratedNotificationHookEvent"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        if !defaultEnabledEvents.contains("Notification") {
            defaultEnabledEvents.insert("Notification")   // didSet reconciles inheriting projects
        } else {
            // Fresh (never-persisted) default already includes the new event, so the
            // insert above is a no-op and didSet never fires — but installed projects'
            // settings.json predate the event. Reconcile them directly.
            for project in projects {
                let path = project.path
                guard projectHookConfigs[path]?.enabledEvents == nil,
                      hooksInstalled(for: path) else { continue }
                try? HookInstaller.installProjectHooks(projectPath: path, events: defaultEnabledEvents)
            }
        }
        for (path, config) in projectHookConfigs {
            if var events = config.enabledEvents, !events.contains("Notification") {
                events.insert("Notification")
                setEnabledEventsOverride(events, for: path)
            }
        }
    }

    func setEnabledEventsOverride(_ events: Set<String>?, for path: String) {
        let managed = hooksInstalled(for: path)   // capture BEFORE mutating (intent OR content)
        if managed { installedHookProjects.insert(path) }   // migrate pre-existing into intent set
        var cfg = projectHookConfigs[path] ?? ProjectHookConfig()
        cfg.enabledEvents = events
        projectHookConfigs[path] = cfg.isEmpty ? nil : cfg
        guard managed else { return }
        try? HookInstaller.installProjectHooks(projectPath: path, events: effectiveEnabledEvents(for: path))
    }

    /// Session IDs that have already had a devlog generated; prevents dupes.
    private var devloggedSessions: Set<String> = []
    /// Per-project debounce tasks for git refresh after detected git/gh commands.
    private var gitRefreshTasks: [String: Task<Void, Never>] = [:]

    func startEventServer() {
        eventServer.onEvent = { [weak self] ev, reply in
            DispatchQueue.main.async {
                let body = self?.handleHookEvent(ev)
                reply(body)
            }
        }
        eventServer.onReady = { [weak self] port in
            DispatchQueue.main.async { self?.eventServerPort = port }
        }
        eventServer.start()
        // Single periodic sweep: removes ended sessions (>5 min) and abandoned
        // active sessions (>15 min idle). Handles crashes/kills that never fire Stop.
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.pruneLiveSessions()
            }
        }
    }

    /// Remove stale sessions. Called once per minute from the event-server sweep task.
    @MainActor private func pruneLiveSessions() {
        let now = Date()
        liveSessions = liveSessions.filter { _, s in
            if s.status == .ended  { return now.timeIntervalSince(s.lastEventAt) < 300  }
            if s.status == .active { return now.timeIntervalSince(s.lastEventAt) < 900  }
            return true
        }
        // Drop devlog dedupe entries for sessions that have been pruned away.
        devloggedSessions = devloggedSessions.filter { liveSessions[$0] != nil }
    }

    /// Build and prepend a ClaudeIntegrationEvent to recentEvents. Purely additive —
    /// no file I/O, no spawning, no side effects on existing session state.
    private func recordEvent(_ ev: ClaudeHookEvent) {
        let (name, path) = projectInfo(for: ev.cwd)
        let input = ev.raw["tool_input"] as? [String: Any] ?? [:]

        let category: ClaudeIntegrationEvent.Category
        let detail: String

        switch ev.event {
        case "SessionStart":
            category = .session
            let src = ev.source.map { " (\($0))" } ?? ""
            detail = "Session started\(src)"

        case "SessionEnd":
            category = .session
            detail = "Session ended"

        case "Stop":
            category = .session
            detail = "Turn finished"

        case "UserPromptSubmit":
            category = .prompt
            let raw = ev.prompt ?? ""
            let oneline = raw.components(separatedBy: .newlines).joined(separator: " ")
            let truncated = oneline.count > 120 ? String(oneline.prefix(120)) + "…" : oneline
            detail = "Prompt: \(truncated)"

        case "PreToolUse", "PostToolUse":
            let toolName = ev.toolName ?? "unknown"
            // Categorize: Bash with a git/gh mutation → .git, else .tool
            let isBash = toolName == "Bash"
            let cmd = input["command"] as? String ?? ""
            if isBash && Self.isGitMutation(cmd) {
                category = .git
            } else {
                category = .tool
            }
            let prefix = ev.event == "PostToolUse" ? "✓ " : ""
            let activity = Self.liveActivity(toolName: toolName, input: input)
            if let file = activity.file {
                let lastComp = URL(fileURLWithPath: file.path).lastPathComponent
                detail = "\(prefix)\(toolName) \(lastComp)"
            } else if let command = activity.command {
                let truncCmd = command.count > 100 ? String(command.prefix(100)) + "…" : command
                detail = "\(prefix)\(truncCmd)"
            } else {
                detail = "\(prefix)\(toolName)"
            }

        case "Notification":
            category = .session
            let msg = ev.raw["message"] as? String ?? "Waiting for input"
            detail = "Needs input: \(msg)"

        default:
            category = .other
            detail = ev.event
        }

        let now = Date()
        let event = ClaudeIntegrationEvent(
            timestamp: now,
            projectPath: path,
            projectName: name,
            hookEvent: ev.event,
            category: category,
            detail: detail
        )
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 300 {
            recentEvents.removeLast(recentEvents.count - 300)
        }

        // Durable NDJSON operation log (ADR 0013). NDJSON is the source of
        // truth; recentEvents above is just the 300-cap tail view. Appended
        // off-main on EventLogStore's serial queue.
        EventLogStore.append(
            PersistedEvent(
                ts: EventLogStore.isoFormatter.string(from: now),
                id: event.id.uuidString,
                session: ev.sessionId,
                cwd: ev.cwd,
                hook: ev.event,
                cat: category.rawValue,
                detail: detail
            ),
            projectPath: path
        )
    }

    @discardableResult
    func handleHookEvent(_ ev: ClaudeHookEvent) -> String? {
        recordEvent(ev)
        guard let sid = ev.sessionId, !sid.isEmpty else { return nil }
        let now = Date()

        switch ev.event {
        case "SessionStart":
            let (name, path) = projectInfo(for: ev.cwd)
            liveSessions[sid] = LiveSession(
                id: sid, cwd: ev.cwd ?? "",
                projectPath: path, projectName: name,
                startedAt: now, lastEventAt: now, status: .active
            )
            let banner = "Claude session started in \(name)"
            lastHookBanner = banner
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                // Clear only the exact banner we set; a newer banner is left alone.
                if self.lastHookBanner == banner { self.lastHookBanner = nil }
            }
            // Context injection: only for known projects, using effective per-project setting.
            if effectiveInjectContext(for: path), let projPath = path {
                var ctx = buildInjectedContext(forProjectPath: projPath, projectName: name) ?? ""
                // Unambiguous task link: exactly one in-progress task → set link + annotate context.
                let active = (projectTasks[projPath] ?? []).filter {
                    ($0.status == .open && $0.owner == .ai) || $0.status == .inProgress
                }
                if active.count == 1 {
                    let t = active[0]
                    liveSessions[sid]?.linkedTaskId = t.id
                    if !ctx.isEmpty { ctx += "\n" }
                    ctx += "Active task (will be marked AI-touched on session end): \(t.title) (id: \(t.id))"
                }
                if !ctx.isEmpty, let json = injectionJSON(event: ev.event, context: ctx) {
                    return json
                }
            }

        case "UserPromptSubmit":
            ensureSession(sid: sid, cwd: ev.cwd, now: now)
            // A new turn began — ensure the session stays (or returns to) active.
            liveSessions[sid]?.status = .active
            liveSessions[sid]?.lastPrompt = ev.prompt
            liveSessions[sid]?.lastEventAt = now
            // Context injection: only for known projects, using effective per-project setting.
            if effectiveInjectContext(for: liveSessions[sid]?.projectPath), let projPath = liveSessions[sid]?.projectPath {
                let projName = liveSessions[sid]?.projectName ?? ""
                var ctx = buildInjectedContext(forProjectPath: projPath, projectName: projName) ?? ""
                // Unambiguous task link: exactly one in-progress task → set link + annotate context.
                let active = (projectTasks[projPath] ?? []).filter {
                    ($0.status == .open && $0.owner == .ai) || $0.status == .inProgress
                }
                if active.count == 1 {
                    let t = active[0]
                    liveSessions[sid]?.linkedTaskId = t.id
                    if !ctx.isEmpty { ctx += "\n" }
                    ctx += "Active task (will be marked AI-touched on session end): \(t.title) (id: \(t.id))"
                }
                if !ctx.isEmpty, let json = injectionJSON(event: ev.event, context: ctx) {
                    return json
                }
            }

        case "PreToolUse":
            ensureSession(sid: sid, cwd: ev.cwd, now: now)
            let input = ev.raw["tool_input"] as? [String: Any] ?? [:]
            let activity = Self.liveActivity(toolName: ev.toolName ?? "", input: input)
            if let file = activity.file {
                liveSessions[sid]?.liveFiles.append(file)
                // Cap to last 50 entries to bound memory on long sessions
                if let count = liveSessions[sid]?.liveFiles.count, count > 50 {
                    liveSessions[sid]?.liveFiles.removeFirst(count - 50)
                }
            }
            if let cmd = activity.command {
                liveSessions[sid]?.liveCommands.append(cmd)
                if let count = liveSessions[sid]?.liveCommands.count, count > 50 {
                    liveSessions[sid]?.liveCommands.removeFirst(count - 50)
                }
            }
            liveSessions[sid]?.currentTool = ev.toolName
            liveSessions[sid]?.lastEventAt = now

        case "PostToolUse":
            ensureSession(sid: sid, cwd: ev.cwd, now: now)
            liveSessions[sid]?.currentTool = nil
            liveSessions[sid]?.lastEventAt = now
            if ev.toolName == "Bash",
               let input = ev.raw["tool_input"] as? [String: Any],
               let cmd = input["command"] as? String {
                // Debounced git/PR refresh when a Bash command mutates git state.
                if Self.isGitMutation(cmd),
                   let path = liveSessions[sid]?.projectPath {
                    scheduleGitRefresh(for: path)
                }
                // PR opened → mark work task done + create a review Task under its ticket.
                if Self.isGHPRCreate(cmd),
                   let session = liveSessions[sid],
                   let taskId = session.linkedTaskId,
                   let projPath = session.projectPath {
                    let prURL = (ev.raw["tool_output"] as? String).flatMap {
                        Self.parsePRURL(from: $0)
                    }
                    // Only act from aiWorking state. This is the source-state guard that
                    // makes the block idempotent: once the work task is .done its
                    // kanbanColumn != .aiWorking, so a second event is a no-op.
                    let current = TaskStore.read(projPath).first { $0.id == taskId }
                    if current?.kanbanColumn == .aiWorking {
                        // Mark the work task done (coding complete).
                        try? TaskStore.setStatus(projectPath: projPath, id: taskId, status: .done)

                        if let ticketId = current?.ticket, !ticketId.isEmpty {
                            // Ticket-aware path: create a review task under the ticket.
                            // Idempotency: skip if a review task with this PR already exists.
                            let existingTasks = TaskStore.read(projPath)
                            let alreadyExists = prURL.map { url in
                                existingTasks.contains { t in
                                    TaskStore.numEq(t.ticket ?? "", ticketId) && t.pr == url
                                }
                            } ?? false

                            if !alreadyExists {
                                // Derive a review title from the ticket (looked up from store).
                                let ticketTitle = (projectTickets[projPath] ?? [])
                                    .first { TicketStore.numEq($0.id, ticketId) }?.title
                                let reviewTitle: String
                                if let prURL, let n = Self.prNumberFromURL(from: prURL) {
                                    reviewTitle = "Review PR #\(n)"
                                } else if let tt = ticketTitle {
                                    reviewTitle = "Review: \(tt)"
                                } else {
                                    reviewTitle = "Review PR"
                                }

                                var createdReviewTaskId: String? = nil
                                do {
                                    let reviewTask = try TaskStore.add(
                                        projectPath: projPath,
                                        title: reviewTitle,
                                        category: .qa,
                                        source: .local
                                    )
                                    createdReviewTaskId = reviewTask.id
                                    // Set ticket + owner + pr in-place.
                                    let dir = TaskStore.file(for: projPath)
                                    if let fname = TaskStore.findFile(id: reviewTask.id, in: dir),
                                       let raw = try? String(contentsOfFile: "\(dir)/\(fname)", encoding: .utf8) {
                                        var patched = TaskStore.setOrAddFrontmatterKey(
                                            in: raw, key: "ticket", value: TaskStore.yamlStr(ticketId))
                                        patched = TaskStore.setOrAddFrontmatterKey(
                                            in: patched, key: "owner", value: TaskOwner.human.rawValue)
                                        if let url = prURL {
                                            patched = TaskStore.setOrAddFrontmatterKey(
                                                in: patched, key: "pr", value: TaskStore.yamlStr(url))
                                        }
                                        try? patched.write(toFile: "\(dir)/\(fname)", atomically: true, encoding: .utf8)
                                    }
                                } catch {
                                    NSLog("DashboardStore: failed to create review task: %@", error.localizedDescription)
                                }

                                reloadTasksAndNotifyForProject(projPath)
                                let body = ticketTitle ?? (current?.title ?? taskId)
                                notificationStore.post(.prOpened, title: "PR opened → review task created",
                                                       body: body,
                                                       projectPath: projPath, tab: .tasks, taskId: createdReviewTaskId)
                            }
                        } else {
                            // Legacy fallback (no ticket): move work task to Review & QA.
                            if let url = prURL {
                                try? TaskStore.setPR(projectPath: projPath, id: taskId, url: url)
                            }
                            try? TaskStore.setHasAIRun(projectPath: projPath, id: taskId)
                            try? TaskStore.setOwner(projectPath: projPath, id: taskId, owner: .human)
                            reloadTasksAndNotifyForProject(projPath)
                            let title = current?.title ?? taskId
                            notificationStore.post(.prOpened, title: "PR opened → Review & QA",
                                                   body: title,
                                                   projectPath: projPath, tab: .tasks, taskId: taskId)
                        }
                    }
                }
            }

        case "Stop":
            // Stop fires at end of each assistant turn — the session is idle/waiting, NOT ended.
            ensureSession(sid: sid, cwd: ev.cwd, now: now)
            liveSessions[sid]?.currentTool = nil
            liveSessions[sid]?.lastEventAt = now
            // Opt-in per-turn idle notification (default off — fires every turn;
            // NotificationStore.shouldRecord drops it entirely unless enabled).
            let idleProj = liveSessions[sid]?.projectName ?? "unknown project"
            notificationStore.post(.sessionIdle, title: "Claude is idle — \(idleProj)",
                                   body: liveSessions[sid]?.lastPrompt.map { "After: \($0.prefix(80))" } ?? "Turn finished",
                                   projectPath: liveSessions[sid]?.projectPath, tab: .claude)

        case "Notification":
            // Claude Code fires this when the session is blocked on the user —
            // a permission prompt or idle waiting-for-input.
            ensureSession(sid: sid, cwd: ev.cwd, now: now)
            liveSessions[sid]?.lastEventAt = now
            let msg = ev.raw["message"] as? String ?? "Waiting for your input"
            let projName = liveSessions[sid]?.projectName ?? "unknown project"
            notificationStore.post(.needsInput, title: "Claude needs input — \(projName)",
                                   body: msg,
                                   projectPath: liveSessions[sid]?.projectPath, tab: .claude)

        case "SessionEnd":
            ensureSession(sid: sid, cwd: ev.cwd, now: now)
            liveSessions[sid]?.status = .ended
            liveSessions[sid]?.lastEventAt = now
            // Removal is handled by the periodic pruneLiveSessions() sweep.
            if let session = liveSessions[sid] {
                maybeAutoDevlog(for: session)
                let hasWrite = session.liveFiles.contains { $0.operation == .write || $0.operation == .edit }
                let hasGit   = session.liveCommands.contains { Self.isGitMutation($0) }
                let meaningful = hasWrite || hasGit
                // Advance linked task when: unambiguous link was set AND session was meaningful.
                if let taskId = session.linkedTaskId,
                   let projPath = session.projectPath {
                    if meaningful {
                        // Re-read current task state — user may have completed/dropped it mid-session.
                        let current = TaskStore.read(projPath).first { $0.id == taskId }
                        if let current, current.status != .done && current.status != .skipped {
                            try? TaskStore.setHasAIRun(projectPath: projPath, id: taskId)
                            try? TaskStore.setOwner(projectPath: projPath, id: taskId, owner: .human)
                            reloadTasks(for: projPath)
                        }
                    }
                }
                // Notify on meaningful session end + diff tasks for that project.
                if meaningful, let projPath = session.projectPath {
                    notificationStore.post(.sessionFinished, title: "Claude finished",
                                           body: "Session ended in \(session.projectName)",
                                           projectPath: projPath, tab: .claude)
                    reloadTasksAndNotifyForProject(projPath)
                }
            }

        default:
            liveSessions[sid]?.lastEventAt = now
        }

        return nil
    }

    /// Lazily create a session for any event that arrives before SessionStart
    /// (e.g. hooks installed mid-session).
    private func ensureSession(sid: String, cwd: String?, now: Date) {
        guard liveSessions[sid] == nil else { return }
        let (name, path) = projectInfo(for: cwd)
        liveSessions[sid] = LiveSession(
            id: sid, cwd: cwd ?? "",
            projectPath: path, projectName: name,
            startedAt: now, lastEventAt: now, status: .active
        )
    }

    /// Returns true if `cmd` contains a segment whose leading token is a git/gh mutation.
    /// Splits on `&&`, `;`, `|` so `grep 'git commit' file` does NOT match.
    private static func isGitMutation(_ cmd: String) -> Bool {
        let gitSubcmds: Set<String> = ["commit","push","merge","checkout","pull",
                                       "rebase","add","stash","reset","rm"]
        let ghSubcmds:  Set<String> = ["pr","repo"]
        let separators = CharacterSet(charactersIn: ";&|")
        return cmd.components(separatedBy: separators).contains { segment in
            let words = segment
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard words.count >= 2 else { return false }
            switch words[0] {
            case "git": return gitSubcmds.contains(words[1])
            case "gh":  return ghSubcmds.contains(words[1])
            default:    return false
            }
        }
    }

    /// Returns true if `cmd` contains a segment whose leading tokens are `gh pr create`.
    /// Splits on `&&`, `;`, `|` — same anchoring as `isGitMutation` — so
    /// `echo "gh pr create"` does NOT match.
    nonisolated static func isGHPRCreate(_ cmd: String) -> Bool {
        let separators = CharacterSet(charactersIn: ";&|")
        return cmd.components(separatedBy: separators).contains { segment in
            let words = segment
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard words.count >= 3 else { return false }
            return words[0] == "gh" && words[1] == "pr" && words[2] == "create"
        }
    }

    /// Extract the PR number from a GitHub-style PR URL, e.g.
    /// `https://github.com/org/repo/pull/42` → 42. Returns nil if not matched.
    nonisolated static func prNumberFromURL(from url: String) -> Int? {
        let pattern = "/pull/([0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(url.startIndex..., in: url)
        guard let match = regex.firstMatch(in: url, range: range),
              match.numberOfRanges >= 2,
              let swiftRange = Range(match.range(at: 1), in: url)
        else { return nil }
        return Int(url[swiftRange])
    }

    /// Extract the first GitHub-style PR URL from `gh pr create` output.
    /// Matches `https://<host>/<owner>/<repo>/pull/<N>` loosely (tolerates
    /// GitHub Enterprise hosts). Returns nil if no match.
    nonisolated static func parsePRURL(from output: String) -> String? {
        // Simple line-by-line scan: find the first token that looks like a PR URL.
        let pattern = "https://[^/\\s]+/[^/\\s]+/[^/\\s]+/pull/[0-9]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range) else { return nil }
        guard let swiftRange = Range(match.range, in: output) else { return nil }
        return String(output[swiftRange])
    }

    /// Cancel any pending refresh for `path` and schedule a new one ~1.5 s out.
    private func scheduleGitRefresh(for path: String) {
        gitRefreshTasks[path]?.cancel()
        gitRefreshTasks[path] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshGitStatus(for: path)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refreshRecentCommits() }
            await MainActor.run { self?.gitRefreshTasks[path] = nil }
        }
    }

    /// Cached date formatter for devlog filenames/frontmatter. Fixed locale/calendar
    /// so the output is always Gregorian yyyy-MM-dd regardless of system calendar.
    private static let devlogDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    /// Build a compact plain-text context block for a known project.
    /// Returns nil if there are no tasks AND no devlog to surface.
    private func buildInjectedContext(forProjectPath path: String, projectName: String) -> String? {
        // Gather tasks: in_progress (owner==.ai) first, then open, cap to 10.
        let all = projectTasks[path] ?? []
        let active = all.filter { $0.status == .open && $0.owner == .ai }
        let open   = all.filter { $0.status == .open && $0.owner != .ai }
        let top = Array((active + open).prefix(10))

        // Latest devlog by filename (yyyy-MM-dd-... prefix → lexicographic sort).
        var devlogTitle: String? = nil
        let devlogDir = "\(path)/docs/devlog"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: devlogDir) {
            let mdFiles = files.filter { $0.hasSuffix(".md") }.sorted()
            if let last = mdFiles.last,
               let handle = FileHandle(forReadingAtPath: "\(devlogDir)/\(last)") {
                // Read only the first 4 KB — title is always near the top.
                let prefix = handle.readData(ofLength: 4096)
                handle.closeFile()
                if let head = String(data: prefix, encoding: .utf8) {
                    // Extract title: frontmatter `title:` or first `#` heading.
                    for line in head.components(separatedBy: "\n") {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("title:") {
                            devlogTitle = t.dropFirst("title:".count)
                                .trimmingCharacters(in: .init(charactersIn: " \""))
                            break
                        }
                        if t.hasPrefix("#") {
                            devlogTitle = t.drop(while: { $0 == "#" || $0 == " " })
                                .trimmingCharacters(in: .whitespaces)
                            break
                        }
                    }
                }
            }
        }

        guard !top.isEmpty || devlogTitle != nil else { return nil }

        var lines: [String] = ["[dev-dash] Project: \(projectName)"]
        if !top.isEmpty {
            lines.append("Open tasks:")
            for t in top {
                let tag = (t.owner == .ai) ? "in_progress" : t.status.rawValue
                lines.append("- [\(tag)] \(t.title) (id: \(t.id))")
            }
        }
        if let dt = devlogTitle {
            lines.append("Most recent devlog: \(dt)")
        }
        return lines.joined(separator: "\n")
    }

    /// Serialize the hookSpecificOutput injection envelope as valid JSON.
    /// Uses JSONSerialization so task titles with quotes/newlines are correctly escaped.
    private func injectionJSON(event: String, context: String) -> String? {
        let obj: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": event,
                "additionalContext": context
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Generate a devlog for a just-ended session if the setting is on and the
    /// session was meaningful (wrote/edited files or ran git commands).
    private func maybeAutoDevlog(for session: LiveSession) {
        guard effectiveAutoDevlog(for: session.projectPath),
              let projectPath = session.projectPath,
              LoreRunner.isInitialized(projectPath: projectPath),
              !devloggedSessions.contains(session.id) else { return }

        // Meaningful = at least one write/edit (primary) OR a git mutation command (secondary).
        let hasWrite = session.liveFiles.contains { $0.operation == .write || $0.operation == .edit }
        let hasGit = session.liveCommands.contains { Self.isGitMutation($0) }
        guard hasWrite || hasGit else { return }

        // Mark deduped before async work to prevent races.
        devloggedSessions.insert(session.id)

        // Capture value types only — LiveSession is a struct so it copies cleanly.
        let sid = session.id
        let projectName = session.projectName
        let lastPrompt = session.lastPrompt ?? "(unknown)"
        let changedPaths = session.liveFiles
            .filter { $0.operation == .write || $0.operation == .edit }
            .map { $0.path }
        let commands = session.liveCommands

        // Detached: all work below is I/O — no @Published state touched until the
        // file write, which is fine off-main (atomically:true is thread-safe).
        Task.detached {
            let commits = await RecapStore.recentCommits(in: projectPath, limit: 10)
            let dateStr = Self.devlogDateFormatter.string(from: Date())

            let filesLine = changedPaths.isEmpty ? "(none)" : changedPaths.joined(separator: "\n  ")
            let cmdsLine = commands.isEmpty ? "(none)" : commands.suffix(20).joined(separator: "\n  ")
            let commitsLine = commits.isEmpty ? "(none)" : commits.joined(separator: "\n  ")
            let userMsg = """
                A Claude Code session just ended in \(projectName).
                Prompt: \(lastPrompt)
                Files changed:
                  \(filesLine)
                Commands:
                  \(cmdsLine)
                Recent commits:
                  \(commitsLine)
                Summarize what was accomplished in this session as a devlog entry.
                """

            let sysPrompt = LoreRunner.schemaPrompt(type: "devlog", projectPath: projectPath) ?? ""
            guard let body = await LoreRunner.generate(
                systemPrompt: sysPrompt,
                userMessage: userMsg,
                projectPath: projectPath,
                timeout: 180
            ), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let devlogDir = "\(projectPath)/docs/devlog"
            let shortId = String(sid.prefix(8))
            var filename = "\(dateStr)-session-\(shortId).md"
            // Guard against overwrite: if file already exists, append a sequential id.
            if FileManager.default.fileExists(atPath: "\(devlogDir)/\(filename)") {
                filename = "\(dateStr)-session-\(shortId)-\(LoreRunner.nextId(in: devlogDir)).md"
            }
            let content = """
                ---
                title: "\(dateStr) — session summary"
                date: "\(dateStr)"
                sessions: \(sid)
                ---

                # \(dateStr) — session summary

                \(body.trimmingCharacters(in: .whitespacesAndNewlines))
                """
            try? content.write(toFile: "\(devlogDir)/\(filename)", atomically: true, encoding: .utf8)
        }
    }

    /// Map a cwd path to the nearest known project name and path.
    private func projectInfo(for cwd: String?) -> (name: String, path: String?) {
        guard let cwd else { return ("unknown", nil) }
        if let proj = projects.first(where: { $0.path == cwd || cwd.hasPrefix("\($0.path)/") }) {
            return (proj.name, proj.path)
        }
        return (URL(fileURLWithPath: cwd).lastPathComponent, nil)
    }

    /// Shared helper: convert a tool call into live-activity events.
    /// Used by both the stream-JSON path (app-spawned tasks) and the hook path (external sessions).
    static func liveActivity(toolName: String, input: [String: Any]) -> (file: LiveFileEvent?, command: String?) {
        let now = Date()
        switch toolName {
        case "Read", "Glob", "LS":
            let p = (input["file_path"] ?? input["pattern"] ?? input["path"]) as? String ?? "unknown"
            return (LiveFileEvent(path: p, operation: .read, timestamp: now), nil)
        case "Write":
            let p = input["file_path"] as? String ?? "unknown"
            return (LiveFileEvent(path: p, operation: .write, timestamp: now), nil)
        case "Edit", "MultiEdit":
            let p = input["file_path"] as? String ?? "unknown"
            return (LiveFileEvent(path: p, operation: .edit, timestamp: now), nil)
        case "Bash":
            let cmd = input["command"] as? String ?? "unknown"
            return (nil, cmd)
        default:
            return (nil, nil)
        }
    }

    /// Installs dev-dash hooks for a project using the effective enabled-event set.
    /// Records install intent in `installedHookProjects` before reconciling so that
    /// the empty-events → re-enable round-trip survives without losing intent.
    /// Safe to call multiple times (idempotent reconcile).
    /// Throws `HookInstaller.InstallError` if existing settings.json is unparseable.
    func installHooks(for projectPath: String) throws {
        installedHookProjects.insert(projectPath)
        try HookInstaller.installProjectHooks(projectPath: projectPath,
                                              events: effectiveEnabledEvents(for: projectPath))
    }

    /// Removes dev-dash hooks from a project's `.claude/settings.json` and clears install intent.
    func uninstallHooks(for projectPath: String) {
        installedHookProjects.remove(projectPath)
        HookInstaller.uninstallProjectHooks(projectPath: projectPath)
    }

    /// Returns true if dev-dash hooks are managed for this project — either the user
    /// explicitly installed them (intent set) or settings.json currently has entries
    /// (covers pre-existing / manually-installed hooks). Intent is checked first so
    /// the "zero events enabled" state still counts as installed.
    func hooksInstalled(for projectPath: String) -> Bool {
        installedHookProjects.contains(projectPath) || HookInstaller.isInstalled(projectPath: projectPath)
    }

    enum HealthFilter: Hashable {
        case all
        case status(HealthStatus)

        var label: String {
            switch self {
            case .all: return "All"
            case .status(let s): return s.label
            }
        }
    }

    private var refreshTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    private var refreshing = false
    /// Set when `refreshAll` is asked to run while one is already in flight, so
    /// the current pass loops once more and the latest state (e.g. a just-added
    /// scan root) is always reflected rather than silently dropped.
    private var refreshPending = false

    /// Group ids currently being fetched from Linear. Mirrors the refreshing/refreshPending
    /// coalescing pattern: if a refresh is already in flight for a group, we skip it.
    private var refreshingGroups: Set<String> = []

    // MARK: - Project folders (scan roots)

    /// Add a folder to the scan roots, persist, and rescan. No-op for blanks
    /// or duplicates (after normalization).
    func addDevRoot(_ raw: String) {
        let norm = DevRoots.normalize(raw)
        guard !norm.isEmpty, !devRoots.contains(norm) else { return }
        DevRoots.setRoots(devRoots + [norm])
        devRoots = DevRoots.roots   // re-read so in-memory matches persisted (normalized/de-duped)
        Task { await refreshAll() }
    }

    /// Remove a folder from the scan roots, persist, and rescan.
    func removeDevRoot(_ root: String) {
        guard devRoots.contains(root) else { return }
        DevRoots.setRoots(devRoots.filter { $0 != root })
        devRoots = DevRoots.roots   // re-read so in-memory matches persisted source of truth
        Task { await refreshAll() }
    }

    /// Forget customization, revert to the built-in defaults, and rescan.
    func resetDevRoots() {
        DevRoots.resetRoots()
        devRoots = DevRoots.roots
        Task { await refreshAll() }
    }

    func refreshAll() async {
        // Coalesce: if a scan is in flight, flag it to loop once more on the
        // current pass rather than spawning a concurrent scan or dropping the
        // request — the latter would leave a just-changed root set unscanned.
        if refreshing { refreshPending = true; return }
        refreshing = true
        isLoading = true
        defer {
            refreshing = false
            isLoading = false
        }

        repeat {
            refreshPending = false

            // Stream results: each scan updates state as soon as it finishes,
            // so the sidebar populates progressively rather than waiting for the slowest.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    let svcs = await ProcessScanner.scan()
                    await MainActor.run { self?.services = svcs }
                }
                group.addTask { [weak self] in
                    let projs = await ProjectScanner.scanAll()
                    await MainActor.run { self?.projects = projs }
                }
                group.addTask { [weak self] in
                    let sess = await SessionScanner.scan(limit: 30)
                    await MainActor.run { self?.sessions = sess }
                }
            }
            self.lastUpdated = Date()
            pollPRMerges()

            // Background git status scan for all git projects — detached so it
            // doesn't block the main refresh tick. Results are collected and merged
            // in ONE @Published write per tick: per-path writes republished the whole
            // store N times (once per project), fanning out to every observing view.
            let gitPaths = projects.filter { $0.isGit }.map { $0.path }
            Task.detached(priority: .utility) { [weak self] in
                let statuses = await withTaskGroup(
                    of: (String, GitStatus)?.self,
                    returning: [String: GitStatus].self
                ) { group in
                    for path in gitPaths {
                        group.addTask {
                            guard let status = await GitStatusScanner.scan(path: path) else { return nil }
                            return (path, status)
                        }
                    }
                    var collected: [String: GitStatus] = [:]
                    for await pair in group {
                        if let (path, status) = pair { collected[path] = status }
                    }
                    return collected
                }
                guard !statuses.isEmpty else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.gitStatuses.merge(statuses) { _, new in new }
                }
            }
            // Linear sync — fan out across groups that have a team binding.
            let boundGroups = projectGroups.filter { $0.linearTeamId != nil }
            if !boundGroups.isEmpty {
                Task.detached(priority: .utility) { [weak self] in
                    await withTaskGroup(of: Void.self) { group in
                        for g in boundGroups {
                            group.addTask { await self?.refreshGroupLinearTasks(g) }
                        }
                    }
                }
            }
        } while refreshPending
    }

    /// Detect merged PRs for tasks with an open PR + active worktree.
    /// Called from refreshAll; each PR polled at most every 5 minutes; gh runs
    /// off-main. On merge: durable frontmatter flag (dedupe) + notification.
    func pollPRMerges() {
        let now = Date()
        var toPoll: [(projectPath: String, taskId: String, title: String, prNumber: Int)] = []
        for (path, tasks) in projectTasks {
            for task in tasks ?? [] where task.worktree != nil && !task.prMerged {
                guard let pr = task.pr,
                      let number = Self.prNumberFromURL(from: pr) else { continue }
                let key = "\(path)#\(task.id)"
                if let last = prMergePollLast[key], now.timeIntervalSince(last) < 300 { continue }
                prMergePollLast[key] = now
                toPoll.append((path, task.id, task.title, number))
            }
        }
        guard !toPoll.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for item in toPoll {
                guard let detail = await GitDiffScanner.prDetail(path: item.projectPath,
                                                                 number: item.prNumber) else { continue }
                guard detail.state.lowercased() == "merged" else { continue }
                // Durable dedupe first (rare, small frontmatter rewrite), then
                // notify + reload on main.
                try? TaskStore.setPRMerged(projectPath: item.projectPath, id: item.taskId)
                await MainActor.run {
                    guard let self else { return }
                    self.reloadTasks(for: item.projectPath)
                    self.notificationStore.post(.prMerged,
                        title: "PR merged", body: item.title,
                        projectPath: item.projectPath, tab: .tasks, taskId: item.taskId)
                }
            }
        }
    }

    func startAutoRefresh(interval: TimeInterval = 15) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                // Skip ticks while the app is inactive — 2 git subprocesses ×
                // N projects every 15s in the background is pure energy burn.
                // didBecomeActive (below) fires a catch-up refresh on return.
                if !NSApplication.shared.isActive { continue }
                await self?.refreshAll()
            }
        }
        // Catch-up refresh when the app comes back to the foreground, so the
        // sidebar is never staler than one activation.
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refreshAll() }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    var devServices: [Service] { _devServices }
    var infraServices: [Service] { _infraServices }
    var activeProjects: [Project] { projects.filter { $0.health == .active } }

    var filteredProjects: [Project] {
        switch healthFilter {
        case .all: return projects
        case .status(let s): return projects.filter { $0.health == s }
        }
    }

    func runningPort(for projectPath: String) -> Int? {
        primaryService(for: projectPath)?.port
    }

    /// Synthesize the current status snapshot for a project. Gathers already-loaded
    /// store data + lore reads and hands them to the pure synthesizer. Returns nil
    /// if `projectPath` isn't a known project.
    func projectStatus(for projectPath: String) -> ProjectStatus? {
        guard let project = projects.first(where: { $0.path == projectPath }) else { return nil }
        return ProjectStatusSynthesizer.synthesize(
            project: project,
            meta: meta(for: projectPath),
            tasks: tasksV2(for: projectPath),
            heatmap: heatmaps[projectPath],
            services: services(for: projectPath),
            now: Date()
        )
    }

    /// All running dev services that belong to a project, sorted by port.
    func services(for projectPath: String) -> [Service] {
        devServices
            .filter { $0.cwd == projectPath || $0.cwd.hasPrefix("\(projectPath)/") }
            .sorted { $0.port < $1.port }
    }

    private let primaryServiceKey = "devdash.primaryServiceByProject"

    /// User-pinned primary port per project (overrides framework heuristic).
    /// Backed by an in-memory cache: the getter is hit inside `primaryService`,
    /// which runs inside view bodies and sort comparators, so reading
    /// `UserDefaults` on every access was a real cost. Loaded lazily once.
    private lazy var _primaryServiceMap: [String: Int] =
        (UserDefaults.standard.dictionary(forKey: primaryServiceKey) as? [String: Int]) ?? [:]
    private var primaryServiceMap: [String: Int] {
        get { _primaryServiceMap }
        set {
            _primaryServiceMap = newValue
            UserDefaults.standard.set(newValue, forKey: primaryServiceKey)
        }
    }

    /// Pick the "primary" service for a project — preferring user override,
    /// then a frontend-framework service, then the lowest port.
    func primaryService(for projectPath: String) -> Service? {
        let svcs = services(for: projectPath)
        guard !svcs.isEmpty else { return nil }
        if let port = primaryServiceMap[projectPath],
           let pinned = svcs.first(where: { $0.port == port }) {
            return pinned
        }
        if let frontend = svcs.first(where: { $0.role == .frontend }) {
            return frontend
        }
        return svcs.first
    }

    func setPrimaryService(_ port: Int, for projectPath: String) {
        var map = primaryServiceMap
        map[projectPath] = port
        primaryServiceMap = map
        objectWillChange.send()
    }

    func project(for selection: Selection?) -> Project? {
        guard let sel = selection else { return nil }
        switch sel {
        case .home, .simulator:
            return nil
        case .project(let path):
            return projects.first { $0.path == path }
        case .service(let id):
            guard let svc = services.first(where: { $0.id == id }) else { return nil }
            return projects.first { svc.cwd == $0.path || svc.cwd.hasPrefix("\($0.path)/") }
        }
    }

    func service(for selection: Selection?) -> Service? {
        guard let sel = selection else { return nil }
        switch sel {
        case .home, .simulator:
            return nil
        case .service(let id):
            return services.first { $0.id == id }
        case .project(let path):
            return primaryService(for: path)
        }
    }

    func tasks(for projectPath: String) -> ProjectTasks? {
        tasksByProject.first { $0.projectPath == projectPath }
    }

    func sessions(for projectPath: String) -> [ClaudeSession] {
        sessions.filter { $0.projectPath == projectPath || $0.projectPath.hasPrefix("\(projectPath)/") }
    }

    func refreshTodos() async {
        let paths = projects.map { $0.path }
        let todoData = await TodoStore.gather(projectPaths: paths)
        var map: [String: ProjectTasks] = [:]
        for entry in todoData {
            map[entry.path] = ProjectTasks(
                projectPath: entry.path,
                projectName: entry.name,
                repo: nil,
                todos: entry.todos,
                issues: []
            )
        }
        // Preserve existing issues
        for existing in tasksByProject {
            if var t = map[existing.projectPath] {
                t = ProjectTasks(
                    projectPath: t.projectPath,
                    projectName: t.projectName,
                    repo: existing.repo,
                    todos: t.todos,
                    issues: existing.issues
                )
                map[existing.projectPath] = t
            } else if !existing.issues.isEmpty {
                map[existing.projectPath] = ProjectTasks(
                    projectPath: existing.projectPath,
                    projectName: existing.projectName,
                    repo: existing.repo,
                    todos: [],
                    issues: existing.issues
                )
            }
        }
        self.tasksByProject = Array(map.values).sorted { $0.projectName < $1.projectName }
    }

    func refreshIssues() async {
        isLoadingIssues = true
        defer { isLoadingIssues = false }

        let issueData = await IssueScanner.gather(projects: projects)
        var map: [String: ProjectTasks] = [:]
        for existing in tasksByProject {
            map[existing.projectPath] = existing
        }
        for entry in issueData {
            if var t = map[entry.path] {
                t = ProjectTasks(
                    projectPath: t.projectPath,
                    projectName: t.projectName,
                    repo: entry.repo,
                    todos: t.todos,
                    issues: entry.issues
                )
                map[entry.path] = t
            } else {
                map[entry.path] = ProjectTasks(
                    projectPath: entry.path,
                    projectName: entry.name,
                    repo: entry.repo,
                    todos: [],
                    issues: entry.issues
                )
            }
        }
        self.tasksByProject = Array(map.values).sorted { $0.projectName < $1.projectName }
    }

    @Published var todoError: String?

    // MARK: - Claude session digests

    /// Re-parse digests for the current sessions list, using the on-disk cache
    /// when the JSONL hasn't changed since last parse.
    func refreshSessionDigests() {
        digestTask?.cancel()
        let sess = sessions
        digestTask = Task.detached(priority: .utility) { [weak self] in
            let claudeDir = "\(NSHomeDirectory())/.claude/projects"
            for s in sess {
                if Task.isCancelled { return }
                let dirName = s.projectPath.replacingOccurrences(of: "/", with: "-")
                let jsonl = "\(claudeDir)/\(dirName)/\(s.id).jsonl"
                let digest: SessionDigest? = {
                    if let cached = ClaudeSessionParser.cachedDigest(sessionId: s.id, jsonlPath: jsonl) {
                        return cached
                    }
                    if FileManager.default.fileExists(atPath: jsonl) {
                        let parsed = ClaudeSessionParser.parseDigest(
                            jsonlPath: jsonl, sessionId: s.id,
                            projectPath: s.projectPath, projectName: s.projectName
                        )
                        if let d = parsed { ClaudeSessionParser.writeCache(d) }
                        return parsed
                    }
                    // Fallback: try to find the JSONL by scanning all dirs (path-encoding edge cases)
                    if let resolved = Self.resolveJsonlPath(sessionId: s.id) {
                        let parsed = ClaudeSessionParser.parseDigest(
                            jsonlPath: resolved, sessionId: s.id,
                            projectPath: s.projectPath, projectName: s.projectName
                        )
                        if let d = parsed { ClaudeSessionParser.writeCache(d) }
                        return parsed
                    }
                    return nil
                }()
                if let d = digest {
                    await MainActor.run { self?.sessionDigests[s.id] = d }
                }
            }
        }
    }

    func digest(for sessionId: String) -> SessionDigest? { sessionDigests[sessionId] }

    func transcript(for sessionId: String) async -> SessionTranscript? {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return nil }
        let path = Self.resolveJsonlPath(sessionId: sessionId) ?? {
            let dir = session.projectPath.replacingOccurrences(of: "/", with: "-")
            return "\(NSHomeDirectory())/.claude/projects/\(dir)/\(sessionId).jsonl"
        }()
        return await Task.detached(priority: .userInitiated) {
            ClaudeSessionParser.parseTranscript(
                jsonlPath: path, sessionId: sessionId,
                projectPath: session.projectPath, projectName: session.projectName
            )
        }.value
    }

    func transcriptForDigest(_ digest: SessionDigest) async -> SessionTranscript? {
        let sessionId = digest.id
        let path = Self.resolveJsonlPath(sessionId: sessionId) ?? {
            let dir = digest.projectPath.replacingOccurrences(of: "/", with: "-")
            return "\(NSHomeDirectory())/.claude/projects/\(dir)/\(sessionId).jsonl"
        }()
        return await Task.detached(priority: .userInitiated) {
            ClaudeSessionParser.parseTranscript(
                jsonlPath: path, sessionId: sessionId,
                projectPath: digest.projectPath, projectName: digest.projectName
            )
        }.value
    }

    nonisolated static func resolveJsonlPath(sessionId: String) -> String? {
        let claudeDir = "\(NSHomeDirectory())/.claude/projects"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: claudeDir) else { return nil }
        for d in dirs {
            let candidate = "\(claudeDir)/\(d)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Project metadata + structured tasks

    func meta(for projectPath: String) -> ProjectMeta {
        projectMeta[projectPath] ?? .empty
    }

    func template(for projectPath: String) -> LaunchTemplate? {
        Templates.find(meta(for: projectPath).templateId)
    }

    func currentStage(for projectPath: String) -> TemplateStage? {
        guard let template = template(for: projectPath),
              let stageId = meta(for: projectPath).currentStageId else { return nil }
        return template.stages.first { $0.id == stageId }
    }

    func tasksV2(for projectPath: String) -> [TaskItem] {
        projectTasks[projectPath] ?? []
    }

    /// Initial load — pulls meta + tasks + tickets + providers for every project.
    /// For each project, runs TicketMigrator off the main actor (blocking file I/O;
    /// self-gated via marker so it only runs once). After migration completes, reads
    /// tickets so the UI shows the post-migration state on first render.
    func loadProjectMetaAndTasks() {
        let paths = projects.map { $0.path }
        Task.detached(priority: .utility) { [weak self] in
            var metaMap: [String: ProjectMeta] = [:]
            var taskMap: [String: [TaskItem]] = [:]
            var ticketMap: [String: [Ticket]] = [:]
            var providerMap: [String: [Provider]] = [:]
            var healthMap: [String: [String: HealthRunResult]] = [:]
            var collisionMap: [String: [String]] = [:]
            for path in paths {
                // Run migration first (marker-gated, fast-path when already done).
                // This is blocking file I/O — must stay off the main actor.
                TicketMigrator.migrate(projectPath: path)

                metaMap[path] = ProjectMetaStore.read(path)
                // Read tasks AFTER migration so post-migration task state is used.
                let tasks = TaskStore.read(path)
                if !tasks.isEmpty { taskMap[path] = tasks }
                // Read tickets AFTER migration so newly-created tickets appear.
                let tickets = TicketStore.read(path)
                if !tickets.isEmpty { ticketMap[path] = tickets }
                let providers = ProviderStore.refresh(path)
                if !providers.isEmpty { providerMap[path] = providers }
                let health = HealthStore.read(path)
                if !health.isEmpty { healthMap[path] = health }
                let collisions = LoreIdAudit.audit(projectPath: path)
                if !collisions.isEmpty { collisionMap[path] = collisions }
            }
            await MainActor.run {
                self?.projectMeta = metaMap
                self?.projectTasks = taskMap
                self?.projectTickets = ticketMap
                self?.projectProviders = providerMap
                self?.projectHealth = healthMap
                self?.projectIdCollisions = collisionMap
                self?.seedTaskSnapshots()
                // Load groups after meta is set so migration can read it.
                self?.loadGroupsAndTasks()
                self?.migratePerRepoLinearBindings()
                self?.restoreRecentEvents()
            }
        }
    }

    private var didRestoreRecentEvents = false

    /// Reconstruct `recentEvents` as a tail view over today's NDJSON operation
    /// logs (ADR 0013) — once, after the first project scan, and only if no
    /// live hook events have arrived yet (live events win over history).
    func restoreRecentEvents() {
        guard !didRestoreRecentEvents else { return }
        didRestoreRecentEvents = true
        guard recentEvents.isEmpty else { return }
        let projs = projects.map { ($0.path, $0.name) }
        Task.detached(priority: .utility) { [weak self] in
            var restored: [ClaudeIntegrationEvent] = []
            for (path, name) in projs {
                for pe in EventLogStore.readToday(projectPath: path) {
                    guard let ts = EventLogStore.isoFormatter.date(from: pe.ts) else { continue }
                    restored.append(ClaudeIntegrationEvent(
                        timestamp: ts,
                        projectPath: path,
                        projectName: name,
                        hookEvent: pe.hook,
                        category: .init(rawValue: pe.cat) ?? .other,
                        detail: pe.detail
                    ))
                }
            }
            restored.sort { $0.timestamp > $1.timestamp }
            let tail = Array(restored.prefix(300))
            guard !tail.isEmpty else { return }
            await MainActor.run {
                guard let self, self.recentEvents.isEmpty else { return }
                self.recentEvents = tail
            }
        }
    }

    /// Reload tickets for a single project from disk, publishing on the main actor.
    /// Call after any in-app ticket mutation.
    func reloadTickets(for projectPath: String) {
        let tickets = TicketStore.read(projectPath)
        projectTickets[projectPath] = tickets.isEmpty ? nil : tickets
    }

    /// Re-read policy docs for a project into `projectPolicies`.
    func reloadPolicies(for projectPath: String) {
        projectPolicies[projectPath] = PolicyStore.read(projectPath)
    }

    /// Active policies whose scope contains `scope` (or "any") and whose
    /// trigger list contains `trigger`, ordered by (priority ?? max, numeric id).
    func policies(for projectPath: String, appliesTo scope: String, trigger: String) -> [Policy] {
        let all = projectPolicies[projectPath] ?? PolicyStore.read(projectPath)
        return all
            .filter { $0.status == .active }
            .filter { $0.appliesTo.contains(scope) || $0.appliesTo.contains("any") }
            .filter { $0.trigger.contains(trigger) }
            .sorted { lhs, rhs in
                let lp = lhs.priority ?? Int.max
                let rp = rhs.priority ?? Int.max
                if lp != rp { return lp < rp }
                return (Int(lhs.id) ?? 0) < (Int(rhs.id) ?? 0)
            }
    }

    /// Joined bodies of active `ticket`-scoped policies for a trigger.
    /// Empty string when none match.
    func ticketPolicyText(projectPath: String, trigger: String) -> String {
        policyText(projectPath: projectPath, appliesTo: "ticket", trigger: trigger)
    }

    /// Joined bodies of active policies for any scope + trigger. Empty when none.
    func policyText(projectPath: String, appliesTo scope: String, trigger: String) -> String {
        policies(for: projectPath, appliesTo: scope, trigger: trigger)
            .map { $0.body }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Build the on-demand ticket-breakdown prompt. Policy text first, then
    /// ticket context, then existing tasks to avoid duplicates. Launch-template
    /// is intentionally not included.
    func buildTicketBreakdownPrompt(ticket: Ticket,
                                    existingTaskTitles: [String],
                                    projectPath: String,
                                    deep: Bool) -> String {
        let policy = ticketPolicyText(projectPath: projectPath, trigger: "on_demand")
        let existing = existingTaskTitles.isEmpty
            ? "(none yet)"
            : existingTaskTitles.map { "- \($0)" }.joined(separator: "\n")
        let deepLine = deep
            ? "\nFirst read the relevant code in this project to ground your suggestions.\n"
            : ""
        return """
        \(policy.isEmpty ? "Break this ticket into concrete child tasks." : policy)
        \(deepLine)
        Ticket: \(ticket.title)
        Category: \(ticket.category.rawValue)
        Notes: \(ticket.notes ?? "(none)")

        Existing tasks on this ticket (don't duplicate these):
        \(existing)

        Output each suggested task on its own line as exactly: `TASK: <title>`
        """
    }

    func applyTemplate(_ template: LaunchTemplate, to projectPath: String) {
        do {
            try ProjectMetaStore.applyTemplate(template, to: projectPath)
            projectMeta[projectPath] = ProjectMetaStore.read(projectPath)
            regenerateRoadmap(for: projectPath)
        } catch {
            todoError = "Couldn't apply template: \(error.localizedDescription)"
        }
    }

    func setProjectNotes(_ notes: String, for projectPath: String) {
        var m = meta(for: projectPath)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        m.notes = trimmed.isEmpty ? nil : trimmed
        try? ProjectMetaStore.write(projectPath, meta: m)
        projectMeta[projectPath] = m
    }

    func setCustomDevServerURL(_ url: String, for projectPath: String) {
        var m = meta(for: projectPath)
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        m.customDevServerURL = trimmed.isEmpty ? nil : trimmed
        try? ProjectMetaStore.write(projectPath, meta: m)
        projectMeta[projectPath] = m
    }

    func setProductionURL(_ url: String, for projectPath: String) {
        var m = meta(for: projectPath)
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        m.productionURL = trimmed.isEmpty ? nil : trimmed
        try? ProjectMetaStore.write(projectPath, meta: m)
        projectMeta[projectPath] = m
    }

    func clearTemplate(for projectPath: String) {
        var m = meta(for: projectPath)
        m.templateId = nil
        m.currentStageId = nil
        m.stageStartedAt = nil
        m.checkedExitCriteria = []
        try? ProjectMetaStore.write(projectPath, meta: m)
        projectMeta[projectPath] = m
    }

    func setStage(_ stageId: String, for projectPath: String) {
        try? ProjectMetaStore.setStage(stageId, for: projectPath)
        projectMeta[projectPath] = ProjectMetaStore.read(projectPath)
        regenerateRoadmap(for: projectPath)
    }

    func toggleExitCriterion(_ criterion: String, stageId: String, for projectPath: String) {
        try? ProjectMetaStore.toggleExitCriterion(criterion, stageId: stageId, for: projectPath)
        projectMeta[projectPath] = ProjectMetaStore.read(projectPath)
        regenerateRoadmap(for: projectPath)
    }

    func setAnswer(_ answer: String, stageId: String, question: String, for projectPath: String) {
        try? ProjectMetaStore.setAnswer(answer, stageId: stageId, question: question, for: projectPath)
        projectMeta[projectPath] = ProjectMetaStore.read(projectPath)
        regenerateRoadmap(for: projectPath)
    }

    /// Write ROADMAP.md and the living product doc from current state. Safe
    /// to call frequently — both regenerators bail / no-op when the project
    /// has no template or when the file isn't DevDash-owned. State mutations
    /// call this.
    func regenerateRoadmap(for projectPath: String) {
        let project = projects.first { $0.path == projectPath }
        let name = project?.name ?? URL(fileURLWithPath: projectPath).lastPathComponent
        let meta = self.meta(for: projectPath)
        let tasks = tasksV2(for: projectPath)
        let template = self.template(for: projectPath)

        if let template = template {
            _ = RoadmapGenerator.write(
                projectName: name, projectPath: projectPath,
                meta: meta, template: template, tasks: tasks
            )
        }
        // Living doc generates whether or not a template is applied — without
        // one, the Roadmap tab just shows an "apply a template" prompt.
        _ = ProductDocGenerator.generate(
            projectName: name, projectPath: projectPath,
            meta: meta, template: template, tasks: tasks,
            status: projectStatus(for: projectPath),
            accent: docAccent, fonts: resolvedDocFonts
        )
    }

    func addTask(
        projectPath: String,
        title: String,
        category: TaskCategory = .other,
        stage: String? = nil,
        notes: String? = nil,
        parentId: String? = nil,
        linkedDocPath: String? = nil,
        ticket: String? = nil
    ) {
        do {
            var task = try TaskStore.add(
                projectPath: projectPath, title: title,
                category: category, stage: stage, notes: notes,
                source: .local, parentId: parentId,
                linkedDocPath: linkedDocPath
            )
            // Set ticket field if provided (write the frontmatter key in-place).
            if let ticketId = ticket {
                let dir = TaskStore.file(for: projectPath)
                if let fname = TaskStore.findFile(id: task.id, in: dir),
                   let raw = try? String(contentsOfFile: "\(dir)/\(fname)", encoding: .utf8) {
                    let patched = TaskStore.setOrAddFrontmatterKey(in: raw, key: "ticket",
                                                                   value: TaskStore.yamlStr(ticketId))
                    try? patched.write(toFile: "\(dir)/\(fname)", atomically: true, encoding: .utf8)
                }
                task.ticket = ticketId
            }
            projectTasks[projectPath] = TaskStore.read(projectPath)
            refreshTaskSnapshot(for: projectPath)
            todoError = nil
            regenerateRoadmap(for: projectPath)
        } catch {
            todoError = "Couldn't add task: \(error.localizedDescription)"
        }
    }

    /// Create a new ticket doc (docs/tickets/*.md) for the project and refresh.
    func addTicket(
        projectPath: String,
        title: String,
        category: TaskCategory = .other,
        owner: TaskOwner = .none,
        notes: String? = nil
    ) {
        do {
            _ = try TicketStore.add(
                projectPath: projectPath, title: title,
                category: category, owner: owner, notes: notes
            )
            reloadTickets(for: projectPath)
            todoError = nil
        } catch {
            todoError = "Couldn't add ticket: \(error.localizedDescription)"
        }
    }

    /// Set status on a ticket by id, then refresh tickets.
    func setTicketStatus(projectPath: String, id: String, status: TaskStatus) {
        try? TicketStore.setStatus(projectPath: projectPath, id: id, status: status)
        reloadTickets(for: projectPath)
    }

    /// Set owner on a ticket by id, then refresh tickets.
    func setTicketOwner(projectPath: String, id: String, owner: TaskOwner) {
        try? TicketStore.setOwner(projectPath: projectPath, id: id, owner: owner)
        reloadTickets(for: projectPath)
    }

    func setTaskParent(projectPath: String, id: String, newParentId: String?) {
        try? TaskStore.setParent(projectPath: projectPath, id: id, newParentId: newParentId)
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)
        regenerateRoadmap(for: projectPath)
    }

    func childTasks(of parentId: String, in projectPath: String) -> [TaskItem] {
        tasksV2(for: projectPath).filter { $0.parentId == parentId }
    }

    func rootTasks(stage: String?, in projectPath: String) -> [TaskItem] {
        tasksV2(for: projectPath).filter { $0.parentId == nil && $0.stage == stage }
    }

    // MARK: - Linear integration

    /// Tracks in-flight (or failed) status pushes to Linear so refreshGroupLinearTasks
    /// won't overwrite local status changes that haven't yet landed remotely.
    private var pendingLinearPush: [String: TaskStatus] = [:]

    /// Published so views can react without calling SecItemCopyMatching on every render.
    @Published var isLinearKeyPresent: Bool = KeychainStore.linearKey() != nil

    func setLinearAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.clearLinearKey()
        } else {
            KeychainStore.setLinearKey(trimmed)
        }
        isLinearKeyPresent = KeychainStore.linearKey() != nil
        // Kick off a refresh for all groups already bound to a Linear team.
        let boundGroups = projectGroups.filter { $0.linearTeamId != nil }
        for g in boundGroups {
            Task { await refreshGroupLinearTasks(g) }
        }
    }

    func clearLinearAPIKey() {
        KeychainStore.clearLinearKey()
        isLinearKeyPresent = false
    }

    // MARK: - Project Groups

    /// Return the group this repo belongs to, if any.
    func group(for projectPath: String) -> ProjectGroup? {
        projectGroups.first { $0.projectPaths.contains(projectPath) }
    }

    func groupById(_ id: String) -> ProjectGroup? {
        projectGroups.first { $0.id == id }
    }

    /// Merge-in a fresh groups array from disk; also load their cached Linear tasks.
    private func loadGroupsAndTasks() {
        let groups = GroupStore.read()
        projectGroups = groups
        var tasksMap: [String: [TaskItem]] = [:]
        for g in groups {
            let t = GroupStore.readTasks(groupId: g.id)
            if !t.isEmpty { tasksMap[g.id] = t }
        }
        groupLinearTasks = tasksMap
        // Kick a one-shot fan-out so bound groups sync on launch rather than
        // waiting for the first 15-second auto-refresh tick.
        let boundGroups = groups.filter { $0.linearTeamId != nil }
        for g in boundGroups {
            Task { await refreshGroupLinearTasks(g) }
        }
    }

    private func persistGroups() {
        GroupStore.write(projectGroups)
    }

    @discardableResult
    func createGroup(
        name: String,
        linearTeamId: String? = nil,
        linearTeamName: String? = nil,
        linearProjectId: String? = nil,
        linearProjectName: String? = nil
    ) -> ProjectGroup {
        let now = Date()
        let g = ProjectGroup(
            id: UUID().uuidString,
            name: name,
            projectPaths: [],
            linearTeamId: linearTeamId,
            linearTeamName: linearTeamName,
            linearProjectId: linearProjectId,
            linearProjectName: linearProjectName,
            createdAt: now,
            updatedAt: now
        )
        projectGroups.append(g)
        persistGroups()
        return g
    }

    func renameGroup(id: String, name: String) {
        guard let idx = projectGroups.firstIndex(where: { $0.id == id }) else { return }
        projectGroups[idx].name = name
        projectGroups[idx].updatedAt = Date()
        persistGroups()
    }

    func deleteGroup(id: String) {
        projectGroups.removeAll { $0.id == id }
        groupLinearTasks.removeValue(forKey: id)
        GroupStore.deleteTasks(groupId: id)
        persistGroups()
        UserDefaults.standard.removeObject(forKey: "devdash.groupCollapsed.\(id)")
    }

    func setGroupLinearBinding(
        id: String,
        teamId: String?,
        teamName: String?,
        projectId: String?,
        projectName: String?
    ) {
        guard let idx = projectGroups.firstIndex(where: { $0.id == id }) else { return }
        let resolvedTeamId = teamId.flatMap { $0.isEmpty ? nil : $0 }
        projectGroups[idx].linearTeamId = resolvedTeamId
        projectGroups[idx].linearTeamName = teamName.flatMap { $0.isEmpty ? nil : $0 }
        projectGroups[idx].linearProjectId = projectId
        projectGroups[idx].linearProjectName = projectName
        projectGroups[idx].updatedAt = Date()
        persistGroups()
        if resolvedTeamId == nil {
            groupLinearTasks.removeValue(forKey: id)
            GroupStore.deleteTasks(groupId: id)
        } else {
            let g = projectGroups[idx]
            Task { await refreshGroupLinearTasks(g) }
        }
    }

    /// Add a repo to a group. Removes it from any other group first (one-group-per-repo).
    func addProjectToGroup(projectPath: String, groupId: String) {
        for idx in projectGroups.indices where projectGroups[idx].projectPaths.contains(projectPath) {
            projectGroups[idx].projectPaths.removeAll { $0 == projectPath }
            projectGroups[idx].updatedAt = Date()
        }
        guard let idx = projectGroups.firstIndex(where: { $0.id == groupId }) else { return }
        if !projectGroups[idx].projectPaths.contains(projectPath) {
            projectGroups[idx].projectPaths.append(projectPath)
        }
        projectGroups[idx].updatedAt = Date()
        persistGroups()
        let g = projectGroups[idx]
        if g.linearTeamId != nil {
            Task { await refreshGroupLinearTasks(g) }
        }
    }

    func removeProjectFromGroup(projectPath: String) {
        for idx in projectGroups.indices where projectGroups[idx].projectPaths.contains(projectPath) {
            projectGroups[idx].projectPaths.removeAll { $0 == projectPath }
            projectGroups[idx].updatedAt = Date()
        }
        persistGroups()
    }

    // MARK: - Migration (per-repo Linear binding → group)

    /// Runs once at init when projectMeta has been loaded. For each project with
    /// a linearTeamId set, finds or creates a matching group and migrates it.
    private func migratePerRepoLinearBindings() {
        let bound = projectMeta.filter { $0.value.linearTeamId != nil }
        guard !bound.isEmpty else { return }

        for (path, meta) in bound {
            guard let teamId = meta.linearTeamId else { continue }
            let bindingKey = meta.linearProjectId ?? teamId

            let existing = projectGroups.first { g in
                if let pid = meta.linearProjectId {
                    return g.linearProjectId == pid
                }
                return g.linearTeamId == teamId && g.linearProjectId == nil
            }

            let groupId: String
            if let g = existing {
                groupId = g.id
            } else {
                let groupName = meta.linearProjectName ?? meta.linearTeamName ?? "Linear"
                let g = createGroup(
                    name: groupName,
                    linearTeamId: meta.linearTeamId,
                    linearTeamName: meta.linearTeamName,
                    linearProjectId: meta.linearProjectId,
                    linearProjectName: meta.linearProjectName
                )
                groupId = g.id
            }

            addProjectToGroup(projectPath: path, groupId: groupId)
            var m = meta
            m.linearTeamId = nil
            m.linearTeamName = nil
            m.linearProjectId = nil
            m.linearProjectName = nil
            try? ProjectMetaStore.write(path, meta: m)
            projectMeta[path] = m

            _ = bindingKey  // suppress unused warning
        }
    }

    // MARK: - Group-level Linear sync

    /// Fetch Linear issues once for the group's team (+project filter) and upsert
    /// into groupLinearTasks[group.id].
    func refreshGroupLinearTasks(_ group: ProjectGroup) async {
        guard let teamId = group.linearTeamId, !teamId.isEmpty,
              KeychainStore.linearKey() != nil else { return }

        let alreadyRefreshing = await MainActor.run {
            if self.refreshingGroups.contains(group.id) { return true }
            self.refreshingGroups.insert(group.id)
            return false
        }
        guard !alreadyRefreshing else { return }
        defer {
            Task { @MainActor in self.refreshingGroups.remove(group.id) }
        }

        let issues = await LinearScanner.fetchIssues(teamId: teamId, projectId: group.linearProjectId)
        guard !issues.isEmpty else { return }

        let bindingStillValid = await MainActor.run {
            guard let live = self.projectGroups.first(where: { $0.id == group.id }) else { return false }
            return live.linearTeamId == group.linearTeamId
                && live.linearProjectId == group.linearProjectId
        }
        guard bindingStillValid else { return }

        await MainActor.run {
            let pending = self.pendingLinearPush
            var existing = self.groupLinearTasks[group.id] ?? []

            for issue in issues {
                let mapped = LinearScanner.toTaskItem(issue)
                if let idx = existing.firstIndex(where: { $0.linearIssueId == issue.id }) {
                    var t = existing[idx]
                    t.title = mapped.title
                    t.notes = mapped.notes
                    t.linearIdentifier = mapped.linearIdentifier
                    t.linearURL = mapped.linearURL
                    if pending[t.id] == nil {
                        t.status = mapped.status
                        t.startedAt = mapped.startedAt
                        t.completedAt = mapped.completedAt
                    }
                    existing[idx] = t
                } else {
                    existing.append(mapped)
                }
            }

            self.groupLinearTasks[group.id] = existing
            GroupStore.writeTasks(groupId: group.id, tasks: existing)
        }
    }

    /// Tasks to display for a selected project: its own local tasks plus, if the
    /// repo belongs to a group, the group's shared Linear tasks.
    func tasksForDisplay(projectPath: String) -> [TaskItem] {
        var result = projectTasks[projectPath] ?? []
        if let g = group(for: projectPath), let linearTasks = groupLinearTasks[g.id] {
            let existingIds = Set(result.map { $0.id })
            let extra = linearTasks.filter { !existingIds.contains($0.id) }
            result.append(contentsOf: extra)
        }
        return result
    }

    func setTaskStatus(projectPath: String, id: String, status: TaskStatus) {
        // Check if this task lives in a group's Linear task list first.
        if let grp = group(for: projectPath),
           var groupTasks = groupLinearTasks[grp.id],
           let idx = groupTasks.firstIndex(where: { $0.id == id }) {
            let task = groupTasks[idx]
            guard task.source == .linear, let issueId = task.linearIssueId else {
                // Non-Linear task in group — fall through to local store.
                return setLocalTaskStatus(projectPath: projectPath, id: id, status: status)
            }
            groupTasks[idx].status = status
            groupLinearTasks[grp.id] = groupTasks
            GroupStore.writeTasks(groupId: grp.id, tasks: groupTasks)

            pendingLinearPush[id] = status
            let teamId = grp.linearTeamId ?? ""
            Task.detached(priority: .utility) {
                let states = await LinearScanner.fetchStates(teamId: teamId)
                guard let stateId = LinearScanner.stateId(for: status, in: states) else {
                    await MainActor.run { _ = self.pendingLinearPush.removeValue(forKey: id) }
                    return
                }
                let success = await LinearScanner.updateIssueState(issueId: issueId, stateId: stateId)
                if success {
                    await MainActor.run { _ = self.pendingLinearPush.removeValue(forKey: id) }
                }
            }
            return
        }

        setLocalTaskStatus(projectPath: projectPath, id: id, status: status)
    }

    private func setLocalTaskStatus(projectPath: String, id: String, status: TaskStatus) {
        try? TaskStore.setStatus(projectPath: projectPath, id: id, status: status)
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)
        regenerateRoadmap(for: projectPath)
    }

    func setTaskOwner(projectPath: String, id: String, owner: TaskOwner) {
        try? TaskStore.setOwner(projectPath: projectPath, id: id, owner: owner)
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)
    }

    // MARK: - Lore-id bridges (for LoreTasksView)

    /// Resolve a lore numeric task id (e.g. "0042" or "42") to a TaskItem and
    /// call the existing AI methods. Numeric comparison tolerates zero-padding.
    func launchClaudeForTask(taskId: String, projectPath: String) {
        guard let t = TaskStore.read(projectPath).first(where: { loreIdEq($0.id, taskId) }) else { return }
        launchClaudeForTask(t, projectPath: projectPath)
    }

    /// Launch Claude for a ticket by creating a work Task under that ticket and
    /// then calling the existing `launchClaudeForTask` path (worktree + terminal +
    /// seeded prompt). The new task is owned by AI so the kanban column reads
    /// .aiWorking immediately.
    ///
    /// Idempotent: if the ticket already has an active (.aiWorking) work task,
    /// re-launches that task instead of creating a duplicate.
    func launchClaudeForTicket(ticketId: String, projectPath: String) {
        // Re-use an existing active work task if one exists for this ticket.
        let existingActive = TaskStore.read(projectPath).first { t in
            guard let tid = t.ticket else { return false }
            return TicketStore.numEq(tid, ticketId) && t.kanbanColumn == .aiWorking
        }
        if let active = existingActive {
            launchClaudeForTask(active, projectPath: projectPath)
            return
        }

        // Resolve the ticket title for the seeded prompt.
        let ticket = (projectTickets[projectPath] ?? [])
            .first { TicketStore.numEq($0.id, ticketId) }
        let ticketTitle = ticket?.title ?? "ticket \(ticketId)"

        // Create the work task with owner=.ai so it lands in aiWorking.
        let dir = TaskStore.file(for: projectPath)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("launchClaudeForTicket: createDirectory failed: %@", error.localizedDescription)
            return
        }

        var workTask: TaskItem
        do {
            workTask = try TaskStore.add(
                projectPath: projectPath,
                title: ticketTitle,
                category: ticket?.category ?? .other,
                source: .local
            )
        } catch {
            NSLog("launchClaudeForTicket: TaskStore.add failed: %@", error.localizedDescription)
            return
        }

        // Set ticket + owner=.ai in-place so the task is linked and the kanban
        // column reflects aiWorking before launchClaudeForTask runs.
        if let fname = TaskStore.findFile(id: workTask.id, in: dir),
           let raw = try? String(contentsOfFile: "\(dir)/\(fname)", encoding: .utf8) {
            var patched = TaskStore.setOrAddFrontmatterKey(
                in: raw, key: "ticket", value: TaskStore.yamlStr(ticketId))
            patched = TaskStore.setOrAddFrontmatterKey(
                in: patched, key: "owner", value: TaskOwner.ai.rawValue)
            try? patched.write(toFile: "\(dir)/\(fname)", atomically: true, encoding: .utf8)
        }
        workTask.ticket = ticketId
        workTask.owner = .ai

        // Refresh in-memory state before launching so the task is visible.
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)
        reloadTickets(for: projectPath)

        // Re-read the task to pick up the persisted ticket/owner fields, then launch.
        let persisted = TaskStore.read(projectPath).first { $0.id == workTask.id } ?? workTask
        launchClaudeForTask(persisted, projectPath: projectPath)
    }

    func runForTask(taskId: String, projectPath: String, allowEdits: Bool) async {
        guard let t = TaskStore.read(projectPath).first(where: { loreIdEq($0.id, taskId) }) else { return }
        await runForTask(t, projectPath: projectPath, allowEdits: allowEdits)
    }

    /// Numeric equality tolerant of zero-padding (e.g. "0042" == "42").
    private func loreIdEq(_ a: String, _ b: String) -> Bool {
        (Int(a) ?? -1) == (Int(b) ?? -2)
    }

    /// Set status by lore numeric id, mapping lore string values to TaskStatus cases.
    /// Falls back gracefully: unknown status values are silently ignored (caller
    /// should fall back to direct file write for those).
    @discardableResult
    func setTaskStatusByLoreId(projectPath: String, taskId: String, loreStatus: String) -> Bool {
        let mapped: TaskStatus
        switch loreStatus {
        case "open":        mapped = .open
        case "in_progress": mapped = .inProgress
        case "blocked":     mapped = .blocked
        case "done":        mapped = .done
        case "skipped":     mapped = .skipped
        default:            return false
        }
        setTaskStatus(projectPath: projectPath, id: taskId, status: mapped)
        return true
    }

    /// Set owner by lore numeric id, mapping lore string values to TaskOwner cases.
    @discardableResult
    func setTaskOwnerByLoreId(projectPath: String, taskId: String, loreOwner: String) -> Bool {
        let mapped: TaskOwner
        switch loreOwner {
        case "human": mapped = .human
        case "ai":    mapped = .ai
        case "none":  mapped = .none
        default:      return false
        }
        setTaskOwner(projectPath: projectPath, id: taskId, owner: mapped)
        return true
    }

    func reloadTasks(for projectPath: String) {
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)
    }

    func deleteTask(projectPath: String, id: String) {
        try? TaskStore.delete(projectPath: projectPath, id: id)
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)
        regenerateRoadmap(for: projectPath)
    }

    func updateTask(projectPath: String, _ task: TaskItem) {
        try? TaskStore.update(projectPath: projectPath, task)
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)
        regenerateRoadmap(for: projectPath)
    }

    /// Remove the git worktree for a task and clear the worktree/branch fields.
    /// Safe to call when the worktree directory no longer exists (prune-only).
    /// Never auto-called — always triggered by an explicit user action.
    func removeWorktreeForTask(projectPath: String, taskId: String) async {
        guard let task = tasksV2(for: projectPath).first(where: { $0.id == taskId }),
              let worktreePath = task.worktree,
              let branch = task.branch
        else { return }

        // Resolve the main repo from the worktree path or fall back to projectPath.
        let repoPath = await WorktreeManager.repoPath(forWorktree: worktreePath) ?? projectPath

        _ = await WorktreeManager.remove(
            repoPath: repoPath,
            worktreePath: worktreePath,
            branch: branch,
            deleteBranch: true
        )

        // Clear the fields on the task regardless of whether git remove succeeded
        // (the user pressed the button; don't leave stale paths).
        await MainActor.run {
            try? TaskStore.setWorktree(projectPath: projectPath, id: taskId, worktree: nil, branch: nil)
            projectTasks[projectPath] = TaskStore.read(projectPath)
            refreshTaskSnapshot(for: projectPath)
        }
    }

    /// Days since the project's roadmap (if any) was last edited.
    func roadmapAgeDays(for projectPath: String) -> Int? {
        ProjectMetaStore.roadmapAgeDays(in: projectPath)
    }

    func roadmapPath(for projectPath: String) -> String? {
        ProjectMetaStore.discoverRoadmap(in: projectPath)
    }

    // MARK: - Providers

    func providers(for projectPath: String) -> [Provider] {
        projectProviders[projectPath] ?? []
    }

    func refreshProviders(for projectPath: String) {
        let merged = ProviderStore.refresh(projectPath)
        projectProviders[projectPath] = merged
    }

    func addProvider(
        projectPath: String,
        name: String,
        category: ProviderCategory,
        dashboardURL: URL? = nil,
        monthlyEstimateUSD: Double? = nil,
        notes: String? = nil
    ) {
        do {
            _ = try ProviderStore.add(
                projectPath: projectPath, name: name, category: category,
                dashboardURL: dashboardURL, monthlyEstimateUSD: monthlyEstimateUSD,
                notes: notes
            )
            projectProviders[projectPath] = ProviderStore.read(projectPath)
        } catch {
            todoError = "Couldn't add provider: \(error.localizedDescription)"
        }
    }

    func updateProvider(projectPath: String, _ provider: Provider) {
        try? ProviderStore.update(projectPath, provider)
        projectProviders[projectPath] = ProviderStore.read(projectPath)
    }

    func deleteProvider(projectPath: String, id: String) {
        try? ProviderStore.delete(projectPath, id: id)
        projectProviders[projectPath] = ProviderStore.read(projectPath)
    }

    func totalMonthlyCost(for projectPath: String) -> Double? {
        ProviderStore.totalMonthlyCost(providers(for: projectPath))
    }

    // MARK: - Validation / health checks

    /// All template-defined checks for the project, scoped to the current
    /// stage when a template is applied (project-wide checks always included).
    func healthChecks(for projectPath: String) -> [HealthCheckSpec] {
        guard let template = template(for: projectPath) else { return [] }
        let currentStageId = meta(for: projectPath).currentStageId
        var out: [HealthCheckSpec] = []
        for stage in template.stages {
            // Only surface checks for the current stage in v1 to keep the UI focused.
            if stage.id == currentStageId {
                out.append(contentsOf: stage.validationChecks)
            }
        }
        return out
    }

    func lastHealthResult(_ checkId: String, for projectPath: String) -> HealthRunResult? {
        projectHealth[projectPath]?[checkId]
    }

    func healthStatus(_ checkId: String, for projectPath: String) -> HealthCheckStatus {
        if runningHealthChecks.contains("\(projectPath):\(checkId)") { return .running }
        guard let r = lastHealthResult(checkId, for: projectPath) else { return .unknown }
        return r.passed ? .passed : .failed
    }

    /// Pass/fail summary for the current stage's checks. nil if no checks defined.
    func healthSummary(for projectPath: String) -> (passed: Int, total: Int)? {
        let checks = healthChecks(for: projectPath)
        guard !checks.isEmpty else { return nil }
        let passed = checks.filter {
            lastHealthResult($0.id, for: projectPath)?.passed == true
        }.count
        return (passed, checks.count)
    }

    func runHealthCheck(_ check: HealthCheckSpec, for projectPath: String) async {
        let key = "\(projectPath):\(check.id)"
        runningHealthChecks.insert(key)
        defer { runningHealthChecks.remove(key) }

        let result = await HealthCheckRunner.run(check, projectPath: projectPath)
        try? HealthStore.record(result, for: projectPath)
        var current = projectHealth[projectPath] ?? [:]
        current[check.id] = result
        projectHealth[projectPath] = current
    }

    func runAllHealthChecks(for projectPath: String) async {
        for check in healthChecks(for: projectPath) {
            await runHealthCheck(check, for: projectPath)
        }
    }

    // MARK: - AI hooks (manual, on-demand)

    /// Run claude -p against a single task. Streams into the Claude tab.
    /// Default is read-only ("explain, don't change") so this is safe to
    /// click without thinking. Pass allowEdits=true to actually let Claude
    /// modify files.
    func runPersona(_ persona: GStackPersona, projectPath: String) async {
        guard let content = persona.content else { return }
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
        let notes = meta(for: projectPath).notes.map { "\nProject notes: \($0)" } ?? ""
        let prompt = """
        DISABLE_OMC

        \(content)

        Project: \(projectName)
        Path: \(projectPath)\(notes)

        Begin your analysis.
        """
        await runClaude(prompt: prompt, projectPath: projectPath, allowEdits: false, kind: .general)
    }

    func runForTask(_ task: TaskItem, projectPath: String, allowEdits: Bool) async {
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
        let actionLine = allowEdits
            ? "Investigate the codebase, design an approach, and make the changes."
            : "Investigate the codebase and explain what you'd change. Do NOT modify any files."

        let phasePreamble: String
        if let existing = task.phases, !existing.isEmpty {
            let list = existing.joined(separator: ", ")
            phasePreamble = """
            This task has pre-configured phases: \(list)
            Use these phases in order. Announce each with exactly: [PHASE: <name>]
            """
        } else {
            let hint = task.category == .engineering
                ? "\nCommon engineering phases: Explore, Code, Test, QA — adapt as needed."
                : ""
            phasePreamble = """
            Before starting, decide which phases make sense for this specific task.\(hint)
            Not every task needs the same phases. Choose what fits.
            Announce your planned phases with exactly: [PHASES: Phase1, Phase2, ...]
            Then begin executing. Announce each phase as you start it with: [PHASE: <name>]
            """
        }

        let testPhase = allowEdits ? """

            Final step — always required:
            [PHASE: Write Tests]
            Write a manual test checklist to: .devdash/manual-tests/\(task.id).md
            Cover: happy path, edge cases, things a human should click/verify.
            Format: markdown checkbox list grouped by area.
            If no UI is involved, cover API contracts, data correctness, and error paths.
            """ : ""

        let personaBlock: String = {
            let resolved: GStackPersona?
            if let overrideId = task.gstackPersonaOverride {
                resolved = GStackSkillLoader.all.first { $0.id == overrideId }
            } else {
                resolved = GStackSkillLoader.autoPersona(for: task.category, hasAIRun: task.hasAIRun)
            }
            return resolved?.content.map { "\n---\n\($0)" } ?? ""
        }()

        let prompt = """
        DISABLE_OMC

        \(phasePreamble)

        I'm working on the project \(projectName). Help me complete this task.

        Task: \(task.title)
        Category: \(task.category.label)
        \(task.notes.map { "Notes: \($0)" } ?? "")

        \(actionLine)\(testPhase)\(personaBlock)
        """

        try? TaskStore.setOwner(projectPath: projectPath, id: task.id, owner: .ai)
        try? TaskStore.setStatus(projectPath: projectPath, id: task.id, status: .open)
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)

        await runClaude(
            prompt: prompt,
            projectPath: projectPath,
            allowEdits: allowEdits,
            kind: .taskExecution,
            linkedTaskId: task.id
        )
    }

    /// Open the project's embedded terminal and start an interactive `claude`
    /// session seeded with the task spec and a report-back protocol using the
    /// `lore` CLI. Distinct from `runForTask` (which uses `claude -p` headless);
    /// this is the interactive terminal path so the user can watch/drive it.
    func launchClaudeForTask(_ task: TaskItem, projectPath: String) {
        guard !projectPath.isEmpty else { return }

        // Check whether this project is a git repo (needed for worktree decision).
        let isGit = gitStatuses[projectPath] != nil
            || FileManager.default.fileExists(atPath: "\(projectPath)/.git")

        // [FIX #2] Only create a worktree when the task is file-backed. For non-file-backed
        // tasks (Linear tasks with UUID ids, no docs/tasks file) TaskStore.setWorktree
        // silently no-ops, so the worktree would be created but never recorded — orphaning it.
        // Guard by checking whether the task file exists on disk before we touch git at all.
        let taskDir = TaskStore.file(for: projectPath)
        let isFileBacked = TaskStore.findFile(id: task.id, in: taskDir) != nil

        // If the setting is on, this is a git repo, and the task is file-backed,
        // try to create a worktree first (async); otherwise fall through.
        if launchInWorktree && isGit && isFileBacked {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await WorktreeManager.create(
                    repoPath: projectPath,
                    taskId: task.id,
                    title: task.title
                )
                if let (worktreePath, branch) = result {
                    // Persist worktree + branch on the task.
                    try? TaskStore.setWorktree(
                        projectPath: projectPath,
                        id: task.id,
                        worktree: worktreePath,
                        branch: branch
                    )
                    self.projectTasks[projectPath] = TaskStore.read(projectPath)
                    self.refreshTaskSnapshot(for: projectPath)
                    self.launchClaudeInDirectory(
                        task: task,
                        projectPath: projectPath,
                        cwd: worktreePath,
                        branch: branch
                    )
                } else {
                    // Worktree creation failed — fall back to the project directory.
                    NSLog("WorktreeManager: create failed for task %@ — launching in project dir", task.id)
                    self.launchClaudeInDirectory(
                        task: task,
                        projectPath: projectPath,
                        cwd: projectPath,
                        branch: nil
                    )
                }
            }
            return
        }

        // Non-worktree path (setting off, or not a git repo).
        launchClaudeInDirectory(task: task, projectPath: projectPath, cwd: projectPath, branch: nil)
    }

    /// Core launch: builds the prompt, opens the terminal at `cwd`, sends the claude command.
    /// `branch` is non-nil only when running in a worktree.
    private func launchClaudeInDirectory(
        task: TaskItem,
        projectPath: String,
        cwd: String,
        branch: String?
    ) {
        let branchLine: String
        if let b = branch {
            branchLine = "\nYou're on branch \(b) in an isolated worktree. When done, open a PR from this branch."
        } else {
            branchLine = ""
        }

        // Inject active on_work policies: project-scoped always, ticket-scoped
        // only when the task belongs to a ticket.
        var preambleParts: [String] = []
        let projectText = policyText(projectPath: projectPath, appliesTo: "project", trigger: "on_work")
        if !projectText.isEmpty { preambleParts.append(projectText) }
        if task.ticket != nil {
            let ticketText = ticketPolicyText(projectPath: projectPath, trigger: "on_work")
            if !ticketText.isEmpty { preambleParts.append(ticketText) }
        }
        let policyPreamble = preambleParts.isEmpty ? "" : preambleParts.joined(separator: "\n\n") + "\n\n"

        let prompt = """
        \(policyPreamble)Task \(task.id): \(task.title)
        Category: \(task.category.label)
        \(task.notes.map { "Notes:\n\($0)" } ?? "")\(branchLine)

        Work on this task in this project.

        As you work, report progress to the dashboard with the `lore` CLI:
        - Update this task's status:  lore set-status task \(task.id) <new-status>
        - If you open a PR, file a review task:  lore add task --title "Review: <desc>" --field pr=<PR_URL> --field category=qa
        - Record an artifact (summary, test plan, report):  lore add artifact --title "<name>" --field task=\(task.id) --field kind=summary
        """

        // Write prompt to a temp file so we can pass it to claude without
        // any shell-quoting hazards from multi-line content.
        let launchDir = (NSHomeDirectory() as NSString).appendingPathComponent(".devdash/launch")
        let promptPath = (launchDir as NSString).appendingPathComponent("\(task.id).txt")
        do {
            try FileManager.default.createDirectory(
                atPath: launchDir, withIntermediateDirectories: true, attributes: nil)
            try prompt.write(toFile: promptPath, atomically: true, encoding: .utf8)
        } catch {
            return
        }

        // Set owner and status to mirror runForTask.
        try? TaskStore.setOwner(projectPath: projectPath, id: task.id, owner: .ai)
        try? TaskStore.setStatus(projectPath: projectPath, id: task.id, status: .open)
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)

        // Navigate to this project and open the terminal drawer.
        selection = .project(path: projectPath)
        terminalOpen = true

        // Ensure the session exists (session(for:) is idempotent — spawns lazily
        // on first call, returns the cached view on subsequent calls). We call it
        // here so the PTY is started before we send the command.
        // When cwd != projectPath (worktree), a separate terminal session is created
        // automatically because TerminalSessionStore keys by path.
        _ = terminals.session(for: cwd)

        // Give the shell a brief moment to finish its login-shell init before
        // the command arrives. 400 ms is enough for a cold PTY; warm sessions
        // are already ready and will just execute immediately.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            let cmd = "claude \"$(cat '\(promptPath)')\"\n"
            self.terminals.send(cmd, to: cwd)
        }
    }

    /// Open an interactive Claude Code session in the terminal drawer, pointed
    /// at a specific lore doc (optionally a selected passage) with an editing
    /// instruction. Mirrors the task-launch flow: prompt goes through a temp
    /// file to avoid shell-quoting hazards; NotesFileWatcher picks up the edit
    /// so the reading pane refreshes live.
    func openClaudeForDoc(projectPath: String, relPath: String, selection: String?, instruction: String) {
        let docsRoot = LoreDocsScanner.docsRoot(projectPath: projectPath)
        let typeDir = relPath.components(separatedBy: "/").dropLast().joined(separator: "/")
        var parts: [String] = []
        parts.append("Edit the lore doc `\(docsRoot)/\(relPath)` (path relative to repo: \(relPath)).")
        if let sel = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            parts.append("The user selected this passage — the instruction applies to it specifically:\n\"\"\"\n\(sel)\n\"\"\"")
        }
        parts.append("Instruction: \(instruction)")
        parts.append("Rules: preserve the lore frontmatter format exactly (comma-separated multi-value fields, no YAML lists). After editing, run `lore reindex \(typeDir.isEmpty ? "<type>" : typeDir)`-equivalent for the doc's type and `lore validate` for it; fix any validation errors. Do not commit unless asked.")
        let prompt = parts.joined(separator: "\n\n")

        let launchDir = (NSHomeDirectory() as NSString).appendingPathComponent(".devdash/launch")
        let promptPath = (launchDir as NSString).appendingPathComponent("doc-edit-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try FileManager.default.createDirectory(
                atPath: launchDir, withIntermediateDirectories: true, attributes: nil)
            try prompt.write(toFile: promptPath, atomically: true, encoding: .utf8)
        } catch { return }

        self.selection = .project(path: projectPath)
        terminalOpen = true
        _ = terminals.session(for: projectPath)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            let cmd = "claude \"$(cat '\(promptPath)')\"\n"
            self.terminals.send(cmd, to: projectPath)
        }
    }

    /// Launch an interactive /coach session in the terminal drawer, cwd = the
    /// wiki root. The coach skill owns its context loading and coaching
    /// contract; the app only seeds the requested mode.
    func openCoachSession(projectPath: String, mode: String) {
        let prompt = "Run the /coach skill: I want a \(mode) session. "
            + "Follow the coaching contract exactly — load its context files first, one question at a time."

        let launchDir = (NSHomeDirectory() as NSString).appendingPathComponent(".devdash/launch")
        let promptPath = (launchDir as NSString).appendingPathComponent("coach-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try FileManager.default.createDirectory(
                atPath: launchDir, withIntermediateDirectories: true, attributes: nil)
            try prompt.write(toFile: promptPath, atomically: true, encoding: .utf8)
        } catch { return }

        selection = .project(path: projectPath)
        terminalOpen = true
        _ = terminals.session(for: projectPath)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            let cmd = "claude \"$(cat '\(promptPath)')\"\n"
            self.terminals.send(cmd, to: projectPath)
        }
    }

    /// Ask claude -p to suggest tasks for the current stage given the
    /// methodology + existing tasks. Output is plain markdown bullets.
    func suggestTasksForStage(projectPath: String, template: LaunchTemplate, stage: TemplateStage) async {
        let existing = tasksV2(for: projectPath)
            .filter { $0.stage == stage.id }
            .map { "- \($0.title) [\($0.status.label)]" }
            .joined(separator: "\n")
        let questions = stage.guidingQuestions.map { "- \($0)" }.joined(separator: "\n")
        let criteria = stage.exitCriteria.map { "- \($0)" }.joined(separator: "\n")

        let prompt = """
        You're a product launch coach. Suggest concrete next tasks for the current stage.

        Project methodology: \(template.name)
        Methodology overview: \(template.methodology)

        Current stage: \(stage.title)
        Stage purpose: \(stage.purpose)
        Stage methodology: \(stage.methodology)

        Guiding questions for this stage:
        \(questions)

        Exit criteria to advance:
        \(criteria)

        Existing tasks I already have for this stage:
        \(existing.isEmpty ? "(none yet)" : existing)

        Suggest 3-6 concrete next tasks aligned with this stage's exit criteria \
        and methodology. Don't repeat existing tasks. Don't suggest generic \
        best-practice tasks — be specific to this stage. Format each suggestion \
        on its own line as exactly: `TASK: <title>` (so the UI can parse them).
        """
        await runClaude(prompt: prompt, projectPath: projectPath, allowEdits: false, kind: .taskSuggestion)
    }

    /// Ask claude -p to suggest child tasks for a ticket, guided by the active
    /// ticket-breakdown policy. Output is `TASK: <title>` lines parsed later by
    /// `parseSuggestedTasks`. `deep` invites the agent to read code first.
    func suggestTasksForTicket(ticketId: String, projectPath: String, deep: Bool) async {
        guard let ticket = (projectTickets[projectPath] ?? [])
            .first(where: { TicketStore.numEq($0.id, ticketId) }) else { return }

        let existingTitles = tasksV2(for: projectPath)
            .filter { t in (t.ticket).map { TicketStore.numEq($0, ticketId) } ?? false }
            .map { $0.title }

        let prompt = buildTicketBreakdownPrompt(
            ticket: ticket, existingTaskTitles: existingTitles,
            projectPath: projectPath, deep: deep)

        await runClaude(prompt: prompt, projectPath: projectPath,
                        allowEdits: false, kind: .taskSuggestion)
    }

    /// Ask claude -p for a suggested roadmap diff given the current roadmap +
    /// recent commits + recently-completed tasks.
    func suggestRoadmapUpdate(projectPath: String) async {
        guard let roadmapPath = self.roadmapPath(for: projectPath) else {
            todoError = "No roadmap found. Add ROADMAP.md or docs/roadmap.md to the project root."
            return
        }
        guard let roadmap = try? String(contentsOfFile: roadmapPath, encoding: .utf8) else {
            todoError = "Couldn't read \(roadmapPath)."
            return
        }
        let projectCommits = recentCommits.filter { $0.projectPath == projectPath }.prefix(20)
        let commitLines = projectCommits.map { "- \($0.shortHash) \($0.subject)" }.joined(separator: "\n")
        let doneTasks = tasksV2(for: projectPath)
            .filter { $0.status == .done }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(20)
            .map { "- \($0.title)" }
            .joined(separator: "\n")

        let prompt = """
        Here's the current roadmap for the project. Below it, recent commits and \
        recently-completed tasks. Suggest a *minimal diff* to the roadmap so it \
        reflects current reality — mark items that look complete, note new \
        directions implied by the commits, and call out anything that looks \
        like scope drift.

        Don't rewrite the roadmap. Output a unified diff (---/+++/@@/-/+) so I \
        can review and apply hunks selectively. If something is genuinely \
        unclear, leave it and call it out at the bottom.

        Current roadmap (\(URL(fileURLWithPath: roadmapPath).lastPathComponent)):
        ```markdown
        \(roadmap)
        ```

        Recent commits:
        \(commitLines.isEmpty ? "(no recent commits)" : commitLines)

        Recently-completed tasks:
        \(doneTasks.isEmpty ? "(none)" : doneTasks)
        """
        await runClaude(prompt: prompt, projectPath: projectPath, allowEdits: false, kind: .roadmapUpdate)
    }

    /// Parse `TASK: <title>` lines out of a Claude task suggestion run.
    /// Returns just the titles in the order they appeared.
    func parseSuggestedTasks(from claudeTaskId: UUID, projectPath: String) -> [String] {
        let arr = claudeTasks[projectPath] ?? []
        guard let task = arr.first(where: { $0.id == claudeTaskId }) else { return [] }
        var out: [String] = []
        for line in task.output {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let r = trimmed.range(of: #"^TASK:\s*"#, options: .regularExpression) {
                let title = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { out.append(title) }
            }
        }
        return out
    }

    func markTaskDone(projectPath: String, taskId: String) async {
        try? TaskStore.setStatus(projectPath: projectPath, id: taskId, status: .done)
        try? TaskStore.setOwner(projectPath: projectPath, id: taskId, owner: .none)
        projectTasks[projectPath] = TaskStore.read(projectPath)
        refreshTaskSnapshot(for: projectPath)
        regenerateRoadmap(for: projectPath)
        guard let task = tasksV2(for: projectPath).first(where: { $0.id == taskId }) else { return }
        await generateTaskReleaseNote(task, projectPath: projectPath)
    }

    private func generateTaskReleaseNote(_ task: TaskItem, projectPath: String) async {
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
        let fmt = ISO8601DateFormatter()
        let since = fmt.string(from: task.startedAt ?? task.createdAt)
        let gitLog = await ShellRunner.run("/bin/zsh", args: ["-ic",
            "cd \(shellQuote(projectPath)) && git log --oneline --since='\(since)' | head -20"
        ]) ?? "(no commits)"

        let phases = task.completedPhases.isEmpty ? "none recorded" : task.completedPhases.joined(separator: " → ")
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)

        let prompt = """
        Generate a concise release note (1–3 sentences) for this completed task.
        Write ONLY the release note text — no preamble, no explanation.

        Task: \(task.title)
        Category: \(task.category.label)
        \(task.notes.map { "Notes: \($0)" } ?? "")
        Phases completed: \(phases)

        Recent commits since task started:
        \(gitLog)

        Then append the release note to .devdash/release-notes.md in this format (include the header):
        ## \(task.title)
        _\(dateStr) · \(task.category.label)_

        <your 1-3 sentence summary here>

        If no commits exist, summarize from the task notes and phases instead.
        """

        await runClaude(prompt: prompt, projectPath: projectPath, allowEdits: true,
                        kind: .releaseNotes, linkedTaskId: task.id)
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // MARK: - Recent commits feed

    @Published var recentCommits: [RecentCommit] = []
    private var recentCommitsTask: Task<Void, Never>?

    func refreshRecentCommits(perProject: Int = 5, total: Int = 40) {
        recentCommitsTask?.cancel()
        let projs = projects
        recentCommitsTask = Task { [weak self] in
            let commits = await RecentCommitsScanner.scan(projects: projs, perProject: perProject)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.recentCommits = Array(commits.prefix(total))
            }
        }
    }

    // MARK: - Commit heatmaps

    @Published var heatmaps: [String: CommitHeatmapStore.Heatmap] = [:]
    private var heatmapTask: Task<Void, Never>?

    func refreshHeatmaps() {
        heatmapTask?.cancel()
        let paths = projects.map { $0.path }
        heatmapTask = Task { [weak self] in
            for path in paths {
                if Task.isCancelled { break }
                if let map = await CommitHeatmapStore.build(projectPath: path) {
                    await MainActor.run { self?.heatmaps[path] = map }
                }
            }
        }
    }

    // MARK: - Claude tasks

    @Published var claudeTasks: [String: [ClaudeTask]] = [:]   // project path → tasks
    private var runningClaude: [UUID: RunningProcess] = [:]
    private var claudeTerminationToken: NSObjectProtocol?

    /// Tear down in-flight `claude -p` agents on app quit. Without this, a running
    /// agent (spawned with `--dangerously-skip-permissions` when edits are allowed)
    /// is reparented to launchd past Cmd-Q and keeps editing the repo / burning
    /// tokens with no UI to stop it. Mirrors BaguetteRunner / TerminalSessionStore.
    init() {
        claudeTerminationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAllRunningClaude() }
        }
    }

    deinit {
        if let claudeTerminationToken {
            NotificationCenter.default.removeObserver(claudeTerminationToken)
        }
    }

    private func stopAllRunningClaude() {
        for proc in runningClaude.values { proc.stop() }
        runningClaude.removeAll()
    }

    func tasks(forClaudeProject projectPath: String) -> [ClaudeTask] {
        claudeTasks[projectPath] ?? []
    }

    func runningTask(for projectPath: String) -> ClaudeTask? {
        claudeTasks[projectPath]?.first { $0.status == .running }
    }

    func runClaude(prompt: String, projectPath: String, allowEdits: Bool,
                   kind: ClaudeTask.Kind = .general, linkedTaskId: String? = nil) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var task = ClaudeTask(
            id: UUID(),
            projectPath: projectPath,
            prompt: trimmed,
            allowEdits: allowEdits,
            kind: kind,
            output: [],
            startedAt: Date(),
            finishedAt: nil,
            status: .running,
            sessionId: nil
        )
        task.linkedTaskId = linkedTaskId

        var arr = claudeTasks[projectPath] ?? []
        arr.insert(task, at: 0)
        claudeTasks[projectPath] = arr

        let proc: RunningProcess
        do {
            proc = try ClaudeRunner.run(prompt: trimmed, cwd: projectPath, allowEdits: allowEdits)
        } catch {
            task.status = .failed
            task.output.append("Error: \(error.localizedDescription)")
            task.finishedAt = Date()
            updateTask(task)
            return
        }

        runningClaude[task.id] = proc

        let taskId = task.id
        let path = projectPath
        Task { [weak self] in
            for await line in proc.lines {
                guard let self = self else { return }
                await MainActor.run {
                    self.parseStreamLine(line, taskId: taskId, path: path)
                }
            }
            await MainActor.run {
                if var arr = self?.claudeTasks[path],
                   let idx = arr.firstIndex(where: { $0.id == taskId }) {
                    arr[idx].finishedAt = Date()
                    if arr[idx].status != .failed {
                        arr[idx].status = .completed
                    }
                    self?.claudeTasks[path] = arr
                    if let tid = arr[idx].linkedTaskId {
                        try? TaskStore.setHasAIRun(projectPath: path, id: tid)
                        try? TaskStore.setOwner(projectPath: path, id: tid, owner: .human)
                        self?.projectTasks[path] = TaskStore.read(path)
                        self?.refreshTaskSnapshot(for: path)
                    }
                }
                self?.runningClaude.removeValue(forKey: taskId)
            }
        }
    }

    func cancelClaude(taskId: UUID, projectPath: String) {
        runningClaude[taskId]?.stop()
        runningClaude.removeValue(forKey: taskId)
        if var arr = claudeTasks[projectPath],
           let idx = arr.firstIndex(where: { $0.id == taskId }) {
            arr[idx].status = .cancelled
            arr[idx].finishedAt = Date()
            claudeTasks[projectPath] = arr
        }
    }

    private func updateTask(_ task: ClaudeTask) {
        if var arr = claudeTasks[task.projectPath],
           let idx = arr.firstIndex(where: { $0.id == task.id }) {
            arr[idx] = task
            claudeTasks[task.projectPath] = arr
        }
    }

    // MARK: - Stream parsing

    private func markRunningTaskFailed(taskId: UUID, path: String) {
        guard var arr = claudeTasks[path],
              let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
        arr[idx].status = .failed
        claudeTasks[path] = arr
    }

    private func parseStreamLine(_ line: String, taskId: UUID, path: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            appendOutputLine(line, taskId: taskId, path: path)
            return
        }
        switch type {
        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for item in content {
                let itemType = item["type"] as? String
                if itemType == "tool_use" {
                    handleToolUse(item, taskId: taskId, path: path)
                } else if itemType == "text", let text = item["text"] as? String, !text.isEmpty {
                    handleTextBlock(text, taskId: taskId, path: path)
                }
            }
        case "result":
            if let exitCode = json["exit_code"] as? Int, exitCode != 0 {
                markRunningTaskFailed(taskId: taskId, path: path)
            }
        default:
            break
        }
    }

    private func handleToolUse(_ item: [String: Any], taskId: UUID, path: String) {
        guard let name = item["name"] as? String,
              let input = item["input"] as? [String: Any] else { return }
        let activity = Self.liveActivity(toolName: name, input: input)
        if let file = activity.file {
            appendLiveFile(file, taskId: taskId, projectPath: path)
        }
        if let cmd = activity.command {
            appendLiveCommand(cmd, taskId: taskId, projectPath: path)
        }
    }

    private func handleTextBlock(_ text: String, taskId: UUID, path: String) {
        var processed = text

        if let range = processed.range(of: #"\[PHASES:\s*([^\]]+)\]"#, options: .regularExpression) {
            let inner = String(processed[range])
                .replacingOccurrences(of: #"^\[PHASES:\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "]", with: "")
            let phases = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !phases.isEmpty {
                setPhasesOnRunningTask(phases, taskId: taskId, projectPath: path)
            }
            processed = processed.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let range = processed.range(of: #"\[PHASE:\s*([^\]]+)\]"#, options: .regularExpression) {
            let inner = String(processed[range])
                .replacingOccurrences(of: #"^\[PHASE:\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty {
                advancePhase(to: inner, taskId: taskId, projectPath: path)
            }
            processed = processed.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !processed.isEmpty {
            appendOutputLine(processed, taskId: taskId, path: path)
        }
    }

    private func appendOutputLine(_ line: String, taskId: UUID, path: String) {
        guard var arr = claudeTasks[path],
              let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
        arr[idx].output.append(line)
        if arr[idx].sessionId == nil, let sid = captureSessionId(from: line) {
            arr[idx].sessionId = sid
        }
        claudeTasks[path] = arr
    }

    private func appendLiveFile(_ event: LiveFileEvent, taskId: UUID, projectPath: String) {
        guard var arr = claudeTasks[projectPath],
              let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
        arr[idx].liveFiles.append(event)
        claudeTasks[projectPath] = arr
    }

    private func appendLiveCommand(_ command: String, taskId: UUID, projectPath: String) {
        guard var arr = claudeTasks[projectPath],
              let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
        arr[idx].liveCommands.append(command)
        claudeTasks[projectPath] = arr
    }

    private func setPhasesOnRunningTask(_ phases: [String], taskId: UUID, projectPath: String) {
        guard var arr = claudeTasks[projectPath],
              let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
        arr[idx].phases = phases
        claudeTasks[projectPath] = arr
        if let taskItemId = arr[idx].linkedTaskId {
            try? TaskStore.setPhases(projectPath: projectPath, id: taskItemId, phases: phases)
        }
    }

    private func advancePhase(to phase: String, taskId: UUID, projectPath: String) {
        guard var arr = claudeTasks[projectPath],
              let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
        if let prev = arr[idx].currentPhase, !arr[idx].completedPhases.contains(prev) {
            arr[idx].completedPhases.append(prev)
        }
        arr[idx].currentPhase = phase
        claudeTasks[projectPath] = arr
    }

    // MARK: - Recap

    @Published var recaps: [String: ProjectRecap] = [:]
    @Published var recapInProgress: Set<String> = []
    @Published var recapStreaming: [String: String] = [:]

    func loadRecap(for projectPath: String) {
        if let r = RecapStore.read(projectPath) {
            recaps[projectPath] = r
        }
    }

    func generateReleaseNotes(for project: Project) async {
        let path = project.path
        let commits = await RecapStore.recentCommits(in: path, limit: 50)
        guard !commits.isEmpty else { return }

        let context = """
        Project: \(project.name)
        Branch: \(project.branch ?? "?")

        # Recent commits (most recent first)
        \(commits.prefix(40).joined(separator: "\n"))
        """

        let prompt = """
        Write a concise CHANGELOG-style release notes section for this project. Group changes under \"Features\", \"Fixes\", \"Refactors\", and \"Other\" — only include sections that have entries. Each bullet should be one line, in past tense, mentioning the relevant commit hash in parentheses. Keep it under 200 words. Use plain Markdown.

        Project context:

        \(context)
        """

        await runClaude(prompt: prompt, projectPath: path, allowEdits: false, kind: .releaseNotes)
    }

    func generateRecap(for project: Project) async {
        let path = project.path
        let port = runningPort(for: path)
        let openTodos = (tasksByProject.first { $0.projectPath == path }?.todos ?? [])
            .filter { !$0.done }.count
        let commits = await RecapStore.recentCommits(in: path, limit: 20)
        let projectSessions = sessions.filter {
            $0.projectPath == path || $0.projectPath.hasPrefix("\(path)/")
        }

        let context = RecapStore.buildContext(
            projectName: project.name,
            commits: commits,
            sessions: projectSessions,
            runningPort: port,
            openTodoCount: openTodos,
            branch: project.branch
        )

        let prompt = """
        You are summarizing a developer's recent activity on a project so they can pick back up where they left off. Write a concise recap with these sections:

        ## Where you left off
        2-4 sentences on the most recent work and current state.

        ## What's been done
        Bullet list of the top 3-6 things accomplished, drawn from the commits and Claude session intents.

        ## What's likely next
        Bullet list of 2-4 specific suggested next actions, based on signals like incomplete features, open todos, or trailing commit messages.

        Be concrete. Reference commit hashes or session intents when useful. Keep the whole thing under 300 words. Use plain Markdown.

        Project context follows:

        \(context)
        """

        await runClaude(prompt: prompt, projectPath: path, allowEdits: false, kind: .recap)
    }

    private func captureSessionId(from line: String) -> String? {
        // Best-effort: look for a UUID-looking session id
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if let m = regex.firstMatch(in: line, range: range),
           let r = Range(m.range, in: line) {
            return String(line[r])
        }
        return nil
    }

    func addTodo(projectPath: String, text: String) async {
        do {
            _ = try TodoStore.add(projectPath: projectPath, text: text)
            todoError = nil
            await refreshTodos()
        } catch {
            todoError = "Couldn't save todo: \(error.localizedDescription)"
        }
    }

    func toggleTodo(projectPath: String, id: String) async {
        do {
            try TodoStore.toggle(projectPath: projectPath, id: id)
            await refreshTodos()
        } catch {
            todoError = "Couldn't toggle todo: \(error.localizedDescription)"
        }
    }

    func deleteTodo(projectPath: String, id: String) async {
        do {
            try TodoStore.delete(projectPath: projectPath, id: id)
            await refreshTodos()
        } catch {
            todoError = "Couldn't delete todo: \(error.localizedDescription)"
        }
    }


    // URL-style host:port patterns (localhost, loopback, any-interface, IPv6 any)
    private static let portSnifferURL = try! NSRegularExpression(
        pattern: #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::\]):(\d{2,5})"#
    )
    // Prose patterns: "port 3000", "ready on 3000", "listening on :3000"
    private static let portSnifferProse = try! NSRegularExpression(
        pattern: #"(?i)(?:port|ready on|listening on)[:\s]+:?(\d{2,5})\b"#
    )

    func startServer(for projectPath: String) async {
        serverStore.startErrors[projectPath] = nil
        serverStore.startingProjects.insert(projectPath)
        serverStore.serverLogs[projectPath] = []
        serverStore.managedRunning.insert(projectPath)

        let lineHandler: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in
                guard let self = self else { return }
                var lines = self.serverStore.serverLogs[projectPath] ?? []
                lines.append(line)
                if lines.count > 500 { lines.removeFirst(lines.count - 500) }
                self.serverStore.serverLogs[projectPath] = lines

                // Auto-detect port and trigger an immediate refresh so it shows
                // in the sidebar without waiting for the next 15s scan tick.
                if self.runningPort(for: projectPath) == nil {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    let sniffers = [Self.portSnifferURL, Self.portSnifferProse]
                    let detected = sniffers.lazy.compactMap { regex -> Int? in
                        guard let m = regex.firstMatch(in: line, range: range),
                              let r = Range(m.range(at: 1), in: line),
                              let port = Int(line[r]),
                              ProcessScanner.isDevPort(port) else { return nil }
                        return port
                    }.first
                    if detected != nil { Task { await self.refreshAll() } }
                }
            }
        }

        do {
            _ = try await ServerRunner.shared.start(projectPath: projectPath, onLine: lineHandler)
            serverStore.startingProjects.remove(projectPath)
            // Backup refreshes in case nothing matched the regex
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshAll()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refreshAll()
        } catch {
            serverStore.startErrors[projectPath] = error.localizedDescription
            serverStore.startingProjects.remove(projectPath)
            serverStore.managedRunning.remove(projectPath)
        }
    }

    func stopServer(pid: Int32) async {
        await ServerRunner.shared.stop(pid: pid)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await refreshAll()
    }

    /// Re-attach to any servers we (or a previous DevDash instance) started.
    /// Survives app restarts because we redirect output to a log file on disk and
    /// persist `{pid, logPath}` to .devdash/server-state.json.
    func reattachManagedServers() async {
        let state = ServerStateStore.load()
        for (path, entry) in state {
            guard ServerStateStore.isAlive(entry.pid) else {
                ServerStateStore.remove(projectPath: path)
                continue
            }
            serverStore.managedRunning.insert(path)
            if serverStore.serverLogs[path] == nil { serverStore.serverLogs[path] = [] }

            let lineHandler: @Sendable (String) -> Void = { [weak self] line in
                Task { @MainActor in
                    guard let self = self else { return }
                    var lines = self.serverStore.serverLogs[path] ?? []
                    lines.append(line)
                    if lines.count > 500 { lines.removeFirst(lines.count - 500) }
                    self.serverStore.serverLogs[path] = lines
                }
            }
            await ServerRunner.shared.reattach(projectPath: path, entry: entry, onLine: lineHandler)
        }
    }

    func stopServer(for projectPath: String) async {
        await ServerRunner.shared.stop(projectPath: projectPath)
        for svc in services(for: projectPath) {
            await ServerRunner.shared.stop(pid: svc.pid)
        }
        serverStore.managedRunning.remove(projectPath)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await refreshAll()
    }


    // MARK: - Git

    func gitStatus(for path: String) -> GitStatus? {
        gitStatuses[path]
    }

    func refreshGitStatus(for path: String) async {
        guard let status = await GitStatusScanner.scan(path: path) else { return }
        gitStatuses[path] = status
    }

    func gitCheckout(_ branch: String, for path: String) async {
        gitOpInProgress.insert(path)
        _ = await GitStatusScanner.op(["checkout", branch], in: path)
        gitOpInProgress.remove(path)
        await refreshGitStatus(for: path)
    }

    func gitFetch(for path: String) async {
        gitOpInProgress.insert(path)
        _ = await GitStatusScanner.op(["fetch"], in: path)
        gitOpInProgress.remove(path)
        await refreshGitStatus(for: path)
    }

    func gitPull(for path: String) async {
        gitOpInProgress.insert(path)
        _ = await GitStatusScanner.op(["pull"], in: path)
        gitOpInProgress.remove(path)
        await refreshGitStatus(for: path)
    }

    func gitPush(for path: String) async {
        gitOpInProgress.insert(path)
        _ = await GitStatusScanner.op(["push"], in: path)
        gitOpInProgress.remove(path)
        await refreshGitStatus(for: path)
    }
}
