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
enum TerminalPlacement: String, CaseIterable {
    case bottom, side, floating

    var label: String {
        switch self {
        case .bottom: return "Bottom"
        case .side: return "Side"
        case .floating: return "Floating"
        }
    }
    var icon: String {
        switch self {
        case .bottom: return "rectangle.bottomthird.inset.filled"
        case .side: return "rectangle.rightthird.inset.filled"
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
    /// Bumped whenever the watcher fires so TaskDetailSheet can re-read artifacts.
    @Published var artifactsRefreshToken: Int = 0
    /// The dir set the current watcher was armed with; used to avoid tearing
    /// down and rebuilding FDs/DispatchSources on every refresh tick when the
    /// project list hasn't actually changed.
    private var taskWatcherDirs: Set<String> = []

    /// Public entry point for the app startup path. Idempotent — safe to call
    /// before projects are loaded (watcher is a no-op until projects populate).
    func armTaskWatcherIfNeeded() { armTaskWatcher() }

    /// (Re-)arm the watcher over every project's docs/tasks and docs/artifacts directories.
    /// Called from `projects.didSet` so it stays current when projects change.
    /// No-ops when the desired dir set is identical to the currently armed set.
    /// NotesFileWatcher skips dirs that don't exist yet (open() returns -1 → fd < 0).
    private func armTaskWatcher() {
        var desired = Set(projects.map { "\($0.path)/docs/tasks" })
        for project in projects {
            desired.insert("\(project.path)/docs/artifacts")
        }
        guard desired != taskWatcherDirs else { return }
        taskWatcher?.stop()
        taskWatcher = nil
        taskWatcherDirs = desired
        guard !desired.isEmpty else { return }
        taskWatcher = NotesFileWatcher(dirs: Array(desired), onChange: { [weak self] in
            // Already debounced by NotesFileWatcher (0.3 s). Hop to main for store mutation.
            DispatchQueue.main.async { self?.reloadTasksAndNotify() }
        })
    }

    /// Reload tasks and artifacts for every project, diff vs snapshots, and fire
    /// notifications for meaningful changes. First call per project seeds silently.
    func reloadTasksAndNotify() {
        var didChangeArtifacts = false
        for project in projects {
            let path = project.path

            // — Tasks —
            let fresh = TaskStore.read(path)
            let freshMap = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })

            if let snap = taskSnapshot[path] {
                // Diff: only notify when we have a prior snapshot (not first load).
                if enableNotifications {
                    for (id, task) in freshMap {
                        if snap[id] == nil {
                            // New task
                            if task.pr != nil {
                                Notifier.post(title: "PR review task created", body: task.title)
                            } else {
                                Notifier.post(title: "New task", body: task.title)
                            }
                        } else if snap[id]?.status != .done && task.status == .done {
                            // Task moved to done
                            Notifier.post(title: "Task done", body: task.title)
                        }
                    }
                }
            }
            // Always update snapshot and projectTasks.
            taskSnapshot[path] = freshMap
            projectTasks[path] = fresh.isEmpty ? nil : fresh

            // — Artifacts —
            let freshArtifacts = ArtifactStore.read(path)
            let freshIds = Set(freshArtifacts.map { $0.id })

            if let snapIds = artifactSnapshot[path] {
                // Diff: only notify when we have a prior snapshot (not first load).
                // LOAD-BEARING: this `if let` (nil snapshot = silent) is the entire
                // anti-spam guarantee for launch AND late-added projects. Do NOT refactor
                // into a seed-then-diff that would notify on every existing artifact.
                if enableNotifications {
                    for artifact in freshArtifacts where !snapIds.contains(artifact.id) {
                        Notifier.post(title: "Artifact added", body: artifact.title)
                    }
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
    private func reloadTasksAndNotifyForProject(_ projectPath: String) {
        let fresh = TaskStore.read(projectPath)
        let freshMap = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })

        if let snap = taskSnapshot[projectPath], enableNotifications {
            for (id, task) in freshMap {
                if snap[id] == nil {
                    if task.pr != nil {
                        Notifier.post(title: "PR review task created", body: task.title)
                    } else {
                        Notifier.post(title: "New task", body: task.title)
                    }
                } else if snap[id]?.status != .done && task.status == .done {
                    Notifier.post(title: "Task done", body: task.title)
                }
            }
        }
        taskSnapshot[projectPath] = freshMap
        projectTasks[projectPath] = fresh.isEmpty ? nil : fresh
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

        default:
            category = .other
            detail = ev.event
        }

        let event = ClaudeIntegrationEvent(
            timestamp: Date(),
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
            // Debounced git/PR refresh when a Bash command mutates git state.
            if ev.toolName == "Bash",
               let input = ev.raw["tool_input"] as? [String: Any],
               let cmd = input["command"] as? String,
               Self.isGitMutation(cmd),
               let path = liveSessions[sid]?.projectPath {
                scheduleGitRefresh(for: path)
            }

        case "Stop":
            // Stop fires at end of each assistant turn — the session is idle/waiting, NOT ended.
            ensureSession(sid: sid, cwd: ev.cwd, now: now)
            liveSessions[sid]?.currentTool = nil
            liveSessions[sid]?.lastEventAt = now

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
                    if enableNotifications {
                        Notifier.post(title: "Claude finished",
                                      body: "Session ended in \(session.projectName)")
                    }
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

    private var refreshing = false
    /// Set when `refreshAll` is asked to run while one is already in flight, so
    /// the current pass loops once more and the latest state (e.g. a just-added
    /// scan root) is always reflected rather than silently dropped.
    private var refreshPending = false

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

            // Background git status scan for all git projects — detached so it
            // doesn't block the main refresh tick. Each result updates the sidebar
            // as it arrives.
            let gitPaths = projects.filter { $0.isGit }.map { $0.path }
            Task.detached(priority: .utility) { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    for path in gitPaths {
                        group.addTask {
                            guard let status = await GitStatusScanner.scan(path: path) else { return }
                            await MainActor.run { self?.gitStatuses[path] = status }
                        }
                    }
                }
            }
        } while refreshPending
    }

    func startAutoRefresh(interval: TimeInterval = 15) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.refreshAll()
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

    /// Initial load — pulls meta + tasks + providers for every project.
    /// Detection runs once per project here; subsequent edits hit just one path.
    func loadProjectMetaAndTasks() {
        let paths = projects.map { $0.path }
        Task.detached(priority: .utility) { [weak self] in
            var metaMap: [String: ProjectMeta] = [:]
            var taskMap: [String: [TaskItem]] = [:]
            var providerMap: [String: [Provider]] = [:]
            var healthMap: [String: [String: HealthRunResult]] = [:]
            for path in paths {
                metaMap[path] = ProjectMetaStore.read(path)
                let tasks = TaskStore.read(path)
                if !tasks.isEmpty { taskMap[path] = tasks }
                let providers = ProviderStore.refresh(path)
                if !providers.isEmpty { providerMap[path] = providers }
                let health = HealthStore.read(path)
                if !health.isEmpty { healthMap[path] = health }
            }
            await MainActor.run {
                self?.projectMeta = metaMap
                self?.projectTasks = taskMap
                self?.projectProviders = providerMap
                self?.projectHealth = healthMap
                self?.seedTaskSnapshots()
            }
        }
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
        linkedDocPath: String? = nil
    ) {
        do {
            _ = try TaskStore.add(
                projectPath: projectPath, title: title,
                category: category, stage: stage, notes: notes,
                source: .local, parentId: parentId,
                linkedDocPath: linkedDocPath
            )
            projectTasks[projectPath] = TaskStore.read(projectPath)
            refreshTaskSnapshot(for: projectPath)
            todoError = nil
            regenerateRoadmap(for: projectPath)
        } catch {
            todoError = "Couldn't add task: \(error.localizedDescription)"
        }
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

    func setTaskStatus(projectPath: String, id: String, status: TaskStatus) {
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

        let prompt = """
        Task \(task.id): \(task.title)
        Category: \(task.category.label)
        \(task.notes.map { "Notes:\n\($0)" } ?? "")

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
        _ = terminals.session(for: projectPath)

        // Give the shell a brief moment to finish its login-shell init before
        // the command arrives. 400 ms is enough for a cold PTY; warm sessions
        // are already ready and will just execute immediately.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            let cmd = "claude \"$(cat '\(promptPath)')\"\n"
            terminals.send(cmd, to: projectPath)
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

    func gitDiff(for path: String) async -> String? {
        await GitStatusScanner.diff(path: path)
    }
}
