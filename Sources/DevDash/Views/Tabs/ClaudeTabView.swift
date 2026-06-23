import SwiftUI
import AppKit

struct ClaudeTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var prompt = ""
    @State private var allowEdits = false
    @State private var showAllEvents = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        if let project = store.project(for: store.selection) {
            VStack(spacing: 0) {
                composer(project: project)
                Divider()
                contentArea(project: project)
            }
        } else {
            Text("Select a project to talk to Claude")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func contentArea(project: Project) -> some View {
        let projectSessions = store.sessions.filter {
            $0.projectPath == project.path || $0.projectPath.hasPrefix("\(project.path)/")
        }
        let tasks = store.tasks(forClaudeProject: project.path)
        let hookSessions = store.liveSessions.values
            .filter { s in
                s.projectPath == project.path
                || s.cwd == project.path
                || s.cwd.hasPrefix("\(project.path)/")
            }
            .sorted { $0.lastEventAt > $1.lastEventAt }

        ScrollView {
            LazyVStack(spacing: DSSpace.lg, pinnedViews: []) {
                GStackSpecialistsSection(project: project)
                    .environmentObject(store)

                if !hookSessions.isEmpty {
                    InlineSectionHeader(label: "Live Claude Sessions", count: hookSessions.count, systemImage: "waveform")
                    ForEach(hookSessions) { session in
                        LiveSessionCard(session: session)
                    }
                }

                RecentEventsSection(project: project, showAllEvents: $showAllEvents)
                    .environmentObject(store)

                if !tasks.isEmpty {
                    InlineSectionHeader(label: "Tasks", count: tasks.count, systemImage: "sparkles")
                    ForEach(tasks) { task in ClaudeTaskCard(task: task) }
                }
                if !projectSessions.isEmpty {
                    InlineSectionHeader(label: "Recent Claude Code Sessions", count: projectSessions.count, systemImage: "bubble.left.and.bubble.right")
                    VStack(spacing: 0) {
                        ForEach(projectSessions.prefix(20)) { s in
                            ClaudeSessionRow(session: s)
                            if s.id != projectSessions.prefix(20).last?.id {
                                Divider()
                            }
                        }
                    }
                    .cardSurface()
                }
                if tasks.isEmpty && projectSessions.isEmpty && hookSessions.isEmpty {
                    EmptyStateClaude()
                }
            }
            .padding(DSSpace.lg)
        }
    }

    @ViewBuilder
    private func composer(project: Project) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(DSColor.assistant)
                Text(project.name)
                    .font(DSFont.bodyEmphasized.weight(.semibold))
                Spacer()
                Toggle(isOn: $allowEdits) {
                    Label("Allow edits", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(allowEdits ? "Claude can read AND modify files" : "Read-only: Claude can read & run commands but won't modify files")
            }

            HStack(spacing: DSSpace.xs) {
                Text("Quick:")
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
                Button {
                    Task { await store.generateRecap(for: project) }
                } label: {
                    Label("Recap", systemImage: "newspaper")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task { await store.generateReleaseNotes(for: project) }
                } label: {
                    Label("Release notes", systemImage: "tag")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(alignment: .top, spacing: DSSpace.sm) {
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Ask Claude to do something in \(project.name)…")
                            .foregroundColor(.secondary)
                            .padding(.horizontal, DSSpace.sm).padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $prompt)
                        .focused($promptFocused)
                        .font(DSFont.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 64, maxHeight: 110)
                        .padding(.horizontal, DSSpace.xs).padding(.vertical, 3)
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))

                Button {
                    submit(project: project)
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (⌘↵)")
            }
        }
        .padding(DSSpace.lg)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func history(project: Project) -> some View {
        let tasks = store.tasks(forClaudeProject: project.path)
        if tasks.isEmpty {
            VStack(spacing: DSSpace.md) {
                Image(systemName: "sparkles")
                    .font(DSFont.display)
                    .foregroundColor(.secondary)
                Text("No tasks yet")
                    .font(.headline)
                Text("Type a prompt above and hit Send. Output streams here.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: DSSpace.md) {
                    ForEach(tasks) { task in
                        ClaudeTaskCard(task: task)
                    }
                }
                .padding(DSSpace.lg)
            }
        }
    }

    private func submit(project: Project) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let path = project.path
        let edits = allowEdits
        prompt = ""
        promptFocused = true
        Task {
            await store.runClaude(prompt: text, projectPath: path, allowEdits: edits)
        }
    }
}

private struct ClaudeTaskCard: View {
    let task: ClaudeTask
    @EnvironmentObject var store: DashboardStore
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack(alignment: .top, spacing: DSSpace.sm) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DSSpace.xs) {
                        if task.kind != .general {
                            Label(task.kind.label, systemImage: task.kind.systemImage)
                                .font(DSFont.sectionHeader)
                                .padding(.horizontal, DSSpace.xs)
                                .padding(.vertical, 2)
                                .background(tintColor(task.kind).opacity(0.15))
                                .foregroundColor(tintColor(task.kind))
                                .clipShape(Capsule())
                        }
                        Text(task.kind == .general ? task.prompt : task.kind.label)
                            .font(DSFont.bodyEmphasized)
                            .lineLimit(expanded ? nil : 2)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: DSSpace.xs) {
                        Text(timeAgo(task.startedAt))
                            .font(DSFont.micro).foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary)
                        if task.allowEdits {
                            Label("edits", systemImage: "pencil")
                                .labelStyle(.iconOnly)
                                .font(DSFont.micro)
                                .foregroundColor(DSColor.warning)
                        } else {
                            Label("read-only", systemImage: "eye")
                                .labelStyle(.iconOnly)
                                .font(DSFont.micro)
                                .foregroundColor(.secondary)
                        }
                        if let sid = task.sessionId {
                            Text("·").foregroundColor(.secondary)
                            Text(verbatim: String(sid.prefix(8)))
                                .font(DSFont.mono(.caption2))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                if task.status == .running {
                    Button(role: .destructive) {
                        store.cancelClaude(taskId: task.id, projectPath: task.projectPath)
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(DSColor.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop task")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse" : "Expand")
            }

            if expanded {
                if let phases = task.phases, !phases.isEmpty {
                    PhaseStepperView(
                        phases: phases,
                        currentPhase: task.currentPhase,
                        completedPhases: task.completedPhases
                    )
                    .padding(.bottom, 4)
                }
                if task.output.isEmpty {
                    HStack(spacing: DSSpace.xs) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundColor(.secondary).font(DSFont.label)
                    }
                    .padding(.vertical, DSSpace.xs)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(task.output.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(DSFont.mono(.caption))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 1)
                        }
                    }
                    .padding(DSSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                }
            }
        }
        .padding(DSSpace.md)
        .cardSurface()
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .running:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(DSColor.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(DSColor.warning)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
        }
    }

    private func tintColor(_ kind: ClaudeTask.Kind) -> Color {
        switch kind {
        case .general:        return DSColor.assistant
        case .recap:          return .indigo
        case .releaseNotes:   return DSColor.gitMeta
        case .taskExecution:  return DSColor.info
        case .taskSuggestion: return DSColor.warning
        case .roadmapUpdate:  return DSColor.success
        }
    }
}

private struct InlineSectionHeader: View {
    let label: String
    let count: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: systemImage)
                .font(DSFont.micro)
                .foregroundColor(.secondary)
            Text(label.uppercased())
                .font(DSFont.sectionHeader)
                .tracking(1.2)
                .foregroundColor(.secondary)
            Text(verbatim: "(\(count))")
                .font(DSFont.micro)
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .padding(.top, DSSpace.xs)
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        Button {
            store.openSessionId = session.id
        } label: {
            HStack(spacing: DSSpace.md) {
                Image(systemName: "bubble.left.fill")
                    .foregroundColor(DSColor.assistant)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.firstUserMessage ?? "(no prompt captured)")
                        .font(DSFont.body)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    HStack(spacing: DSSpace.xs) {
                        Text(session.id.prefix(8) + "…")
                            .font(DSFont.mono(.caption2))
                            .foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary).font(DSFont.micro)
                        Text(timeAgo(session.lastActivity))
                            .font(DSFont.micro)
                            .foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary).font(DSFont.micro)
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
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(DSFont.micro)
            }
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
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.sm)
    }
}

// MARK: - Live session card (external terminal sessions via hook events)

private struct LiveSessionCard: View {
    let session: LiveSession
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            // Header row
            HStack(alignment: .center, spacing: DSSpace.sm) {
                LiveStatusDot(active: session.status == .active)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DSSpace.xs) {
                        Text(session.projectName)
                            .font(DSFont.bodyEmphasized)
                            .lineLimit(1)
                        Text(verbatim: "·")
                            .foregroundColor(.secondary)
                        Text(verbatim: String(session.id.prefix(8)))
                            .font(DSFont.mono(.caption2))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: DSSpace.xs) {
                        Text(session.status == .active ? "active" : "ended")
                            .font(DSFont.micro)
                            .foregroundColor(session.status == .active ? DSColor.success : .secondary)
                        if let tool = session.currentTool {
                            Text("·").foregroundColor(.secondary).font(DSFont.micro)
                            Text(tool)
                                .font(DSFont.mono(.caption2))
                                .foregroundColor(DSColor.info)
                        }
                        Text("·").foregroundColor(.secondary).font(DSFont.micro)
                        Text(timeAgo(session.lastEventAt))
                            .font(DSFont.micro)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Collapse" : "Expand")
            }

            if expanded {
                // Last prompt
                if let prompt = session.lastPrompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(DSFont.label)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, DSSpace.sm)
                        .padding(.vertical, DSSpace.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                        .overlay(RoundedRectangle(cornerRadius: DSRadius.small)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                }

                // Recent file activity (last 8)
                let recentFiles = session.liveFiles.suffix(8)
                if !recentFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(recentFiles)) { event in
                            LiveFileRow(event: event)
                        }
                    }
                }

                // Recent commands (last 4)
                let recentCmds = session.liveCommands.suffix(4)
                if !recentCmds.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(recentCmds.enumerated()), id: \.offset) { _, cmd in
                            HStack(spacing: DSSpace.xs) {
                                Image(systemName: "terminal")
                                    .font(DSFont.micro)
                                    .foregroundColor(.secondary)
                                    .frame(width: 12)
                                Text(cmd)
                                    .font(DSFont.mono(.caption2))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .padding(DSSpace.md)
        .cardSurface()
    }
}

/// Shared live-file row used by LiveSessionCard (and factored out for reuse).
private struct LiveFileRow: View {
    let event: LiveFileEvent

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: event.operation.systemImage)
                .font(DSFont.micro)
                .foregroundColor(operationColor)
                .frame(width: 12)
            Text(event.path)
                .font(DSFont.mono(.caption2))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var operationColor: Color {
        switch event.operation {
        case .read:  return .secondary
        case .write: return DSColor.success
        case .edit:  return DSColor.info
        }
    }
}

/// Animated pulsing dot for active sessions; static for ended.
private struct LiveStatusDot: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(active ? DSColor.success : Color.secondary)
            .frame(width: 8, height: 8)
            .opacity(active ? (pulse ? 0.4 : 1.0) : 0.5)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { if active { pulse = true } }
    }
}

private struct EmptyStateClaude: View {
    var body: some View {
        VStack(spacing: DSSpace.md) {
            Image(systemName: "sparkles")
                .font(DSFont.display)
                .foregroundColor(.secondary)
            Text("No Claude activity yet")
                .font(.headline)
            Text("Type a prompt above and hit Send. Past Claude Code sessions for this project will also appear here.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

private struct PhaseStepperView: View {
    let phases: [String]
    let currentPhase: String?
    let completedPhases: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpace.xs) {
                ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
                    let isDone = completedPhases.contains(phase)
                    let isCurrent = phase == currentPhase

                    HStack(spacing: DSSpace.xs) {
                        Text(isDone ? "✓ \(phase)" : phase)
                            .font(DSFont.sectionHeader.weight(isCurrent ? .semibold : .regular))
                            .padding(.horizontal, DSSpace.sm).padding(.vertical, 3)
                            .background(
                                isDone ? DSColor.success.opacity(0.15) :
                                isCurrent ? DSColor.info.opacity(0.18) :
                                Color.secondary.opacity(0.10)
                            )
                            .foregroundColor(
                                isDone ? DSColor.success :
                                isCurrent ? DSColor.info :
                                .secondary
                            )
                            .clipShape(Capsule())
                            .overlay(isCurrent ? Capsule().stroke(DSColor.info.opacity(0.4), lineWidth: 0.8) : nil)

                        if i < phases.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(DSFont.micro)
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Recent Claude events feed

private struct RecentEventsSection: View {
    let project: Project
    @Binding var showAllEvents: Bool
    @EnvironmentObject var store: DashboardStore

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        let filtered = store.recentEvents.filter { $0.projectPath == project.path }
        let displayed = showAllEvents
            ? filtered
            : filtered.filter { $0.category != .tool }
        let capped = Array(displayed.prefix(100))
        if capped.isEmpty { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                HStack(spacing: DSSpace.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                    Text("RECENT CLAUDE EVENTS")
                        .font(DSFont.sectionHeader)
                        .tracking(1.2)
                        .foregroundColor(.secondary)
                    Text(verbatim: "(\(filtered.count))")
                        .font(DSFont.micro)
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer()
                    Button {
                        showAllEvents.toggle()
                    } label: {
                        Text(showAllEvents ? "Show key events" : "Show all")
                            .font(DSFont.micro)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, DSSpace.xs)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(capped) { event in
                        RecentEventRow(event: event, formatter: Self.timeFormatter)
                    }
                }
                .padding(DSSpace.sm)
                .cardSurface()
            }
        )
    }
}

private struct RecentEventRow: View {
    let event: ClaudeIntegrationEvent
    let formatter: DateFormatter

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: categoryIcon)
                .font(DSFont.micro)
                .foregroundColor(categoryColor)
                .frame(width: 12)
            Text(formatter.string(from: event.timestamp))
                .font(DSFont.mono(.caption2))
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(event.detail)
                .font(DSFont.label)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(event.detail)
        }
    }

    private var categoryIcon: String {
        switch event.category {
        case .session: return "play.circle"
        case .prompt:  return "text.bubble"
        case .tool:    return "wrench.and.screwdriver"
        case .git:     return "arrow.triangle.branch"
        case .other:   return "circle.dotted"
        }
    }

    private var categoryColor: Color {
        switch event.category {
        case .session: return DSColor.assistant
        case .prompt:  return DSColor.info
        case .tool:    return .secondary
        case .git:     return DSColor.gitMeta
        case .other:   return .secondary
        }
    }
}

private struct GStackSpecialistsSection: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore

    private let phases: [(String, [GStackPersona])] = [
        ("Plan", GStackSkillLoader.all.filter { ["plan-eng-review"].contains($0.id) }),
        ("Design", GStackSkillLoader.all.filter { ["design-consultation", "design-review"].contains($0.id) }),
        ("Build", GStackSkillLoader.all.filter { ["review", "investigate"].contains($0.id) }),
        ("Quality", GStackSkillLoader.all.filter { ["qa", "cso"].contains($0.id) }),
        ("Release", GStackSkillLoader.all.filter { ["ship", "document-release"].contains($0.id) }),
    ]

    var body: some View {
        let installed = GStackSkillLoader.all.filter { $0.isInstalled }
        if installed.isEmpty { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: DSSpace.md) {
                HStack(spacing: DSSpace.xs) {
                    Image(systemName: "person.3")
                        .font(DSFont.sectionHeader)
                        .foregroundColor(.secondary)
                    Text("AI SPECIALISTS")
                        .font(DSFont.sectionHeader)
                        .tracking(1.2)
                        .foregroundColor(.secondary)
                }

                ForEach(phases, id: \.0) { phase, personas in
                    let available = personas.filter { $0.isInstalled }
                    if !available.isEmpty {
                        VStack(alignment: .leading, spacing: DSSpace.xs) {
                            Text(phase.uppercased())
                                .font(DSFont.sectionHeader)
                                .tracking(1.0)
                                .foregroundColor(.secondary.opacity(0.6))

                            ForEach(available) { persona in
                                SpecialistRow(persona: persona, project: project)
                                    .environmentObject(store)
                            }
                        }
                    }
                }
            }
            .padding(DSSpace.lg)
            .cardSurface()
        )
    }
}

private struct SpecialistRow: View {
    let persona: GStackPersona
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @State private var running = false

    var body: some View {
        HStack(spacing: DSSpace.sm) {
            Image(systemName: persona.systemImage)
                .font(DSFont.title)
                .foregroundColor(.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(persona.role)
                    .font(DSFont.label.weight(.semibold))
                Text(persona.tagline)
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                running = true
                Task {
                    await store.runPersona(persona, projectPath: project.path)
                    store.tabStore.detailTab = .claude
                    running = false
                }
            } label: {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Run")
                        .font(DSFont.micro.weight(.medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(running)
        }
        .padding(.vertical, DSSpace.xs)
    }
}
