import Foundation
import SwiftUI

@MainActor
final class DashboardStore: ObservableObject {
    @Published var services: [Service] = []
    @Published var projects: [Project] = []
    @Published var sessions: [ClaudeSession] = []
    @Published var tasksByProject: [ProjectTasks] = []
    @Published var lastUpdated: Date = .distantPast
    @Published var isLoading = false
    @Published var isLoadingIssues = false
    @Published var healthFilter: HealthFilter = .all
    @Published var selection: Selection? {
        didSet {
            restoreTabForCurrentSelection()
            recordNavigation()
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
    @Published var detailTab: DetailTab = .info {
        didSet { persistTabForCurrentSelection() }
    }
    @Published var pinnedProjects: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "devdash.pinnedProjects") ?? []
    )
    @Published var sessionDigests: [String: SessionDigest] = [:]
    @Published var openSessionId: String? = nil
    /// Path the FilesTab should open. Set then switch detailTab to .files.
    @Published var pendingFilePath: String? = nil
    /// Open a TaskDetailSheet for this task. Set to nil to dismiss.
    @Published var openTaskId: String? = nil
    @Published var openTaskProjectPath: String? = nil
    private var digestTask: Task<Void, Never>?

    @Published var projectMeta: [String: ProjectMeta] = [:]   // path → meta
    @Published var projectTasks: [String: [TaskItem]] = [:]   // path → tasks
    @Published var projectProviders: [String: [Provider]] = [:]   // path → providers
    @Published var projectHealth: [String: [String: HealthRunResult]] = [:]   // path → checkId → result
    @Published var runningHealthChecks: Set<String> = []   // "<path>:<checkId>"

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

    private let tabMemoryKey = "devdash.lastTabPerProject"
    private var tabMemory: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: tabMemoryKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: tabMemoryKey) }
    }

    private func projectKey(for selection: Selection?) -> String? {
        guard let sel = selection else { return nil }
        switch sel {
        case .home: return nil
        case .project(let path): return path
        case .service(let id):
            // Map service to its project so a service↔project switch shares tab memory
            guard let svc = services.first(where: { $0.id == id }) else { return nil }
            return projects.first { svc.cwd == $0.path || svc.cwd.hasPrefix("\($0.path)/") }?.path
        }
    }

    private func restoreTabForCurrentSelection() {
        guard let key = projectKey(for: selection),
              let raw = tabMemory[key],
              let tab = DetailTab(rawValue: raw) else { return }
        // Avoid re-triggering persist
        if detailTab != tab { detailTab = tab }
    }

    private func persistTabForCurrentSelection() {
        guard let key = projectKey(for: selection) else { return }
        var memory = tabMemory
        memory[key] = detailTab.rawValue
        tabMemory = memory
    }
    @Published var startingProjects: Set<String> = []
    @Published var startErrors: [String: String] = [:]
    @Published var serverLogs: [String: [String]] = [:]
    @Published var managedRunning: Set<String> = []

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

    func refreshAll() async {
        if refreshing { return }
        refreshing = true
        isLoading = true
        defer {
            refreshing = false
            isLoading = false
        }

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

    var devServices: [Service] { services.filter { !$0.isInfra } }
    var infraServices: [Service] { services.filter { $0.isInfra } }
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

    /// All running dev services that belong to a project, sorted by port.
    func services(for projectPath: String) -> [Service] {
        devServices
            .filter { $0.cwd == projectPath || $0.cwd.hasPrefix("\(projectPath)/") }
            .sorted { $0.port < $1.port }
    }

    private let primaryServiceKey = "devdash.primaryServiceByProject"

    /// User-pinned primary port per project (overrides framework heuristic).
    private var primaryServiceMap: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: primaryServiceKey) as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: primaryServiceKey) }
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
        case .home:
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
        case .home:
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

    nonisolated private static func resolveJsonlPath(sessionId: String) -> String? {
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
            meta: meta, template: template, tasks: tasks
        )
    }

    func addTask(
        projectPath: String,
        title: String,
        category: TaskCategory = .other,
        stage: String? = nil,
        notes: String? = nil,
        parentId: String? = nil
    ) {
        do {
            _ = try TaskStore.add(
                projectPath: projectPath, title: title,
                category: category, stage: stage, notes: notes,
                source: .local, parentId: parentId
            )
            projectTasks[projectPath] = TaskStore.read(projectPath)
            todoError = nil
            regenerateRoadmap(for: projectPath)
        } catch {
            todoError = "Couldn't add task: \(error.localizedDescription)"
        }
    }

    func setTaskParent(projectPath: String, id: String, newParentId: String?) {
        try? TaskStore.setParent(projectPath: projectPath, id: id, newParentId: newParentId)
        projectTasks[projectPath] = TaskStore.read(projectPath)
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
        regenerateRoadmap(for: projectPath)
    }

    func setTaskOwner(projectPath: String, id: String, owner: TaskOwner) {
        try? TaskStore.setOwner(projectPath: projectPath, id: id, owner: owner)
        projectTasks[projectPath] = TaskStore.read(projectPath)
    }

    func reloadTasks(for projectPath: String) {
        projectTasks[projectPath] = TaskStore.read(projectPath)
    }

    func deleteTask(projectPath: String, id: String) {
        try? TaskStore.delete(projectPath: projectPath, id: id)
        projectTasks[projectPath] = TaskStore.read(projectPath)
        regenerateRoadmap(for: projectPath)
    }

    func updateTask(projectPath: String, _ task: TaskItem) {
        try? TaskStore.update(projectPath: projectPath, task)
        projectTasks[projectPath] = TaskStore.read(projectPath)
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

        await runClaude(
            prompt: prompt,
            projectPath: projectPath,
            allowEdits: allowEdits,
            kind: .taskExecution,
            linkedTaskId: task.id
        )
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
        let now = Date()
        switch name {
        case "Read", "Glob", "LS":
            let p = (input["file_path"] ?? input["pattern"] ?? input["path"]) as? String ?? "unknown"
            appendLiveFile(LiveFileEvent(path: p, operation: .read, timestamp: now), taskId: taskId, projectPath: path)
        case "Write":
            let p = input["file_path"] as? String ?? "unknown"
            appendLiveFile(LiveFileEvent(path: p, operation: .write, timestamp: now), taskId: taskId, projectPath: path)
        case "Edit", "MultiEdit":
            let p = input["file_path"] as? String ?? "unknown"
            appendLiveFile(LiveFileEvent(path: p, operation: .edit, timestamp: now), taskId: taskId, projectPath: path)
        case "Bash":
            let cmd = input["command"] as? String ?? "unknown"
            appendLiveCommand(cmd, taskId: taskId, projectPath: path)
        default:
            break
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

    func isStarting(_ projectPath: String) -> Bool {
        startingProjects.contains(projectPath)
    }

    func startError(_ projectPath: String) -> String? {
        startErrors[projectPath]
    }

    private static let portSniffer = try! NSRegularExpression(pattern: #"localhost:(\d{2,5})"#)

    func startServer(for projectPath: String) async {
        startErrors[projectPath] = nil
        startingProjects.insert(projectPath)
        serverLogs[projectPath] = []
        managedRunning.insert(projectPath)

        let lineHandler: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in
                guard let self = self else { return }
                var lines = self.serverLogs[projectPath] ?? []
                lines.append(line)
                if lines.count > 500 { lines.removeFirst(lines.count - 500) }
                self.serverLogs[projectPath] = lines

                // Auto-detect port and trigger an immediate refresh so it shows
                // in the sidebar without waiting for the next 15s scan tick.
                if self.runningPort(for: projectPath) == nil {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    if let match = Self.portSniffer.firstMatch(in: line, range: range),
                       let r = Range(match.range(at: 1), in: line),
                       let _ = Int(line[r]) {
                        Task { await self.refreshAll() }
                    }
                }
            }
        }

        do {
            _ = try await ServerRunner.shared.start(projectPath: projectPath, onLine: lineHandler)
            startingProjects.remove(projectPath)
            // Backup refreshes in case nothing matched the regex
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshAll()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refreshAll()
        } catch {
            startErrors[projectPath] = error.localizedDescription
            startingProjects.remove(projectPath)
            managedRunning.remove(projectPath)
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
            managedRunning.insert(path)
            if serverLogs[path] == nil { serverLogs[path] = [] }

            let lineHandler: @Sendable (String) -> Void = { [weak self] line in
                Task { @MainActor in
                    guard let self = self else { return }
                    var lines = self.serverLogs[path] ?? []
                    lines.append(line)
                    if lines.count > 500 { lines.removeFirst(lines.count - 500) }
                    self.serverLogs[path] = lines
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
        managedRunning.remove(projectPath)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await refreshAll()
    }

    func logs(for projectPath: String) -> [String] {
        serverLogs[projectPath] ?? []
    }
}
