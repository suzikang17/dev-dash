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
    @FocusState private var titleFocused: Bool

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
                VStack(alignment: .leading, spacing: 16) {
                    titleEditor
                    metadataRow
                    descriptionEditor
                    personaSection
                    phasesSection
                    artifactsSection
                    if !children.isEmpty { childrenSection }
                    timeline
                    aiActions
                }
                .padding(20)
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
        HStack(spacing: 10) {
            statusBadge
            VStack(alignment: .leading, spacing: 1) {
                Text("TICKET")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                Text(task?.id.prefix(8).description ?? "—")
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(.secondary)
            }
            if let p = parent {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Button {
                    store.openTaskId = p.id
                    store.openTaskProjectPath = projectPath
                } label: {
                    Text(p.title)
                        .font(.system(size: 11))
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
        .padding(14)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let color: Color = {
            switch status {
            case .open: return .secondary
            case .inProgress: return .blue
            case .blocked: return .orange
            case .done: return .green
            case .skipped: return .secondary.opacity(0.6)
            }
        }()
        Image(systemName: statusIcon)
            .foregroundColor(color)
            .font(.system(size: 18))
    }

    @ViewBuilder
    private var titleEditor: some View {
        TextField("Title", text: $title, axis: .vertical)
            .font(.system(size: 18, weight: .semibold))
            .textFieldStyle(.plain)
            .focused($titleFocused)
            .lineLimit(1...3)
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 12) {
            Picker("Status", selection: $status) {
                ForEach([TaskStatus.open, .inProgress, .done, .skipped], id: \.self) { s in
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
        VStack(alignment: .leading, spacing: 6) {
            Text("DESCRIPTION")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)
            TextEditor(text: $notes)
                .font(.system(size: 13))
                .padding(8)
                .frame(minHeight: 160)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            if notes.isEmpty {
                Text("Add context — what's the goal, why does it matter, what does done look like?")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUBTASKS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)
            VStack(spacing: 4) {
                ForEach(children) { c in
                    Button {
                        store.openTaskId = c.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: childIcon(c.status))
                                .foregroundColor(childColor(c.status))
                                .frame(width: 14)
                            Text(c.title)
                                .font(.system(size: 12))
                                .strikethrough(c.status == .done)
                                .foregroundColor(c.status == .done ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                            Text(c.category.label)
                                .font(.system(size: 10))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12))
                                .foregroundColor(.secondary)
                                .clipShape(Capsule())
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if let t = task {
            VStack(alignment: .leading, spacing: 6) {
                Text("ACTIVITY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    timelineRow(label: "Created", date: t.createdAt)
                    if let s = t.startedAt { timelineRow(label: "Started", date: s) }
                    if let c = t.completedAt { timelineRow(label: "Completed", date: c) }
                }
            }
        }
    }

    private func timelineRow(label: String, date: Date) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(timeAgo(date))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
            Text(absoluteDate(date))
                .font(.system(size: 11).monospaced())
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

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PERSONA")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                if override == nil {
                    Text("auto")
                        .font(.system(size: 9, weight: .semibold))
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
                HStack(spacing: 10) {
                    Image(systemName: p.systemImage)
                        .font(.system(size: 16))
                        .foregroundColor(.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.role)
                            .font(.system(size: 12, weight: .semibold))
                        Text(p.tagline)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5))
            } else if installed.isEmpty {
                Text("Install gstack to enable AI personas")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if !installed.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(installed) { p in
                            let isSelected = override == p.id
                            Button {
                                if var updated = t {
                                    updated.gstackPersonaOverride = isSelected ? nil : p.id
                                    store.updateTask(projectPath: projectPath, updated)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: p.systemImage)
                                        .font(.system(size: 10))
                                    Text(p.role)
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PHASES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
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
                    HStack(spacing: 8) {
                        Image(systemName: (task?.completedPhases.contains(phase) == true) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor((task?.completedPhases.contains(phase) == true) ? .green : .secondary)
                            .frame(width: 14)
                        Text(phase)
                            .font(.system(size: 13))
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
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("Let AI decide phases for this task")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var artifactsSection: some View {
        let testsPath = "\(projectPath)/.devdash/manual-tests/\(task?.id ?? "").md"
        let hasTests = FileManager.default.fileExists(atPath: testsPath)

        if hasTests {
            VStack(alignment: .leading, spacing: 6) {
                Text("MANUAL TESTS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                Button {
                    store.pendingFilePath = testsPath
                    store.detailTab = .files
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
        VStack(alignment: .leading, spacing: 6) {
            Text("CLAUDE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                if let t = task {
                    Button {
                        Task {
                            await store.runForTask(t, projectPath: projectPath, allowEdits: false)
                            store.detailTab = .claude
                            dismiss()
                        }
                    } label: { Label("Investigate (read-only)", systemImage: "magnifyingglass") }
                        .buttonStyle(.bordered)
                    Button {
                        Task {
                            await store.runForTask(t, projectPath: projectPath, allowEdits: true)
                            store.detailTab = .claude
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
        HStack(spacing: 8) {
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
                    .tint(.green)
            }
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
            Button("Save") { saveAndDismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
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
        case .inProgress: return .blue
        case .blocked: return .orange
        case .done: return .green
        case .skipped: return .secondary.opacity(0.6)
        }
    }

    private func absoluteDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: d)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

