import SwiftUI
import AppKit
import SwiftTerm

/// Wraps SwiftTerm's `LocalProcessTerminalView` so we can host a real terminal
/// session (running nvim, or any TUI app) inside SwiftUI.
struct EmbeddedTerminal: NSViewRepresentable {
    /// Absolute path of the binary to launch (e.g. /usr/local/bin/nvim).
    let executable: String
    /// Arguments to pass.
    let arguments: [String]
    /// Working directory.
    let cwd: String?
    /// Optional environment overrides.
    let environment: [String: String]

    init(executable: String,
         arguments: [String] = [],
         cwd: String? = nil,
         environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        // Inherit the user's PATH so fnm/nvm/asdf-installed nvim is found
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        for (k, v) in environment { env[k] = v }
        let envArray = env.map { "\($0)=\($1)" }
        view.startProcess(
            executable: executable,
            args: arguments,
            environment: envArray,
            execName: nil,
            currentDirectory: cwd
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

/// Convenience: spawn nvim editing a specific file. Resolves the binary by
/// looking in common install locations + scanning PATH so fnm/asdf shims work.
extension EmbeddedTerminal {
    static func neovim(filePath: String, readOnly: Bool = false) -> EmbeddedTerminal? {
        guard let nvim = resolveNvim() else { return nil }
        let dir = (filePath as NSString).deletingLastPathComponent

        // Stash swap files in a DevDash-owned tmp dir so the project tree stays clean
        // (nvim writes .swp next to the file by default; can clutter Files tree).
        let swapDir = "\(NSTemporaryDirectory())devdash-nvim-swap"
        try? FileManager.default.createDirectory(atPath: swapDir, withIntermediateDirectories: true)

        var args: [String] = [
            "-c", "set directory=\(swapDir)//",
            "-c", "set backupdir=\(swapDir)//",
            "-c", "set undodir=\(swapDir)//",
        ]
        if readOnly {
            // -R: readonly. nomodifiable belt-and-suspenders so :w fails too.
            args.append(contentsOf: ["-R", "-c", "set nomodifiable"])
        }
        args.append(filePath)

        return EmbeddedTerminal(
            executable: nvim,
            arguments: args,
            cwd: dir
        )
    }

    private static func resolveNvim() -> String? {
        let candidates = [
            "/usr/local/bin/nvim",
            "/opt/homebrew/bin/nvim",
            "\(NSHomeDirectory())/.local/bin/nvim",
            "/usr/bin/nvim"
        ]
        let fm = FileManager.default
        for p in candidates where fm.fileExists(atPath: p) { return p }
        // Fall back to login-shell PATH lookup
        return resolveViaShell("nvim")
    }

    private static func resolveViaShell(_ binary: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-ic", "command -v \(binary)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (result?.isEmpty == false) ? result : nil
        } catch {
            return nil
        }
    }
}
