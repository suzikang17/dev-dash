import SwiftUI
import AppKit
import SwiftTerm

/// Caches one live login-shell terminal per project so sessions (a running
/// `claude`, a build, an `ssh`) survive tab and project switches. Views ask for
/// `session(for:)`; the same `LocalProcessTerminalView` is returned until the
/// shell exits or the user restarts it.
@MainActor
final class TerminalSessionStore {
    private struct Session {
        let view: LocalProcessTerminalView
        let delegate: ShellTerminalDelegate
    }

    private var sessions: [String: Session] = [:]
    private var terminationToken: NSObjectProtocol?

    private var appearance: TerminalAppearance

    /// The live look, so non-cached terminals can theme themselves from the same
    /// source and re-theme when it changes.
    var currentAppearance: TerminalAppearance { appearance }

    init(appearance: TerminalAppearance) {
        self.appearance = appearance
        // Deterministically tear down every shell on app quit. Without this,
        // forkpty()'d login shells (and their children — a running claude/build)
        // get reparented to launchd and leak past app exit.
        terminationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateAll() }
        }
    }

    deinit {
        if let terminationToken { NotificationCenter.default.removeObserver(terminationToken) }
    }

    /// The terminal for a project, spawning a login shell on first request.
    func session(for projectPath: String) -> LocalProcessTerminalView {
        if let existing = sessions[projectPath] { return existing.view }
        let session = makeShell(cwd: projectPath)
        sessions[projectPath] = session
        return session.view
    }

    /// Kill and respawn a project's shell (for a dead or cluttered session).
    @discardableResult
    func restart(projectPath: String) -> LocalProcessTerminalView {
        if let session = sessions[projectPath] { terminate(session) }
        sessions[projectPath] = nil
        return session(for: projectPath)
    }

    /// Evict sessions whose project no longer exists (deleted/renamed/moved).
    /// Their drawer is unreachable, so they'd otherwise leak fds for the app's life.
    func reconcile(activePaths: Set<String>) {
        for (path, session) in sessions where !activePaths.contains(path) {
            terminate(session)
            sessions[path] = nil
        }
    }

    /// Terminate every cached shell (app quit).
    func terminateAll() {
        for session in sessions.values { terminate(session) }
        sessions.removeAll()
    }

    /// Best-effort teardown of a shell and its job tree. SwiftTerm's terminate()
    /// closes the PTY master (SIGHUP to the foreground job) and SIGTERMs the shell;
    /// we then SIGKILL the shell's process group to catch anything that ignored it.
    private func terminate(_ session: Session) {
        let pid = session.view.process.shellPid
        session.view.process.terminate()
        guard pid > 0 else { return }
        let pgid = getpgid(pid)
        if pgid > 0 { killpg(pgid, SIGKILL) }
        // SwiftTerm cancels its own child-exit monitor in terminate(), so the
        // killed shell would linger as a zombie until app exit. Reap it off the
        // main thread (it's our forkpty child, so waitpid succeeds).
        DispatchQueue.global().async {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
    }

    // MARK: - Appearance, input, focus

    /// Retheme every live terminal (called when the app theme changes).
    func applyTheme(_ theme: AppTheme) {
        appearance.theme = theme
        reapplyAll()
    }

    /// Resize the font of every live terminal (zoom).
    func setFontSize(_ size: Double) {
        appearance.fontSize = CGFloat(size)
        reapplyAll()
    }

    /// Change the monospace family of every live terminal.
    func setFontFamily(_ family: TerminalFontFamily) {
        appearance.fontFamily = family
        reapplyAll()
    }

    /// Change the cursor shape of every live terminal.
    func setCursorStyle(_ style: TerminalCursorStyle) {
        appearance.cursorStyle = style
        reapplyAll()
    }

    /// Change the scrollback line count of every live terminal.
    func setScrollback(_ lines: Int) {
        appearance.scrollback = lines
        reapplyAll()
    }

    private func reapplyAll() {
        for session in sessions.values { applyTerminalAppearance(appearance, to: session.view) }
    }

    // MARK: - Search (find-in-terminal, bound to the active session)

    @discardableResult
    func findNext(_ term: String, in projectPath: String) -> Bool {
        guard let view = sessions[projectPath]?.view, !term.isEmpty else { return false }
        return view.findNext(term, options: SearchOptions(caseSensitive: false), scrollToResult: true)
    }

    @discardableResult
    func findPrevious(_ term: String, in projectPath: String) -> Bool {
        guard let view = sessions[projectPath]?.view, !term.isEmpty else { return false }
        return view.findPrevious(term, options: SearchOptions(caseSensitive: false), scrollToResult: true)
    }

    func clearSearch(in projectPath: String) {
        sessions[projectPath]?.view.clearSearch()
    }

    /// Send text to a project's shell (quick-run buttons). Focuses first so the
    /// keystrokes land and the user can keep typing.
    func send(_ text: String, to projectPath: String) {
        guard let view = sessions[projectPath]?.view else { return }
        view.window?.makeFirstResponder(view)
        view.send(txt: text)
    }

    /// Make a project's terminal the first responder so the user can type at once.
    func focus(projectPath: String) {
        guard let view = sessions[projectPath]?.view else { return }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    private func makeShell(cwd: String) -> Session {
        let view = LocalProcessTerminalView(frame: .zero)
        let delegate = ShellTerminalDelegate()
        // When the shell exits (`exit`/⌃D), drop it so the next open respawns.
        delegate.onTerminated = { [weak self] in self?.sessions[cwd] = nil }
        view.processDelegate = delegate

        // The GUI app's PATH is minimal; a login shell sources the user's
        // profile so lore/claude/node shims resolve.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let shell = env["SHELL"] ?? "/bin/zsh"
        let envArray = env.map { "\($0)=\($1)" }

        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: envArray,
            execName: nil,
            currentDirectory: cwd
        )
        // Apply after startProcess so cursor/scrollback land on the live emulator.
        applyTerminalAppearance(appearance, to: view)
        return Session(view: view, delegate: delegate)
    }
}

final class ShellTerminalDelegate: NSObject, LocalProcessTerminalViewDelegate {
    var onTerminated: (() -> Void)?
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onTerminated?() }
}

/// Bridges an already-running, cached `LocalProcessTerminalView` into SwiftUI
/// without re-spawning its process (unlike `EmbeddedTerminal`, which starts one).
struct TerminalHostView: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView { terminal }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
