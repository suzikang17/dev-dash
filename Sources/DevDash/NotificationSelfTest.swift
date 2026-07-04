import Foundation

/// Headless deterministic checks for the notification store + NDJSON log.
///   DevDash --selftest-notifications
/// Runs entirely in a fresh temp directory, prints PASS/FAIL per check, exits.
enum NotificationSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-notifications") else { return }
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { print("  ok   \(label)") }
            else     { failures.append(label); print("  FAIL \(label)") }
        }

        checkLogRoundTrip(check)
        checkRestoreWindowAndCap(check)
        checkGatingAndUnread(check)

        let msg = failures.isEmpty
            ? "notifications-selftest: ALL PASS"
            : "notifications-selftest: \(failures.count) FAILURE(S)"
        print(msg)
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func makeTempDir(_ suffix: String) -> String {
        let dir = NSTemporaryDirectory() + "devdash-notif-selftest-\(suffix)"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func notif(_ n: Int, kind: NotificationKind = .taskDone,
                              date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AppNotification {
        AppNotification(
            id: UUID(), kind: kind, date: date.addingTimeInterval(Double(n)),
            title: "title \(n)", body: "body \(n)",
            projectPath: "/tmp/proj", tab: "tasks", taskId: n % 2 == 0 ? "0001" : nil
        )
    }

    // Round-trip: append N notifications, read back all fields in order.
    private static func checkLogRoundTrip(_ check: (Bool, String) -> Void) {
        let dir = makeTempDir("rt")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let path = NotificationLogStore.filePath(dir: dir, date: base)

        let n1 = notif(1, kind: .needsInput), n2 = notif(2), n3 = notif(3, kind: .prMerged)
        for n in [n1, n2, n3] { NotificationLogStore.appendSync(n, to: path) }

        let back = NotificationLogStore.read(at: path)
        check(back.count == 3,                          "rt: 3 notifications read back")
        check(back.first?.kind == .needsInput,          "rt: kind round-trip (first)")
        check(back.last?.kind == .prMerged,             "rt: kind round-trip (last)")
        check(back.first?.title == "title 1",           "rt: title round-trip")
        check(back.first?.projectPath == "/tmp/proj",   "rt: projectPath round-trip")
        check(back.first?.tab == "tasks",               "rt: tab round-trip")
        check(back.first?.taskId == nil,                "rt: nil taskId round-trip")
        check(back.first.map { abs($0.date.timeIntervalSince(n1.date)) < 1.0 } == true,
              "rt: date round-trip")
        check(path.hasSuffix(".ndjson"),                "rt: .ndjson file naming")

        // Torn tail must not poison the log (same crash-safety contract as EventLogStore).
        if let handle = FileHandle(forUpdatingAtPath: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(#"{"id":"tor"#.utf8))
            try? handle.close()
        }
        NotificationLogStore.appendSync(notif(4), to: path)
        check(NotificationLogStore.read(at: path).count == 4,
              "rt: torn line skipped, post-crash append survives")
    }

    // Pure gating + unread logic on NotificationStore statics.
    private static func checkGatingAndUnread(_ check: (Bool, String) -> Void) {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = (0..<5).map { notif($0, date: base) }   // dates base+0 … base+4

        check(NotificationStore.unreadCount(feed: feed, lastSeenAt: base.addingTimeInterval(2)) == 2,
              "unread: items strictly newer than lastSeenAt")
        check(NotificationStore.unreadCount(feed: feed, lastSeenAt: base.addingTimeInterval(100)) == 0,
              "unread: none when lastSeenAt is newest")
        check(NotificationStore.unreadCount(feed: [], lastSeenAt: .distantPast) == 0,
              "unread: empty feed")

        let kinds: Set<NotificationKind> = [.taskDone, .needsInput]
        check(NotificationStore.shouldBanner(kind: .taskDone, bannerKinds: kinds, masterEnabled: true),
              "gate: banner when kind enabled + master on")
        check(!NotificationStore.shouldBanner(kind: .taskDone, bannerKinds: kinds, masterEnabled: false),
              "gate: master off suppresses banner")
        check(!NotificationStore.shouldBanner(kind: .prMerged, bannerKinds: kinds, masterEnabled: true),
              "gate: kind off suppresses banner")

        check(NotificationStore.shouldRecord(kind: .taskDone, bannerKinds: []),
              "gate: non-idle kinds always recorded in feed")
        check(!NotificationStore.shouldRecord(kind: .sessionIdle, bannerKinds: []),
              "gate: sessionIdle hidden from feed when disabled")
        check(NotificationStore.shouldRecord(kind: .sessionIdle, bannerKinds: [.sessionIdle]),
              "gate: sessionIdle recorded when enabled")

        check(NotificationStore.defaultBannerKinds == Set(NotificationKind.allCases).subtracting([.sessionIdle]),
              "gate: default = all kinds except sessionIdle")
    }

    // Restore: last-3-days window, newest first, 300 cap.
    private static func checkRestoreWindowAndCap(_ check: (Bool, String) -> Void) {
        let dir = makeTempDir("restore")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400

        // 2 notifications today, 2 yesterday, 2 two days ago, 2 four days ago (outside window)
        for dayOffset in [0.0, 1.0, 2.0, 4.0] {
            let d = now.addingTimeInterval(-dayOffset * day)
            let path = NotificationLogStore.filePath(dir: dir, date: d)
            for n in 0..<2 {
                NotificationLogStore.appendSync(notif(n, date: d), to: path)
            }
        }
        let restored = NotificationLogStore.restore(dir: dir, now: now, limit: 300)
        check(restored.count == 6, "restore: 3-day window (6 of 8 restored)")
        check(restored.first.map { $0.date > restored.last!.date } == true,
              "restore: newest first")

        // Cap: write 10 more today, restore with limit 8 keeps the newest 8.
        let todayPath = NotificationLogStore.filePath(dir: dir, date: now)
        for n in 10..<20 { NotificationLogStore.appendSync(notif(n, date: now), to: todayPath) }
        let capped = NotificationLogStore.restore(dir: dir, now: now, limit: 8)
        check(capped.count == 8, "restore: cap respected")
    }
}
