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
    /// Resolved look (palette/font/cursor/scrollback). Defaults to the persisted
    /// app settings so nvim matches the rest of the app.
    let appearance: TerminalAppearance
    /// Use SwiftTerm's standard xterm 256-color ramp instead of the app-wide
    /// `.base16Lab` strategy. The base16 ramp interpolates the 232–255 greys from
    /// background→foreground, which inverts them on a light theme and wrecks tools
    /// that emit raw 256-color indices (glow). Read-only viewers opt in.
    let standardAnsiPalette: Bool

    init(executable: String,
         arguments: [String] = [],
         cwd: String? = nil,
         environment: [String: String] = [:],
         appearance: TerminalAppearance = .current(),
         standardAnsiPalette: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.appearance = appearance
        self.standardAnsiPalette = standardAnsiPalette
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // Start with a real frame, NOT .zero. SwiftTerm derives its column count
        // from the frame at startProcess time; at .zero the PTY reports ~0 columns
        // and one-shot renderers like bat/glow hard-wrap every couple characters.
        // A generous initial size gives them a sane width; interactive apps (nvim)
        // reflow via SIGWINCH once SwiftUI resizes the view to the real pane.
        let initial = NSRect(x: 0, y: 0, width: 1000, height: 760)
        let view = LocalProcessTerminalView(frame: initial)
        view.processDelegate = context.coordinator
        // Inherit the user's PATH so fnm/nvm/asdf-installed nvim is found
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        // Advertise 24-bit color so truecolor-capable renderers (bat) emit exact
        // RGB that SwiftTerm draws directly, bypassing the palette entirely.
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        for (k, v) in environment { env[k] = v }
        let envArray = env.map { "\($0)=\($1)" }
        // Apply font/palette first so column count uses real metrics and the 16
        // ANSI colors are installed.
        applyTerminalAppearance(appearance, to: view)
        // glow renders with raw 256-color indices, so it depends on the grey ramp
        // being standard (low=dark, high=light). The app-wide .base16Lab strategy
        // inverts that ramp on a light theme; switch the read-only viewer to the
        // standard xterm ramp. Set before startProcess so the first bytes parse
        // against the correct palette.
        if standardAnsiPalette {
            view.getTerminal().ansi256PaletteStrategy = .xterm
        }
        // For one-shot read-only renderers the cursor follows the streamed output
        // to the bottom, leaving the view scrolled past the start. Snap back to the
        // top once the process exits (see processTerminated).
        context.coordinator.scrollToTopOnExit = standardAnsiPalette
        view.startProcess(
            executable: executable,
            args: arguments,
            environment: envArray,
            execName: nil,
            currentDirectory: cwd
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Live re-theme: when the app theme or terminal settings change, SwiftUI
        // re-creates this representable with a fresh `appearance` and calls us with
        // the existing view, so the open nvim session repaints without respawning.
        applyTerminalAppearance(appearance, to: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        /// Set for read-only viewers (glow/bat): scroll back to the top once the
        /// renderer exits so the document starts at the beginning, not the end.
        var scrollToTopOnExit = false

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard scrollToTopOnExit else { return }
            // Delay so any trailing output has flushed; otherwise late bytes would
            // auto-scroll back to the bottom right after we reset.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak source] in
                (source as? LocalProcessTerminalView)?.scroll(toPosition: 0)
            }
        }
    }
}

/// Convenience: spawn nvim editing a specific file. Resolves the binary by
/// looking in common install locations + scanning PATH so fnm/asdf shims work.
extension EmbeddedTerminal {
    static func neovim(filePath: String, readOnly: Bool = false,
                       appearance: TerminalAppearance = .current()) -> EmbeddedTerminal? {
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
            cwd: dir,
            appearance: appearance
        )
    }

    /// Read-only "Source" viewer: glow renders markdown with styled output;
    /// bat syntax-highlights everything else. Both run as terminal pagers so we
    /// inherit scrolling/theming from SwiftTerm. Returns nil if the tool is missing.
    static func sourceViewer(filePath: String, isMarkdown: Bool,
                             appearance: TerminalAppearance = .current()) -> EmbeddedTerminal? {
        let dir = (filePath as NSString).deletingLastPathComponent
        if isMarkdown, let glow = resolveBinary("glow") {
            // No -p (pager): dump styled output straight into the terminal so
            // SwiftTerm's own scrollback handles trackpad/scroll-wheel scrolling.
            // -s: pick the built-in style that matches the app theme — glow can't
            // auto-detect the bg inside SwiftTerm and otherwise defaults to dark.
            let style = appearance.theme == .light ? "light" : "dark"
            return EmbeddedTerminal(executable: glow, arguments: ["-s", style, filePath],
                                    cwd: dir, appearance: appearance, standardAnsiPalette: true)
        }
        if let bat = resolveBinary("bat") {
            // --paging=never: same reasoning — let SwiftTerm scroll, not an inner
            // pager. Match the syntax theme to the app theme so highlighting stays
            // legible on a light background (bat's default theme is tuned for dark).
            let theme = appearance.theme == .light ? "GitHub" : "Monokai Extended"
            return EmbeddedTerminal(
                executable: bat,
                arguments: ["--paging=never", "--theme=\(theme)",
                            "--style=numbers,changes", "--color=always", filePath],
                cwd: dir, appearance: appearance, standardAnsiPalette: true)
        }
        return nil
    }

    private static func resolveNvim() -> String? { resolveBinary("nvim") }

    /// Resolve a CLI binary by checking common Homebrew/local install dirs first,
    /// then falling back to a login-shell PATH lookup (so fnm/asdf shims work).
    static func resolveBinary(_ name: String) -> String? {
        let candidates = [
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "\(NSHomeDirectory())/.nix-profile/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        let fm = FileManager.default
        for p in candidates where fm.fileExists(atPath: p) { return p }
        // Fall back to login-shell PATH lookup
        return resolveViaShell(name)
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
