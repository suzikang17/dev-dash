import SwiftUI
import AppKit

/// Ticket-style task detail. Opens as a sheet from any TaskLine click.
/// Full editing surface: title, multi-line description, category/stage/
/// status, parent, child list, AI actions, lifecycle timeline.
struct TaskDetailSheet: View {
    let projectPath: String
    let taskId: String

    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var category: TaskCategory = .other
    @State private var stage: String = ""
    @State private var status: TaskStatus = .open
    @State private var loaded = false
    /// Whether this task has a generated manual-test file. Resolved on load so
    /// `artifactsSection` doesn't hit disk (`fileExists`) on every render.
    @State private var hasTests = false
    @FocusState private var titleFocused: Bool

    // PR card state
    enum PRLoadState {
        case idle, loading, loaded(PRDetail), failed
    }
    @State private var prLoadState: PRLoadState = .idle

    private var task: TaskItem? {
        store.tasksV2(for: projectPath).first { $0.id == taskId }
    }
    private var template: LaunchTemplate? { store.template(for: projectPath) }
    private var children: [TaskItem] { store.childTasks(of: taskId, in: projectPath) }
    private var parent: TaskItem? {
        guard let pid = task?.parentId else { return nil }
        return store.tasksV2(for: projectPath).first { $0.id == pid }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    titleEditor
                    metadataRow
                    descriptionEditor
                    if task?.pr != nil { prCard }
                    personaSection
                    phasesSection
                    artifactsSection
                    if !children.isEmpty { childrenSection }
                    if let docPath = task?.linkedDocPath { backlinksSection(docPath: docPath) }
                    timeline
                    aiActions
                }
                .padding(DSSpace.xl)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 700)
        .onAppear { loadFromStore() }
        .onChange(of: taskId) { _, _ in loadFromStore() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: DSSpace.sm) {
            statusBadge
            VStack(alignment: .leading, spacing: 1) {
                Text("TICKET")
                    .font(DSFont.sectionHeader)
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                Text(task?.id.prefix(8).description ?? "—")
                    .font(DSFont.mono(.caption))
                    .foregroundColor(.secondary)
            }
            if let p = parent {
                Image(systemName: "chevron.right")
                    .font(DSFont.sectionHeader)
                    .foregroundColor(.secondary)
                Button {
                    store.openTaskId = p.id
                    store.openTaskProjectPath = projectPath
                } label: {
                    Text(p.title)
                        .font(DSFont.micro)
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open parent")
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(DSSpace.md)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let color: Color = {
            switch status {
            case .open: return .secondary
            case .inProgress: return DSColor.info
            case .blocked: return DSColor.warning
            case .done: return DSColor.success
            case .skipped: return .secondary.opacity(0.6)
            }
        }()
        Image(systemName: statusIcon)
            .foregroundColor(color)
            .font(DSFont.sectionTitle)
    }

    @ViewBuilder
    private var titleEditor: some View {
        TextField("Title", text: $title, axis: .vertical)
            .font(DSFont.sectionTitle)
            .textFieldStyle(.plain)
            .focused($titleFocused)
            .lineLimit(1...3)
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: DSSpace.md) {
            Picker("Status", selection: $status) {
                ForEach([TaskStatus.open, .inProgress, .blocked, .done, .skipped], id: \.self) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            .labelsHidden()

            Picker("Category", selection: $category) {
                ForEach(TaskCategory.allCases, id: \.self) { c in
                    Label(c.label, systemImage: c.systemImage).tag(c)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
            .labelsHidden()

            if let template = template {
                Picker("Stage", selection: $stage) {
                    Text("(unstaged)").tag("")
                    ForEach(template.stages) { s in
                        Text(s.title).tag(s.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                .labelsHidden()
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var descriptionEditor: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            SectionHeader("Description")
            TextEditor(text: $notes)
                .font(DSFont.body)
                .padding(DSSpace.sm)
                .frame(minHeight: 160)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium))
                .dsHairline(DSRadius.medium)
            if notes.isEmpty {
                Text("Add context — what's the goal, why does it matter, what does done look like?")
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            SectionHeader("Subtasks")
            VStack(spacing: DSSpace.xs) {
                ForEach(children) { c in
                    Button {
                        store.openTaskId = c.id
                        store.openTaskProjectPath = projectPath
                    } label: {
                        HStack(spacing: DSSpace.sm) {
                            Image(systemName: childIcon(c.status))
                                .foregroundColor(childColor(c.status))
                                .frame(width: 14)
                            Text(c.title)
                                .font(DSFont.label)
                                .strikethrough(c.status == .done)
                                .foregroundColor(c.status == .done ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                            Text(c.category.label)
                                .font(DSFont.micro)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12))
                                .foregroundColor(.secondary)
                                .clipShape(Capsule())
                        }
                        .padding(.vertical, DSSpace.xs).padding(.horizontal, DSSpace.sm)
                        .cardSurface(DSRadius.small)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func backlinksSection(docPath: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            SectionHeader("Referenced in")
            Button {
                store.openFile(docPath)
            } label: {
                HStack(spacing: DSSpace.xs) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(DSColor.assistant)
                        .font(DSFont.label)
                    Text(URL(fileURLWithPath: docPath).lastPathComponent)
                        .font(DSFont.label)
                        .foregroundStyle(DSColor.assistant)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - PR Card

    /// Parse a PR number from a GitHub pull URL like `.../pull/42`.
    @ViewBuilder
    private var prCard: some View {
        if let prURL = task?.pr {
            let number = prNumberFromURL(prURL)
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                SectionHeader("Pull Request")
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    // Header row: branch icon + PR # + open button
                    HStack(spacing: DSSpace.sm) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundColor(.accentColor)
                            .font(DSFont.label)
                        if let n = number {
                            Text("PR #\(n)")
                                .font(DSFont.bodyEmphasized)
                        } else {
                            Text("Pull Request")
                                .font(DSFont.bodyEmphasized)
                        }
                        Spacer()
                        let canOpen = number != nil || URL(string: prURL) != nil
                        Button {
                            if let n = number {
                                Task { await GitDiffScanner.openPRWeb(path: projectPath, number: n) }
                            } else if let u = URL(string: prURL) {
                                NSWorkspace.shared.open(u)
                            }
                        } label: {
                            Label("Open PR", systemImage: "arrow.up.forward.app")
                                .font(DSFont.micro)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canOpen)
                    }

                    // Live detail or loading/fallback
                    switch prLoadState {
                    case .idle:
                        EmptyView()
                    case .loading:
                        HStack(spacing: DSSpace.xs) {
                            ProgressView().controlSize(.small)
                            Text("Fetching PR details…")
                                .font(DSFont.micro)
                                .foregroundColor(.secondary)
                        }
                    case .loaded(let detail):
                        VStack(alignment: .leading, spacing: DSSpace.xs) {
                            Text(detail.title)
                                .font(DSFont.label)
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            HStack(spacing: DSSpace.md) {
                                prStateBadge(detail.state)
                                Label("+\(detail.additions)", systemImage: "plus")
                                    .font(DSFont.monoDigits(.caption2))
                                    .foregroundColor(DSColor.success)
                                Label("-\(detail.deletions)", systemImage: "minus")
                                    .font(DSFont.monoDigits(.caption2))
                                    .foregroundColor(DSColor.danger)
                                if !detail.headRefName.isEmpty {
                                    Label(detail.headRefName, systemImage: "arrow.triangle.branch")
                                        .font(DSFont.mono(.caption2))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    case .failed:
                        // Fallback: just show the raw link
                        Text(prURL)
                            .font(DSFont.mono(.caption2))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(DSSpace.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.medium)
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5))
            }
            .task(id: prURL) {
                guard let n = prNumberFromURL(prURL) else {
                    prLoadState = .failed; return
                }
                prLoadState = .loading
                if let detail = await GitDiffScanner.prDetail(path: projectPath, number: n) {
                    prLoadState = .loaded(detail)
                } else {
                    prLoadState = .failed
                }
            }
        }
    }

    @ViewBuilder
    private func prStateBadge(_ state: String) -> some View {
        let (label, color): (String, Color) = {
            switch state.lowercased() {
            case "open":   return ("Open", DSColor.success)
            case "merged": return ("Merged", Color.purple)
            default:       return ("Closed", .secondary)
            }
        }()
        Text(label)
            .font(DSFont.sectionHeader)
            .tracking(0.6)
            .padding(.horizontal, DSSpace.xs).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var timeline: some View {
        if let t = task {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                SectionHeader("Activity")
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    timelineRow(label: "Created", date: t.createdAt)
                    if let s = t.startedAt { timelineRow(label: "Started", date: s) }
                    if let c = t.completedAt { timelineRow(label: "Completed", date: c) }
                }
            }
        }
    }

    private func timelineRow(label: String, date: Date) -> some View {
        HStack(spacing: DSSpace.sm) {
            Text(label)
                .font(DSFont.micro)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(timeAgo(date))
                .font(DSFont.monoDigits(.caption2))
                .foregroundColor(.secondary)
            Text(absoluteDate(date))
                .font(DSFont.mono(.caption2))
                .foregroundColor(.secondary.opacity(0.7))
        }
    }

    @ViewBuilder
    private var personaSection: some View {
        let t = task
        let override = t?.gstackPersonaOverride
        let autoP = GStackSkillLoader.autoPersona(for: t?.category ?? .other, hasAIRun: t?.hasAIRun ?? false)
        let active = override.flatMap { id in GStackSkillLoader.all.first { $0.id == id } } ?? autoP
        let installed = GStackSkillLoader.all.filter { $0.isInstalled }

        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack {
                SectionHeader("Persona")
                if override == nil {
                    Text("auto")
                        .font(DSFont.sectionHeader)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                } else {
                    Button("Reset to auto") {
                        if var updated = t {
                            updated.gstackPersonaOverride = nil
                            store.updateTask(projectPath: projectPath, updated)
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundColor(.secondary)
                }
                Spacer()
            }

            if let p = active {
                HStack(spacing: DSSpace.sm) {
                    Image(systemName: p.systemImage)
                        .font(DSFont.title)
                        .foregroundColor(.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.role)
                            .font(DSFont.label.weight(.semibold))
                        Text(p.tagline)
                            .font(DSFont.micro)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(DSSpace.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5))
            } else if installed.isEmpty {
                Text("Install gstack to enable AI personas")
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
            }

            if !installed.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DSSpace.xs) {
                        ForEach(installed) { p in
                            let isSelected = override == p.id
                            Button {
                                if var updated = t {
                                    updated.gstackPersonaOverride = isSelected ? nil : p.id
                                    store.updateTask(projectPath: projectPath, updated)
                                }
                            } label: {
                                HStack(spacing: DSSpace.xs) {
                                    Image(systemName: p.systemImage)
                                        .font(DSFont.micro)
                                    Text(p.role)
                                        .font(DSFont.micro.weight(isSelected ? .semibold : .regular))
                                }
                                .padding(.horizontal, DSSpace.sm).padding(.vertical, DSSpace.xs)
                                .background(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                .clipShape(Capsule())
                                .overlay(isSelected ? Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 0.8) : nil)
                            }
                            .buttonStyle(.plain)
                            .help(p.tagline)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var phasesSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack {
                SectionHeader("Phases")
                Spacer()
                Button("+ Add") {
                    if var t = task {
                        t.phases = (t.phases ?? []) + ["New phase"]
                        store.updateTask(projectPath: projectPath, t)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(task == nil)
            }

            if let phases = task?.phases, !phases.isEmpty {
                ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
                    HStack(spacing: DSSpace.sm) {
                        Image(systemName: (task?.completedPhases.contains(phase) == true) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor((task?.completedPhases.contains(phase) == true) ? DSColor.success : .secondary)
                            .frame(width: 14)
                        Text(phase)
                            .font(DSFont.body)
                        Spacer()
                        Button {
                            if var t = task {
                                var p = t.phases ?? []
                                p.remove(at: i)
                                t.phases = p.isEmpty ? nil : p
                                store.updateTask(projectPath: projectPath, t)
                            }
                        } label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                            .buttonStyle(.borderless).controlSize(.small)
                            .accessibilityLabel("Remove phase")
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("Let AI decide phases for this task")
                    .font(DSFont.label)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var artifactsSection: some View {
        let testsPath = "\(projectPath)/.devdash/manual-tests/\(task?.id ?? "").md"

        if hasTests {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                SectionHeader("Manual tests")
                Button {
                    store.openFile(testsPath)
                    dismiss()
                } label: {
                    Label("Open test checklist", systemImage: "checklist")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var aiActions: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            SectionHeader("Claude")
            HStack(spacing: DSSpace.sm) {
                if let t = task {
                    Button {
                        store.launchClaudeForTask(t, projectPath: projectPath)
                        dismiss()
                    } label: { Label("Launch with Claude", systemImage: "play.circle") }
                        .buttonStyle(.borderedProminent)
                    Button {
                        Task {
                            await store.runForTask(t, projectPath: projectPath, allowEdits: false)
                            store.tabStore.detailTab = .claude
                            dismiss()
                        }
                    } label: { Label("Investigate (read-only)", systemImage: "magnifyingglass") }
                        .buttonStyle(.bordered)
                    Button {
                        Task {
                            await store.runForTask(t, projectPath: projectPath, allowEdits: true)
                            store.tabStore.detailTab = .claude
                            dismiss()
                        }
                    } label: { Label("Run + edit files", systemImage: "wand.and.stars") }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: DSSpace.sm) {
            if let t = task {
                Button(role: .destructive) {
                    store.deleteTask(projectPath: projectPath, id: t.id)
                    dismiss()
                } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if let t = task, t.status != .done {
                Button {
                    Task { await store.markTaskDone(projectPath: projectPath, taskId: t.id) }
                    dismiss()
                } label: { Label("Mark Done", systemImage: "checkmark.circle") }
                    .buttonStyle(.bordered)
                    .tint(DSColor.success)
            }
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
            Button("Save") { saveAndDismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(DSSpace.md)
    }

    // MARK: - Bindings

    private func loadFromStore() {
        guard let t = task else { return }
        title = t.title
        notes = t.notes ?? ""
        category = t.category
        stage = t.stage ?? ""
        status = t.status
        loaded = true
        hasTests = FileManager.default.fileExists(
            atPath: "\(projectPath)/.devdash/manual-tests/\(t.id).md")
        prLoadState = .idle
    }

    private func saveAndDismiss() {
        guard var t = task else { dismiss(); return }
        t.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        t.category = category
        t.stage = stage.isEmpty ? nil : stage
        // Status changes also flip lifecycle dates the same way setTaskStatus does
        if t.status != status {
            switch status {
            case .inProgress where t.startedAt == nil:
                t.startedAt = Date()
            case .done where t.completedAt == nil:
                t.completedAt = Date()
            default: break
            }
            t.status = status
        }
        store.updateTask(projectPath: projectPath, t)
        dismiss()
    }

    private var statusIcon: String {
        switch status {
        case .open: return "circle"
        case .inProgress: return "circle.dotted"
        case .blocked: return "exclamationmark.circle"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func childIcon(_ s: TaskStatus) -> String {
        switch s {
        case .open: return "circle"
        case .inProgress: return "circle.dotted"
        case .blocked: return "exclamationmark.circle"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func childColor(_ s: TaskStatus) -> Color {
        switch s {
        case .open: return .secondary
        case .inProgress: return DSColor.info
        case .blocked: return DSColor.warning
        case .done: return DSColor.success
        case .skipped: return .secondary.opacity(0.6)
        }
    }

    private func absoluteDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: d)
    }
}

/// Parse a PR number from a GitHub pull URL (e.g. `.../pull/42` → 42).
/// Shared by TaskDetailSheet and TasksTabView so the two can't drift.
func prNumberFromURL(_ url: String) -> Int? {
    guard let u = URL(string: url),
          let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
    let parts = comps.path.components(separatedBy: "/")
    guard let pullIdx = parts.firstIndex(of: "pull"), pullIdx + 1 < parts.count else { return nil }
    return Int(parts[pullIdx + 1])
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

