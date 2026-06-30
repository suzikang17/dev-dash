---
lore_type: devlog
created: 2026-06-30
title: "Canvas workspace + iOS simulator preview"
date: 2026-06-30
day: 13
---

**Turned the iOS simulator into a project-scoped Preview surface, then a right-side dock, then a full freeform canvas workspace — and made the baguette server shared so it stops being flaky.**

## What got done
- **Subdir Xcode discovery**: `XcodeProject.discover` now scans one level deep (preferring `ios`/`App`/`apple`/`macos`, skipping `node_modules`/`Pods`/`.build`) so a Next.js repo like pet-homepage with its project in `ios/PetHomepage.xcodeproj` is found. The returned `rootPath` points at the dir containing the project so `xcodebuild` cwd + derived-data slug stay right.
- **Preview tab → iOS mode**: extracted the simulator surface (baguette server, live `WKWebView` embed, `SimAppRunner` build→install→launch) into a reusable `SimulatorEmbedView(fixedProject:)`. `SimulatorView` is now a thin wrapper. Preview gained a Web | iOS switcher (per-project, persisted) for repos that have both. Added pinch + button zoom on the embed and moved Build & Run into a compact bottom bar (was a side panel that squished the phone).
- **Preview right dock**: Preview left the main tab strip and became a resizable right-side dock (`PreviewDockContainer`, ⌘P / sidebar button), following the current project. Dropped the terminal's right-side placement (bottom + floating only); deleted `SideTerminalContainer`.
- **Canvas workspace (Tier 1)**: per-project freeform board (`CanvasView` + `CanvasPanelView` + `CanvasStore`, persisted). Panels (tabs, web preview, iOS simulator, terminal, and a new general **Browser** panel) float, drag, resize, stack, pan. Right-click to spawn at the cursor.
- Pushed both **dev-dash** and **lore** to their remotes (lore needed a rebase onto newer remote work).

## Decisions
- **No global canvas zoom (Tier 1).** A throwaway spike confirmed `scaleEffect` over an `NSView`-backed `WKWebView` goes blurry and breaks hit-testing. So panels render at native scale and "zoom into a thing" = resize the panel. This supersedes the parked i3-style tiling spec — freeform floating, not a tiler.
- **Canvas is an additive mode**, entered by a toolbar toggle; the tab strip + detail pane stay intact (low-risk, reversible).
- **One shared baguette server.** `baguette serve` is a single machine-wide process on port 8421, so all simulator views observe `BaguetteRunner.shared` instead of each owning a `@StateObject`.

## Issues
- **Simulator flakiness ("stop/start a few times")** was multiple `BaguetteRunner` instances spawning duplicate servers that collided on 8421, plus orphaned `baguette serve` processes surviving past app quit. Fix: shared runner + `start()` now probes the port and **adopts** an already-running server; the server is no longer torn down on view disappear (only the explicit Stop button).
- **Drag flicker + cursor drift** on canvas panels: the drag was measured in the panel's own (moving) local coordinate space → feedback loop. Fixed by measuring in a stable named `canvasBoardSpace`, plus dropping the shadow while interacting (same trick as `FloatingTerminalPanel`).
- **Resize wouldn't grow** the simulator panel: the heavy `WKWebView` reflowed every drag frame (growing is costlier than shrinking, so the gesture starved). Fixed by freezing content at its start size during the drag and reflowing once on release — content stays mounted so the running sim keeps state.
- **"Random line across the middle"** when the dock opened: `ResizeHandle(edge: .leading)` drew its hairline as `Divider().rotationEffect(90°)`, which mis-laid-out into a full-width horizontal streak. Replaced with a 1pt vertical rule.
- **Panel content wasn't clickable** (couldn't use the simulator): a panel-wide `.onTapGesture { raise }` ate every click. Moved raise-to-front to the title bar only.
- Two-pane views (Today/Changes/Tasks are HSplitView/HStack needing ~640px+) spawned crushed; gave them wide/tall defaults.

## What to remember
- The dock and canvas **must not** swap heavy content for a placeholder during resize (the trick the terminal uses) — it tears down the panel and kills the running simulator's `BaguetteRunner`. Keep content mounted; freeze its size instead.
- `BaguetteRunner` is a singleton now — don't reintroduce per-view `@StateObject` runners.
- Browser-panel URLs aren't persisted across launches yet (reopens blank). `pkill baguette` is not yet in `run.sh`, so dev relaunches can leave orphaned servers (now harmless thanks to adopt).

---

## Commits
- a6d8103 feat(sim): discover Xcode projects in subdirectories (e.g. ios/)
- 88f1ba8 feat(preview): iOS simulator mode in Preview tab
- aceaef1 feat(preview): dock Preview to a resizable right panel; move terminal off the right side
- 4d01585 docs(spec): canvas workspace design (Tier 1 — freeform panels, no global zoom)
- c75b916 feat(canvas): per-project freeform panel workspace (Tier 1)
- f9ce074 feat(canvas): browser panel, resize/interaction polish, shared simulator server
- 8c24d76 docs: refresh living-doc site (roadmap/decisions) + tickets 0005/0006
