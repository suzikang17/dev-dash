import SwiftUI
import AppKit

/// Detail view for a single Claude session, presented as a sheet from
/// HomeView's "Recent Claude Sessions" rows or the per-project Claude tab.
struct SessionDetailView: View {
    let sessionId: String
    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss

    @State private var transcript: SessionTranscript?
    @State private var loading = true
    @State private var tab: Tab = .transcript

    enum Tab: String, CaseIterable, Identifiable {
        case transcript, files, commands, stats
        var id: String { rawValue }
        var label: String {
            switch self {
            case .transcript: return "Transcript"
            case .files: return "Files"
            case .commands: return "Commands"
            case .stats: return "Stats"
            }
        }
        var systemImage: String {
            switch self {
            case .transcript: return "bubble.left.and.bubble.right"
            case .files: return "doc.text"
            case .commands: return "terminal"
            case .stats: return "chart.bar"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.label, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(DSSpace.sm)
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 600)
        .task(id: sessionId) { await load() }
    }

    private var session: ClaudeSession? {
        store.sessions.first(where: { $0.id == sessionId })
    }

    private var digest: SessionDigest? { store.digest(for: sessionId) }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: DSSpace.md) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(DSFont.sectionTitle)
                .foregroundColor(DSColor.assistant)
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text(digest?.title ?? session?.firstUserMessage ?? "Session")
                    .font(DSFont.title)
                    .lineLimit(2)
                HStack(spacing: DSSpace.sm) {
                    if let name = session?.projectName {
                        Label(name, systemImage: "folder")
                            .font(DSFont.micro)
                            .foregroundColor(.secondary)
                    }
                    if let last = session?.lastActivity {
                        Label(timeAgo(last), systemImage: "clock")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                    }
                    if let d = digest {
                        Label(formatDuration(d.durationSeconds), systemImage: "hourglass")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                        Label("\(d.tokens.total.formatted()) tok", systemImage: "circle.hexagongrid")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("claude --resume \(sessionId)", forType: .string)
            } label: {
                Label("Copy resume", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(DSSpace.md)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Reading session…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch tab {
            case .transcript: transcriptView
            case .files: filesView
            case .commands: commandsView
            case .stats: statsView
            }
        }
    }

    @ViewBuilder
    private var transcriptView: some View {
        if let t = transcript, !t.turns.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpace.md) {
                    ForEach(t.turns) { turn in
                        TurnView(turn: turn)
                    }
                }
                .padding(DSSpace.lg)
            }
        } else {
            placeholder("No turns parsed", subtitle: "The JSONL exists but had no user/assistant messages.")
        }
    }

    @ViewBuilder
    private var filesView: some View {
        if let d = digest, !d.filesTouched.isEmpty {
            List(d.filesTouched, id: \.path) { file in
                HStack {
                    Image(systemName: file.writes > 0 ? "pencil" : "eye")
                        .foregroundColor(file.writes > 0 ? DSColor.warning : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: file.path).lastPathComponent)
                            .font(DSFont.bodyEmphasized)
                        Text(DevRoots.shortenPath(file.path))
                            .font(DSFont.mono(.caption))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    if file.reads > 0 {
                        Text(verbatim: "\(file.reads)R")
                            .font(DSFont.monoDigits(.caption))
                            .foregroundColor(.secondary)
                    }
                    if file.writes > 0 {
                        Text(verbatim: "\(file.writes)W")
                            .font(DSFont.monoDigits(.caption))
                            .foregroundColor(DSColor.warning)
                    }
                }
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    }
                    Button("Open file") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                    }
                }
            }
        } else {
            placeholder("No files touched", subtitle: "This session didn't read or write any files.")
        }
    }

    @ViewBuilder
    private var commandsView: some View {
        if let d = digest, !d.commandsRun.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpace.xs) {
                    ForEach(Array(d.commandsRun.enumerated()), id: \.offset) { _, cmd in
                        VStack(alignment: .leading, spacing: 2) {
                            if let ts = cmd.timestamp {
                                Text(timeAgo(ts))
                                    .font(DSFont.monoDigits(.caption2))
                                    .foregroundColor(.secondary)
                            }
                            Text(cmd.command)
                                .font(DSFont.mono(.caption))
                                .textSelection(.enabled)
                                .padding(DSSpace.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                        }
                    }
                }
                .padding(DSSpace.lg)
            }
        } else {
            placeholder("No commands", subtitle: "This session didn't run Bash.")
        }
    }

    @ViewBuilder
    private var statsView: some View {
        if let d = digest {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    StatGroup(title: "Tokens") {
                        StatLine(label: "Input", value: d.tokens.input.formatted())
                        StatLine(label: "Output", value: d.tokens.output.formatted())
                        StatLine(label: "Cache create", value: d.tokens.cacheCreate.formatted())
                        StatLine(label: "Cache read", value: d.tokens.cacheRead.formatted())
                        Divider()
                        StatLine(label: "Total", value: d.tokens.total.formatted(), bold: true)
                    }
                    StatGroup(title: "Activity") {
                        StatLine(label: "User messages", value: String(d.userMessageCount))
                        StatLine(label: "Assistant messages", value: String(d.assistantMessageCount))
                        StatLine(label: "Files touched", value: String(d.filesTouched.count))
                        StatLine(label: "Commands run", value: String(d.commandsRun.count))
                        StatLine(label: "Duration", value: formatDuration(d.durationSeconds))
                    }
                    if !d.toolCallsByName.isEmpty {
                        StatGroup(title: "Tool calls") {
                            ForEach(d.toolCallsByName.sorted { $0.value > $1.value }, id: \.key) { name, count in
                                StatLine(label: name, value: String(count))
                            }
                        }
                    }
                }
                .padding(DSSpace.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            placeholder("No digest", subtitle: "Re-open after the session has finished parsing.")
        }
    }

    private func placeholder(_ title: String, subtitle: String) -> some View {
        VStack(spacing: DSSpace.sm) {
            Image(systemName: "doc.questionmark").font(DSFont.display).foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(subtitle).foregroundColor(.secondary).font(DSFont.label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        transcript = await store.transcript(for: sessionId)
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return "\(h)h\(m)m"
    }
}

private struct TurnView: View {
    let turn: SessionTranscript.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.xs) {
                Image(systemName: roleIcon)
                    .foregroundColor(roleColor)
                    .font(DSFont.micro)
                Text(roleLabel)
                    .font(DSFont.micro.weight(.semibold))
                    .foregroundColor(roleColor)
                if let ts = turn.timestamp {
                    Text(verbatim: shortTime(ts))
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let t = turn.tokens, t.total > 0 {
                    Text(verbatim: "\(t.total.formatted()) tok")
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(.secondary)
                }
            }
            ForEach(Array(turn.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, role: turn.role)
            }
        }
        .padding(DSSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(roleColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium).stroke(roleColor.opacity(0.18), lineWidth: 0.5))
    }

    private var roleLabel: String { turn.role.rawValue.capitalized }

    private var roleIcon: String {
        switch turn.role {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .system: return "gearshape"
        case .tool: return "wrench.and.screwdriver"
        case .attachment: return "paperclip"
        }
    }

    private var roleColor: Color {
        switch turn.role {
        case .user: return DSColor.user
        case .assistant: return DSColor.assistant
        case .system: return .gray
        case .tool: return DSColor.warning
        case .attachment: return DSColor.gitMeta
        }
    }

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

private struct BlockView: View {
    let block: SessionTranscript.Block
    let role: SessionTranscript.Turn.Role

    @State private var expanded = false

    var body: some View {
        switch block {
        case .text(let t):
            Text(t)
                .font(DSFont.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking(let t):
            DisclosureGroup {
                Text(t)
                    .font(DSFont.label)
                    .foregroundColor(.secondary)
                    .padding(DSSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
            }

        case .toolUse(let name, let summary, let fullInput):
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(fullInput)
                        .font(DSFont.mono(.caption))
                        .textSelection(.enabled)
                        .padding(DSSpace.sm)
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
            } label: {
                HStack(spacing: DSSpace.xs) {
                    Image(systemName: toolIcon(name))
                        .font(DSFont.micro)
                        .foregroundColor(DSColor.warning)
                    Text(name)
                        .font(DSFont.mono(.caption2).weight(.semibold))
                        .foregroundColor(DSColor.warning)
                    Text(summary)
                        .font(DSFont.mono(.caption2))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

        case .toolResult(let text, let isError):
            DisclosureGroup {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(DSFont.mono(.caption))
                        .textSelection(.enabled)
                        .padding(DSSpace.sm)
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
            } label: {
                Label(isError ? "Tool error" : "Tool result", systemImage: isError ? "exclamationmark.triangle" : "arrow.turn.down.right")
                    .font(DSFont.micro)
                    .foregroundColor(isError ? DSColor.danger : .secondary)
            }

        case .attachment(let name, let content):
            DisclosureGroup {
                Text(content)
                    .font(DSFont.mono(.caption))
                    .textSelection(.enabled)
                    .padding(DSSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSColor.gitMeta.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
            } label: {
                Label(name, systemImage: "paperclip")
                    .font(DSFont.micro)
                    .foregroundColor(DSColor.gitMeta)
            }
        }
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "Read", "NotebookRead": return "doc.text"
        case "Write", "Edit", "NotebookEdit": return "pencil"
        case "Bash": return "terminal"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.questionmark"
        case "WebFetch", "WebSearch": return "globe"
        case "Task": return "person.crop.circle"
        default: return "wrench.and.screwdriver"
        }
    }
}

private struct StatGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            SectionHeader(title)
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                content()
            }
            .padding(DSSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

private struct StatLine: View {
    let label: String
    let value: String
    var bold: Bool = false
    var body: some View {
        HStack {
            Text(label)
                .font(DSFont.label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(DSFont.monoDigits(.caption).weight(bold ? .semibold : .regular))
        }
    }
}
