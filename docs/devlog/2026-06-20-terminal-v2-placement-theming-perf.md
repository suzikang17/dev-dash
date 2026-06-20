---
lore_type: devlog
created: 2026-06-20
title: "Terminal v2: placement, theming, perf, quick-run"
date: 2026-06-20
day: 5
---

**Extended the embedded terminal with configurable placement (bottom/side/floating), theme-following colors, font zoom, quick-run, and persistence — then an adversarial review caught 8 issues (off-screen stranding, per-frame reflow, stuck cursor, tab rebuilds) which were fixed and committed in `874355e`.**

## What got done
- **Placement** — `TerminalPlacement` (bottom drawer / side panel / floating), switchable from the header `⋯` menu and Settings, persisted. New `TerminalPanel` is placement-agnostic; `BottomTerminalContainer` / `SideTerminalContainer` / `FloatingTerminalPanel` wrap it and own resizing.
- **Theming** — terminal bg/fg/caret follow the app light/dark theme via `applyTerminalAppearance`; re-applies live on theme change. `TerminalSessionStore` now holds a `TerminalAppearance` (theme/font/cursor/scrollback).
- **UX** — auto-focus on open (`makeFirstResponder`), font zoom (⌘= / ⌘− / ⌘0), quick-run bar (claude / lore / build) via `send(txt:)`, persisted geometry (height/width/floating frame/font size/open state).
- **Review fixes** (see Issues) — floating clamp, resize placeholder, balanced hover cursor, stable `tabArea` identity, on-disappear geometry commit.

## Decisions
- **Resize state lives in each container, not `DetailPaneView`** — so dragging the handle doesn't re-evaluate the tab content body above (the original perf win).
- **`tabArea` gets one stable identity; the terminal attaches via `safeAreaInset`/`overlay`** rather than a per-placement `switch` that reparents it. Switching placement no longer tears down/rebuilds heavy tab views (WebViews, scroll state).
- **Floating "modal" = movable/resizable non-blocking panel**, not a true blocking modal.
- Reused the existing SwiftTerm dependency for everything; no new deps.

## Issues
- Adversarial multi-lens review (4 lenses → per-finding verification) flagged 11, confirmed 8, all fixed:
  - **Floating panel could be dragged/persisted off-screen** with no on-screen handle to recover → clamp origin+size to the container (`GeometryReader` → `containerSize`) on drag, on appear, and on window resize.
  - **Resize still redrew SwiftTerm every frame** (the `@State` split only fixed SwiftUI churn) → swap the live terminal for a placeholder during the drag; one reflow on release.
  - **NSCursor push/pop imbalance** left a stuck resize cursor app-wide when a handle was removed mid-hover (⌘`-close, placement switch) → self-balancing `HoverCursor` modifier with guarded push/pop + `onDisappear` pop.
  - **Placement switch rebuilt tab content** (WebView reloads) → fixed by the stable-`tabArea` decision above.
  - **Interrupted drags dropped the geometry write** (only committed in `onEnded`) → also commit in `onDisappear`.

## What to remember
- The repo was being edited concurrently by another workstream (lore-as-engine migration + a design-system token pass: `DSColor`/`DSSpace`/`DSFont`). `DashboardStore.swift` and `SettingsView.swift` ended up shared between terminal v2 and a "living-doc appearance" feature, so the commit necessarily bundles both — they can't be split per-file without interactive staging.
- `ProductDocGenerator`/`ProductTabView` now depend on `LoreSection` (lore-as-engine Phase 1), so those are coupled to that migration.
- Lifecycle teardown (kill + `waitpid` reap) is verified by `TerminalSelfTest` (`--selftest-terminal`); it still passes after the appearance/init changes.

---

## Commits
- 874355e terminal v2: placement, theming, perf, quick-run + review fixes
