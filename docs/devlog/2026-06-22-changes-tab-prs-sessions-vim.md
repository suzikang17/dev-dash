---
lore_type: devlog
created: 2026-06-22
title: "Changes tab iteration: stacked commits, vim nav, PRs + Sessions views"
date: 2026-06-22
day: 5
---

**Iterated the new Changes tab into a real diff client: stacked commit/PR/session views, full vim navigation, and a PRs + Claude Code Sessions mode switcher.**

## What got done
- **Follow-ups from the build:** surfaced git mutation failures via an error banner (stage/unstage/revert no longer fail silently); replaced the dead `pendingFilePath` cross-tab writes with `DashboardStore.openFile()` (opens in the OS default app, since the in-app file viewer is gone) and removed the property.
- **Layout fixes:** side-by-side diff now fills the pane (vertical-only scroll; the both-axes ScrollView had collapsed the columns to center). Extracted `DiffRowsView` (no inner ScrollView) so the stacked commit view scrolls as one — fixed nested scroll views clipping section heights (couldn't reach the bottom of files). Rows render lazily; files >600 rows start collapsed.
- **Stacked commit detail (GitHub-style):** flat selectable commit list → right pane shows commit header + every changed file as a collapsible side-by-side diff in one scroll, with a jump bar and per-file +/- stats. One `git show` per commit, split via new `UnifiedDiffParser.parseMultiFile` (+ `FileDiff.additions/deletions`). 2 new parser tests (10 total).
- **Sidebar UX:** resizable divider with width persisted in `@AppStorage` (200–500pt, default 300); abbreviated relative commit dates (`34s`, `3m`, `2h`).
- **Vim navigation:** `j/k`/`gg`/`G`/Ctrl-d/u to move a cursor through the sidebar (auto-loads each diff), `l`/Enter to focus the diff pane, `j/k`/Ctrl-d/u/`gg`/`G` to scroll it (lines for a file, file-sections for a stacked view), `h`/Tab/Esc back. Uses `scrollPosition(id:)`; suppressed the `.focusable()` focus ring with `.focusEffectDisabled()`.
- **PRs + Sessions view modes:** segmented switcher (Changes | PRs | Sessions) atop the sidebar, all sharing a generalized `StackedDiffView`. PRs = `gh pr list --state all` → `gh pr diff`. Sessions = this project's `SessionDigest`s → stacked diff of files the session wrote.

## Decisions
- **One generalized `StackedDiffView`** (title/subtitle/sections) backs commits, PRs, and sessions instead of three bespoke views — the vim scroll + jump-bar plumbing is shared.
- **Session diff base = the commit just before the session started** (`git rev-list -1 --before=<startedAt>`), diffed to the working tree. Diffing vs HEAD showed 0 changes because session edits were already committed.
- **Sidebar is resizable but persistent** (AppStorage), not a fresh HSplitView each time — user wanted a stable width that survives tab switches/relaunch.

## Issues
- Sessions initially showed 0 diffs — files were already committed, so vs-HEAD was empty. Fixed with the pre-session-commit base (above). Tradeoff: the diff now folds in any later edits to those same files (no per-session snapshots exist).
- PRs depend on `gh` auth + a GitHub remote; under the app's sandboxed shell they resolve via `/bin/zsh -lc` (login PATH for nix-installed gh). Empty list = check `gh auth status`.
- `@main`-style nested scroll views silently clipped content height; the symptom was "can't scroll to the bottom," not a crash.

## What to remember
- New stacked sources just need: a list in the sidebar, a `NavItem` case, and an `activate` branch calling `loadStacked(key:title:subtitle:)` with an async `[FileDiffSection]` loader. Everything else (scroll, vim, collapse, jump bar) is shared.
- `SessionDigest.filesTouched` records absolute `file_path`s with read/write counts; `rel()` strips the project prefix for git.
- Vim keys live in `handleSidebarKey`/`handleDiffKey` in `ChangesTabView`; `gg` uses a `pendingG` flag.

---

## Commits
- 7b5618e changes: surface git mutation failures + route cross-tab file opens externally
- d049d78 changes: fix diff layout — fill pane width (vertical-only scroll, top-aligned cells)
- d2b8f47 changes: stacked commit detail view (all files in one scroll)
- 30f7b7f changes: fix stacked-diff scroll cutoff + lazy-render commit sections
- 3bb78e3 changes: fixed-width commit sidebar instead of resizable split
- 7a55ce2 changes: abbreviate commit relative dates (34s ago, 3m ago, 2h ago)
- f26bf1b changes: resizable sidebar with persisted width (drag handle, 200-500pt)
- a50c3d7 changes: drop "ago" from relative dates (34s, 3m, 2h)
- 937959a changes: vim-style navigation (j/k/gg/G, focus switch, diff scrolling)
- 993f445 changes: add PRs and Claude Code Session view modes
- 8fb5edb changes: session diff vs pre-session commit (fixes empty session diffs)
- 1de20a4 changes: hide focus ring on diff panes (focusEffectDisabled)
