---
lore_type: devlog
created: 2026-06-19
title: "Perf sweep, sidebar process grouping, and the project one-pager"
date: 2026-06-19
day: 2
---

**Made the SwiftUI UI snappier, grouped the sidebar's running processes under their project, and shipped an auto-synthesized per-project status snapshot in the living document.**

## What got done

- **Store-perf split.** Pulled the high-frequency dev-server state (`serverLogs`, `managedRunning`, `startingProjects`, `startErrors`) out of the `DashboardStore` mega-store into a new `ServerStore` (`Sources/DevDash/ServerStore.swift`), injected as its own `@EnvironmentObject`. Server-log streaming was firing `objectWillChange` on the whole store on every stdout line, re-rendering Home/Sidebar/every tab.
- **Killed in-body hot paths.** Cached `primaryServiceMap` in memory (was reading `UserDefaults` inside HomeView's sort comparator every render) and cached `devServices`/`infraServices` via a `didSet` on `services`. Hoisted per-render collection work out of `body` in HomeView, SidebarView, and TasksTabView (group-by-column once, group-by-stage once, MyQueue derive-once). Moved synchronous `FileManager` disk hits out of bodies (AppleAppPreview, KanbanCard, ProductTabView, TaskDetailSheet) into `@State` resolved on appear.
- **Sidebar process grouping.** The Running list now groups services under their owning project (`SidebarView.groupRunning`): projects with 2+ processes show a header surfacing the ports (instead of the git branch) with nested process rows; single-process projects stay flat.
- **Project one-pager (new feature).** `ProjectStatus` (pure `Codable` value) synthesized by `ProjectStatusSynthesizer` from store data (tasks / commit heatmap / running services / health) plus `LoreReader` reads of the latest devlog + decision. Rendered as a deterministic "Snapshot" card pinned to the top of the living-document Overview tab via `ProductDocGenerator`. Brainstormed → spec'd → planned under `docs/superpowers/`.
- **Adversarial review.** Ran a multi-agent review of the one-pager; it surfaced 2 low-severity determinism bugs in `LoreReader.latest`, both fixed and re-verified.

## Decisions

- **Split the store by update frequency, not mechanically.** Only the server domain churns at high frequency (per-log-line). `recapStreaming` is declared-but-never-mutated; the other ~30 `@Published` props change on user action or the 15s refresh, so splitting them adds rewiring risk across ~340 `store.` sites for no perceptible gain.
- **The one-pager reads lore, it does not extend it.** No new `status` lore type — a written snapshot goes stale the instant it's saved and would clutter the append-only log. lore stays the capture layer; the one-pager is a deterministic projection over it.
- **Deterministic synthesis (no AI).** Always current, zero upkeep, and it composes trivially into a future cross-project roll-up (`projects.map(projectStatus)`).
- **Build-and-launch verification.** The repo has no test target (executable-only package with custom Info.plist linker flags); adding one risks fighting those flags. Verified with `swift build` + launching the app instead.

## Issues

- `ProjectStatus: Codable` required adding `Codable` to the bare `String` enum `HealthStatus` (automatic synthesis).
- SourceKit throws "Cannot find X in scope" for newly-added same-module types until reindex — `swift build` is the source of truth, as CLAUDE.md notes.
- Review caught `LoreReader.latest` picking an arbitrary file on same-date/undated ties (filesystem iteration order) and letting a malformed date string out-sort real dates while rendering undated. Fixed by validating the date prefix through the `DateFormatter` before using it as the sort key and making the ordering total with a filename tiebreak.

## What to remember

- `ServerStore` is a separate `@EnvironmentObject` injected on ContentView. Readers: LogsTabView (+ `EmptyLogsView`), InfoTabView, PreviewTabView's `NotRunningView`. Action methods (`startServer`/`stopServer`) stay on `DashboardStore` and write through to it.
- Phase-2 cross-project board is set up but intentionally unbuilt — it's `projects.map(projectStatus)`; `ProjectStatus` is `Codable` for exactly that.
- The frontmatter parser now lives canonically on `LoreReader.parseFrontmatter` (extracted from DailyTabView's deleted private copy).
- To force a headless living-doc regen for verification, seed `UserDefaults` (domain `com.suki.devdash`): `devdash.lastSelection = "project:<path>"` and `devdash.lastTabPerProject = {<path>: "product"}`, then launch — the Product tab's `regen()` fires on appear. (Side effect: this repointed the app's restored selection to cliphy → Product.)
- Nothing from this session is committed yet — perf split, perf sweep, sidebar grouping, and the one-pager (+ spec/plan docs) are all uncommitted on `main`.
