---
lore_type: devlog
created: 2026-06-20
title: "Command bar: toolbar-integrated command line + repo jump"
date: 2026-06-20
day: 3
---

**Turned the ⌘K palette into a toolbar-integrated command line with repo jump-to and vim navigation, moved the refresh/terminal/timestamp controls into the sidebar footer, and split `detailTab` into `TabStore` to kill ⌘1–9 lag.**

## What got done
- **Repo navigation in the command bar:** typing a repo name surfaces `Go to <repo>` rows (full path as subtitle), jumping via `store.selection` (which already records nav history, so ⌘[ back works). Repos sort first, so the default highlight + Enter lands on the top match.
- **Vim-style keyboard nav:** Ctrl-J/Ctrl-K (plus Ctrl-N/P and arrows) move the highlight; Enter activates; Esc dismisses. Clamps at the ends (no wrap-around, per request). Bare j/k can't be used while the field has focus, hence the Ctrl modifier.
- **Placement iteration:** floating centered overlay → top-right drop-from-chrome → finally an inline `TextField` in the toolbar's `primaryAction`, with results rendered as a same-window `.overlay` (not an `NSPopover`).
- **⌘K focus via AppKit:** SwiftUI `@FocusState` doesn't reach a `TextField` hosted in the toolbar (separate titlebar context), so focus/blur go through `window.makeFirstResponder`, locating the field by placeholder.
- **Relocated controls:** refresh + terminal toggle + "Ns ago" timestamp moved out of the toolbar into a new sidebar bottom-footer row (⌘R / ⌘` still bound there).
- **`TabStore` split:** `detailTab` + per-project tab memory extracted from `DashboardStore` so tab switches stop republishing the whole store / re-rendering the sidebar. (Detailed separately in the design-token devlog; this session is what surfaced the lag.)
- Removed the now-dead `store.isCommandBarVisible`.

## Decisions
- **Field + results in one place vs. split:** chose an inline toolbar field with a *same-window overlay* for results, because an `NSPopover` takes key focus and breaks type-ahead. Both halves share a small `CommandBarModel`; key handling lives in `ContentView` (where focus is), results are presentational.
- **AppKit for ⌘K focus:** the only reliable way to focus a toolbar-hosted field programmatically.
- **`TabStore` split is justified, not naive:** hot, user-driven, narrowly consumed — same profile as the earlier `ServerStore` split, not the "don't naively split the rest" anti-pattern.

## Issues
- A concurrent design-token migration was rewriting ~27 view files mid-session; `swift build` kept aborting with "input file modified during build" until the sweep went quiescent. Had to gate builds on source-tree write-idle. That same process ended up committing the working tree (incl. this session's work) into `878562f`.
- `stat -f` on this machine is GNU-flavored (prints filesystem info, not a format string) — used `date -r <file>` for mtimes instead.
- `@FocusState` + toolbar = no programmatic focus; that was the ⌘K-not-focusing bug.

## What to remember
- `detailTab` now lives on `store.tabStore`, not `store`. Writers set `store.tabStore.detailTab`; observers (`DetailPaneView`, toolbar `Picker`) need `@EnvironmentObject TabStore` (injected in `App.swift`).
- The command field is in the toolbar but its vim/Enter handling is in `ContentView`; results are a separate same-window overlay. Don't convert results back to a popover — it breaks focus.
- ⌘K focus matches the field by placeholder ("Jump to a repo…"). If that copy changes, update `findCommandField`.

---

## Commits
- 878562f extract TabStore from DashboardStore for granular tab re-render; command-bar + terminal + lore-doc polish
