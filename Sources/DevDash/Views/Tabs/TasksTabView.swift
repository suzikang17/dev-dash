import SwiftUI
import AppKit

/// Stage-aware Tasks tab. Top of the page shows the current launch stage
/// (purpose, guiding questions, exit criteria, advance button). Below that
/// is the task list grouped by stage; unstaged tasks at the bottom.
/// If no template is applied, the user sees a template picker.
struct TasksTabView: View {
    @EnvironmentObject var store: DashboardStore

    @State private var newTitle = ""
    @State private var newCategory: TaskCategory = .other
    @State private var newCategoryIsAuto = true
    @State private var newStage: String? = nil
    @State private var showTemplatePicker = false
    @FocusState private var addFocused: Bool
    @AppStorage("taskViewMode") private var viewMode: String = "board"
    @AppStorage("taskSource") private var taskSource: String = "devdash"
    @State private var migrateMsg: String?

    var body: some View {
        if let project = store.project(for: store.selection) {
            if taskSource == "lore" {
                VStack(spacing: 0) {
                    sourceToggle
                    Divider()
                    LoreTasksView(projectPath: project.path)
                }
            } else {
            VStack(spacing: 0) {
                sourceToggle
                Divider()
                ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    headerRow(project: project)

                    if let template = store.template(for: project.path) {
                        stageCard(project: project, template: template)
                        suggestedTasksCard(project: project)
                    } else {
                        templatePickerCard(project: project)
                    }

                    roadmapBanner(project: project)

                    if let err = store.todoError {
                        Text(err)
                            .font(DSFont.label)
                            .foregroundColor(DSColor.danger)
                            .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DSColor.danger.opacity(0.1))
                            .cornerRadius(DSRadius.small)
                    }

                    addBar(project: project)

                    if viewMode == "board" {
                        KanbanBoardView(project: project)
                            .environmentObject(store)
                    } else {
                        taskList(project: project)

                        let issues = store.tasks(for: project.path)?.issues ?? []
                        if !issues.isEmpty {
                            TaskGroupCard(title: "GitHub Issues", systemImage: "exclamationmark.bubble", count: issues.count) {
                                ForEach(issues) { iss in
                                    IssueRow(issue: iss)
                                    if iss.id != issues.last?.id { Divider() }
                                }
                            }
                        }

                        MyQueueView(project: project)
                            .environmentObject(store)
                    }
                }
                .padding(DSSpace.xl)
            }
            .sheet(isPresented: $showTemplatePicker) {
                TemplatePickerSheet(projectPath: project.path)
                    .environmentObject(store)
            }
            } // end VStack
            } // end else (devdash source)
        } else {
            Text("Select a project to see tasks")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Source toggle

    private var sourceToggle: some View {
        HStack(spacing: DSSpace.sm) {
            Picker("Source", selection: $taskSource) {
                Text("Dev Dash").tag("devdash")
                Text("Lore").tag("lore")
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            Spacer()
            if let msg = migrateMsg {
                Text(msg).font(.caption).foregroundColor(.secondary)
            }
            Button("Migrate → Lore") {
                if let p = store.project(for: store.selection)?.path {
                    let r = TaskLoreMigrator.migrate(projectPath: p)
                    migrateMsg = "exported \(r.created), skipped \(r.skipped)"
                    taskSource = "lore"   // switch so the migrated tasks are visible
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Export Dev Dash tasks (.devdash/tasks.json) to lore (docs/tasks/*.md) — idempotent")
        }
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.sm)
    }

    // MARK: - Header

    @ViewBuilder
    private func headerRow(project: Project) -> some View {
        HStack {
            Text(project.name)
                .font(.title2.bold())
            if let template = store.template(for: project.path) {
                Text("·").foregroundColor(.secondary)
                Text(template.name)
                    .font(DSFont.body)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("View", selection: $viewMode) {
                Label("Board", systemImage: "square.grid.3x3").tag("board")
                Label("My Queue", systemImage: "person.fill").tag("queue")
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .labelsHidden()

            Button {
                Task { await store.refreshIssues() }
            } label: {
                Label("Sync issues", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.isLoadingIssues)

            if store.template(for: project.path) != nil {
                Menu {
                    Button("Change template…") { showTemplatePicker = true }
                    Button(role: .destructive) {
                        store.clearTemplate(for: project.path)
                    } label: { Text("Clear template") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
                .accessibilityLabel("Template options")
            }
        }
    }

    // MARK: - Stage card

    @ViewBuilder
    private func stageCard(project: Project, template: LaunchTemplate) -> some View {
        let meta = store.meta(for: project.path)
        let stage = template.stages.first { $0.id == meta.currentStageId } ?? template.stages.first!
        let stageIndex = template.stages.firstIndex { $0.id == stage.id } ?? 0
        let nextStage: TemplateStage? = stageIndex + 1 < template.stages.count ? template.stages[stageIndex + 1] : nil

        VStack(alignment: .leading, spacing: DSSpace.md) {
            // Stepper across stages
            HStack(spacing: DSSpace.xs) {
                ForEach(Array(template.stages.enumerated()), id: \.element.id) { i, s in
                    Button {
                        store.setStage(s.id, for: project.path)
                    } label: {
                        Text(s.title)
                            .font(DSFont.micro.weight(i == stageIndex ? .semibold : .regular))
                            .padding(.horizontal, DSSpace.sm)
                            .padding(.vertical, DSSpace.xs)
                            .background(i == stageIndex ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                            .foregroundColor(i == stageIndex ? .accentColor : .secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(s.purpose)
                    if i < template.stages.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: DSSpace.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stage.title)
                        .font(DSFont.sectionTitle)
                    Spacer()
                    if let started = meta.stageStartedAt {
                        Text("Started \(timeAgo(started))")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                    }
                }
                Text(stage.purpose)
                    .font(DSFont.body)
                    .foregroundColor(.secondary)
                if !stage.methodology.isEmpty {
                    Text(stage.methodology)
                        .font(DSFont.label.italic())
                        .foregroundColor(.secondary.opacity(0.85))
                }
            }

            if !stage.guidingQuestions.isEmpty {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    let answeredCount = stage.guidingQuestions.filter { !meta.answer(for: stage.id, question: $0).isEmpty }.count
                    HStack(spacing: DSSpace.xs) {
                        Label("Guiding questions", systemImage: "questionmark.circle")
                            .font(DSFont.sectionHeader)
                            .tracking(0.6)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(verbatim: "\(answeredCount)/\(stage.guidingQuestions.count) answered")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                    }
                    ForEach(stage.guidingQuestions, id: \.self) { q in
                        QuestionAnswerRow(
                            projectPath: project.path,
                            projectName: project.name,
                            template: template,
                            stage: stage,
                            question: q,
                            onAddAsTask: {
                                newTitle = q
                                newStage = stage.id
                                addFocused = true
                            }
                        )
                    }
                }
                .padding(DSSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
            }

            if !stage.exitCriteria.isEmpty {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    Label("Exit criteria", systemImage: "flag.checkered")
                        .font(DSFont.sectionHeader)
                        .tracking(0.6)
                        .foregroundColor(.secondary)
                    ForEach(stage.exitCriteria, id: \.self) { c in
                        let key = "\(stage.id):\(c)"
                        let checked = meta.checkedExitCriteria.contains(key)
                        Button {
                            store.toggleExitCriterion(c, stageId: stage.id, for: project.path)
                        } label: {
                            HStack(spacing: DSSpace.sm) {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundColor(checked ? DSColor.success : .secondary)
                                Text(c)
                                    .font(DSFont.body)
                                    .strikethrough(checked)
                                    .foregroundColor(checked ? .secondary : .primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DSSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(DSRadius.small)
                .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            }

            if !stage.validationChecks.isEmpty {
                ValidationSection(projectPath: project.path, checks: stage.validationChecks)
            }

            HStack(spacing: DSSpace.sm) {
                Button {
                    Task {
                        await store.suggestTasksForStage(projectPath: project.path, template: template, stage: stage)
                        store.tabStore.detailTab = .claude
                    }
                } label: {
                    Label("Suggest tasks", systemImage: "lightbulb")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Ask Claude to suggest concrete tasks for this stage")

                Spacer()

                if let next = nextStage {
                    let allChecked = stage.exitCriteria.allSatisfy {
                        meta.checkedExitCriteria.contains("\(stage.id):\($0)")
                    }
                    Button {
                        store.setStage(next.id, for: project.path)
                    } label: {
                        Label("Advance to \(next.title)", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .help(allChecked ? "All exit criteria checked" : "Some criteria unchecked — you can still advance, but consider revisiting")
                }
            }
        }
        .padding(DSSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(DSRadius.medium)
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(Color.accentColor.opacity(0.4), lineWidth: 0.8))
    }

    @ViewBuilder
    private func suggestedTasksCard(project: Project) -> some View {
        let claudeRuns = store.claudeTasks[project.path] ?? []
        let latest = claudeRuns.first { $0.kind == .taskSuggestion }
        let parsed: [String] = latest.map {
            store.parseSuggestedTasks(from: $0.id, projectPath: project.path)
        } ?? []

        if let latest = latest {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                HStack(spacing: DSSpace.xs) {
                    Label("Suggestions from Claude", systemImage: "lightbulb")
                        .font(DSFont.label.weight(.semibold))
                        .foregroundColor(DSColor.warning)
                    if latest.status == .running {
                        ProgressView().controlSize(.small)
                        Text("Streaming…")
                            .font(DSFont.micro)
                            .foregroundColor(.secondary)
                    } else if !parsed.isEmpty {
                        Text(verbatim: "\(parsed.count) parsed")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        store.tabStore.detailTab = .claude
                    } label: {
                        Label("Open in Claude tab", systemImage: "arrow.up.forward.app")
                            .font(DSFont.micro)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }

                if parsed.isEmpty && latest.status == .completed {
                    Text("No `TASK:` lines parsed from the response. Open the Claude tab to read the raw output.")
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(parsed, id: \.self) { suggestion in
                        SuggestionRow(
                            suggestion: suggestion,
                            projectPath: project.path,
                            stageId: store.meta(for: project.path).currentStageId
                        )
                    }
                }
            }
            .padding(DSSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.warning.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(DSColor.warning.opacity(0.3), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func templatePickerCard(project: Project) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack(spacing: DSSpace.sm) {
                Image(systemName: "map")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No template applied")
                        .font(DSFont.title)
                    Text("Pick a launch methodology to guide stages, exit criteria, and the kind of tasks to create.")
                        .font(DSFont.label)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    showTemplatePicker = true
                } label: {
                    Label("Choose template", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DSSpace.lg)
        .cardSurface(DSRadius.medium)
    }

    // MARK: - Roadmap

    @ViewBuilder
    private func roadmapBanner(project: Project) -> some View {
        if let path = store.roadmapPath(for: project.path),
           let days = store.roadmapAgeDays(for: project.path) {
            let stale = days >= 14
            HStack(spacing: DSSpace.sm) {
                Image(systemName: stale ? "exclamationmark.triangle.fill" : "doc.text")
                    .foregroundColor(stale ? DSColor.warning : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Roadmap: \(URL(fileURLWithPath: path).lastPathComponent)")
                        .font(DSFont.label.weight(.semibold))
                    Text(stale
                         ? "Last updated \(days)d ago — likely stale"
                         : "Last updated \(days)d ago")
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    store.openFile(path)
                } label: {
                    Label("Open", systemImage: "doc.text")
                        .font(DSFont.micro)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open roadmap in Files tab")
                Button {
                    Task {
                        await store.suggestRoadmapUpdate(projectPath: project.path)
                        store.tabStore.detailTab = .claude
                    }
                } label: {
                    Label("Suggest update", systemImage: "sparkles")
                        .font(DSFont.micro)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Ask Claude for a unified diff of suggested roadmap updates")
            }
            .padding(DSSpace.sm)
            .background((stale ? DSColor.warning : Color.secondary).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
        }
    }

    // MARK: - Add bar

    @ViewBuilder
    private func addBar(project: Project) -> some View {
        HStack(spacing: DSSpace.sm) {
            TextField("Add a task…", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .focused($addFocused)
                .onSubmit { submit(project: project) }
                .onChange(of: newTitle) { _, title in
                    if newCategoryIsAuto {
                        newCategory = suggestCategory(from: title)
                    }
                }

            Picker("Category", selection: Binding(
                get: { newCategory },
                set: { newCategory = $0; newCategoryIsAuto = false }
            )) {
                ForEach(TaskCategory.allCases, id: \.self) { c in
                    Label(c.label, systemImage: c.systemImage).tag(c)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .help(newCategoryIsAuto ? "Auto-suggested from title" : "Manually selected")

            if let template = store.template(for: project.path) {
                Picker("Stage", selection: Binding(
                    get: { newStage ?? store.meta(for: project.path).currentStageId ?? "" },
                    set: { newStage = $0.isEmpty ? nil : $0 }
                )) {
                    Text("(unstaged)").tag("")
                    ForEach(template.stages) { s in
                        Text(s.title).tag(s.id)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            Button {
                submit(project: project)
            } label: {
                Text("Add").frame(minWidth: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit(project: Project) {
        let text = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let stage = newStage ?? store.meta(for: project.path).currentStageId
        store.addTask(
            projectPath: project.path,
            title: text,
            category: newCategory,
            stage: stage
        )
        newTitle = ""
        newCategory = .other
        newCategoryIsAuto = true
        addFocused = true
    }

    private func suggestCategory(from title: String) -> TaskCategory {
        let t = title.lowercased()
        let keywords: [(TaskCategory, [String])] = [
            (.qa,           ["test", "qa", "quality", "verify", "regression", "e2e", "unit", "spec", "coverage"]),
            (.design,       ["design", "ui", "ux", "figma", "mockup", "wireframe", "layout", "visual", "brand", "component", "screen", "style"]),
            (.ops,          ["deploy", "security", "audit", "infra", "ci", "cd", "pipeline", "monitor", "devops", "ops", "incident", "alert"]),
            (.distribution, ["ship", "release", "launch", "publish", "submit", "app store", "distribute", "upload"]),
            (.content,      ["write", "copy", "docs", "documentation", "readme", "blog", "post", "content"]),
            (.marketing,    ["market", "campaign", "email", "social", "ads", "analytics", "growth", "seo", "promo"]),
            (.research,     ["research", "investigate", "explore", "analyze", "spike", "poc", "prototype", "survey"]),
            (.engineering,  ["fix", "bug", "build", "implement", "add", "refactor", "migrate", "upgrade", "api", "backend", "frontend", "feature", "crash", "error", "performance", "integrate"]),
        ]
        for (category, words) in keywords {
            if words.contains(where: { t.contains($0) }) { return category }
        }
        return .other
    }

    // MARK: - Task list

    @ViewBuilder
    private func taskList(project: Project) -> some View {
        let tasks = store.tasksV2(for: project.path)
        let template = store.template(for: project.path)
        let currentStageId = store.meta(for: project.path).currentStageId

        if tasks.isEmpty {
            Text("No tasks yet — answer a guiding question above, or add your own.")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, DSSpace.xl)
        } else if let template = template {
            // Group by stage in template order. Within a stage, render only
            // root-level tasks; their descendants are rendered indented by
            // TaskTreeNode. Bucket the task list by stage once here rather than
            // filtering the whole list twice per stage on every render.
            let byStage = Dictionary(grouping: tasks, by: { $0.stage })
            ForEach(template.stages) { s in
                let inStage = byStage[s.id] ?? []
                let rootsInStage = inStage.filter { $0.parentId == nil }
                if !rootsInStage.isEmpty {
                    let isCurrent = s.id == currentStageId
                    TaskGroupCard(
                        title: s.title,
                        systemImage: isCurrent ? "play.circle.fill" : "circle",
                        count: inStage.count
                    ) {
                        ForEach(rootsInStage) { t in
                            TaskTreeNode(task: t, projectPath: project.path, depth: 0, allTasks: tasks)
                            if t.id != rootsInStage.last?.id { Divider() }
                        }
                    }
                }
            }
            let unstaged = byStage[nil] ?? []
            let unstagedRoots = unstaged.filter { $0.parentId == nil }
            let unstagedTotal = unstaged.count
            if !unstagedRoots.isEmpty {
                TaskGroupCard(title: "Unstaged", systemImage: "tray", count: unstagedTotal) {
                    ForEach(unstagedRoots) { t in
                        TaskTreeNode(task: t, projectPath: project.path, depth: 0, allTasks: tasks)
                        if t.id != unstagedRoots.last?.id { Divider() }
                    }
                }
            }
        } else {
            let roots = tasks.filter { $0.parentId == nil }
            TaskGroupCard(title: "Tasks", systemImage: "checklist", count: tasks.count) {
                ForEach(roots) { t in
                    TaskTreeNode(task: t, projectPath: project.path, depth: 0, allTasks: tasks)
                    if t.id != roots.last?.id { Divider() }
                }
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: String
    let projectPath: String
    let stageId: String?
    @EnvironmentObject var store: DashboardStore
    @State private var category: TaskCategory = .other
    @State private var added = false

    var body: some View {
        HStack(spacing: DSSpace.sm) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(DSColor.warning)
                .frame(width: 14)
            Text(suggestion)
                .font(DSFont.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            Picker("", selection: $category) {
                ForEach(TaskCategory.allCases, id: \.self) { c in
                    Label(c.label, systemImage: c.systemImage).tag(c)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .controlSize(.small)
            .disabled(added)

            Button {
                store.addTask(
                    projectPath: projectPath,
                    title: suggestion,
                    category: category,
                    stage: stageId
                )
                added = true
            } label: {
                Label(added ? "Added" : "Add", systemImage: added ? "checkmark" : "plus")
                    .font(DSFont.micro)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(added)
        }
        .padding(.vertical, DSSpace.xs)
    }
}

/// Stage validation checks — pass/fail badges with run + expand-to-tail.
private struct ValidationSection: View {
    let projectPath: String
    let checks: [HealthCheckSpec]
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.xs) {
                Label("Validation", systemImage: "checkmark.shield")
                    .font(DSFont.sectionHeader)
                    .tracking(0.6)
                    .foregroundColor(.secondary)
                if let summary = store.healthSummary(for: projectPath) {
                    Text(verbatim: "\(summary.passed)/\(summary.total) passed")
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(summary.passed == summary.total ? DSColor.success : .secondary)
                }
                Spacer()
                Button {
                    Task { await store.runAllHealthChecks(for: projectPath) }
                } label: {
                    Label("Run all", systemImage: "play.fill")
                        .font(DSFont.micro)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ForEach(checks, id: \.id) { check in
                ValidationRow(projectPath: projectPath, check: check)
            }
        }
        .padding(DSSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(DSRadius.small)
        .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

private struct ValidationRow: View {
    let projectPath: String
    let check: HealthCheckSpec
    @EnvironmentObject var store: DashboardStore
    @State private var expanded = false

    var body: some View {
        let status = store.healthStatus(check.id, for: projectPath)
        let result = store.lastHealthResult(check.id, for: projectPath)

        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.sm) {
                statusBadge(status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                        .font(DSFont.bodyEmphasized)
                    Text(check.command)
                        .font(DSFont.mono(.caption2))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let r = result {
                    Text(timeAgo(r.finishedAt))
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(.secondary)
                }
                Button {
                    Task { await store.runHealthCheck(check, for: projectPath) }
                } label: {
                    Image(systemName: status == .running ? "stop.circle" : "play.circle")
                }
                .buttonStyle(.borderless)
                .disabled(status == .running)
                .accessibilityLabel(status == .running ? "Stop check" : "Run check")

                if result != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(expanded ? "Collapse output" : "Expand output")
                }
            }
            if expanded, let r = result {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    HStack(spacing: DSSpace.md) {
                        Text(verbatim: "exit \(r.exitCode)")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(r.passed ? DSColor.success : DSColor.danger)
                        Text(verbatim: "\(r.durationSeconds)s")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                        if r.timedOut {
                            Text("timed out")
                                .font(DSFont.micro.weight(.semibold))
                                .foregroundColor(DSColor.warning)
                        }
                    }
                    if !r.stdoutTail.isEmpty {
                        outputBlock("stdout", text: r.stdoutTail)
                    }
                    if !r.stderrTail.isEmpty {
                        outputBlock("stderr", text: r.stderrTail)
                    }
                }
                .padding(.leading, DSSpace.xl)
                .padding(.top, DSSpace.xs)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: HealthCheckStatus) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small).frame(width: 14)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(DSColor.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundColor(DSColor.danger)
        case .unknown:
            Image(systemName: "circle").foregroundColor(.secondary)
        }
    }

    private func outputBlock(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(DSFont.mono(.caption2).weight(.semibold))
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(DSFont.mono(.caption2))
                    .textSelection(.enabled)
                    .padding(DSSpace.xs)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
            .frame(maxHeight: 120)
        }
    }
}

/// One guiding question + its persisted answer. Collapsed by default;
/// expand to see/edit the answer. Saves on commit (Enter / blur).
private struct QuestionAnswerRow: View {
    let projectPath: String
    let projectName: String
    let template: LaunchTemplate
    let stage: TemplateStage
    let question: String
    let onAddAsTask: () -> Void

    @EnvironmentObject var store: DashboardStore
    @State private var expanded = false
    @State private var draft: String = ""
    @State private var chatOpen = false
    @FocusState private var focused: Bool

    private var stageId: String { stage.id }

    private var current: String {
        store.meta(for: projectPath).answer(for: stageId, question: question)
    }
    private var isAnswered: Bool { !current.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(alignment: .top, spacing: DSSpace.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                    if expanded {
                        draft = current
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
                    } else {
                        commitIfChanged()
                    }
                } label: {
                    Image(systemName: isAnswered ? "checkmark.circle.fill" : "circle")
                        .font(DSFont.micro)
                        .foregroundColor(isAnswered ? DSColor.success : .secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse answer" : "Expand answer")

                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                    if expanded {
                        draft = current
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
                    } else {
                        commitIfChanged()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question)
                            .font(DSFont.body)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                        if !expanded, isAnswered {
                            Text(current)
                                .font(DSFont.label)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button {
                    chatOpen = true
                } label: {
                    Image(systemName: "sparkles")
                        .foregroundColor(DSColor.assistant)
                }
                .buttonStyle(.plain)
                .help("Chat with Claude about this question")
                .accessibilityLabel("Chat with Claude about this question")

                Button(action: onAddAsTask) {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Add as task")
                .accessibilityLabel("Add as task")
            }

            if expanded {
                TextField("Type your answer…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...8)
                    .focused($focused)
                    .padding(.leading, 22)
                    .onSubmit { commitAndCollapse() }
                HStack(spacing: DSSpace.xs) {
                    Spacer()
                    if !current.isEmpty {
                        Button {
                            store.setAnswer("", stageId: stageId, question: question, for: projectPath)
                            draft = ""
                            expanded = false
                        } label: { Text("Clear") }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    Button("Save") { commitAndCollapse() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines) == current)
                }
                .padding(.leading, 22)
            }
        }
        .modifier(ChatSheetModifier(
            isPresented: $chatOpen,
            projectPath: projectPath,
            projectName: projectName,
            template: template,
            stage: stage,
            question: question
        ))
    }

    private func commitIfChanged() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != current {
            store.setAnswer(trimmed, stageId: stageId, question: question, for: projectPath)
        }
    }

    private func commitAndCollapse() {
        commitIfChanged()
        expanded = false
        focused = false
    }
}

private extension QuestionAnswerRow {
    /// Wraps body with the chat sheet. Called via .modifier.
    struct ChatSheetModifier: ViewModifier {
        @Binding var isPresented: Bool
        let projectPath: String
        let projectName: String
        let template: LaunchTemplate
        let stage: TemplateStage
        let question: String

        func body(content: Content) -> some View {
            content.sheet(isPresented: $isPresented) {
                QuestionChatSheet(
                    projectPath: projectPath,
                    projectName: projectName,
                    stage: stage,
                    template: template,
                    question: question
                )
            }
        }
    }
}

private struct TaskGroupCard<Content: View>: View {
    let title: String
    let systemImage: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(DSFont.title)
                Spacer()
                Text(verbatim: "\(count)")
                    .font(DSFont.monoDigits(.caption2))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, DSSpace.lg)
            .padding(.vertical, DSSpace.sm)
            .background(.regularMaterial)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, DSSpace.lg)
                .padding(.vertical, DSSpace.xs)
        }
        .cardSurface(DSRadius.medium)
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

/// Recursive tree row. Renders the task plus its descendants indented.
/// Depth caps visual indent at 3 levels so wide trees don't shrink to nothing.
private struct TaskTreeNode: View {
    let task: TaskItem
    let projectPath: String
    let depth: Int
    let allTasks: [TaskItem]

    @EnvironmentObject var store: DashboardStore
    @State private var expanded = true

    private var children: [TaskItem] {
        allTasks.filter { $0.parentId == task.id }
    }

    private var visualDepth: Int { min(depth, 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DSSpace.xs) {
                if !children.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Collapse subtasks" : "Expand subtasks")
                } else {
                    Color.clear.frame(width: 12)
                }
                TaskLine(task: task, projectPath: projectPath, allTasks: allTasks, isParent: !children.isEmpty)
            }
            .padding(.leading, CGFloat(visualDepth) * DSSpace.lg)
            if expanded {
                ForEach(children) { c in
                    Divider().padding(.leading, CGFloat(visualDepth + 1) * DSSpace.lg)
                    TaskTreeNode(task: c, projectPath: projectPath, depth: depth + 1, allTasks: allTasks)
                }
            }
        }
    }
}

private struct TaskLine: View {
    let task: TaskItem
    let projectPath: String
    var allTasks: [TaskItem] = []
    var isParent: Bool = false
    @EnvironmentObject var store: DashboardStore
    @State private var hover = false

    var body: some View {
        HStack(spacing: DSSpace.sm) {
            Button {
                let next: TaskStatus = task.status == .done ? .open : .done
                store.setTaskStatus(projectPath: projectPath, id: task.id, status: next)
            } label: {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.status == .done ? "Mark task open" : "Mark task done")

            Button {
                store.openTaskId = task.id
                store.openTaskProjectPath = projectPath
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(DSFont.body)
                        .strikethrough(task.status == .done)
                        .foregroundColor(task.status == .done ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let notes = task.notes, !notes.isEmpty {
                        Text(notes)
                            .font(DSFont.micro)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            CategoryChip(category: task.category)
            if let prURL = task.pr, let n = prNumberFromURL(prURL) {
                PRBadge(number: n)
            }
            if task.source != .local {
                SourceBadge(source: task.source)
            }

            if hover {
                Menu {
                    Button("Mark in progress") {
                        store.setTaskStatus(projectPath: projectPath, id: task.id, status: .inProgress)
                    }
                    Button("Mark done") {
                        store.setTaskStatus(projectPath: projectPath, id: task.id, status: .done)
                    }
                    Button("Skip") {
                        store.setTaskStatus(projectPath: projectPath, id: task.id, status: .skipped)
                    }
                    Divider()
                    Section("Hierarchy") {
                        if task.parentId != nil {
                            Button {
                                store.setTaskParent(projectPath: projectPath, id: task.id, newParentId: nil)
                            } label: { Label("Promote to top-level", systemImage: "arrow.up.to.line") }
                        }
                        let candidates = allTasks.filter { $0.id != task.id && !isDescendant($0.id, ancestorOf: task.id) }
                        if !candidates.isEmpty {
                            Menu("Move under…") {
                                ForEach(candidates) { p in
                                    Button(p.title) {
                                        store.setTaskParent(projectPath: projectPath, id: task.id, newParentId: p.id)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Section("Claude") {
                        Button {
                            store.launchClaudeForTask(task, projectPath: projectPath)
                        } label: { Label("Launch with Claude", systemImage: "play.circle") }
                        Button {
                            Task {
                                await store.runForTask(task, projectPath: projectPath, allowEdits: false)
                                store.tabStore.detailTab = .claude
                            }
                        } label: { Label("Investigate (read-only)", systemImage: "magnifyingglass") }
                        Button {
                            Task {
                                await store.runForTask(task, projectPath: projectPath, allowEdits: true)
                                store.tabStore.detailTab = .claude
                            }
                        } label: { Label("Run + edit files", systemImage: "wand.and.stars") }
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.deleteTask(projectPath: projectPath, id: task.id)
                    } label: { Text("Delete") }
                } label: {
                    Image(systemName: "ellipsis").foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .accessibilityLabel("Task options")
            }
        }
        .padding(.vertical, DSSpace.xs)
        .onHover { hover = $0 }
    }

    /// Walk children of `ancestorId` down the tree; return true if `id`
    /// is anywhere in that subtree. Prevents circular reparenting.
    private func isDescendant(_ id: String, ancestorOf maybeAncestor: String) -> Bool {
        // Children of maybeAncestor — does any descend to id?
        var stack = allTasks.filter { $0.parentId == maybeAncestor }.map { $0.id }
        var seen = Set<String>()
        while let cur = stack.popLast() {
            if cur == id { return true }
            if seen.contains(cur) { continue }
            seen.insert(cur)
            stack.append(contentsOf: allTasks.filter { $0.parentId == cur }.map { $0.id })
        }
        return false
    }

    private var statusIcon: String {
        switch task.status {
        case .open: return "circle"
        case .inProgress: return "circle.dotted"
        case .blocked: return "exclamationmark.circle"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .open: return .secondary
        case .inProgress: return DSColor.info
        case .blocked: return DSColor.warning
        case .done: return DSColor.success
        case .skipped: return .secondary.opacity(0.6)
        }
    }
}

private struct PRBadge: View {
    let number: Int
    var body: some View {
        Label("#\(number)", systemImage: "arrow.triangle.branch")
            .font(DSFont.micro)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, DSSpace.xs).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12))
            .foregroundColor(.accentColor)
            .clipShape(Capsule())
    }
}

private struct CategoryChip: View {
    let category: TaskCategory
    var body: some View {
        Label(category.label, systemImage: category.systemImage)
            .font(DSFont.micro)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, DSSpace.xs).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .foregroundColor(.secondary)
            .clipShape(Capsule())
    }
}

private struct SourceBadge: View {
    let source: TaskSource
    var body: some View {
        Text(source.label)
            .font(DSFont.sectionHeader)
            .tracking(0.6)
            .padding(.horizontal, DSSpace.xs).padding(.vertical, 2)
            .background(badgeColor.opacity(0.18))
            .foregroundColor(badgeColor)
            .clipShape(Capsule())
    }
    private var badgeColor: Color {
        switch source {
        case .local: return .secondary
        case .template: return .accentColor
        case .suggested: return DSColor.assistant
        case .github: return DSColor.warning
        }
    }
}

private struct IssueRow: View {
    let issue: Issue
    var body: some View {
        Button {
            NSWorkspace.shared.open(issue.url)
        } label: {
            HStack(spacing: DSSpace.sm) {
                Text("#\(issue.number)")
                    .font(DSFont.monoDigits(.caption2))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .leading)
                Text(issue.title)
                    .font(DSFont.body)
                    .lineLimit(1)
                Spacer()
                if !issue.labels.isEmpty {
                    ForEach(issue.labels.prefix(2), id: \.self) { label in
                        Text(label)
                            .font(DSFont.micro)
                            .padding(.horizontal, DSSpace.xs).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(timeAgo(issue.updatedAt))
                    .font(DSFont.monoDigits(.caption2))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, DSSpace.xs)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - My Queue (Task 8)

private struct MyQueueView: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore

    private func urgencyScore(_ t: TaskItem) -> Int {
        switch t.kanbanColumn {
        case .blocked:  return 3
        case .reviewQA: return 2
        case .speccing: return 1
        default:        return 0
        }
    }

    var body: some View {
        // Fetch + derive once per render; humanTasks/aiTasks are each read
        // several times below and previously re-hit the store + re-sorted each time.
        let all = store.tasksV2(for: project.path)
        let humanTasks = all
            .filter { $0.kanbanColumn.ownerIsHuman && $0.status != .done && $0.status != .skipped }
            .sorted { urgencyScore($0) > urgencyScore($1) }
        let aiTasks = all.filter { $0.kanbanColumn == .aiWorking }
        return ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                if humanTasks.isEmpty && aiTasks.isEmpty {
                    Text("Nothing needs your attention right now.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                }

                if !humanTasks.isEmpty {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Label("Needs you (\(humanTasks.count))", systemImage: "person.fill")
                            .font(DSFont.sectionHeader)
                            .tracking(0.5)
                            .foregroundColor(.secondary)
                        ForEach(humanTasks) { task in
                            QueueRow(task: task, projectPath: project.path)
                                .environmentObject(store)
                        }
                    }
                }

                if !aiTasks.isEmpty {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Label("AI handling (\(aiTasks.count))", systemImage: "sparkles")
                            .font(DSFont.sectionHeader)
                            .tracking(0.5)
                            .foregroundColor(.secondary)
                        ForEach(aiTasks) { task in
                            QueueRow(task: task, projectPath: project.path, dimmed: true)
                                .environmentObject(store)
                        }
                    }
                }
            }
            .padding(DSSpace.md)
        }
    }
}

private struct QueueRow: View {
    let task: TaskItem
    let projectPath: String
    var dimmed: Bool = false
    @EnvironmentObject var store: DashboardStore

    private var runningPhase: String? {
        store.claudeTasks[projectPath]?.first {
            $0.linkedTaskId == task.id && $0.status == .running
        }?.currentPhase
    }

    var body: some View {
        Button {
            store.openTaskId = task.id
            store.openTaskProjectPath = projectPath
        } label: {
            HStack(spacing: DSSpace.sm) {
                Rectangle()
                    .fill(columnColor)
                    .frame(width: 3)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(DSFont.bodyEmphasized)
                        .foregroundColor(dimmed ? .secondary : .primary)
                        .lineLimit(1)
                    HStack(spacing: DSSpace.xs) {
                        Text(task.kanbanColumn.label)
                            .font(DSFont.micro)
                            .foregroundColor(.secondary)
                        if let phase = runningPhase {
                            Text("· ⚡ \(phase)")
                                .font(DSFont.micro)
                                .foregroundColor(DSColor.info)
                        }
                    }
                }
                Spacer()
                CategoryChip(category: task.category)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
            .cardSurface(DSRadius.small)
            .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            .opacity(dimmed ? 0.5 : 1)
        }
        .buttonStyle(.plain)
    }

    private var columnColor: Color {
        switch task.kanbanColumn {
        case .blocked:   return DSColor.warning
        case .reviewQA:  return DSColor.assistant
        case .speccing:  return DSColor.success
        case .aiWorking: return DSColor.info
        default:         return .secondary
        }
    }
}

// MARK: - Kanban board

private struct KanbanBoardView: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore
    /// Task ids that have a generated manual-test file. Resolved once per project
    /// off the render path (one directory listing) instead of a `fileExists`
    /// disk hit per card on every render.
    @State private var testIds: Set<String> = []

    var body: some View {
        // Group tasks by column once per render rather than filtering the full
        // list once per column (was 6× O(n) per body evaluation).
        let allTasks = store.tasksV2(for: project.path)
        let byColumn = Dictionary(grouping: allTasks, by: { $0.kanbanColumn })
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: DSSpace.md) {
                ForEach(KanbanColumn.allCases, id: \.self) { col in
                    KanbanColumnView(
                        column: col,
                        tasks: byColumn[col] ?? [],
                        projectPath: project.path,
                        testIds: testIds
                    )
                    .environmentObject(store)
                }
            }
            .padding(.horizontal, DSSpace.xs)
        }
        .task(id: project.path) {
            testIds = await Self.loadTestIds(projectPath: project.path)
        }
    }

    static func loadTestIds(projectPath: String) async -> Set<String> {
        await Task.detached(priority: .utility) {
            let dir = "\(projectPath)/.devdash/manual-tests"
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            return Set(files.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
        }.value
    }
}

private struct KanbanColumnView: View {
    let column: KanbanColumn
    let tasks: [TaskItem]
    let projectPath: String
    let testIds: Set<String>
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack {
                Circle()
                    .fill(columnColor)
                    .frame(width: 8, height: 8)
                Text(column.label)
                    .font(DSFont.sectionHeader)
                    .tracking(0.4)
                Spacer()
                Text(verbatim: "\(tasks.count)")
                    .font(DSFont.monoDigits(.caption2))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, DSSpace.sm).padding(.vertical, DSSpace.sm)
            .background(columnColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))

            VStack(spacing: DSSpace.xs) {
                ForEach(tasks.filter { $0.parentId == nil }) { task in
                    KanbanCard(task: task, projectPath: projectPath, columnColor: columnColor,
                               hasTests: testIds.contains(task.id))
                        .environmentObject(store)
                }
            }

            if tasks.isEmpty {
                Text("Empty")
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpace.lg)
            }
        }
        .frame(width: 200)
        .padding(DSSpace.xs)
        .background(DSColor.cardBg.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium))
    }

    private var columnColor: Color {
        switch column {
        case .backlog:   return .secondary
        case .speccing:  return DSColor.success
        case .aiWorking: return DSColor.info
        case .blocked:   return DSColor.warning
        case .reviewQA:  return DSColor.assistant
        case .done:      return DSColor.success.opacity(0.6)
        }
    }
}

private struct KanbanCard: View {
    let task: TaskItem
    let projectPath: String
    let columnColor: Color
    let hasTests: Bool
    @EnvironmentObject var store: DashboardStore
    @State private var hover = false

    private var runningClaudeTask: ClaudeTask? {
        store.claudeTasks[projectPath]?.first {
            $0.linkedTaskId == task.id && $0.status == .running
        }
    }

    var body: some View {
        Button {
            store.openTaskId = task.id
            store.openTaskProjectPath = projectPath
        } label: {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text(task.title)
                    .font(DSFont.bodyEmphasized)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)

                if let ct = runningClaudeTask, let phase = ct.currentPhase {
                    HStack(spacing: DSSpace.xs) {
                        ProgressView().controlSize(.mini)
                        Text("⚡ \(phase)")
                            .font(DSFont.micro)
                            .foregroundColor(DSColor.info)
                    }
                }

                if hasTests {
                    Label("Tests ready", systemImage: "checklist")
                        .font(DSFont.micro)
                        .foregroundColor(DSColor.assistant)
                }

                HStack(spacing: DSSpace.xs) {
                    CategoryChip(category: task.category)
                    Spacer()
                    if task.status == .done {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(DSColor.success)
                            .font(DSFont.micro)
                    }
                }
            }
            .padding(DSSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(DSRadius.small)
            .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(
                hover ? columnColor.opacity(0.6) : Color(NSColor.separatorColor),
                lineWidth: hover ? 1 : 0.5
            ))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Launch with Claude") {
                store.launchClaudeForTask(task, projectPath: projectPath)
            }
            Button("Investigate (read-only)") {
                Task { await store.runForTask(task, projectPath: projectPath, allowEdits: false) }
            }
            Button("Run + edit files") {
                Task { await store.runForTask(task, projectPath: projectPath, allowEdits: true) }
            }
            Divider()
            Button("Move to Backlog") {
                store.setTaskOwner(projectPath: projectPath, id: task.id, owner: .none)
                store.setTaskStatus(projectPath: projectPath, id: task.id, status: .open)
            }
            Button("Mark Blocked") {
                store.setTaskStatus(projectPath: projectPath, id: task.id, status: .blocked)
                store.setTaskOwner(projectPath: projectPath, id: task.id, owner: .human)
            }
            Button("Mark Done") {
                Task { await store.markTaskDone(projectPath: projectPath, taskId: task.id) }
            }
            Divider()
            Button(role: .destructive) {
                store.deleteTask(projectPath: projectPath, id: task.id)
            } label: { Text("Delete") }
        }
        .onHover { hover = $0 }
    }
}

private struct TemplatePickerSheet: View {
    let projectPath: String
    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Choose a launch template")
                    .font(DSFont.title)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DSSpace.lg)
            Divider()
            ScrollView {
                VStack(spacing: DSSpace.sm) {
                    ForEach(Templates.all) { t in
                        Button {
                            selected = t.id
                        } label: {
                            VStack(alignment: .leading, spacing: DSSpace.xs) {
                                HStack {
                                    Image(systemName: selected == t.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(selected == t.id ? .accentColor : .secondary)
                                    Text(t.name)
                                        .font(DSFont.title)
                                    Spacer()
                                    Text(verbatim: "\(t.stages.count) stages")
                                        .font(DSFont.monoDigits(.caption2))
                                        .foregroundColor(.secondary)
                                }
                                Text(t.summary)
                                    .font(DSFont.label)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: DSSpace.xs) {
                                    ForEach(t.stages) { s in
                                        Text(s.title)
                                            .font(DSFont.micro)
                                            .padding(.horizontal, DSSpace.xs).padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.10))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(DSSpace.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(DSRadius.small)
                            .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(
                                selected == t.id ? Color.accentColor : Color(NSColor.separatorColor),
                                lineWidth: selected == t.id ? 1 : 0.5
                            ))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DSSpace.lg)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    if let id = selected, let t = Templates.find(id) {
                        store.applyTemplate(t, to: projectPath)
                        dismiss()
                    }
                } label: {
                    Text("Apply").frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(DSSpace.lg)
        }
        .frame(width: 600, height: 480)
    }
}
