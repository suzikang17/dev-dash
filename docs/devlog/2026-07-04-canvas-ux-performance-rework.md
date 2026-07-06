---
lore_type: devlog
created: 2026-07-04
title: "Canvas UX/performance rework: equatable board, event bridge, panel pinning"
date: 2026-07-04
day: 17
---

**Reworked the canvas view end-to-end: killed the three main jank sources (hover-state re-renders, per-frame panel re-evaluation while panning, a 4000×3000 rasterized grid), added scroll-to-pan / raise-on-click / fit-all / snapping via an AppKit event bridge, and made panels pinnable to a different project than the canvas's.**

## What got done

- **Equatable board extraction** (`CanvasBoardView`): pan/scroll/hover state changes in `CanvasView` now move the panels layer as a pure compositor offset; panel bodies (WKWebViews, terminals, simulator) are only re-evaluated when the layout actually changes.
- **Removed `onContinuousHover` @State tracking** — it re-rendered the entire canvas on every mouse move. Right-click spawn location now comes from a non-consuming local NSEvent monitor writing into a non-observable class ref (`CanvasPointerRef`).
- **Viewport-phase grid** (`GridCanvas`): the grid is drawn viewport-sized with its line phase offset by `pan % 40`, replacing the fixed 4000×3000 `Canvas` (a huge backing texture). The board is now effectively infinite; `boardSize` is gone.
- **`CanvasEventBridgeView`** (NSView, `hitTest → nil`, local monitors): two-finger scroll pans the board over empty canvas (passes through over panels so their content scrolls), left-click anywhere in a panel raises it *without consuming the click*, double-click empty canvas = fit-all. Gated off while the floating terminal overlays the canvas, since its SwiftUI chrome is invisible to the monitors.
- **Fit All Panels**: double-click empty canvas or context menu; centers the bounding rect of all panels (top-left-pins when content exceeds the viewport). Fixes "panned into the void with no way home".
- **Snapping**: drag/resize snap to an 8pt grid with a stronger 6pt magnet to neighboring panel edges (edge alignment + flush adjacency).
- **Resize feel**: content reflow during resize is throttled to ~150ms steps instead of frozen-until-release (no more end-of-resize pop); shadow fades over 0.12s instead of vanishing when a drag starts.
- **Occlusion**: panels fully outside the viewport (+100pt hysteresis margin) get `opacity(0)` + no hit-testing but stay mounted, so terminals/simulators keep running.
- **Per-panel project pinning**: `CanvasPanel.projectOverride` + a `\.panelSelection` EnvironmentValue; all seven tab views resolve `panelSelection ?? store.selection`. Title-bar context menu → "Show Project". Simulator/terminal get the resolved project directly; content re-mounts (`.id(proj.path)`) when the pin changes.
- **CanvasStore hygiene**: z-values compacted to 0..<count on raise (they grew forever); persistence debounced 400ms (drag-end fired two full JSON encodes back-to-back); scroll-pan commits debounced 300ms in the view.

## Decisions

- **Event monitors over hit-tested NSViews** for scroll-pan/raise: a real NSView in the hit-test chain would steal mouseDown from SwiftUI gestures and scroll from panel content. The bridge view returns `nil` from `hitTest` and does everything through non-consuming local monitors + its own panel-frame hit-testing — zero interference with existing gestures.
- **Selection-level override (not project-level)** for pinning: injecting a `Selection?` lets `store.service(for:)` resolve too (Preview tab), and unpinned panels inject nothing so behavior is byte-identical to before.
- **Only pinned panels inject** `panelSelection` — a canvas shown for a `.service` selection keeps its service context in unpinned Preview panels.

## Issues

- **Reviewer caught a real resize bug** in my first throttle implementation: `DragGesture.translation` is cumulative from gesture start, and I re-anchored the baseline every throttle tick → panel size would balloon exponentially during a long resize. Fixed by splitting the never-reassigned gesture baseline (`resizeStart`) from the throttled content snapshot (`frozenContentSize`).
- Also caught: a stale 300ms scroll-pan commit could overwrite a later drag-pan/fit-all commit (now cancelled at drag-end/fit-all), and `PreviewTabView`'s `onChange(of: store.selection)` reset `showingProduction` on pinned panels for unrelated selection changes.
- `ChangesTabView` initially failed to compile — I edited its two use sites but forgot to add the `@Environment(\.panelSelection)` property.

## What to remember

- **Any @State written on every mouse move / drag frame re-renders the whole owning view** — keep pointer scratch in a plain class held by @State (identity only), and split per-frame-changing state away from expensive subtrees with an `Equatable` view + `.equatable()`.
- The board coordinate space (`canvasBoard`) must stay on the *panned container*, and panel drags must measure in it — measuring in a panel's own moving space feeds back on itself.
- The floating terminal (and any same-window overlay above the canvas) is invisible to local NSEvent monitors; new canvas-wide event handling must check `store.terminalOpen && store.terminalPlacement == .floating`.
- Old persisted layouts decode fine: `projectOverride` is optional (synthesized `decodeIfPresent`).
