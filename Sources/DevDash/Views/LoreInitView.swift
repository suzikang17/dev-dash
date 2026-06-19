import SwiftUI

/// Empty state shown on lore-backed tabs when a project hasn't initialized lore.
/// Offers one-click `lore init docs`, degrading to copy-paste instructions if the
/// CLI isn't on PATH or the command fails.
struct LoreInitView: View {
    let projectPath: String
    /// Called after lore is successfully initialized so the host tab can reload.
    let onInitialized: () -> Void

    @State private var running = false
    @State private var failure: String? = nil
    @State private var cliMissing = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                Text("Lore isn't set up for this project")
                    .font(.headline)
                Text("Lore tracks tasks, devlogs, decisions, and ideas as plain Markdown in docs/. Initialize it to start using this tab.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            if cliMissing {
                fallback
            } else {
                Button {
                    Task { await initialize() }
                } label: {
                    HStack(spacing: 6) {
                        if running { ProgressView().controlSize(.small) }
                        Text(running ? "Initializing…" : "Initialize lore")
                    }
                    .frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(running)

                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    fallback
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Copy-pasteable command shown when one-click init is unavailable or failed.
    private var fallback: some View {
        VStack(spacing: 4) {
            Text("Or run this from the project root:")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text("lore init docs")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("lore init docs", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
        }
    }

    private func initialize() async {
        failure = nil
        running = true
        defer { running = false }

        guard await LoreRunner.lorePath() != nil else {
            cliMissing = true
            return
        }
        let result = await LoreRunner.runInit(projectPath: projectPath)
        if result.ok {
            onInitialized()
        } else {
            failure = "lore init didn't complete." + (result.output.map { "\n\($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? "")
        }
    }
}
