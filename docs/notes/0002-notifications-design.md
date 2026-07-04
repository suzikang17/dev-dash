---
type: note
title: "Design spec: notifications — in-app center, click-to-navigate, per-event triggers"
tags: design, spec, notifications
created: 2026-07-04
---

Approved design for the notifications feature (brainstormed 2026-07-04). Builds on
the existing `Notifier` (UNUserNotificationCenter wrapper) and diff-based triggers
in `DashboardStore`. Three deliverables: an in-app notification center, click-to-
navigate on both system banners and feed rows, and new triggers with per-event
banner control.

## Architecture: new `NotificationStore` child store

A separate main-actor `ObservableObject` alongside `ServerStore`/`TabStore`/
`CanvasStore`, injected as an `@EnvironmentObject`. Rationale: the unread badge is
a frequent writer, and the perf guardrail forbids adding high-frequency writers to
`DashboardStore` (~64 publishers, full fan-out per mutation). All existing
`Notifier.post` call sites in `DashboardStore` switch to the store's `post(...)`
funnel. `Notifier` remains the low-level system-banner poster, called only by the
store.

Rejected alternatives: extending `DashboardStore` in place (guardrail violation);
deriving notifications from the NDJSON op log (task 0009) — diff-derived facts
(task done, PR merged, ticket status) are not hook events and would have to be
synthesized into the log anyway.

## Data model

```swift
enum NotificationKind: String, Codable, CaseIterable {
    // existing triggers
    case taskCreated, prReviewTask, taskDone, artifactAdded, prOpened, sessionFinished
    // new triggers
    case needsInput, sessionIdle, prMerged, ticketStatusChanged
}

struct AppNotification: Identifiable, Codable {
    let id: UUID
    let kind: NotificationKind
    let date: Date
    let title: String
    let body: String
    let projectPath: String?   // navigation target
    let tab: String?           // DetailTab rawValue to open
    let taskId: String?        // optional deep target (opens TaskDetailSheet)
}
```

`NotificationStore`:

- `@Published private(set) var feed: [AppNotification]` — newest first, 300-cap
  in memory (op-log tail pattern).
- `@Published var lastSeenAt: Date` — persisted to UserDefaults. **Unread = items
  newer than `lastSeenAt`**; opening the panel marks all seen. No per-item read
  flags, so NDJSON files stay append-only and never need rewriting.
- `post(kind:title:body:projectPath:tab:taskId:)` — single funnel: append to feed,
  append NDJSON (off main actor), post a system banner via `Notifier` iff that
  kind's banner toggle is on and the master `enableNotifications` is on.
- Per-kind banner prefs: `Set<NotificationKind>` in UserDefaults. Default:
  everything on except `sessionIdle`. `sessionIdle` is additionally hidden from
  the feed unless enabled (per-turn noise).

## Persistence

`NotificationLogStore` modeled on `EventLogStore` (crash-safe seek-to-end
appends): one NDJSON line per notification at
`~/.devdash/notifications/<yyyy-MM-dd>.ndjson`. Machine-global (not per-project)
because the feed spans projects. On launch, restore the last 3 days capped at
300. All writes off the main actor (`Task.detached`), per ADR 0013's pattern.

## New triggers

- **Claude needs input (`needsInput`)** — add the `Notification` hook event to
  `HookInstaller.hookSpecs` (fires when Claude waits on permission or input).
  Handle in the `DashboardStore` event switch → post with the session's project
  as target, tab `claude`. Existing projects pick it up via the installer's
  idempotent re-run on launch.
- **Session idle (`sessionIdle`)** — post from the existing `case "Stop"`
  handler. Banner default off; feed entry only when the kind is enabled.
- **PR merged (`prMerged`)** — new throttled poller on the existing refresh
  tick: for tasks with a `pr:` URL AND an active `worktree:`, run
  `gh pr view <url> --json state` off-main-actor, at most once per ~5 min per
  PR. On `merged`: post, and write `pr_merged: true` into the task frontmatter
  via `TaskStore.setOrAddFrontmatterKey` — dedupes across launches and lets
  `TaskDetailSheet` show its existing cleanup button without the on-demand
  fetch.
- **Ticket status changed (`ticketStatusChanged`)** — extend the existing
  snapshot-diff in the reload paths (same pattern as `taskSnapshot`): snapshot
  each ticket's rollup status, notify on transition, first-load silent
  (preserve the load-bearing nil-snapshot anti-spam guarantee).

## Click-to-navigate

- `AppDelegate` adopts `UNUserNotificationCenterDelegate`; each banner's
  `userInfo` carries `projectPath`/`tab`/`taskId`.
- `didReceive response:` → activate app → `store.selection = .project(path:)`,
  `tabStore.detailTab = tab`, and if `taskId` present, open the task detail
  sheet.
- One shared `navigate(to:)` implementation used by both the banner delegate and
  in-app feed rows.
- Implement `willPresent` to show banners while the app is foregrounded
  (currently macOS suppresses them for a frontmost app).

## UI

- **Bell icon in the ContentView toolbar** (near the mode picker) with an
  unread-count badge. Click opens a popover: newest-first list, each row = kind
  icon + title + body + relative time + project name; click navigates; "Clear"
  marks all seen. Empty state: "No notifications yet."
- **Settings → Notifications** grows into a per-kind list of banner toggles;
  the global `enableNotifications` toggle remains the master switch.

## Testing

Headless self-test suite `--selftest-notifications` (no-XCTest pattern): NDJSON
round-trip (append → restore, cap, 3-day window), unread computation vs
`lastSeenAt`, per-kind gating logic, ticket-status diff (silent first load,
notify on transition). PR poll + hook wiring verified live via open tasks
0003/0004.
