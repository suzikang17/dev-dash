import SwiftUI
import AppKit

struct LogsTabView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var serverStore: ServerStore
    @State private var autoScroll = true

    var body: some View {
        if let project = store.project(for: store.selection) {
            let lines = serverStore.logs(for: project.path)
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "terminal")
                        .foregroundColor(.secondary)
                    Text("\(project.name)")
                        .font(DSFont.label.weight(.medium))
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(verbatim: "\(lines.count) lines")
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    if serverStore.managedRunning.contains(project.path) {
                        Button(role: .destructive) {
                            Task { await store.stopServer(for: project.path) }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, DSSpace.md)
                .padding(.vertical, DSSpace.sm)
                .background(.regularMaterial)
                Divider()

                if let running = store.runningTask(for: project.path), !running.liveCommands.isEmpty {
                    LiveCommandsSection(task: running)
                }

                if lines.isEmpty {
                    EmptyLogsView(projectPath: project.path)
                } else {
                    LogScrollView(lines: lines, autoScroll: autoScroll)
                }
            }
        } else {
            Text("Select a project to see logs")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct EmptyLogsView: View {
    let projectPath: String
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var serverStore: ServerStore

    var isExternallyRunning: Bool {
        store.runningPort(for: projectPath) != nil && !serverStore.managedRunning.contains(projectPath)
    }

    var body: some View {
        VStack(spacing: DSSpace.lg) {
            Image(systemName: isExternallyRunning ? "info.circle" : "terminal")
                .font(DSFont.display)
                .foregroundColor(.secondary)

            if isExternallyRunning {
                Text("This server wasn't started by DevDash")
                    .font(.headline)
                Text("macOS can't capture stdout/stderr of processes another tool started. Restart it from here to stream its output.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: DSSpace.sm) {
                    Button {
                        Task {
                            await store.stopServer(for: projectPath)
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await store.startServer(for: projectPath)
                        }
                    } label: {
                        Label("Restart from DevDash", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("No logs yet")
                    .font(.headline)
                Text("Output is captured when you start the dev server from DevDash. Servers you started in another terminal won't stream here.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button {
                    Task { await store.startServer(for: projectPath) }
                } label: {
                    Label("Start dev server", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LogScrollView: View {
    let lines: [String]
    let autoScroll: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(stripAnsi(line))
                            .font(DSFont.mono(.caption))
                            .foregroundColor(colorFor(line))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DSSpace.lg)
                            .padding(.vertical, 2)
                            .id(idx)
                    }
                    Color.clear.frame(height: 1).id(-1)
                }
                .padding(.vertical, DSSpace.sm)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: lines.count) { _, _ in
                if autoScroll {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(-1, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if autoScroll {
                    proxy.scrollTo(-1, anchor: .bottom)
                }
            }
        }
    }

    private func stripAnsi(_ s: String) -> String {
        // Strip ANSI color escape sequences
        guard let regex = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*m") else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private func colorFor(_ line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("✗") { return DSColor.danger }
        if lower.contains("warn") { return DSColor.warning }
        if lower.contains("ready") || lower.contains("compiled") || lower.contains("✓") { return DSColor.success }
        if lower.contains("local:") || lower.contains("localhost") { return DSColor.info }
        return .primary
    }
}

private struct LiveCommandsSection: View {
    let task: ClaudeTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DSSpace.sm) {
                ProgressView().controlSize(.mini)
                Label("Live commands · \(task.currentPhase ?? "Running")", systemImage: "terminal")
                    .font(DSFont.sectionHeader)
                    .foregroundColor(DSColor.info)
                Spacer()
            }
            .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
            .background(DSColor.info.opacity(0.08))

            ForEach(Array(task.liveCommands.suffix(10).enumerated()), id: \.offset) { _, cmd in
                Text(cmd)
                    .font(DSFont.mono(.caption2))
                    .lineLimit(2)
                    .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
                Divider()
            }
        }
        .cardSurface(DSRadius.small)
        .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(DSColor.info.opacity(0.3), lineWidth: 0.5))
        .padding(DSSpace.sm)
    }
}
