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
    nonisolated static let defaultBannerKinds: Set<NotificationKind> =
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
