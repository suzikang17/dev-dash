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
    @State private var newStage: String? = nil
    @State private var showTemplatePicker = false
    @FocusState private var addFocused: Bool

    var body: some View {
        if let project = store.project(for: store.selection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerRow(project: project)

                    if let template = store.template(for: project.path) {
                        stageCard(project: project, template: template)
                    } else {
                        templatePickerCard(project: project)
                    }

                    roadmapBanner(project: project)

                    if let err = store.todoError {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }

                    addBar(project: project)

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
                }
                .padding(20)
            }
            .sheet(isPresented: $showTemplatePicker) {
                TemplatePickerSheet(projectPath: project.path)
                    .environmentObject(store)
            }
        } else {
            Text("Select a project to see tasks")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer()
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

        VStack(alignment: .leading, spacing: 12) {
            // Stepper across stages
            HStack(spacing: 4) {
                ForEach(Array(template.stages.enumerated()), id: \.element.id) { i, s in
                    Button {
                        store.setStage(s.id, for: project.path)
                    } label: {
                        Text(s.title)
                            .font(.system(size: 11, weight: i == stageIndex ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
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

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stage.title)
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if let started = meta.stageStartedAt {
                        Text("Started \(timeAgo(started))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                Text(stage.purpose)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                if !stage.methodology.isEmpty {
                    Text(stage.methodology)
                        .font(.system(size: 12).italic())
                        .foregroundColor(.secondary.opacity(0.85))
                }
            }

            if !stage.guidingQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    let answeredCount = stage.guidingQuestions.filter { !meta.answer(for: stage.id, question: $0).isEmpty }.count
                    HStack(spacing: 6) {
                        Label("Guiding questions", systemImage: "questionmark.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(verbatim: "\(answeredCount)/\(stage.guidingQuestions.count) answered")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    ForEach(stage.guidingQuestions, id: \.self) { q in
                        QuestionAnswerRow(
                            projectPath: project.path,
                            stageId: stage.id,
                            question: q,
                            onAddAsTask: {
                                newTitle = q
                                newStage = stage.id
                                addFocused = true
                            }
                        )
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !stage.exitCriteria.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Exit criteria", systemImage: "flag.checkered")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(.secondary)
                    ForEach(stage.exitCriteria, id: \.self) { c in
                        let key = "\(stage.id):\(c)"
                        let checked = meta.checkedExitCriteria.contains(key)
                        Button {
                            store.toggleExitCriterion(c, stageId: stage.id, for: project.path)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundColor(checked ? .green : .secondary)
                                Text(c)
                                    .font(.system(size: 13))
                                    .strikethrough(checked)
                                    .foregroundColor(checked ? .secondary : .primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            }

            if !stage.validationChecks.isEmpty {
                ValidationSection(projectPath: project.path, checks: stage.validationChecks)
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        await store.suggestTasksForStage(projectPath: project.path, template: template, stage: stage)
                        store.detailTab = .claude
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.4), lineWidth: 0.8))
    }

    @ViewBuilder
    private func templatePickerCard(project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "map")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No template applied")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Pick a launch methodology to guide stages, exit criteria, and the kind of tasks to create.")
                        .font(.system(size: 12))
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
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }

    // MARK: - Roadmap

    @ViewBuilder
    private func roadmapBanner(project: Project) -> some View {
        if let path = store.roadmapPath(for: project.path),
           let days = store.roadmapAgeDays(for: project.path) {
            let stale = days >= 14
            HStack(spacing: 10) {
                Image(systemName: stale ? "exclamationmark.triangle.fill" : "doc.text")
                    .foregroundColor(stale ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Roadmap: \(URL(fileURLWithPath: path).lastPathComponent)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(stale
                         ? "Last updated \(days)d ago — likely stale"
                         : "Last updated \(days)d ago")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    store.pendingFilePath = path
                    store.detailTab = .files
                } label: {
                    Label("Open", systemImage: "doc.text")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open roadmap in Files tab")
                Button {
                    Task {
                        await store.suggestRoadmapUpdate(projectPath: project.path)
                        store.detailTab = .claude
                    }
                } label: {
                    Label("Suggest update", systemImage: "sparkles")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Ask Claude for a unified diff of suggested roadmap updates")
            }
            .padding(10)
            .background((stale ? Color.orange : Color.secondary).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Add bar

    @ViewBuilder
    private func addBar(project: Project) -> some View {
        HStack(spacing: 8) {
            TextField("Add a task…", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .focused($addFocused)
                .onSubmit { submit(project: project) }

            Picker("Category", selection: $newCategory) {
                ForEach(TaskCategory.allCases, id: \.self) { c in
                    Label(c.label, systemImage: c.systemImage).tag(c)
                }
            }
            .labelsHidden()
            .frame(width: 150)

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
        addFocused = true
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
                .padding(.top, 24)
        } else if let template = template {
            // Group by stage in template order, then unstaged at the bottom
            ForEach(template.stages) { s in
                let inStage = tasks.filter { $0.stage == s.id }
                if !inStage.isEmpty {
                    let isCurrent = s.id == currentStageId
                    TaskGroupCard(
                        title: s.title,
                        systemImage: isCurrent ? "play.circle.fill" : "circle",
                        count: inStage.count
                    ) {
                        ForEach(inStage) { t in
                            TaskLine(task: t, projectPath: project.path)
                            if t.id != inStage.last?.id { Divider() }
                        }
                    }
                }
            }
            let unstaged = tasks.filter { $0.stage == nil }
            if !unstaged.isEmpty {
                TaskGroupCard(title: "Unstaged", systemImage: "tray", count: unstaged.count) {
                    ForEach(unstaged) { t in
                        TaskLine(task: t, projectPath: project.path)
                        if t.id != unstaged.last?.id { Divider() }
                    }
                }
            }
        } else {
            TaskGroupCard(title: "Tasks", systemImage: "checklist", count: tasks.count) {
                ForEach(tasks) { t in
                    TaskLine(task: t, projectPath: project.path)
                    if t.id != tasks.last?.id { Divider() }
                }
            }
        }
    }
}

/// Stage validation checks — pass/fail badges with run + expand-to-tail.
private struct ValidationSection: View {
    let projectPath: String
    let checks: [HealthCheckSpec]
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Validation", systemImage: "checkmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.secondary)
                if let summary = store.healthSummary(for: projectPath) {
                    Text(verbatim: "\(summary.passed)/\(summary.total) passed")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(summary.passed == summary.total ? .green : .secondary)
                }
                Spacer()
                Button {
                    Task { await store.runAllHealthChecks(for: projectPath) }
                } label: {
                    Label("Run all", systemImage: "play.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ForEach(checks, id: \.id) { check in
                ValidationRow(projectPath: projectPath, check: check)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
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

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusBadge(status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                        .font(.system(size: 12, weight: .medium))
                    Text(check.command)
                        .font(.system(size: 10).monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let r = result {
                    Text(timeAgo(r.finishedAt))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Button {
                    Task { await store.runHealthCheck(check, for: projectPath) }
                } label: {
                    Image(systemName: status == .running ? "stop.circle" : "play.circle")
                }
                .buttonStyle(.borderless)
                .disabled(status == .running)

                if result != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if expanded, let r = result {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(verbatim: "exit \(r.exitCode)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(r.passed ? .green : .red)
                        Text(verbatim: "\(r.durationSeconds)s")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.secondary)
                        if r.timedOut {
                            Text("timed out")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                    }
                    if !r.stdoutTail.isEmpty {
                        outputBlock("stdout", text: r.stdoutTail)
                    }
                    if !r.stderrTail.isEmpty {
                        outputBlock("stderr", text: r.stderrTail)
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: HealthCheckStatus) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small).frame(width: 14)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        case .unknown:
            Image(systemName: "circle").foregroundColor(.secondary)
        }
    }

    private func outputBlock(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold).monospaced())
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxHeight: 120)
        }
    }
}

/// One guiding question + its persisted answer. Collapsed by default;
/// expand to see/edit the answer. Saves on commit (Enter / blur).
private struct QuestionAnswerRow: View {
    let projectPath: String
    let stageId: String
    let question: String
    let onAddAsTask: () -> Void

    @EnvironmentObject var store: DashboardStore
    @State private var expanded = false
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private var current: String {
        store.meta(for: projectPath).answer(for: stageId, question: question)
    }
    private var isAnswered: Bool { !current.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
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
                        .font(.system(size: 11))
                        .foregroundColor(isAnswered ? .green : .secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

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
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                        if !expanded, isAnswered {
                            Text(current)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button(action: onAddAsTask) {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Add as task")
            }

            if expanded {
                TextField("Type your answer…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...8)
                    .focused($focused)
                    .padding(.leading, 22)
                    .onSubmit { commitAndCollapse() }
                HStack(spacing: 6) {
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

private struct TaskGroupCard<Content: View>: View {
    let title: String
    let systemImage: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(verbatim: "\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

private struct TaskLine: View {
    let task: TaskItem
    let projectPath: String
    @EnvironmentObject var store: DashboardStore
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                let next: TaskStatus = task.status == .done ? .open : .done
                store.setTaskStatus(projectPath: projectPath, id: task.id, status: next)
            } label: {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.status == .done)
                    .foregroundColor(task.status == .done ? .secondary : .primary)
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            CategoryChip(category: task.category)
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
                    Section("Claude") {
                        Button {
                            Task {
                                await store.runForTask(task, projectPath: projectPath, allowEdits: false)
                                store.detailTab = .claude
                            }
                        } label: { Label("Investigate (read-only)", systemImage: "magnifyingglass") }
                        Button {
                            Task {
                                await store.runForTask(task, projectPath: projectPath, allowEdits: true)
                                store.detailTab = .claude
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
            }
        }
        .padding(.vertical, 6)
        .onHover { hover = $0 }
    }

    private var statusIcon: String {
        switch task.status {
        case .open: return "circle"
        case .inProgress: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .open: return .secondary
        case .inProgress: return .blue
        case .done: return .green
        case .skipped: return .secondary.opacity(0.6)
        }
    }
}

private struct CategoryChip: View {
    let category: TaskCategory
    var body: some View {
        Label(category.label, systemImage: category.systemImage)
            .font(.system(size: 10))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .foregroundColor(.secondary)
            .clipShape(Capsule())
    }
}

private struct SourceBadge: View {
    let source: TaskSource
    var body: some View {
        Text(source.label)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(badgeColor.opacity(0.18))
            .foregroundColor(badgeColor)
            .clipShape(Capsule())
    }
    private var badgeColor: Color {
        switch source {
        case .local: return .secondary
        case .template: return .accentColor
        case .suggested: return .purple
        case .github: return .orange
        }
    }
}

private struct IssueRow: View {
    let issue: Issue
    var body: some View {
        Button {
            NSWorkspace.shared.open(issue.url)
        } label: {
            HStack(spacing: 10) {
                Text("#\(issue.number)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .leading)
                Text(issue.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
                if !issue.labels.isEmpty {
                    ForEach(issue.labels.prefix(2), id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(timeAgo(issue.updatedAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
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
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Templates.all) { t in
                        Button {
                            selected = t.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: selected == t.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(selected == t.id ? .accentColor : .secondary)
                                    Text(t.name)
                                        .font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Text(verbatim: "\(t.stages.count) stages")
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                Text(t.summary)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 4) {
                                    ForEach(t.stages) { s in
                                        Text(s.title)
                                            .font(.system(size: 10))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.10))
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                selected == t.id ? Color.accentColor : Color(NSColor.separatorColor),
                                lineWidth: selected == t.id ? 1 : 0.5
                            ))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
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
            .padding(14)
        }
        .frame(width: 600, height: 480)
    }
}
