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

    init() {
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

/// VS Code–style bottom terminal panel: drag-to-resize handle, a header with the
/// project's cwd plus restart/close, and the project's live shell filling the rest.
struct TerminalDrawer: View {
    @EnvironmentObject var store: DashboardStore
    let project: Project
    @Binding var height: CGFloat

    @State private var dragStartHeight: CGFloat? = nil
    @State private var restartTick = 0

    private let minHeight: CGFloat = 120
    private let maxHeight: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            header
            Divider()
            TerminalHostView(terminal: store.terminals.session(for: project.path))
                .id("\(project.path)#\(restartTick)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .overlay(Divider(), alignment: .top)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStartHeight ?? height
                        if dragStartHeight == nil { dragStartHeight = start }
                        height = min(maxHeight, max(minHeight, start - value.translation.height))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(project.name)
                .font(.system(size: 11, weight: .semibold))
            Text(abbreviatedPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                store.terminals.restart(projectPath: project.path)
                restartTick += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Restart shell")
            Button {
                store.terminalOpen = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close terminal (⌘`)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var abbreviatedPath: String {
        let home = NSHomeDirectory()
        return project.path.hasPrefix(home)
            ? "~" + project.path.dropFirst(home.count)
            : project.path
    }
}
