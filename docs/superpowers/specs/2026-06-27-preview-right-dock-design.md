# Preview right dock + terminal relocation

**Date:** 2026-06-27
**Status:** Approved — implementing

## Problem / goal

Preview should be viewable *alongside* the other tabs, not only as the main detail page.
Move it into a **right-docked, resizable panel** (draggable from narrow up to nearly
full-width). Since the right side is now reserved for Preview, also **remove the
terminal's right-side placement** and keep it in the main page (bottom or floating).

Mirrors the existing side-terminal pattern: a toggle + persisted width, a panel rendered
beside the `NavigationSplitView` in `ContentView`.

## Part A — Preview right dock

**Store (`DashboardStore`), persisted like the terminal:**
- `previewDockOpen: Bool` — `devdash.previewDock.open`
- `previewDockWidth: CGFloat` — `devdash.previewDock.width`, default 480

**Layout (`ContentView`):** render a `PreviewDockContainer` in the trailing `HStack`,
beside the `NavigationSplitView`, when `previewDockOpen && a project is selected`. A
draggable divider on its leading edge writes back to `store.previewDockWidth` (same
pattern as `SideTerminalContainer`). Dragging it wide shrinks the main pane toward the
left. It follows the current selection.

**Content:** hosts the existing `PreviewTabView()` unchanged (Web | iOS switcher, address
bar, snapshot tools, iOS simulator embed with zoom). No new preview logic — relocated.

**Remove the tab:** drop `.preview` from `DetailTab` (segmented strip + ⌘-number
shortcuts) and from `DetailPaneView`'s switch. Preview lives *only* in the dock now.

**Toggle:** a Preview button in the sidebar footer next to the terminal toggle, bound to
**⌘P** (currently unused). Disabled when no project is selected (like the terminal toggle).

**New component:** `PreviewDockContainer` — fixed-position right panel with a draggable
resize divider (mirrors `SideTerminalContainer`), wrapping `PreviewTabView`. Bounds:
min ~360, max = nearly full window width.

## Part B — Terminal placement

- `TerminalPlacement`: remove `.side`; keep `.bottom` and `.floating`.
- Migrate any persisted `.side` value to `.bottom` on load (so existing users don't land
  on a now-invalid placement).
- `ContentView`: remove the `SideTerminalContainer` block beside the split view.
- Delete the now-unused `SideTerminalContainer` struct in `TerminalPanel.swift`.
- The two placement pickers (`SettingsView`, `TerminalPanel`) iterate
  `TerminalPlacement.allCases`, so they update automatically.
- `terminalWidth` store property is now unused by the terminal; leave it (harmless) — the
  Preview dock uses its own `previewDockWidth`.

## Files

- **Modify** `DashboardStore.swift` — add `previewDockOpen` / `previewDockWidth`; remove
  `.side` from `TerminalPlacement`; migrate persisted `.side` → `.bottom`.
- **Modify** `ContentView.swift` — render `PreviewDockContainer`; add ⌘P toggle; remove
  the side-terminal block.
- **New** `PreviewDockContainer` (in `ContentView.swift` or its own file) — resizable
  right panel wrapping `PreviewTabView`.
- **Modify** `Models.swift` — drop `.preview` from `DetailTab`.
- **Modify** `DetailPaneView.swift` — drop the `.preview` switch case.
- **Modify** `TerminalPanel.swift` — delete `SideTerminalContainer`.
- **Modify** `SidebarView.swift` — add the Preview-dock toggle button (footer).

## Out of scope

- Bottom/floating placements for the Preview dock (right-only).
- Responsive collapse of the iOS sim's Build & Run panel at narrow dock widths (widen the
  dock for comfort; collapse is a possible follow-up).
- Changes to the global Simulator destination.
