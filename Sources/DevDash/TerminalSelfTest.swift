import Foundation
import AppKit

/// Headless runtime check for the terminal session lifecycle. Runs inside the
/// real app binary (real AppKit + real TerminalSessionStore) when launched with
/// `--selftest-terminal`, then exits. Invoked from `DevDashApp.init()` before any
/// window is built. This is the closest we can get to testing the PTY spawn/kill
/// paths without a human clicking the GUI.
enum TerminalSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-terminal") else { return }
        _ = NSApplication.shared   // ensure the AppKit app object exists
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    private static func run() -> Never {
        var failures: [String] = []
        func check(_ cond: Bool, _ msg: String) {
            print((cond ? "  ok   " : "  FAIL ") + msg)
            if !cond { failures.append(msg) }
        }

        let store = TerminalSessionStore()
        let dirA = NSTemporaryDirectory() + "devdash-selftest-A"
        let dirB = NSTemporaryDirectory() + "devdash-selftest-B"
        for d in [dirA, dirB] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }

        // 1. Spawn a session → a live shell.
        let viewA = store.session(for: dirA)
        let pidA = viewA.process.shellPid
        check(pidA > 0, "spawn returns a valid shell pid (\(pidA))")
        check(waitFor({ isAlive(pidA) }, timeout: 2), "shell \(pidA) is alive after spawn")

        // 2. Caching → same view + pid for the same project path.
        let viewA2 = store.session(for: dirA)
        check(viewA2 === viewA && viewA2.process.shellPid == pidA,
              "session(for:) is cached per project (no respawn)")

        // 3. Restart → old shell dies, a new one spawns with a different pid.
        let viewAR = store.restart(projectPath: dirA)
        let pidAR = viewAR.process.shellPid
        check(pidAR != pidA, "restart spawns a new pid (\(pidA) -> \(pidAR))")
        check(waitFor({ !isAlive(pidA) }, timeout: 3), "old shell \(pidA) is dead after restart")
        check(waitFor({ isAlive(pidAR) }, timeout: 2), "new shell \(pidAR) is alive after restart")

        // 4. Reconcile → evicts + kills a session whose project no longer exists,
        //    leaves the still-active one alone.
        let viewB = store.session(for: dirB)
        let pidB = viewB.process.shellPid
        check(waitFor({ isAlive(pidB) }, timeout: 2), "second project shell \(pidB) is alive")
        store.reconcile(activePaths: [dirA])   // dirB no longer active
        check(waitFor({ !isAlive(pidB) }, timeout: 3), "reconcile killed the evicted shell \(pidB)")
        check(isAlive(pidAR), "reconcile kept the active shell \(pidAR) alive")

        // 5. terminateAll → everything is torn down (the app-quit path).
        store.terminateAll()
        check(waitFor({ !isAlive(pidAR) }, timeout: 3), "terminateAll killed the remaining shell \(pidAR)")

        for d in [dirA, dirB] { try? FileManager.default.removeItem(atPath: d) }

        print(failures.isEmpty
              ? "\nSELFTEST PASS"
              : "\nSELFTEST FAIL — \(failures.count) failure(s)")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// A killed-but-unreaped child reads as alive via kill(0), so this asserts
    /// full teardown: the pid must be gone (reaped), not merely a zombie.
    private static func isAlive(_ pid: pid_t) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    /// Poll a condition while spinning the run loop so SwiftTerm's child-reaping
    /// source can fire (a killed process reads as alive until reaped).
    @MainActor
    private static func waitFor(_ cond: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return cond()
    }
}
