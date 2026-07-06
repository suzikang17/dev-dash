---
lore_type: decision
title: "Canvas focus/navigation interaction model: explicit focused panel gates all input routing"
date: 2026-07-06
category: architecture
revisit: false
---

## Why this choice

The canvas mixes two kinds of input targets: the board itself (pan, WASD, zoom)
and panel content (terminals, webviews, lists) that legitimately wants the same
keys and scroll gestures. The first implementation routed by *implicit* AppKit
state — WASD checked `NSWindow.firstResponder`'s class, scroll checked what was
under the cursor per event. Both felt arbitrary in practice: a once-clicked
terminal silently owned the keyboard forever (clicking empty canvas doesn't move
first responder off it), and a pan gesture that slid a panel under the cursor
started scrolling that panel's content mid-gesture.

The fix is one explicit, *visible* piece of state: **the focused panel**
(`CanvasView.focusedPanelID`, transient, accent ring when set).

- **Navigation mode** (`nil`, the default): WASD steers, two-finger scroll pans
  the board *everywhere* — including over panels — and the pinch-out overview is
  always navigation. Text fields outside the board (toolbar ⌘K) still keep keys.
- **Focused mode** (click a panel): keys and scroll-under-cursor belong to panel
  content; the board only pans from empty canvas. Esc or an empty-canvas click
  returns to navigation (and drops AppKit first responder so webviews/terminals
  release the keyboard).
- Scroll gestures **latch their route at gesture start** (`.began` → pan or
  content) and hold it through momentum, so a route can't flip mid-gesture.
- Focus lands on mouse-**up**, never mouse-down: focusing re-renders the board
  (ring + raise), and doing that on mouse-down resets an in-flight title-bar
  drag before it can start.
- Jump shortcuts (⌘1–9) and overview double-click-dive set focus to their target
  panel; entering the overview clears it.

## Options considered

1. **Implicit routing off `firstResponder` + cursor position** (the first
   implementation). Rejected: state invisible to the user, WASD availability
   unpredictable, per-event scroll routing breaks gesture continuity.
2. **Modifier-key navigation** (hold Space/Alt to pan, like design tools).
   Rejected for now: fine for pointer, but doesn't answer *keyboard* routing
   (WASD vs terminal typing) which was the actual conflict.
3. **Explicit focused-panel state gating all routing** (chosen).
4. **Consume the first click on an unfocused panel** (click-to-focus, then
   interact — iPad style). Rejected: breaks click-through to title-bar drags and
   feels unresponsive; non-consuming focus-follows-click keeps macOS semantics.

## Tradeoffs

- One more piece of transient UI state to keep coherent across zoom, project
  switches, panel removal, and jumps — all reset/derive it explicitly.
- In navigation mode, scroll over a panel pans the board instead of scrolling
  the panel; users must click a panel first to scroll its content. This is the
  point of the model, but it's a behavior change from stock macOS
  scroll-under-cursor.
- Focus is session-transient (not persisted in `CanvasLayout`) — deliberate:
  restoring a stale focus ring after relaunch would surprise more than it helps.
- The event bridge (non-consuming local NSEvent monitors + `hitTest → nil`)
  stays the single place all this routing lives; any new canvas-wide gesture
  must go through it or it will fight the latching/focus rules.
