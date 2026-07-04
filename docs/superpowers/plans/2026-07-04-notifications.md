# Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In-app notification center with click-to-navigate and new per-event-controlled triggers (needs-input, session-idle, PR-merged, ticket-status), per spec `docs/notes/0002-notifications-design.md`.

**Architecture:** A new main-actor `NotificationStore` child store (sibling of `ServerStore`/`TabStore`/`CanvasStore`) is the single funnel for every notification: it appends to an in-memory feed (300-cap), persists NDJSON via a new `NotificationLogStore` (modeled on `EventLogStore`, ADR 0013), and posts system banners via the existing `Notifier` iff that kind's toggle + the master toggle are on. All existing `Notifier.post` call sites in `DashboardStore` route through it. `AppDelegate` becomes `UNUserNotificationCenterDelegate` for banner clicks; both banners and in-app feed rows navigate via one `DashboardStore.navigate` method.

**Tech Stack:** Swift/SwiftUI, macOS 14+, no external dependencies. UserNotifications framework. Headless self-tests (no XCTest).

## Global Constraints

- **No external Swift dependencies** — stdlib + AppKit/WebKit/UserNotifications only.
- **Perf guardrails** (`docs/policies/0003-performance-guardrails.md`): no synchronous file I/O on the main actor from `body`/`.onAppear`/`.onChange`; never add a high-frequency writer to `DashboardStore`'s publishers — that is why `NotificationStore` is a separate `ObservableObject`; static `DateFormatter`s only.
- Build with `swift build`; ignore SourceKit "Cannot find X in scope" cross-file errors (stale-index noise) — trust `swift build`.
- Self-test suite pattern: `enum XSelfTest { static func runIfRequested() }` called from `DevDashApp.init()`, triggered by a `--selftest-*` CLI flag, prints `ok/FAIL` per check, exits 0/1 (see `Sources/DevDash/EventLogSelfTest.swift` for the canonical example).
- Commit directly to `main`, imperative mood, concise messages.
- Reuse `TaskStore` frontmatter helpers (`setOrAddFrontmatterKey`, `yamlStr`) — never reimplement frontmatter parsing.
- All new persistence lives at `~/.devdash/notifications/` (machine-global — the feed spans projects).

---

### Task 1: Notification models + `NotificationLogStore` (NDJSON persistence)

**Files:**
- Create: `Sources/DevDash/Scanners/NotificationLogStore.swift`
- Create: `Sources/DevDash/NotificationSelfTest.swift`
- Modify: `Sources/DevDash/App.swift:16` (register self-test)

**Interfaces:**
- Consumes: nothing new.
- Produces: `NotificationKind` (String-raw enum), `AppNotification` (Codable struct), `NotificationLogStore` with `filePath(dir:date:) -> String`, `append(_:dirOverride:)`, `appendSync(_:to:)`, `flush()`, `read(at:) -> [AppNotification]`, `restore(dir:now:limit:) -> [AppNotification]`.

- [ ] **Step 1: Write the failing self-test**

Create `Sources/DevDash/NotificationSelfTest.swift`:

```swift
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
        check(back.first.map { abs($0.date.timeIntervalSince(n1.date)) < 0.01 } == true,
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
                var item = notif(n, date: d)
                item = AppNotification(id: item.id, kind: item.kind, date: d.addingTimeInterval(Double(n)),
                                       title: item.title, body: item.body,
                                       projectPath: item.projectPath, tab: item.tab, taskId: item.taskId)
                NotificationLogStore.appendSync(item, to: path)
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `cannot find 'NotificationLogStore' in scope` / `cannot find type 'AppNotification'`.

- [ ] **Step 3: Implement models + log store**

Create `Sources/DevDash/Scanners/NotificationLogStore.swift`:

```swift
import Foundation

/// The kind of an app notification — one case per trigger. Drives per-kind
/// banner toggles (Settings) and icons/labels in the notification center.
enum NotificationKind: String, Codable, CaseIterable {
    // existing triggers (previously raw Notifier.post calls)
    case taskCreated, prReviewTask, taskDone, artifactAdded, prOpened, sessionFinished
    // new triggers
    case needsInput, sessionIdle, prMerged, ticketStatusChanged

    var label: String {
        switch self {
        case .taskCreated:         return "New task created"
        case .prReviewTask:        return "PR review task created"
        case .taskDone:            return "Task completed"
        case .artifactAdded:       return "Artifact added"
        case .prOpened:            return "PR opened"
        case .sessionFinished:     return "Claude session finished"
        case .needsInput:          return "Claude needs input"
        case .sessionIdle:         return "Claude turn finished (idle)"
        case .prMerged:            return "PR merged"
        case .ticketStatusChanged: return "Ticket status changed"
        }
    }

    var systemImage: String {
        switch self {
        case .taskCreated:         return "plus.circle"
        case .prReviewTask:        return "eye.circle"
        case .taskDone:            return "checkmark.circle"
        case .artifactAdded:       return "doc.badge.plus"
        case .prOpened:            return "arrow.triangle.pull"
        case .sessionFinished:     return "sparkles"
        case .needsInput:          return "exclamationmark.bubble"
        case .sessionIdle:         return "zzz"
        case .prMerged:            return "checkmark.seal"
        case .ticketStatusChanged: return "square.stack.3d.up"
        }
    }
}

/// One notification in the feed. Codable → one NDJSON line per notification.
/// `projectPath`/`tab`/`taskId` are the click-to-navigate target (all optional).
struct AppNotification: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: NotificationKind
    let date: Date
    let title: String
    let body: String
    let projectPath: String?
    let tab: String?       // DetailTab rawValue
    let taskId: String?    // opens TaskDetailSheet when present
}

/// Append-only NDJSON notification log at `~/.devdash/notifications/<YYYY-MM-DD>.ndjson`
/// (machine-global — the feed spans projects). Same crash-safety contract as
/// `EventLogStore` (ADR 0013): seekToEnd + single write on a serial utility
/// queue, torn-tail healing, readers skip malformed lines.
enum NotificationLogStore {

    private static let queue = DispatchQueue(label: "devdash.notiflog", qos: .utility)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static var defaultDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".devdash/notifications")
    }

    static func filePath(dir: String = defaultDir, date: Date = Date()) -> String {
        "\(dir)/\(dayFormatter.string(from: date)).ndjson"
    }

    /// Fire-and-forget append, serialized off-main; errors swallowed.
    static func append(_ item: AppNotification, dirOverride: String? = nil) {
        let path = filePath(dir: dirOverride ?? defaultDir, date: item.date)
        queue.async { appendSync(item, to: path) }
    }

    /// Synchronous append — used directly by self-tests; production goes
    /// through `append` (same code, on the serial queue).
    static func appendSync(_ item: AppNotification, to path: String) {
        guard var data = try? encoder.encode(item) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        let dirPath = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forUpdatingAtPath: path) else { return }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end > 0 {
            // Heal a crash-torn tail (see EventLogStore.appendSync for rationale).
            try? handle.seek(toOffset: end - 1)
            let last = try? handle.read(upToCount: 1)
            _ = try? handle.seekToEnd()
            if last?.first != 0x0A {
                try? handle.write(contentsOf: Data([0x0A]))
            }
        }
        try? handle.write(contentsOf: data)
    }

    /// Block until all queued appends have been written (tests + shutdown).
    static func flush() {
        queue.sync {}
    }

    /// Read one log file, skipping malformed lines.
    static func read(at path: String) -> [AppNotification] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return raw.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AppNotification.self, from: data)
        }
    }

    /// Launch-time feed reconstruction: today + the previous 2 days, newest
    /// first, capped at `limit`.
    static func restore(dir: String = defaultDir, now: Date = Date(), limit: Int = 300) -> [AppNotification] {
        var all: [AppNotification] = []
        for dayOffset in 0..<3 {
            let d = now.addingTimeInterval(-Double(dayOffset) * 86_400)
            all.append(contentsOf: read(at: filePath(dir: dir, date: d)))
        }
        all.sort { $0.date > $1.date }
        return Array(all.prefix(limit))
    }
}
```

- [ ] **Step 4: Register the self-test in `App.swift`**

In `Sources/DevDash/App.swift`, after line 16 (`EventLogSelfTest.runIfRequested()`), add:

```swift
        NotificationSelfTest.runIfRequested() // exits early when launched with --selftest-notifications
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift build && .build/debug/DevDash --selftest-notifications`
Expected: every line `ok`, final line `notifications-selftest: ALL PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Scanners/NotificationLogStore.swift Sources/DevDash/NotificationSelfTest.swift Sources/DevDash/App.swift
git commit -m "feat: notification models + NDJSON notification log (ADR 0013 pattern)"
```

---

### Task 2: `NotificationStore` — feed, unread, per-kind prefs, post funnel

**Files:**
- Create: `Sources/DevDash/NotificationStore.swift` (top level, next to ServerStore/TabStore)
- Modify: `Sources/DevDash/NotificationSelfTest.swift` (add gating/unread checks)
- Modify: `Sources/DevDash/Scanners/Notifier.swift` (add `userInfo` parameter)

**Interfaces:**
- Consumes: `AppNotification`, `NotificationKind`, `NotificationLogStore` (Task 1); `Notifier.post`.
- Produces:
  - `NotificationStore: ObservableObject` (`@MainActor`) with `feed: [AppNotification]`, `lastSeenAt: Date`, `bannerKinds: Set<NotificationKind>`, `unreadCount: Int`, `post(_ kind:title:body:projectPath:tab:taskId:)`, `markAllSeen()`, `restoreFromDisk()`, `isBannerEnabled(_:) -> Bool`, `setBanner(_:enabled:)`.
  - Pure/testable statics: `NotificationStore.unreadCount(feed:lastSeenAt:) -> Int`, `NotificationStore.shouldRecord(kind:bannerKinds:) -> Bool`, `NotificationStore.shouldBanner(kind:bannerKinds:masterEnabled:) -> Bool`.
  - `Notifier.post(title:body:userInfo:)` — `userInfo` defaults to `[:]`.

- [ ] **Step 1: Add failing checks to the self-test**

In `Sources/DevDash/NotificationSelfTest.swift`, add to `runIfRequested()` after `checkRestoreWindowAndCap(check)`:

```swift
        checkGatingAndUnread(check)
```

and add the method:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `cannot find 'NotificationStore' in scope`.

- [ ] **Step 3: Implement `NotificationStore`**

Create `Sources/DevDash/NotificationStore.swift`:

```swift
import SwiftUI

/// Child store for the notification feed, split out of `DashboardStore` per the
/// store-split guardrail: the unread badge is a frequent writer and must not
/// republish the hub store's ~64 publishers on every event.
///
/// Single funnel: every notification goes through `post(...)` — it appends to
/// the in-memory feed (300-cap tail), persists one NDJSON line via
/// `NotificationLogStore` (off-main), and posts a system banner via `Notifier`
/// iff that kind's toggle AND the master "Notify on Claude task activity"
/// toggle are on.
@MainActor
final class NotificationStore: ObservableObject {

    static let feedCap = 300
    static let defaultBannerKinds: Set<NotificationKind> =
        Set(NotificationKind.allCases).subtracting([.sessionIdle])

    /// Newest first, capped at `feedCap`.
    @Published private(set) var feed: [AppNotification] = []

    /// Unread = items strictly newer than this. Mark-all-seen model — no
    /// per-item read flags, so the NDJSON log stays append-only.
    @Published var lastSeenAt: Date {
        didSet {
            UserDefaults.standard.set(lastSeenAt.timeIntervalSince1970,
                                      forKey: "devdash.notifications.lastSeenAt")
        }
    }

    /// Kinds with system banners enabled. Also gates `sessionIdle`'s presence
    /// in the feed (it fires every turn — pure noise unless opted in).
    @Published var bannerKinds: Set<NotificationKind> {
        didSet {
            let raw = bannerKinds.map { $0.rawValue }.sorted()
            UserDefaults.standard.set(raw, forKey: "devdash.notifications.bannerKinds")
        }
    }

    var unreadCount: Int { Self.unreadCount(feed: feed, lastSeenAt: lastSeenAt) }

    init() {
        let seenTs = UserDefaults.standard.object(forKey: "devdash.notifications.lastSeenAt") as? Double
        // First run: seed to now so a restored feed doesn't open all-unread.
        lastSeenAt = seenTs.map { Date(timeIntervalSince1970: $0) } ?? Date()

        if let raw = UserDefaults.standard.stringArray(forKey: "devdash.notifications.bannerKinds") {
            bannerKinds = Set(raw.compactMap { NotificationKind(rawValue: $0) })
        } else {
            bannerKinds = Self.defaultBannerKinds
        }
    }

    // MARK: - Pure logic (headless self-tested)

    nonisolated static func unreadCount(feed: [AppNotification], lastSeenAt: Date) -> Int {
        feed.reduce(0) { $0 + ($1.date > lastSeenAt ? 1 : 0) }
    }

    /// Everything is recorded in the feed except sessionIdle when disabled.
    nonisolated static func shouldRecord(kind: NotificationKind,
                                         bannerKinds: Set<NotificationKind>) -> Bool {
        kind != .sessionIdle || bannerKinds.contains(.sessionIdle)
    }

    nonisolated static func shouldBanner(kind: NotificationKind,
                                         bannerKinds: Set<NotificationKind>,
                                         masterEnabled: Bool) -> Bool {
        masterEnabled && bannerKinds.contains(kind)
    }

    // MARK: - API

    func isBannerEnabled(_ kind: NotificationKind) -> Bool { bannerKinds.contains(kind) }

    func setBanner(_ kind: NotificationKind, enabled: Bool) {
        if enabled { bannerKinds.insert(kind) } else { bannerKinds.remove(kind) }
    }

    func markAllSeen() { lastSeenAt = Date() }

    /// Launch-time reconstruction from the NDJSON log — call off the main
    /// startup path (it reads up to 3 files).
    func restoreFromDisk() {
        Task.detached(priority: .utility) {
            let restored = NotificationLogStore.restore()
            await MainActor.run { [weak self] in
                guard let self, self.feed.isEmpty else { return }
                self.feed = restored
            }
        }
    }

    /// The single funnel. Feed + NDJSON + (gated) system banner.
    func post(_ kind: NotificationKind, title: String, body: String,
              projectPath: String? = nil, tab: DetailTab? = nil, taskId: String? = nil) {
        guard Self.shouldRecord(kind: kind, bannerKinds: bannerKinds) else { return }

        let item = AppNotification(
            id: UUID(), kind: kind, date: Date(),
            title: title, body: body,
            projectPath: projectPath, tab: tab?.rawValue, taskId: taskId
        )
        feed.insert(item, at: 0)
        if feed.count > Self.feedCap { feed.removeLast(feed.count - Self.feedCap) }

        NotificationLogStore.append(item)   // off-main serial queue

        // Master toggle is DashboardStore's `enableNotifications`, persisted to
        // this key (registered default true). Read at post time — always current.
        let master = UserDefaults.standard.bool(forKey: "devdash.enableNotifications")
        if Self.shouldBanner(kind: kind, bannerKinds: bannerKinds, masterEnabled: master) {
            var info: [String: String] = [:]
            if let projectPath { info["projectPath"] = projectPath }
            if let tab { info["tab"] = tab.rawValue }
            if let taskId { info["taskId"] = taskId }
            Notifier.post(title: title, body: body, userInfo: info)
        }
    }
}
```

- [ ] **Step 4: Add `userInfo` to `Notifier.post`**

In `Sources/DevDash/Scanners/Notifier.swift`, replace the `post` method:

```swift
    /// Post an immediate local notification. Safe to call without prior auth check.
    /// `userInfo` carries the click-to-navigate target (read by AppDelegate's
    /// UNUserNotificationCenterDelegate).
    static func post(title: String, body: String, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        if !userInfo.isEmpty { content.userInfo = userInfo }
        let id = UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
```

- [ ] **Step 5: Run tests**

Run: `swift build && .build/debug/DevDash --selftest-notifications`
Expected: all checks `ok` (including the new `unread:`/`gate:` ones), `ALL PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/NotificationStore.swift Sources/DevDash/NotificationSelfTest.swift Sources/DevDash/Scanners/Notifier.swift
git commit -m "feat: NotificationStore child store — feed, unread, per-kind banner gating"
```

---

### Task 3: Wire the store in; route existing call sites through it

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift` (store property ~line 114-117; call sites ~354-390, ~949-1005)
- Modify: `Sources/DevDash/App.swift` (environmentObject + restore)

**Interfaces:**
- Consumes: `NotificationStore` (Task 2).
- Produces: `DashboardStore.notificationStore: NotificationStore` (a `let`, like `tabStore`/`canvasStore`). All 7 previous `Notifier.post` sites now call `notificationStore.post(...)` with kind + navigation target. `Notifier` is no longer called directly from `DashboardStore`.

- [ ] **Step 1: Add the store property**

In `Sources/DevDash/DashboardStore.swift`, next to `let tabStore = TabStore()` (line ~114) and `let canvasStore = CanvasStore()` (line ~117), add:

```swift
    /// Notification feed + banner gating (split store — see perf guardrails).
    let notificationStore = NotificationStore()
```

- [ ] **Step 2: Inject + restore in `App.swift`**

In `Sources/DevDash/App.swift`, after `.environmentObject(store.canvasStore)` add:

```swift
                .environmentObject(store.notificationStore)
```

and inside the `.task { ... }` block, immediately after `Notifier.requestAuthIfNeeded()`:

```swift
                    store.notificationStore.restoreFromDisk()
```

- [ ] **Step 3: Route the task/artifact diff sites**

In `DashboardStore.reloadTasksAndNotify` (line ~352-390): the per-kind + master gating now lives inside `notificationStore.post`, so the outer `if enableNotifications` guards are removed (the feed must record even when banners are off). Replace the task-diff block:

```swift
            if let snap = taskSnapshot[path] {
                // Diff: only notify when we have a prior snapshot (not first load).
                // Banner gating (per-kind + master) lives inside NotificationStore.post;
                // the in-app feed records regardless.
                for (id, task) in freshMap {
                    if snap[id] == nil {
                        // New task
                        if task.pr != nil {
                            notificationStore.post(.prReviewTask, title: "PR review task created",
                                                   body: task.title,
                                                   projectPath: path, tab: .tasks, taskId: id)
                        } else {
                            notificationStore.post(.taskCreated, title: "New task", body: task.title,
                                                   projectPath: path, tab: .tasks, taskId: id)
                        }
                    } else if snap[id]?.status != .done && task.status == .done {
                        // Task moved to done
                        notificationStore.post(.taskDone, title: "Task done", body: task.title,
                                               projectPath: path, tab: .tasks, taskId: id)
                    }
                }
            }
```

and the artifact-diff block (KEEP the load-bearing `if let snapIds` + its comment exactly as is — only the inner loop changes):

```swift
                for artifact in freshArtifacts where !snapIds.contains(artifact.id) {
                    notificationStore.post(.artifactAdded, title: "Artifact added",
                                           body: artifact.title,
                                           projectPath: path, tab: .tasks)
                }
```

(Delete the now-empty `if enableNotifications { ... }` wrappers.)

- [ ] **Step 4: Route the PR-opened and session-finished sites**

Line ~949 (`PR opened → review task created`):

```swift
                                reloadTasksAndNotifyForProject(projPath)
                                let body = ticketTitle ?? (current?.title ?? taskId)
                                notificationStore.post(.prOpened, title: "PR opened → review task created",
                                                       body: body,
                                                       projectPath: projPath, tab: .tasks, taskId: reviewTask.id)
```

Line ~962 (legacy fallback `PR opened → Review & QA`):

```swift
                            reloadTasksAndNotifyForProject(projPath)
                            let title = current?.title ?? taskId
                            notificationStore.post(.prOpened, title: "PR opened → Review & QA",
                                                   body: title,
                                                   projectPath: projPath, tab: .tasks, taskId: taskId)
```

Line ~1002 (`Claude finished` in SessionEnd):

```swift
                if meaningful, let projPath = session.projectPath {
                    notificationStore.post(.sessionFinished, title: "Claude finished",
                                           body: "Session ended in \(session.projectName)",
                                           projectPath: projPath, tab: .claude)
                    reloadTasksAndNotifyForProject(projPath)
                }
```

(In each case delete the surrounding `if enableNotifications { ... }`.)

- [ ] **Step 5: Verify no direct Notifier calls remain in DashboardStore**

Run: `swift build && grep -n "Notifier.post" Sources/DevDash/DashboardStore.swift`
Expected: clean build; grep returns nothing.

Run: `.build/debug/DevDash --selftest-notifications && .build/debug/DevDash --selftest-taskstore`
Expected: both `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/DashboardStore.swift Sources/DevDash/App.swift
git commit -m "feat: route all notifications through NotificationStore funnel"
```

---

### Task 4: Click-to-navigate (banner delegate + shared navigate)

**Files:**
- Modify: `Sources/DevDash/App.swift` (`AppDelegate`, lines 108-117)
- Modify: `Sources/DevDash/DashboardStore.swift` (add `navigate` + observer)

**Interfaces:**
- Consumes: `Notifier.post(userInfo:)` payload keys `projectPath`/`tab`/`taskId` (Task 2); `store.selection`, `tabStore.detailTab`, `openTaskId`/`openTaskProjectPath`.
- Produces:
  - `Notification.Name.devdashNavigate` (internal NSNotification bridging AppDelegate → store).
  - `DashboardStore.navigate(projectPath: String?, tabRaw: String?, taskId: String?)` — also used by the in-app feed rows (Task 5).

- [ ] **Step 1: Make `AppDelegate` the notification-center delegate**

In `Sources/DevDash/App.swift`, replace the `AppDelegate` class:

```swift
extension Notification.Name {
    /// Posted by AppDelegate when a system notification banner is clicked.
    /// userInfo: projectPath / tab / taskId (all optional strings).
    static let devdashNavigate = Notification.Name("devdash.navigate")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Show banners even while the app is frontmost (macOS suppresses them by default).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Banner clicked → activate and forward the navigation target to the store.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo
        var info: [String: String] = [:]
        for (k, v) in raw {
            if let ks = k as? String, let vs = v as? String { info[ks] = vs }
        }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .devdashNavigate, object: nil, userInfo: info)
        }
    }
}
```

- [ ] **Step 2: Add `navigate` + observer to `DashboardStore`**

Add near the other `@Published` selection state (after `openTaskProjectPath`, line ~131):

```swift
    /// Observer for banner-click navigation requests forwarded by AppDelegate.
    private var navigateObserver: NSObjectProtocol?
```

Add a method (place it near `restoreLastSelection`):

```swift
    /// Shared click-to-navigate: system banner clicks (via .devdashNavigate)
    /// and in-app notification rows both land here.
    func navigate(projectPath: String?, tabRaw: String?, taskId: String?) {
        guard let projectPath else { return }
        // Order matters: selection first (its didSet may restore a remembered
        // tab via tabStore.selectionChanged), THEN the explicit tab override.
        selection = .project(path: projectPath)
        if let tabRaw, let tab = DetailTab(rawValue: tabRaw) {
            tabStore.detailTab = tab
        }
        if let taskId {
            openTaskProjectPath = projectPath
            openTaskId = taskId
        }
    }

    /// Call once at startup (from App.task, alongside startEventServer).
    func armNavigationObserver() {
        guard navigateObserver == nil else { return }
        navigateObserver = NotificationCenter.default.addObserver(
            forName: .devdashNavigate, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            Task { @MainActor in
                self?.navigate(projectPath: info["projectPath"],
                               tabRaw: info["tab"], taskId: info["taskId"])
            }
        }
    }
```

- [ ] **Step 3: Arm the observer at startup**

In `Sources/DevDash/App.swift` `.task` block, after `store.startEventServer()`:

```swift
                    store.armNavigationObserver()
```

- [ ] **Step 4: Build + verify**

Run: `swift build 2>&1 | tail -3`
Expected: clean build.

Manual smoke (deferred to Task 9's live QA): `bash run.sh`, trigger a test notification, click banner → app focuses the right project/tab.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/App.swift Sources/DevDash/DashboardStore.swift
git commit -m "feat: click-to-navigate — banner delegate + shared navigate path"
```

---

### Task 5: Bell icon + notification center popover

**Files:**
- Create: `Sources/DevDash/Views/NotificationCenterView.swift`
- Modify: `Sources/DevDash/Views/ContentView.swift` (toolbar, ~line 194)

**Interfaces:**
- Consumes: `NotificationStore` (env object), `DashboardStore.navigate` (Task 4), `NotificationKind.systemImage`/`label`, DS tokens (`DSFont`, `DSSpace`, `DSColor`, `DSRadius` — follow existing usage in `ContentView.swift`).
- Produces: `NotificationBellButton` view (toolbar item content, owns the popover).

- [ ] **Step 1: Create the view**

Create `Sources/DevDash/Views/NotificationCenterView.swift`:

```swift
import SwiftUI

/// Toolbar bell + unread badge; click opens the notification center popover.
struct NotificationBellButton: View {
    @EnvironmentObject private var notifications: NotificationStore
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if notifications.unreadCount > 0 {
                        Text(verbatim: notifications.unreadCount > 99 ? "99+" : String(notifications.unreadCount))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .help("Notifications")
        .accessibilityLabel("Notifications")
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            NotificationCenterPanel()
        }
        .onChange(of: showPanel) { _, open in
            // Opening the panel marks everything seen (mark-all-seen model).
            if open { notifications.markAllSeen() }
        }
    }
}

/// The popover: newest-first feed, click a row to navigate.
struct NotificationCenterPanel: View {
    @EnvironmentObject private var notifications: NotificationStore
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(DSFont.bodyEmphasized)
                Spacer()
                if !notifications.feed.isEmpty {
                    Button("Clear") { notifications.markAllSeen() }
                        .buttonStyle(.plain)
                        .font(DSFont.micro)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(DSSpace.sm)
            Divider()

            if notifications.feed.isEmpty {
                Text("No notifications yet.")
                    .font(DSFont.label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpace.lg)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(notifications.feed) { item in
                            NotificationRow(item: item)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 360)
    }
}

private struct NotificationRow: View {
    let item: AppNotification
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.dismiss) private var dismiss

    /// Project display name from the path's last component.
    private var projectName: String? {
        item.projectPath.map { ($0 as NSString).lastPathComponent }
    }

    var body: some View {
        Button {
            store.navigate(projectPath: item.projectPath, tabRaw: item.tab, taskId: item.taskId)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: DSSpace.sm) {
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(DSFont.label)
                        .foregroundStyle(.primary)
                    Text(item.body)
                        .font(DSFont.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: DSSpace.xs) {
                        if let projectName {
                            Text(projectName)
                        }
                        Text(item.date, format: .relative(presentation: .named))
                    }
                    .font(DSFont.micro)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpace.sm)
            .padding(.vertical, DSSpace.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

Note for the implementer: check `DSFont`/`DSSpace` member names against `Sources/DevDash/Views/DesignSystem.swift` before building — the tokens used above (`bodyEmphasized`, `label`, `micro`, `xs/sm/md/lg`) all appear in existing views (`TaskDetailSheet.swift`, `ContentView.swift`); if one is missing, substitute the nearest existing token rather than adding new ones.

- [ ] **Step 2: Add the bell to the toolbar**

In `Sources/DevDash/Views/ContentView.swift`, in the toolbar builder just before `ToolbarItem(placement: .primaryAction) { commandField }` (line ~194), add:

```swift
        ToolbarItem(placement: .primaryAction) {
            NotificationBellButton()
        }
```

- [ ] **Step 3: Build + visual check**

Run: `swift build 2>&1 | tail -3`
Expected: clean build.

Run: `bash run.sh` — bell appears in the toolbar; empty panel shows "No notifications yet."; feed entries restored from previous runs (if `~/.devdash/notifications/` has data) render with icon/title/relative time; clicking a row selects the project + tab.

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Views/NotificationCenterView.swift Sources/DevDash/Views/ContentView.swift
git commit -m "feat: notification bell + in-app notification center popover"
```

---

### Task 6: Settings — per-kind banner toggles

**Files:**
- Modify: `Sources/DevDash/Views/SettingsView.swift` (lines ~509-517)

**Interfaces:**
- Consumes: `NotificationStore.isBannerEnabled(_:)` / `setBanner(_:enabled:)` / `bannerKinds`, `NotificationKind.allCases`/`label`; existing `$store.enableNotifications` master toggle.
- Produces: UI only.

- [ ] **Step 1: Replace the single notifications toggle with master + per-kind list**

In `Sources/DevDash/Views/SettingsView.swift`, `SettingsView` needs the store: add next to the existing `@EnvironmentObject` for `DashboardStore` (top of the struct):

```swift
    @EnvironmentObject private var notifications: NotificationStore
```

`SettingsView` is presented from `App.swift`'s overlay with only `.environmentObject(store)` — add the notification store there too (in `Sources/DevDash/App.swift`):

```swift
                    if store.isSettingsVisible {
                        SettingsView()
                            .environmentObject(store)
                            .environmentObject(store.notificationStore)
                    }
```

Then replace the existing block (lines ~509-517):

```swift
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Notify on Claude task activity", isOn: $store.enableNotifications)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Text("Native notifications when Claude creates a PR task, completes a task, or finishes a session.")
                            .font(DSFont.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
```

with:

```swift
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Notify on Claude task activity", isOn: $store.enableNotifications)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Text("Master switch for native notification banners. The in-app feed (bell) always records events. Per-event control:")
                            .font(DSFont.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(NotificationKind.allCases, id: \.rawValue) { kind in
                                Toggle(kind.label, isOn: Binding(
                                    get: { notifications.isBannerEnabled(kind) },
                                    set: { notifications.setBanner(kind, enabled: $0) }
                                ))
                                .toggleStyle(.checkbox)
                                .controlSize(.mini)
                                .disabled(!store.enableNotifications)
                            }
                            Text("“Claude turn finished (idle)” fires every turn — enabling it also shows those entries in the feed.")
                                .font(DSFont.micro)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, DSSpace.md)
                        .padding(.top, 2)
                    }
```

- [ ] **Step 2: Build + visual check**

Run: `swift build 2>&1 | tail -3` then `bash run.sh`
Expected: Settings shows the master switch with 10 per-kind checkboxes beneath, disabled (greyed) when master is off; toggles persist across relaunch (UserDefaults).

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Views/SettingsView.swift Sources/DevDash/App.swift
git commit -m "feat: per-event notification toggles in Settings"
```

---

### Task 7: New triggers — `needsInput` (Notification hook) + `sessionIdle`

**Files:**
- Modify: `Sources/DevDash/Scanners/HookInstaller.swift` (hookSpecs, line ~26-51)
- Modify: `Sources/DevDash/DashboardStore.swift` (`recordEvent` switch ~line 709; `handleHookEvent` switch ~line 794; one-time migration)
- Modify: `Sources/DevDash/App.swift` (call migration)

**Interfaces:**
- Consumes: `notificationStore.post` (Task 2); `ensureSession`, `projectInfo`, `ev.raw`.
- Produces: `DashboardStore.migrateNotificationHookEventOnce()`; hook event `"Notification"` flows end-to-end (installer → bridge script → EventServer → recordEvent + handleHookEvent).

- [ ] **Step 1: Add the hook spec**

In `Sources/DevDash/Scanners/HookInstaller.swift`, in `hookSpecs` after the `Stop` entry (line ~46), insert:

```swift
        .init(event: "Notification",
              firesWhen: "Claude is waiting on you — a permission request or idle prompt.",
              reaction: "Posts a “Claude needs input” notification pointing at the session's project.",
              gatedBy: "Notify on Claude task activity"),
```

(The bridge script forwards any hook payload verbatim, and `installProjectHooks` iterates `hookSpecs` — no other installer change needed. The Settings per-project event pickers pick the new event up automatically since they iterate `HookInstaller.hookSpecs`.)

- [ ] **Step 2: One-time migration for saved event sets**

`defaultEnabledEvents` defaults to all specs only when no value is saved (DashboardStore line ~587); existing installs have a persisted set without `"Notification"`. Add to `DashboardStore`:

```swift
    /// One-time: add the "Notification" hook event to previously-saved event
    /// sets (global default + per-project overrides predate this event and
    /// would silently never install it). didSet on defaultEnabledEvents
    /// re-reconciles installed projects.
    func migrateNotificationHookEventOnce() {
        let flag = "devdash.migratedNotificationHookEvent"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        if !defaultEnabledEvents.contains("Notification") {
            defaultEnabledEvents.insert("Notification")
        }
        for (path, config) in projectHookConfigs {
            if var events = config.enabledEvents, !events.contains("Notification") {
                events.insert("Notification")
                setEnabledEventsOverride(events, for: path)
            }
        }
    }
```

Note: check the actual shape of `projectHookConfigs` (`grep -n "projectHookConfigs" Sources/DevDash/DashboardStore.swift`) — the loop above assumes `[String: SomeConfig]` with `enabledEvents: Set<String>?` and a `setEnabledEventsOverride(_:for:)` setter (both referenced from `SettingsView.swift:754-766`). Adjust member access to match.

In `Sources/DevDash/App.swift` `.task` block, after `store.armNavigationObserver()`:

```swift
                    store.migrateNotificationHookEventOnce()
```

- [ ] **Step 3: Record + react to the event**

In `DashboardStore.recordEvent` (line ~709), add a case before `default:`:

```swift
        case "Notification":
            category = .session
            let msg = ev.raw["message"] as? String ?? "Waiting for input"
            detail = "Needs input: \(msg)"
```

In `DashboardStore.handleHookEvent` (line ~794), add before `default:`:

```swift
        case "Notification":
            // Claude Code fires this when the session is blocked on the user —
            // a permission prompt or idle waiting-for-input.
            ensureSession(sid: sid, cwd: ev.cwd, now: now)
            liveSessions[sid]?.lastEventAt = now
            let msg = ev.raw["message"] as? String ?? "Waiting for your input"
            let projName = liveSessions[sid]?.projectName ?? "unknown project"
            notificationStore.post(.needsInput, title: "Claude needs input — \(projName)",
                                   body: msg,
                                   projectPath: liveSessions[sid]?.projectPath, tab: .claude)
```

- [ ] **Step 4: `sessionIdle` on Stop**

In the existing `case "Stop":` in `handleHookEvent` (line ~971), after `liveSessions[sid]?.lastEventAt = now`, add:

```swift
            // Opt-in per-turn idle notification (default off — fires every turn).
            let idleProj = liveSessions[sid]?.projectName ?? "unknown project"
            notificationStore.post(.sessionIdle, title: "Claude is idle — \(idleProj)",
                                   body: liveSessions[sid]?.lastPrompt.map { "After: \($0.prefix(80))" } ?? "Turn finished",
                                   projectPath: liveSessions[sid]?.projectPath, tab: .claude)
```

(`NotificationStore.shouldRecord` drops this entirely unless the user enabled the kind — no feed spam by default.)

- [ ] **Step 5: Build + self-tests**

Run: `swift build && .build/debug/DevDash --selftest-notifications`
Expected: clean build, `ALL PASS`.

Live check (with the app running and hooks reinstalled — open Settings → confirm the project event pickers show 7 events): in a hook-installed project, run a `claude` session that hits a permission prompt → a "Claude needs input" banner + feed entry appears; clicking it lands on that project's Claude tab.

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Scanners/HookInstaller.swift Sources/DevDash/DashboardStore.swift Sources/DevDash/App.swift
git commit -m "feat: needs-input + session-idle notification triggers (Notification hook)"
```

---

### Task 8: PR-merged poller

**Files:**
- Modify: `Sources/DevDash/Models.swift` (TaskItem, line ~278-323)
- Modify: `Sources/DevDash/Scanners/TaskStore.swift` (parse + write `pr_merged`)
- Modify: `Sources/DevDash/DashboardStore.swift` (poller, called from `refreshAll`)

**Interfaces:**
- Consumes: `GitDiffScanner.prDetail(path:number:) -> PRDetail?` (`state` field, "MERGED"/"merged" when merged); `DashboardStore.prNumberFromURL(from:)` (line 1067, `nonisolated static`); `TaskStore.setOrAddFrontmatterKey`; `notificationStore.post`.
- Produces: `TaskItem.prMerged: Bool`; `TaskStore.setPRMerged(projectPath:id:)`; `DashboardStore.pollPRMerges()` (throttled, off-main).

- [ ] **Step 1: Add the model field + store parsing/writing**

In `Sources/DevDash/Models.swift`, in `TaskItem` after `var pr: String? = nil`:

```swift
    /// Set once the PR at `pr` is observed merged (durable dedupe for the
    /// merge notification; also lets UI show cleanup affordances without a fetch).
    var prMerged: Bool = false
```

In `Sources/DevDash/Scanners/TaskStore.swift`: find where `pr` is parsed from frontmatter (`grep -n '"pr"' Sources/DevDash/Scanners/TaskStore.swift`) and mirror it exactly for `pr_merged` (truthy = `"true"`), assigning `prMerged`. Where tasks are serialized (`bare(...)`/`setBare(...)` pattern), write `pr_merged` only when true. Then add a setter following the existing `setPR`/`setHasAIRun` pattern (find with `grep -n "func setPR\|func setHasAIRun" Sources/DevDash/Scanners/TaskStore.swift`):

```swift
    /// Mark a task's PR as merged (idempotent frontmatter write).
    static func setPRMerged(projectPath: String, id: String) throws {
        let dir = file(for: projectPath)
        guard let fname = findFile(id: id, in: dir) else { return }
        let path = "\(dir)/\(fname)"
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let patched = setOrAddFrontmatterKey(in: raw, key: "pr_merged", value: "true")
        try patched.write(toFile: path, atomically: true, encoding: .utf8)
    }
```

(Adjust `file(for:)`/`findFile(id:in:)` names to the actual helpers used by `setPR` — copy its body shape verbatim.)

- [ ] **Step 2: Add a parsing check to the task-store self-test**

In `Sources/DevDash/TaskStoreSelfTest.swift`, locate an existing frontmatter round-trip check and add alongside it (matching local helper conventions in that file):

```swift
        // pr_merged round-trip: absent → false; set → true after re-read.
```

Write a doc with `pr: https://github.com/x/y/pull/7`, read → `prMerged == false`; call `TaskStore.setPRMerged`, re-read → `prMerged == true`. Use the same temp-project scaffolding the file already uses for other checks.

Run: `swift build && .build/debug/DevDash --selftest-taskstore`
Expected: FAIL until Step 1 is complete and correct, then `ALL PASS`.

- [ ] **Step 3: The poller**

In `Sources/DevDash/DashboardStore.swift`, add near the other private state:

```swift
    /// Last `gh pr view` poll per "<projectPath>#<taskId>" (5-min throttle).
    private var prMergePollLast: [String: Date] = [:]
```

Add the method:

```swift
    /// Detect merged PRs for tasks with an open PR + active worktree.
    /// Called from refreshAll; each PR polled at most every 5 minutes; gh runs
    /// off-main. On merge: durable frontmatter flag (dedupe) + notification.
    func pollPRMerges() {
        let now = Date()
        var toPoll: [(projectPath: String, taskId: String, title: String, prNumber: Int)] = []
        for (path, tasks) in projectTasks {
            for task in tasks ?? [] where task.worktree != nil && !task.prMerged {
                guard let pr = task.pr,
                      let number = Self.prNumberFromURL(from: pr) else { continue }
                let key = "\(path)#\(task.id)"
                if let last = prMergePollLast[key], now.timeIntervalSince(last) < 300 { continue }
                prMergePollLast[key] = now
                toPoll.append((path, task.id, task.title, number))
            }
        }
        guard !toPoll.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for item in toPoll {
                guard let detail = await GitDiffScanner.prDetail(path: item.projectPath,
                                                                 number: item.prNumber) else { continue }
                guard detail.state.lowercased() == "merged" else { continue }
                await MainActor.run {
                    guard let self else { return }
                    try? TaskStore.setPRMerged(projectPath: item.projectPath, id: item.taskId)
                    self.reloadTasks(for: item.projectPath)
                    self.notificationStore.post(.prMerged,
                        title: "PR merged", body: item.title,
                        projectPath: item.projectPath, tab: .tasks, taskId: item.taskId)
                }
            }
        }
    }
```

Note: `TaskStore.setPRMerged` is sync file I/O — called here inside `MainActor.run` for state consistency with `reloadTasks`. It's one small frontmatter rewrite per merge event (rare); if review flags it, move the write into the detached section before hopping to main.

Call it in `refreshAll()` right after `self.lastUpdated = Date()` (line ~1400):

```swift
            pollPRMerges()
```

- [ ] **Step 4: Build + tests**

Run: `swift build && .build/debug/DevDash --selftest-taskstore && .build/debug/DevDash --selftest-notifications`
Expected: clean build, both `ALL PASS`.

Live check happens with open task 0004 (merge a real PR → notification fires once, never repeats across relaunches because `pr_merged: true` is in the task doc).

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Models.swift Sources/DevDash/Scanners/TaskStore.swift Sources/DevDash/TaskStoreSelfTest.swift Sources/DevDash/DashboardStore.swift
git commit -m "feat: PR-merged notification via throttled gh poll + pr_merged frontmatter dedupe"
```

---

### Task 9: Ticket-status-changed trigger + final verification

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift` (`reloadTasksAndNotify`, ~line 341)
- Modify: `Sources/DevDash/NotificationSelfTest.swift` (rollup checks)
- Modify: `CLAUDE.md` (self-test command list)

**Interfaces:**
- Consumes: `TicketStore.read(_:) -> [Ticket]` (Ticket.status: TaskStatus), `TaskStore.read(_:) -> [TaskItem]` (TaskItem.ticket: String?), `notificationStore.post`.
- Produces: `DashboardStore.ticketRollupStatus(ticketId:tasks:) -> TaskStatus?` (`nonisolated static`, mirrors the display-only rollup in `LoreTasksView.swift:605-614` but over `[TaskItem]`); private `ticketStatusSnapshot: [String: [String: TaskStatus]]`.

- [ ] **Step 1: Failing self-test for the rollup**

Add to `NotificationSelfTest.runIfRequested()`:

```swift
        checkTicketRollup(check)
```

and the method (build `TaskItem`s with the memberwise initializer — every field through `ghIssueURL` is required; the trailing defaulted fields can be set after):

```swift
    private static func task(_ id: String, status: TaskStatus, owner: TaskOwner, ticket: String?) -> TaskItem {
        var t = TaskItem(id: id, title: "t\(id)", notes: nil, stage: nil,
                         category: .general, source: .manual, status: status,
                         createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                         startedAt: nil, completedAt: nil, ghIssueURL: nil)
        t.owner = owner
        t.ticket = ticket
        return t
    }

    // Rollup mirrors LoreTasksView.ticketRollupStatus over [TaskItem].
    private static func checkTicketRollup(_ check: (Bool, String) -> Void) {
        typealias R = DashboardStore
        check(R.ticketRollupStatus(ticketId: "0001", tasks: []) == nil,
              "rollup: no tasks → nil (caller uses stored status)")
        check(R.ticketRollupStatus(ticketId: "0001", tasks: [
            task("1", status: .done, owner: .human, ticket: "0001"),
            task("2", status: .skipped, owner: .none, ticket: "0001"),
        ]) == .done, "rollup: all done/skipped → done")
        check(R.ticketRollupStatus(ticketId: "0001", tasks: [
            task("1", status: .blocked, owner: .human, ticket: "0001"),
            task("2", status: .done, owner: .none, ticket: "0001"),
        ]) == .blocked, "rollup: any blocked → blocked")
        check(R.ticketRollupStatus(ticketId: "0001", tasks: [
            task("1", status: .open, owner: .ai, ticket: "0001"),
        ]) == .inProgress, "rollup: open+ai → inProgress")
        check(R.ticketRollupStatus(ticketId: "0001", tasks: [
            task("1", status: .inProgress, owner: .human, ticket: "0001"),
        ]) == .inProgress, "rollup: in_progress → inProgress")
        check(R.ticketRollupStatus(ticketId: "0001", tasks: [
            task("1", status: .open, owner: .human, ticket: "0001"),
        ]) == .open, "rollup: plain open → open")
        check(R.ticketRollupStatus(ticketId: "0001", tasks: [
            task("1", status: .done, owner: .human, ticket: "0002"),
        ]) == nil, "rollup: other tickets' tasks ignored")
    }
```

Check `TaskCategory`/`TaskSource` case names before building (`grep -n "enum TaskCategory\|enum TaskSource" Sources/DevDash/Models.swift`) and use real cases (e.g. if there is no `.general`/`.manual`, pick the first case of each).

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `type 'DashboardStore' has no member 'ticketRollupStatus'`.

- [ ] **Step 3: Implement rollup + diff**

In `DashboardStore`, add (near `reloadTasksAndNotify`):

```swift
    /// Rollup status for a ticket from its child tasks — the notification-side
    /// twin of LoreTasksView.ticketRollupStatus (which renders from lore items).
    /// nil when the ticket has no tasks (caller falls back to stored status).
    nonisolated static func ticketRollupStatus(ticketId: String, tasks: [TaskItem]) -> TaskStatus? {
        let ticketTasks = tasks.filter { $0.ticket == ticketId }
        guard !ticketTasks.isEmpty else { return nil }
        if ticketTasks.allSatisfy({ $0.status == .done || $0.status == .skipped }) { return .done }
        if ticketTasks.contains(where: { $0.status == .blocked }) { return .blocked }
        if ticketTasks.contains(where: { ($0.status == .open && $0.owner == .ai) || $0.status == .inProgress }) {
            return .inProgress
        }
        return .open
    }

```

Also add the snapshot dict next to `taskSnapshot`'s declaration (`grep -n "taskSnapshot" Sources/DevDash/DashboardStore.swift` to find it):

```swift
    /// Per-project ticket rollup snapshot: projectPath → (ticketId → status).
    private var ticketStatusSnapshot: [String: [String: TaskStatus]] = [:]
```

Then in `reloadTasksAndNotify`, replace the ticket reload comment + lines (341-343):

```swift
            // — Tickets (diff rollup status; first load per project seeds silently) —
            let freshTickets = TicketStore.read(path)
            projectTickets[path] = freshTickets.isEmpty ? nil : freshTickets
```

and after the **task** diff/snapshot block (once `fresh` — the `[TaskItem]` — exists, right after `projectTasks[path] = fresh.isEmpty ? nil : fresh`), add:

```swift
            // — Ticket rollup status diff —
            var freshTicketStatuses: [String: TaskStatus] = [:]
            for ticket in freshTickets {
                freshTicketStatuses[ticket.id] =
                    Self.ticketRollupStatus(ticketId: ticket.id, tasks: fresh) ?? ticket.status
            }
            if let snap = ticketStatusSnapshot[path] {
                // Diff: only notify when we have a prior snapshot (not first load).
                for ticket in freshTickets {
                    guard let old = snap[ticket.id],
                          let new = freshTicketStatuses[ticket.id], old != new else { continue }
                    notificationStore.post(.ticketStatusChanged,
                        title: "Ticket \(new == .done ? "complete" : new.rawValue): \(ticket.title)",
                        body: "\(old.rawValue) → \(new.rawValue)",
                        projectPath: path, tab: .tasks)
                }
            }
            ticketStatusSnapshot[path] = freshTicketStatuses
```

Check `TaskStatus.rawValue` exists (it's `String`-backed — `grep -n "enum TaskStatus" Sources/DevDash/Models.swift`); if it isn't `String`-raw, use a small `label` switch instead.

- [ ] **Step 4: Run all self-tests**

Run:
```bash
swift build && for t in notifications taskstore policy eventlog; do .build/debug/DevDash --selftest-$t || exit 1; done && .build/debug/DevDash --daily-selftest && .build/debug/DevDash --selftest-terminal
```
Expected: every suite `ALL PASS` / exit 0.

- [ ] **Step 5: Document the new self-test + live QA**

In `CLAUDE.md`, extend the self-test command list with `--selftest-notifications`:

```
- Self-tests (headless, no XCTest): `swift build && .build/debug/DevDash --selftest-taskstore | --selftest-policy | --selftest-notifications | --daily-selftest | --selftest-terminal` — run the relevant suite before claiming a data-layer change done
```

Live QA pass with `bash run.sh`:
1. Bell + panel render; unread badge increments on a posted notification and clears on open.
2. Complete a task via the Tasks tab → "Task done" appears in feed; banner if enabled; clicking navigates to that project's Tasks tab and opens the task sheet.
3. Settings toggles gate banners but not the feed.

- [ ] **Step 6: Commit + devlog**

```bash
git add Sources/DevDash/DashboardStore.swift Sources/DevDash/NotificationSelfTest.swift CLAUDE.md
git commit -m "feat: ticket-status-changed notifications via rollup diff"
```

Then write the session devlog with the `/devlog` command (per repo convention) and run `lore reindex devlog && lore validate devlog`.
