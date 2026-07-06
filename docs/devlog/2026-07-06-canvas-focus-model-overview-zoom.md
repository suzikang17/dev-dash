---
lore_type: devlog
created: 2026-07-06
title: "Canvas focus model, pinch overview zoom, minimap, WASD + gesture fixes"
date: 2026-07-06
day: 19
---

**Iterated the canvas into a coherent interaction model with the user in the loop: explicit focused-panel state (ADR 0014) gating WASD/scroll routing, pinch-out overview zoom, minimap, ⌘1–9 panel jumps — plus a debugging saga that ended in "NSLog doesn't reach `log show` on this OS".**

## What got done

- **Focus/navigation model** ([[0014-canvas-focus-navigation-interaction-model]]): navigation mode (no focus) = WASD steers + scroll pans everywhere; click a panel → accent ring, keys/scroll go to content; Esc / empty-click returns to navigation and drops AppKit first responder.
- **Pinch-out overview zoom**: transient render-only `scaleEffect` (panels non-interactive below 100% — AppKit content can't hit-test under a scale); drag pans the overview, double-click dives in centered, Esc/pinch-in exit, snap-home above 0.8. Fit All now *actually fits*: zooms out to the panels' bounding box instead of only centering.
- **Minimap** (bottom-right): tinted blocks per panel kind + viewport outline, click/drag to fly; doubles as the bridge's dead zone so its clicks don't read as canvas clicks.
- **WASD navigation**: 60Hz timer-driven pan from non-consuming key monitors, diagonal-normalized, never steals from text fields.
- **⌘1–9 panel shortcuts**: assigned via title-bar menu, stored on `CanvasPanel`, jump = raise + center + focus; in canvas mode numbers prefer panels over (inert) tab switching.
- Gesture-correctness fixes from live user testing: scroll route latched at `.began` through momentum (panning was bleeding into panel content mid-gesture); focus moved to mouse-up (focusing on mouse-down re-rendered the board and reset title-bar drags — panels became undraggable); overview click-to-dive demoted to double-click.

## Decisions

- ADR 0014 — explicit focused-panel state over implicit `firstResponder`/cursor routing.
- Zoom is transient and capped at 1 (overview only) — working scale stays pixel-perfect and drag/snap math never runs under a transform.

## Issues

- **NSLog is stderr-only on this macOS** — `log show`/`log stream` never saw the canvas diagnostics (and `log` in zsh is a *builtin*, silently shadowing `/usr/bin/log`). Debugging only progressed after launching the binary directly with stderr captured to a file. Also: `open DevDash.app` does NOT restart a running instance — earlier "relaunches" sometimes just foregrounded a stale build.
- WASD's original gate (`firstResponder` class check) was unfixable UX: clicking empty canvas never moves first responder off a terminal/webview, so keys stayed stolen. The focus model + explicit `makeFirstResponder(nil)` on empty-click solved it.

## What to remember

- Debugging this app's runtime: `sed '$d' run.sh | bash` then run `DevDash.app/Contents/MacOS/DevDash 2>&1 > file` directly (nohup) — that's the only way to see NSLog output; use `/usr/bin/log` explicitly if querying unified log (zsh shadows `log`).
- Never mutate state that re-renders the board on mouse-*down* — it resets in-flight SwiftUI drag gestures; defer to mouse-up.
- All canvas-wide input routing lives in `CanvasEventBridgeView` (non-consuming monitors, `hitTest → nil`); new gestures must respect the scroll-route latch and focus gates.
