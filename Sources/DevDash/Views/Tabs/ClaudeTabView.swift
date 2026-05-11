import SwiftUI
import AppKit

struct ClaudeTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var prompt = ""
    @State private var allowEdits = false
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

        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: []) {
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
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                }
                GStackSpecialistsSection(project: project)
                    .environmentObject(store)

                if tasks.isEmpty && projectSessions.isEmpty {
                    EmptyStateClaude()
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func composer(project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                Text(project.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle(isOn: $allowEdits) {
                    Label("Allow edits", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(allowEdits ? "Claude can read AND modify files" : "Read-only: Claude can read & run commands but won't modify files")
            }

            HStack(spacing: 6) {
                Text("Quick:")
                    .font(.system(size: 11))
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

            HStack(alignment: .top, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Ask Claude to do something in \(project.name)…")
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $prompt)
                        .focused($promptFocused)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 64, maxHeight: 110)
                        .padding(.horizontal, 4).padding(.vertical, 3)
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))

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
        .padding(14)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func history(project: Project) -> some View {
        let tasks = store.tasks(forClaudeProject: project.path)
        if tasks.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
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
                LazyVStack(spacing: 12) {
                    ForEach(tasks) { task in
                        ClaudeTaskCard(task: task)
                    }
                }
                .padding(14)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if task.kind != .general {
                            Label(task.kind.label, systemImage: task.kind.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tintColor(task.kind).opacity(0.15))
                                .foregroundColor(tintColor(task.kind))
                                .clipShape(Capsule())
                        }
                        Text(task.kind == .general ? task.prompt : task.kind.label)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(expanded ? nil : 2)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 6) {
                        Text(timeAgo(task.startedAt))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary)
                        if task.allowEdits {
                            Label("edits", systemImage: "pencil")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        } else {
                            Label("read-only", systemImage: "eye")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        if let sid = task.sessionId {
                            Text("·").foregroundColor(.secondary)
                            Text(verbatim: String(sid.prefix(8)))
                                .font(.system(size: 11).monospaced())
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
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
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
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundColor(.secondary).font(.system(size: 12))
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(task.output.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 1)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .running:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
        }
    }

    private func tintColor(_ kind: ClaudeTask.Kind) -> Color {
        switch kind {
        case .general:        return .purple
        case .recap:          return .indigo
        case .releaseNotes:   return .teal
        case .taskExecution:  return .blue
        case .taskSuggestion: return .orange
        case .roadmapUpdate:  return .green
        }
    }
}

private struct InlineSectionHeader: View {
    let label: String
    let count: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)
            Text(verbatim: "(\(count))")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .padding(.top, 4)
    }
}

private struct ClaudeSessionRow: View {
    let session: ClaudeSession
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        Button {
            store.openSessionId = session.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.fill")
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.firstUserMessage ?? "(no prompt captured)")
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    HStack(spacing: 6) {
                        Text(session.id.prefix(8) + "…")
                            .font(.system(size: 10).monospaced())
                            .foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary).font(.system(size: 10))
                        Text(timeAgo(session.lastActivity))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("·").foregroundColor(.secondary).font(.system(size: 10))
                        if let d = store.digest(for: session.id) {
                            Text(verbatim: "\(d.tokens.total.formatted()) tok")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(.secondary)
                        } else {
                            Text(verbatim: "\(session.messageCount) msgs")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct EmptyStateClaude: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
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
            HStack(spacing: 4) {
                ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
                    let isDone = completedPhases.contains(phase)
                    let isCurrent = phase == currentPhase

                    HStack(spacing: 4) {
                        Text(isDone ? "✓ \(phase)" : phase)
                            .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(
                                isDone ? Color.green.opacity(0.15) :
                                isCurrent ? Color.blue.opacity(0.18) :
                                Color.secondary.opacity(0.10)
                            )
                            .foregroundColor(
                                isDone ? .green :
                                isCurrent ? .blue :
                                .secondary
                            )
                            .clipShape(Capsule())
                            .overlay(isCurrent ? Capsule().stroke(Color.blue.opacity(0.4), lineWidth: 0.8) : nil)

                        if i < phases.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                }
            }
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "person.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("AI SPECIALISTS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(.secondary)
                }

                ForEach(phases, id: \.0) { phase, personas in
                    let available = personas.filter { $0.isInstalled }
                    if !available.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(phase.uppercased())
                                .font(.system(size: 9, weight: .semibold))
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
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
        )
    }
}

private struct SpecialistRow: View {
    let persona: GStackPersona
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @State private var running = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: persona.systemImage)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(persona.role)
                    .font(.system(size: 12, weight: .semibold))
                Text(persona.tagline)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                running = true
                Task {
                    await store.runPersona(persona, projectPath: project.path)
                    store.detailTab = .claude
                    running = false
                }
            } label: {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Run")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(running)
        }
        .padding(.vertical, 4)
    }
}
