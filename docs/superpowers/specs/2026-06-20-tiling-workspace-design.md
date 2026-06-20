# Tiling Workspace — Design Spec

**Status:** Parked (spec only — not yet scheduled for build)
**Date:** 2026-06-20
**Author:** brainstormed with Claude (Opus 4.8)

## Goal

Replace the detail pane's "one tab at a time + bottom/side/floating terminal
placement" model with a **freeform tiling workspace** (a true window-manager-style
tiler) scoped per project. Every view — a terminal shell, or any existing detail
tab (Files, Preview, Docs, Claude, Tasks, Info, Product, Logs, Daily) — becomes a
**tile** the user can open, split, resize, rearrange, and close.

This was chosen over lighter options (a 2-pane split, or a preset-layout picker)
and over keeping tabs+tiles side by side. Decision: **tiling *becomes* the detail
area** — the tab bar and the placement modes go away rather than coexisting with a
second model.

## Non-goals

- Tiling across multiple OS windows. Single-window, the workspace is the detail pane.
- Floating tiles. This is a *tiling* WM (every leaf fills its slot), not floating.
- Tiling the sidebar / projects list. The `NavigationSplitView` sidebar stays.

## Data model

A **binary split tree**, one per project (i3-style; binary keeps split/join/resize
simple — every split has exactly two children and one ratio):

```swift
indirect enum WorkspaceNode {
    case leaf(Tile)
    case split(axis: Axis, ratio: CGFloat, WorkspaceNode, WorkspaceNode)
}
enum Axis { case horizontal, vertical }   // horizontal = side-by-side, vertical = stacked

struct Tile: Identifiable {
    let id: UUID
    var content: TileContent
}
enum TileContent {
    case terminal(id: UUID)     // a shell, keyed independently of project
    case view(DetailTab)        // reuse the existing DetailTab views as tile bodies
}
```

- `ratio` ∈ (0,1): fraction the *first* child gets along `axis`.
- `DetailTab` survives from the current code, but only as a *content kind* — the
  single-selection tab bar UI is removed.

## Operations

- **Split** the focused tile (H or V): replace its `.leaf` with a `.split` whose
  first child is the original tile and second child is a new tile (defaults to a
  new terminal). Default ratio 0.5.
- **Close** a tile: remove the leaf; its sibling collapses up to take the parent's
  space (the parent `.split` is replaced by the surviving child).
- **Resize**: drag the divider between a split's two children → adjust that node's
  `ratio`. Clamp so neither child goes below a min size.
- **Set content**: each tile header has a picker to switch what it shows (a shell,
  or any `DetailTab`).
- **Rearrange (drag-and-drop)** — *the hard part*: drag a tile's header onto another
  tile. Drop zones over the target: **center** = swap the two tiles; **edge**
  (left/right/top/bottom) = split the target along that edge and drop the dragged
  tile into the new slot. Removing the dragged tile from its old location collapses
  its old sibling up.
- **Focus**: click a tile to focus it; focused tile shows a ring/highlight; split
  and close act on the focused tile. Keyboard shortcuts operate on focus.

## Architecture / components

- **`WorkspaceStore`** (`ObservableObject`): holds the per-project trees
  (`[projectPath: WorkspaceNode]`), the focused tile id, and all mutating ops
  (split / close / resize / setContent / move). Owns persistence.
- **`DetailPaneView`**: renders `WorkspaceView(project:)` instead of `tabArea` +
  the bottom/side/floating insets. `ContentView`'s `NavigationSplitView` (sidebar +
  detail) is unchanged; only the detail content changes.
- **`WorkspaceView(project:)`**: looks up the project's tree, renders the root node.
- **`WorkspaceNodeView`** (recursive): for `.split`, lays out two `WorkspaceNodeView`s
  along the axis with a draggable divider between them (drives `ratio`); for `.leaf`,
  renders a `TileView`.
- **`TileView`**: header (content picker, split-H, split-V, close; focus ring when
  focused) + body (a `TerminalHostView` for `.terminal`, or the matching tab view
  for `.view`). Acts as a drag source (header) and drop target (body, with edge/center
  zones) for rearrange.

## Terminal session model change

`TerminalSessionStore` currently caches **one shell per project path**. The
workspace allows **multiple terminals per project**, so sessions must be keyed by
**tile/terminal id**, not project path:

- `session(for terminalId: UUID, cwd: projectPath)` spawns/returns a shell per tile.
- Lifecycle (teardown on close, reconcile on project removal, app-quit cleanup)
  generalizes to per-terminal-id. When a terminal tile is closed, its shell is torn
  down (reusing the existing terminate/reap logic).

## Persistence

- Each project's `WorkspaceNode` tree encodes to JSON, persisted under a per-project
  UserDefaults key (e.g. `devdash.workspace.<projectPath>`).
- Terminal **content** persists structurally (a tile is `.terminal`), but live shell
  *processes* do not survive app relaunch — on load, terminal tiles spawn fresh
  shells. (Matches today's behavior: sessions are in-memory.)
- A sensible default tree for a project with no saved layout: a single `.leaf` whose
  content is the project's primary view (e.g. `.view(.product)` or `.view(.files)`).

## What gets removed

- The detail tab bar + `⌘1–9` tab shortcuts (tabs become tile content, not a bar).
- `TerminalPlacement` enum and the placement modes:
  `BottomTerminalContainer`, `SideTerminalContainer`, `FloatingTerminalPanel`,
  and the `terminalOpen` / `terminalPlacement` / `terminalFloatingFrame` /
  `terminalWidth` / `terminalHeight` state.
- The `⌘\`` toggle becomes "split a terminal into the focused tile" (or similar).
- `DetailTab` enum itself is **kept** (reused as `TileContent.view`).

## Phased build plan

1. **Core tiler:** tree model + `WorkspaceStore` + recursive render + split/close/
   resize + content picker. Multiple-terminal session keying. No drag-rearrange yet.
   (Working tiler you can split/close/resize.)
2. **Drag-to-rearrange:** header drag source + tile drop target with center/edge
   drop zones, swap + split-on-edge.
3. **Persistence + polish:** per-project tree persistence, keyboard shortcuts
   (split/close/focus-move), focus ring, sensible defaults, empty-state.

## Risks / constraints

- **Large teardown of just-shipped code.** This removes the floating/side/bottom
  terminal work (committed `d79bbda`) and subsumes the other session's tab refactor
  (`TabStore` / `detailTab`). Those files (`ContentView`, `DetailPaneView`,
  `TerminalPanel`, `TabStore`, `DashboardStore`) are exactly where a concurrent
  session has been actively working — **coordinate / pause that work before building**
  to avoid severe conflicts.
- **Drag-and-drop is hard to validate without seeing the GUI.** The current dev loop
  has been "edit blind → rebuild → user eyeballs," because the DevDash window sits
  behind a fullscreen cmux session and can't reliably be screenshotted by the agent.
  A drag-rearrange WM needs tight visual iteration — either set up reliable
  screenshotting/driving for the agent, or expect the user to test each phase closely.
- **Scope:** this is days of work across multiple sessions, not a single pass. Treat
  each phase as its own spec→plan→build cycle. Phase 1 is the foundation; phases 2–3
  are independently shippable increments.

## Open questions (resolve before Phase 1)

- Default new-tile content on split: always a terminal, or a content picker prompt?
- Min tile size (px) before a split is refused.
- What `⌘\`` and other existing terminal shortcuts map to in the new model.
- Whether the project's first-open default tree is fixed or remembers last layout.
