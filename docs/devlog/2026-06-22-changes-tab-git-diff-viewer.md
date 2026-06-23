---
lore_type: devlog
created: 2026-06-22
title: "Changes tab: kyde-style git diff viewer (replaces Files tab)"
date: 2026-06-22
day: 5
---

**Replaced the Files tab with a Changes tab — a side-by-side git diff viewer with working-tree stage/revert + commit history — built via a 4-phase autonomous workflow.**

## What got done
- Brainstormed + specced a kyde-inspired diff viewer, then drove it to completion as a phased autonomous build (one Workflow per phase: implement → independent verify → adversarial review → fix).
- **Phase 1** — new `DevDashCore` SwiftPM library target holding the pure diff model (`DiffRow`/`WordSpan`/`FileDiff`/`DiffRowKind`) and `UnifiedDiffParser`, with a `DevDashCoreTests` target (8 passing tests). Split into a library specifically so the parser is unit-testable without linking the `@main` executable.
- **Phase 2** — `GitDiffScanner` (porcelain status → staged/unstaged `ChangedFile`s, `git log`, `git show --name-status`, per-file `fileDiff` incl. `--no-index` for untracked, and stage/unstage/revert via `GitStatusScanner.op`).
- **Phase 3** — `SideBySideDiffView`: single virtualized `LazyVStack` of pre-aligned left/right rows, reusing `SyntaxHighlighter` (NSColor tokens → `AttributedString`) plus word-level change backgrounds on `.modified` rows.
- **Phase 4** — `ChangesTabView` (Unstaged / Staged groups with per-file stage/revert + destructive-confirm, collapsible commit history → per-commit file diffs); renamed `DetailTab.files` → `.changes`, rewired `DetailPaneView`, deleted `FilesTabView.swift` (447 lines), and updated the 5 `.files` call sites.

## Decisions
- **Side-by-side via one aligned-row list**, not two synced NSTextViews — row alignment and `LazyVStack` virtualization come for free; can swap to dual-pane later.
- **Parse git's unified diff** rather than write an LCS line-differ; word-level highlight is char-level common-prefix/suffix (deterministic, easy to test). Git is effectively our `similar` crate.
- **Per-file** stage/revert only (no per-hunk), **no commit box** — scope was "see commits + stage files," not authoring.
- **Verification gate = `swift build` + parser unit tests only** (user opted into "full auto on compile signal"); GUI/IO layers have no behavioral tests by design.

## Issues
- `@main` makes the executable target unreliable to `@testable import`; the `DevDashCore` library split sidesteps it. SwiftPM also refused the test target until `Tests/DevDashCoreTests/` had a source file (a `Placeholder.swift` was added).
- Concurrent `daily:` work was committing to `main` during the run; agents were instructed to add only feature files by explicit path (never `git add -A`) so nothing unrelated got swept — verified each commit's stat afterward.

## What to remember
- `DevDashCore` is the home for pure, testable logic — put new unit-tested helpers there and `import DevDashCore` from the app.
- Known non-blocking follow-ups: stage/unstage/revert discard their `Bool` success (failures are silent); and `store.pendingFilePath` writes from ProductTab/TasksTab/TaskDetailSheet/VisualDiffSheet are now dead ends (the Changes tab ignores them) — either consume it (reveal/select the file) or remove those writes.
- Spec + plan: `docs/superpowers/specs/2026-06-22-changes-tab-diff-viewer-design.md`, `docs/superpowers/plans/2026-06-22-changes-tab-diff-viewer.md`.

---

## Commits
- dca9b7c core: add DevDashCore target + diff data model
- 4891604 core: unified diff parser with word-level spans + tests
- dabec5c changes: ChangedFile/GitCommit/FileDiffSource models
- 678e4a8 changes: GitDiffScanner (status/log/show/diff + stage/unstage/revert)
- 3b3b1c7 changes: side-by-side diff renderer (syntax + word-level highlight)
- 57e5fcd changes: ChangesTabView (sidebar groups + history + diff pane)
- 5b2fc54 changes: wire Changes tab, remove Files tab
