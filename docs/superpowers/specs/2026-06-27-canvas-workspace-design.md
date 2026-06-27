# Canvas workspace (Tier 1 — freeform, no global zoom)

**Date:** 2026-06-27
**Status:** Approved — implementing

## Background

Vision: a spatial workspace where the simulator, task board, preview, logs, etc.
coexist as draggable/resizable panels. A spike proved that **global canvas zoom**
(SwiftUI `scaleEffect` over `WKWebView`s) is brittle — webviews go blurry and lose
hit-testing. So Tier 1 drops global zoom and keeps everything at native scale; "zoom
into a thing" = resize that panel. This supersedes the parked tiling-workspace spec
(`2026-06-20-tiling-workspace-design.md`): freeform floating panels, not an i3 tiler.

## Goal

A per-project **Canvas mode**, entered by a toolbar toggle. Today's tab strip + detail
pane stay exactly as they are — Canvas is additive and reversible. On the canvas, panels
hosting existing views float, drag, resize, and stack on a pannable board.

## Surface

- **Pannable** board (drag empty space to pan), bounded (e.g. 4000×3000), not literally
  infinite. Pan offset persisted per project.
- **No global zoom** — panels render at native scale. (The iOS sim keeps its own internal
  magnification from the Preview work.)

## Panels

Float, **drag** (by title bar), **resize** (bottom-right corner), **stack** (click to
raise z-order), **close** (✕). Each hosts one content kind. A **"+" menu** on the canvas
spawns a panel of a chosen kind.

Content kinds (v1) reuse existing views, wrapped in panel chrome:

- `.view(DetailTab)` — Info, Claude, Tasks, Product, Changes, Logs, Today
- `.preview` — web preview (`PreviewTabView`'s web surface for the project)
- `.simulator` — `SimulatorEmbedView(fixedProject:)`
- `.terminal(id)` — a live shell (reuses the terminal infra)

## Data model & persistence

Per project, persisted as JSON in UserDefaults (mirrors existing geometry persistence):

```swift
enum PanelKind: Codable, Hashable {
    case view(DetailTab)
    case preview
    case simulator
    case terminal(id: UUID)
}

struct CanvasPanel: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: PanelKind
    var frame: CGRect    // position + size on the board
    var z: Int           // stacking order; higher = front
}

struct CanvasLayout: Codable {
    var panels: [CanvasPanel] = []
    var pan: CGSize = .zero
}
```

`CanvasStore` (or `DashboardStore` fields) holds `[projectPath: CanvasLayout]`, persisted
under `devdash.canvas.<key>`. Reopening Canvas for a project restores its layout.

## Components

- **`CanvasView`** — the pannable surface for the current project: renders panels sorted
  by `z`, hosts the "+" spawn menu, owns pan-drag state, reads/writes the project's
  `CanvasLayout`.
- **`CanvasPanelView`** — generic panel chrome (title bar drag, resize corner, raise-on-
  click, close button) wrapping arbitrary content. Generalizes the floating-terminal
  pattern already in `TerminalPanel.swift`.
- **`PanelContentView`** — maps a `PanelKind` to its view (`DetailTab` body / web preview
  / `SimulatorEmbedView` / terminal).
- **Store** — per-project `CanvasLayout` + a `canvasMode: Bool` toggle (per project).
- **Toolbar** (`ContentView`) — a Canvas toggle shown when a project is selected; when on,
  `DetailPaneView` renders `CanvasView` instead of the selected tab.

## Routing

`DetailPaneView`: when `store.canvasMode` (and a project is selected), render `CanvasView`;
otherwise the existing tab switch. The tab picker stays visible but inert under canvas, or
is hidden while canvas is on (decide in build — lean: hide it, show a "Canvas" label).

## Scope

- **In:** drag, resize, stack, pan, spawn/close, per-project persistence, all content kinds
  above.
- **Out (v1):** global zoom; multi-project/global canvas; snapping / alignment guides;
  saved layout presets; minimize/maximize.
- **Risk — many live panels** (several webviews + terminals) cost memory/CPU. v1 mitigation:
  panels are spawned deliberately (no auto-fill). If it bites, add a "suspend offscreen
  panels" pass later (out of scope now).

## Build order (incremental, each builds + launches)

1. Data model (`PanelKind`/`CanvasPanel`/`CanvasLayout`) + store fields + persistence.
2. `CanvasPanelView` chrome (drag/resize/raise/close) with a placeholder body.
3. `CanvasView` surface + pan + "+" spawn menu; wire into `DetailPaneView` behind the toggle.
4. `PanelContentView` — real content for each kind.
5. Polish: focus ring, persistence round-trip, empty-state hint.
