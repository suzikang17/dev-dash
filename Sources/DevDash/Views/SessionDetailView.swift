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
            .padding(10)
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 22))
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 4) {
                Text(digest?.title ?? session?.firstUserMessage ?? "Session")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    if let name = session?.projectName {
                        Label(name, systemImage: "folder")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let last = session?.lastActivity {
                        Label(timeAgo(last), systemImage: "clock")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    if let d = digest {
                        Label(formatDuration(d.durationSeconds), systemImage: "hourglass")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                        Label("\(d.tokens.total.formatted()) tok", systemImage: "circle.hexagongrid")
                            .font(.system(size: 11).monospacedDigit())
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
        .padding(14)
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(t.turns) { turn in
                        TurnView(turn: turn)
                    }
                }
                .padding(16)
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
                        .foregroundColor(file.writes > 0 ? .orange : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: file.path).lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                        Text(DevRoots.shortenPath(file.path))
                            .font(.system(size: 11).monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    if file.reads > 0 {
                        Text(verbatim: "\(file.reads)R")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    if file.writes > 0 {
                        Text(verbatim: "\(file.writes)W")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.orange)
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
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(d.commandsRun.enumerated()), id: \.offset) { _, cmd in
                        VStack(alignment: .leading, spacing: 2) {
                            if let ts = cmd.timestamp {
                                Text(timeAgo(ts))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            Text(cmd.command)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(16)
            }
        } else {
            placeholder("No commands", subtitle: "This session didn't run Bash.")
        }
    }

    @ViewBuilder
    private var statsView: some View {
        if let d = digest {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            placeholder("No digest", subtitle: "Re-open after the session has finished parsing.")
        }
    }

    private func placeholder(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.questionmark").font(.system(size: 28)).foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(subtitle).foregroundColor(.secondary).font(.system(size: 12))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: roleIcon)
                    .foregroundColor(roleColor)
                    .font(.system(size: 11))
                Text(roleLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(roleColor)
                if let ts = turn.timestamp {
                    Text(verbatim: shortTime(ts))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let t = turn.tokens, t.total > 0 {
                    Text(verbatim: "\(t.total.formatted()) tok")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            ForEach(Array(turn.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, role: turn.role)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(roleColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(roleColor.opacity(0.18), lineWidth: 0.5))
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
        case .user: return .blue
        case .assistant: return .purple
        case .system: return .gray
        case .tool: return .orange
        case .attachment: return .teal
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
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking(let t):
            DisclosureGroup {
                Text(t)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

        case .toolUse(let name, let summary, let fullInput):
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(fullInput)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: toolIcon(name))
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(name)
                        .font(.system(size: 11, weight: .semibold).monospaced())
                        .foregroundColor(.orange)
                    Text(summary)
                        .font(.system(size: 11).monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

        case .toolResult(let text, let isError):
            DisclosureGroup {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } label: {
                Label(isError ? "Tool error" : "Tool result", systemImage: isError ? "exclamationmark.triangle" : "arrow.turn.down.right")
                    .font(.system(size: 11))
                    .foregroundColor(isError ? .red : .secondary)
            }

        case .attachment(let name, let content):
            DisclosureGroup {
                Text(content)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.teal.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } label: {
                Label(name, systemImage: "paperclip")
                    .font(.system(size: 11))
                    .foregroundColor(.teal)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
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
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: bold ? .semibold : .regular).monospacedDigit())
        }
    }
}
