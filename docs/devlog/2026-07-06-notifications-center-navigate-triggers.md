---
lore_type: devlog
created: 2026-07-06
title: "Notifications: in-app center, click-to-navigate, per-event triggers"
date: 2026-07-06
day: 19
---

**Shipped the full notifications feature — a `NotificationStore` child store feeding an in-app bell/popover, click-to-navigate from banners and rows, per-event toggles, four new triggers, NDJSON persistence — and live verification caught two real migration bugs before they shipped.**

## What got done

- **`NotificationStore`** (new child store, per the store-split guardrail): 300-cap feed,
  `lastSeenAt` mark-all-seen unread model, per-kind banner prefs, single `post(...)` funnel.
  All 7 existing `Notifier.post` call sites in `DashboardStore` route through it with a
  `NotificationKind` + navigation target.
- **`NotificationLogStore`**: append-only NDJSON at `~/.devdash/notifications/<date>.ndjson`
  (EventLogStore's crash-safe pattern); feed restores last 3 days on launch. Verified the
  restore survives two app relaunches.
- **In-app notification center**: toolbar bell + red unread badge, popover with kind icons,
  relative times, project names; opening marks all seen.
- **Click-to-navigate**: `AppDelegate` is now `UNUserNotificationCenterDelegate`
  (`willPresent` shows banners while frontmost); banner `userInfo` and feed rows share
  `DashboardStore.navigate` → selection → tab → TaskDetailSheet. Verified end-to-end: clicking
  the feed row jumped from pet-homepage to dev-dash's Tasks tab with task 0999's sheet open.
- **New triggers**: `needsInput` (new `Notification` hook event in HookInstaller + one-time
  migration for existing installs), `sessionIdle` (Stop hook; default off, hidden from feed
  unless enabled), `prMerged` (throttled `gh pr view` poll for tasks with pr+worktree; durable
  `pr_merged: true` frontmatter dedupe), `ticketStatusChanged` (rollup-status snapshot diff).
- **Settings**: per-kind checkbox list under the master toggle.
- **`--selftest-notifications`** suite (NDJSON round-trip/torn-tail/restore-window, unread,
  gating, ticket rollup) + `pr_merged` round-trip in the taskstore suite. All suites pass.
- Project verify skill written to `.claude/skills/verify/SKILL.md` (window-scoped capture,
  EventServer curl injection, AX gotchas).

## Decisions

- Separate `ObservableObject` instead of `@Published` on `DashboardStore`: the unread badge is
  a high-frequency writer; the hub store's ~64 publishers fan out everywhere (guardrail).
- Unread = `date > lastSeenAt` (mark-all-seen), no per-item read flags — keeps the NDJSON log
  append-only forever.
- Feed records everything regardless of banner toggles (except opt-in `sessionIdle`); toggles
  gate banners only. Master `enableNotifications` stays the banner kill-switch, read from
  UserDefaults at post time.
- PR-merge detection by polling on the refresh tick (5-min/PR throttle) rather than
  hook-only — catches merges done on github.com or another machine.

## Issues

- **Live verification caught two real bugs** the self-tests couldn't:
  1. The Notification-hook migration no-op'd when `defaultEnabledEvents` had never been
     persisted (fresh default already contains the new event → no didSet → installed
     projects' settings.json never reconciled).
  2. The migration ran in App.task **before** `refreshAll()`, so its reconcile loop iterated
     an empty `projects` array. Moved after `refreshAll()`.
  Both fixed in `229e4ec`; verified `Notification` now lands in `.claude/settings.json`.
- Concurrent session left `CanvasView.swift` mid-edit (`spawnOrigin` deleted but referenced);
  blocked builds for a while — the other session fixed it.
- AppleScript `click at {x,y}` passes **through** the Settings overlay to views behind it
  (custom rows expose no AX elements); Settings toggles verified by injection-site grep +
  gating self-tests instead of pixels.

## What to remember

- Popovers are separate NSWindows — `screencapture -l<mainWindowID>` misses them; the window
  ID changes every relaunch.
- Injecting hook events without a live Claude session:
  `curl -H "X-DevDash-Token: $token" --data-binary '{"hook_event_name":"Notification",...}' http://127.0.0.1:$port/hook`
  (endpoint + token in `~/.devdash/event-endpoint.json`).
- One-time migration flags live in the `com.suki.devdash` defaults domain
  (`defaults delete com.suki.devdash devdash.migratedNotificationHookEvent` to re-run).
- macOS suppressed banners while the app was frontmost until `willPresent` returned
  `[.banner, .sound]` — likely why the pre-existing notifications felt absent.

---

## Commits

- 25ccd13 docs: design spec for notifications (in-app center, click-to-navigate, per-event triggers)
- 4d7e713 docs: implementation plan for notifications feature
- e3fd980 feat: notification models + NDJSON notification log (ADR 0013 pattern)
- ed554ce feat: NotificationStore child store — feed, unread, per-kind banner gating
- 1893412 feat: route all notifications through NotificationStore funnel
- 4289fa3 feat: click-to-navigate — banner delegate + shared navigate path
- 653764a feat: notification bell + in-app notification center popover
- 86080d3 feat: per-event notification toggles in Settings
- f3088a3 feat: needs-input + session-idle notification triggers (Notification hook)
- e6bc1f6 feat: PR-merged notification via throttled gh poll + pr_merged frontmatter dedupe
- 95118fc feat: ticket-status-changed notifications via rollup diff
- 229e4ec fix: Notification-hook migration — reconcile fresh defaults, run after projects load
