---
lore_type: policy
title: Performance guardrails
applies_to: project, task
trigger: on_work
status: active
---
Every rule here comes from a real, user-visible UI lag incident in this repo.
Follow them when writing or reviewing any Swift code. Narrative + history:
`docs/ARCHITECTURE.md` §"Performance guardrails"; summary in `CLAUDE.md`.

## Main-thread rules

1. **No synchronous file I/O or subprocess on the main actor from `body`,
   `.onAppear`, `.onChange`, or `.task` bodies.** Offload with `Task.detached`
   and write back on the MainActor. After the `await`, re-check the result is
   still current (the user may have switched project/selection) before
   assigning state — pattern: `ProductTabView.regen`, `DocsTabView.reload`.
2. **Nothing expensive inside `var body`.** No `FileManager` checks, no
   `UserDefaults` reads, no re-filter/re-sort of large collections per render.
   Resolve once into `@State` via `.task(id:)` / `.onAppear`, or group once
   with `Dictionary(grouping:)` and reuse — incidents: per-card
   `fileExists` in Kanban cards, disk hits in `AppleAppPreview.body`,
   `UserDefaults` inside HomeView's sort comparator.

## Store rules (DashboardStore has ~64 @Published properties)

3. **Batch `@Published` dict writes: one assignment per refresh, not one per
   project/key.** Every mutation republishes to every observer of the store —
   a per-project write loop re-renders the whole app N times.
4. **Never add a high-frequency writer to `DashboardStore`.** Per-line log
   output re-rendering every tab is why `ServerStore` exists; laggy ⌘1–9 is
   why `TabStore` exists; per-frame panel drags are why `CanvasStore` exists.
   Split a child store ONLY when the writer is hot AND narrowly consumed —
   do not mechanically split the other ~30 properties (they change rarely;
   rewiring ~340 `store.` sites adds risk for no gain).
5. **Prefer single-file / single-project reload paths**
   (`LoreTasksView.updateInPlace`, `reloadTasksAndNotifyForProject`) over
   directory-wide rescans of all projects.

## View & gesture rules

6. **Per-frame state (drags, pans, hover) must not invalidate big views.**
   Keep live gesture state in local `@State` on the smallest view and commit
   to the store on gesture end. Cursor-tracking scratch goes in a plain class
   held by `@State` (identity only — property writes don't invalidate).
   Isolate expensive subtrees behind an `Equatable` view + `.equatable()` so
   per-frame parent state changes skip them — pattern: `CanvasView` /
   `CanvasBoardView`.
7. **Static `DateFormatter`s only** — never allocate one in a loop or `body`.
8. **Guard WKWebView reloads with a content hash** in `updateNSView` — it
   fires for unrelated state changes, and a reload resets scroll position
   (pattern: `DocWebView`).
9. **Arm watchers/timers once per scope, not per reload** — a watcher that
   rearms from its own change events churns dispatch sources.

## Process rules

10. **One subprocess where two would do**; batch git scanner invocations.
    Never shell out from views — use the runner stack
    (`ShellRunner` → `ClaudeRunner`/`LoreRunner`).
11. Before claiming a change done: `swift build` **from the repo root** (the
    link step resolves `Info.plist` relatively) plus the relevant self-test
    suite; for anything interactive, `bash run.sh` and feel it.
