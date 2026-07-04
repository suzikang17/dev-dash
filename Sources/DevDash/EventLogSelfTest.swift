import Foundation

/// Headless deterministic checks for the NDJSON operation log (ADR 0013).
///   DevDash --selftest-eventlog
/// Runs entirely in a fresh temp directory, prints PASS/FAIL per check, exits.
enum EventLogSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-eventlog") else { return }
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { print("  ok   \(label)") }
            else     { failures.append(label); print("  FAIL \(label)") }
        }

        checkRoundTrip(check)
        checkUnmatchedRouting(check)
        checkCrashTornTail(check)
        checkAsyncAppendOrdering(check)

        let msg = failures.isEmpty
            ? "eventlog-selftest: ALL PASS"
            : "eventlog-selftest: \(failures.count) FAILURE(S)"
        print(msg)
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func makeTempProject(_ suffix: String) -> String {
        let dir = NSTemporaryDirectory() + "devdash-eventlog-selftest-\(suffix)"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func event(_ n: Int, hook: String = "PreToolUse") -> PersistedEvent {
        PersistedEvent(
            ts: EventLogStore.isoFormatter.string(from: Date(timeIntervalSince1970: 1_800_000_000 + Double(n))),
            id: UUID().uuidString,
            session: "sess-\(n)",
            cwd: "/tmp/proj",
            hook: hook,
            cat: "tool",
            detail: "event \(n)"
        )
    }

    // Round-trip: append N events, read back all fields in order.
    private static func checkRoundTrip(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("rt")
        defer { try? FileManager.default.removeItem(atPath: proj) }
        let path = EventLogStore.filePath(projectPath: proj)

        let e1 = event(1, hook: "SessionStart"), e2 = event(2), e3 = event(3, hook: "Stop")
        for e in [e1, e2, e3] { EventLogStore.appendSync(e, to: path) }

        let back = EventLogStore.read(at: path)
        check(back.count == 3,                    "rt: 3 events read back")
        check(back.first?.hook == "SessionStart", "rt: order preserved (first)")
        check(back.last?.hook == "Stop",          "rt: order preserved (last)")
        check(back.first?.session == "sess-1",    "rt: session round-trip")
        check(back.first?.cwd == "/tmp/proj",     "rt: cwd round-trip")
        check(back.first?.cat == "tool",          "rt: cat round-trip")
        check(back.first?.ts == e1.ts,            "rt: ts round-trip")
        check(back.first?.id == e1.id,            "rt: id round-trip")
        check(path.contains("/.devdash/events/") && path.hasSuffix(".ndjson"),
              "rt: file at .devdash/events/<date>.ndjson")
    }

    // Unmatched events (no project) route to <dir>/_unmatched.ndjson.
    private static func checkUnmatchedRouting(_ check: (Bool, String) -> Void) {
        let dir = makeTempProject("unmatched")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = EventLogStore.filePath(projectPath: nil, unmatchedDirOverride: dir)
        check(path == "\(dir)/_unmatched.ndjson", "unmatched: path is _unmatched.ndjson")
        EventLogStore.appendSync(event(1), to: path)
        check(EventLogStore.read(at: path).count == 1, "unmatched: append+read works")
    }

    // Crash safety: a torn (partial, no-newline) tail must not poison the log
    // or swallow the next append after "reopen".
    private static func checkCrashTornTail(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("crash")
        defer { try? FileManager.default.removeItem(atPath: proj) }
        let path = EventLogStore.filePath(projectPath: proj)

        EventLogStore.appendSync(event(1), to: path)
        // Simulate a kill mid-write: torn JSON fragment with NO trailing newline.
        if let handle = FileHandle(forUpdatingAtPath: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(#"{"ts":"2026-07-04T12:"#.utf8))
            try? handle.close()
        }
        // "Reopen" and keep appending.
        EventLogStore.appendSync(event(2), to: path)

        let back = EventLogStore.read(at: path)
        check(back.count == 2,                 "crash: torn line skipped, both real events survive")
        check(back.last?.detail == "event 2",  "crash: post-crash append lands on its own line")
    }

    // The production path (async serial queue) preserves order and flushes.
    private static func checkAsyncAppendOrdering(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("async")
        defer { try? FileManager.default.removeItem(atPath: proj) }
        for n in 1...20 { EventLogStore.append(event(n), projectPath: proj) }
        EventLogStore.flush()
        let back = EventLogStore.readToday(projectPath: proj)
        check(back.count == 20, "async: all 20 queued appends flushed")
        check(back.map { $0.detail } == (1...20).map { "event \($0)" },
              "async: serial queue preserves order")
    }
}
