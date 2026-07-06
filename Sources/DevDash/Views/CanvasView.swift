import SwiftUI
import AppKit

/// Stable coordinate space for panel drag/resize math (see CanvasView/CanvasPanelView).
private let canvasBoardSpace = "canvasBoard"

/// Mutable scratch shared with the event bridge that must NOT invalidate SwiftUI:
/// cursor tracking through `@State` used to re-render the whole canvas on every
/// mouse move. Held in `@State` for identity only; property writes are invisible.
private final class CanvasPointerRef {
    var lastRightClick: CGPoint = .zero   // viewport-local; where spawned panels land
    var panCommit: Task<Void, Never>?     // debounces persisting scroll-wheel pans
}

/// Lightweight (name, path) pair for the panel "Show Project" pin menu, so panels
/// don't need to observe the (very chatty) DashboardStore just to list projects.
struct PanelProjectChoice: Hashable, Identifiable {
    let name: String
    let path: String
    var id: String { path }
}

// MARK: - CanvasView

/// Per-project freeform workspace: a pannable (drag empty space or two-finger
/// scroll), effectively infinite board of draggable/resizable panels. No global
/// zoom (panels render at native scale). Layout persists per project via
/// `CanvasStore`.
struct CanvasView: View {
    let project: Project
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var canvas: CanvasStore

    @State private var pan: CGSize = .zero
    @State private var panAccum: CGSize = .zero
    /// Pinch-out overview zoom, in (0, 1]. Transient — never persisted: 1 is the
    /// only working state (panels interact at native scale); anything below is a
    /// look-around mode where clicking a spot zooms back in on it.
    @State private var zoom: CGFloat = 1
    /// The panel that owns keyboard/scroll right now. nil = navigation mode:
    /// WASD steers, scroll pans everywhere (even over panels). Click a panel to
    /// focus it; click empty canvas or press Esc to return to navigation.
    @State private var focusedPanelID: UUID?
    @State private var pointer = CanvasPointerRef()

    private static let minZoom: CGFloat = 0.15

    /// Screen (viewport) point → board point, accounting for pan and the
    /// center-anchored overview zoom. At zoom 1 this is just `p - pan`.
    private func boardPoint(fromViewport p: CGPoint, viewport: CGSize) -> CGPoint {
        let cx = viewport.width / 2, cy = viewport.height / 2
        return CGPoint(x: (p.x - cx) / zoom + cx - pan.width,
                       y: (p.y - cy) / zoom + cy - pan.height)
    }

    private var layout: CanvasLayout { canvas.layout(for: project.path) }

    var body: some View {
        GeometryReader { geo in
            canvasBody(viewport: geo.size)
        }
        .onAppear { pan = layout.pan; panAccum = layout.pan }
        .onChange(of: project.path) { _, _ in
            pan = layout.pan; panAccum = layout.pan; zoom = 1; focusedPanelID = nil
        }
    }

    private func canvasBody(viewport: CGSize) -> some View {
        let l = layout
        let hidden = offscreenIDs(panels: l.panels, viewport: viewport)
        let choices = store.projects.map { PanelProjectChoice(name: $0.name, path: $0.path) }
        // Base fills the viewport; the board rides above as a pure-offset overlay.
        // The board subview is Equatable so per-frame pan/scroll state changes only
        // move its layer — panel bodies aren't re-evaluated unless the layout changes.
        return Color(NSColor.underPageBackgroundColor)
            .overlay { GridCanvas(pan: pan, zoom: zoom) }
            .overlay {
                CanvasEventBridge(
                    panels: l.panels,
                    pan: pan,
                    // The floating terminal overlays the canvas in the same window;
                    // its SwiftUI chrome is invisible to our monitors, so pause
                    // scroll-pan/raise rather than fight it for events.
                    interactive: !(store.terminalOpen && store.terminalPlacement == .floating),
                    // The minimap floats over the canvas; its clicks/drags must not
                    // read as empty-canvas clicks (raise / double-click fit).
                    deadZone: l.panels.isEmpty ? .zero : Self.minimapFrame(in: viewport),
                    zoom: zoom,
                    focusedPanel: focusedPanelID,
                    onScrollPan: { applyScrollPan($0) },
                    onFocusPanel: { setFocus($0) },
                    onRightClickEmpty: { pointer.lastRightClick = $0 },
                    onDoubleClickEmpty: { fitAll(viewport: viewport) },
                    onMagnify: { applyMagnify($0) },
                    onMagnifyEnded: { snapZoomIfClose() },
                    onZoomClick: { exitZoom(at: $0, viewport: viewport) },
                    onZoomExit: { exitZoom(at: nil, viewport: viewport) })
            }
            .contentShape(Rectangle())
            .gesture(panGesture)
            // Right-click empty canvas to add a panel.
            .contextMenu { addPanelMenuItems(viewport: viewport) }
            // Panels board — anchored to the viewport's top-left, panned via offset.
            .overlay(alignment: .topLeading) {
                CanvasBoardView(panels: l.panels, hidden: hidden, focused: focusedPanelID,
                                project: project, projectChoices: choices)
                    .equatable()
                    .offset(pan)
                    // Stable reference for panel drags: measuring translation in a
                    // panel's own (moving) local space feeds back on itself → drift.
                    .coordinateSpace(name: canvasBoardSpace)
                    // Overview zoom is a pure render transform, and panels are only
                    // interactive at working scale — clicking while zoomed out dives
                    // back in instead (AppKit content can't hit-test under a scale).
                    .scaleEffect(zoom, anchor: .center)
                    .allowsHitTesting(zoom == 1)
            }
            .overlay { if l.panels.isEmpty { emptyHint } }
            // Minimap: zoomed-out map of every panel + the current viewport.
            // Click or drag it to move the view.
            .overlay(alignment: .bottomTrailing) {
                if !l.panels.isEmpty {
                    CanvasMinimap(panels: l.panels, pan: pan, viewport: viewport, zoom: zoom) { newPan in
                        setPan(newPan, animated: false)
                    }
                    .padding(Self.minimapPadding)
                }
            }
            .onChange(of: canvas.jump) { _, j in handleJump(j, viewport: viewport) }
            .clipped()
    }

    static let minimapSize = CGSize(width: 180, height: 130)
    static let minimapPadding: CGFloat = 12

    /// Where the minimap sits, in viewport coords (for the event bridge's dead zone).
    static func minimapFrame(in viewport: CGSize) -> CGRect {
        CGRect(x: viewport.width - minimapPadding - minimapSize.width,
               y: viewport.height - minimapPadding - minimapSize.height,
               width: minimapSize.width, height: minimapSize.height)
    }

    // MARK: Panning

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                // Screen-space translation → board-space pan (zoom-corrected).
                pan = CGSize(width: panAccum.width + v.translation.width / zoom,
                             height: panAccum.height + v.translation.height / zoom)
            }
            .onEnded { _ in
                panAccum = pan
                // A scroll-pan's delayed commit must not overwrite this one later.
                pointer.panCommit?.cancel()
                canvas.setPan(pan, for: project.path)
            }
    }

    /// Single write path for programmatic pans (scroll, minimap, fit-all, jumps):
    /// local state immediately, store commit debounced so bursts persist once.
    private func setPan(_ new: CGSize, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) { pan = new }
        } else {
            pan = new
        }
        panAccum = new
        pointer.panCommit?.cancel()
        let path = project.path
        pointer.panCommit = Task { [canvas] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            canvas.setPan(new, for: path)
        }
    }

    /// Two-finger scroll / WASD pan (from the event bridge). Deltas arrive in
    /// screen px; divide by zoom so motion tracks the finger in overview too.
    private func applyScrollPan(_ delta: CGSize) {
        NSLog("[CanvasDebug] applyScrollPan delta=(%.1f, %.1f)", delta.width, delta.height)
        setPan(CGSize(width: pan.width + delta.width / zoom, height: pan.height + delta.height / zoom),
               animated: false)
    }

    /// Focus a panel (raising it) or, with nil, return to navigation mode.
    private func setFocus(_ id: UUID?) {
        focusedPanelID = id
        if let id { canvas.raise(id, for: project.path) }
    }

    // MARK: Overview zoom (pinch out)

    private func applyMagnify(_ delta: CGFloat) {
        zoom = min(1, max(Self.minZoom, zoom * (1 + delta)))
        if zoom < 1 { focusedPanelID = nil }   // the overview is navigation mode
    }

    /// Pinch ended close to working scale → snap home so the canvas doesn't
    /// linger at 97%.
    private func snapZoomIfClose() {
        guard zoom < 1, zoom > 0.8 else { return }
        withAnimation(.easeOut(duration: 0.18)) { zoom = 1 }
    }

    /// Leave the overview: click dives in centered on the clicked spot; Esc
    /// (viewportPoint nil) returns to working scale keeping the current center.
    private func exitZoom(at viewportPoint: CGPoint?, viewport: CGSize) {
        guard zoom < 1 else { return }
        if let p = viewportPoint {
            let b = boardPoint(fromViewport: p, viewport: viewport)
            setPan(CGSize(width: viewport.width / 2 - b.x,
                          height: viewport.height / 2 - b.y), animated: true)
            // Diving in on a panel focuses it — you came here to work on it.
            focusedPanelID = layout.panels
                .filter { $0.frame.contains(b) }
                .max { $0.z < $1.z }?.id
        }
        withAnimation(.easeOut(duration: 0.25)) { zoom = 1 }
    }

    /// Frame every panel (double-click empty canvas, or the context menu):
    /// center on the panels' bounding box AND zoom out just enough that all of
    /// it is visible. If that lands below working scale you're in the overview —
    /// click anywhere to dive back in at 100%.
    private func fitAll(viewport: CGSize) {
        let panels = layout.panels
        guard !panels.isEmpty else {
            withAnimation(.easeOut(duration: 0.22)) { zoom = 1 }
            setPan(.zero, animated: true)
            return
        }
        var bounds = panels[0].frame
        for p in panels.dropFirst() { bounds = bounds.union(p.frame) }
        let margin: CGFloat = 40
        let fit = min(1, (viewport.width - 2 * margin) / bounds.width,
                         (viewport.height - 2 * margin) / bounds.height)
        let target = CGSize(width: viewport.width / 2 - bounds.midX,
                            height: viewport.height / 2 - bounds.midY)
        NSLog("[CanvasDebug] fitAll viewport=(%.0f,%.0f) bounds=(%.0f,%.0f,%.0f,%.0f) zoom=%.2f target=(%.0f,%.0f)",
              viewport.width, viewport.height,
              bounds.minX, bounds.minY, bounds.width, bounds.height,
              fit, target.width, target.height)
        withAnimation(.easeOut(duration: 0.25)) { zoom = max(Self.minZoom, fit) }
        setPan(target, animated: true)
    }

    /// ⌘N panel shortcut fired (from ContentView via the store): raise + center.
    private func handleJump(_ j: CanvasStore.JumpRequest?, viewport: CGSize) {
        guard let j, j.path == project.path,
              let panel = layout.panels.first(where: { $0.id == j.panelID }) else { return }
        canvas.raise(panel.id, for: project.path)
        focusedPanelID = panel.id
        withAnimation(.easeOut(duration: 0.22)) { zoom = 1 }
        setPan(CGSize(width: viewport.width / 2 - panel.frame.midX,
                      height: viewport.height / 2 - panel.frame.midY),
               animated: true)
    }

    /// Panels fully outside the viewport (with margin) — kept mounted so terminals/
    /// simulators keep running, but hidden from the compositor. The margin gives the
    /// set hysteresis so it rarely changes mid-pan (each change re-evals the board).
    private func offscreenIDs(panels: [CanvasPanel], viewport: CGSize) -> Set<UUID> {
        let origin = boardPoint(fromViewport: .zero, viewport: viewport)
        let visible = CGRect(x: origin.x, y: origin.y,
                             width: viewport.width / zoom, height: viewport.height / zoom)
            .insetBy(dx: -100, dy: -100)
        return Set(panels.filter { !$0.frame.intersects(visible) }.map(\.id))
    }

    // MARK: Context menu (add panels / fit)

    @ViewBuilder
    private func addPanelMenuItems(viewport: CGSize) -> some View {
        // Spawn where the user right-clicked (board coords, zoom-aware).
        let spawn = boardPoint(fromViewport: pointer.lastRightClick, viewport: viewport)
        Section("Views") {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    canvas.addPanel(kind: .view(tab), for: project.path, at: spawn)
                } label: { Label(tab.label, systemImage: tab.systemImage) }
            }
        }
        Divider()
        Button { canvas.addPanel(kind: .preview, for: project.path, at: spawn) } label: {
            Label("Preview", systemImage: "globe")
        }
        Button { canvas.addPanel(kind: .browser, for: project.path, at: spawn) } label: {
            Label("Browser", systemImage: "safari")
        }
        Button { canvas.addPanel(kind: .simulator, for: project.path, at: spawn) } label: {
            Label("Simulator", systemImage: "iphone")
        }
        Button { canvas.addPanel(kind: .terminal(id: UUID()), for: project.path, at: spawn) } label: {
            Label("Terminal", systemImage: "terminal")
        }
        Divider()
        Button { fitAll(viewport: viewport) } label: {
            Label("Fit All Panels", systemImage: "arrow.down.forward.and.arrow.up.backward")
        }
    }

    private var emptyHint: some View {
        VStack(spacing: DSSpace.sm) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Empty canvas")
                .font(DSFont.sectionTitle)
            Text("Right-click anywhere to drop the preview, simulator, tasks, terminal, and more here — then drag and resize them however you like. Two-finger scroll pans; double-click empty space to re-center.")
                .font(DSFont.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - GridCanvas

/// Viewport-sized grid whose line phase follows the pan — reads as an infinite
/// board without the giant rasterized layer a board-sized Canvas would cost.
private struct GridCanvas: View {
    let pan: CGSize
    let zoom: CGFloat

    var body: some View {
        Canvas { ctx, size in
            // Board gridlines are 40pt apart; on screen that's 40·zoom, with the
            // phase matching the center-anchored zoom transform the board uses:
            // screen = (board + pan − C)·zoom + C.
            let step = 40 * zoom
            guard step >= 12 else { return }   // too dense to be useful when far out
            let cx = size.width / 2, cy = size.height / 2
            var p = Path()
            var x = ((pan.width - cx) * zoom + cx).truncatingRemainder(dividingBy: step) - step
            while x < size.width { p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height)); x += step }
            var y = ((pan.height - cy) * zoom + cy).truncatingRemainder(dividingBy: step) - step
            while y < size.height { p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)); y += step }
            ctx.stroke(p, with: .color(.gray.opacity(0.10)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - CanvasBoardView

/// The panels layer, split out and Equatable so pan/scroll/hover state changes in
/// `CanvasView` move this subtree as a layer instead of re-evaluating every panel
/// (whose bodies host WKWebViews, terminals, the simulator — expensive to diff).
private struct CanvasBoardView: View, Equatable {
    let panels: [CanvasPanel]
    let hidden: Set<UUID>
    let focused: UUID?
    let project: Project
    let projectChoices: [PanelProjectChoice]

    static func == (a: Self, b: Self) -> Bool {
        a.panels == b.panels && a.hidden == b.hidden && a.focused == b.focused
            && a.project == b.project && a.projectChoices == b.projectChoices
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(panels) { panel in
                CanvasPanelView(panel: panel,
                                projectPath: project.path,
                                offscreen: hidden.contains(panel.id),
                                isFocused: panel.id == focused,
                                neighborFrames: panels.filter { $0.id != panel.id }.map(\.frame),
                                projectChoices: projectChoices) {
                    PanelContentView(kind: panel.kind, project: project,
                                     overridePath: panel.projectOverride)
                }
                .zIndex(Double(panel.z))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - CanvasMinimap

/// Zoomed-out map of the whole board: every panel as a tinted block, plus the
/// current viewport as an outlined rectangle. Click or drag anywhere on it to
/// recenter the view there — the no-zoom answer to "where is everything?".
private struct CanvasMinimap: View {
    let panels: [CanvasPanel]
    let pan: CGSize
    let viewport: CGSize
    let zoom: CGFloat
    let onMove: (CGSize) -> Void   // new pan value

    /// The board rect currently visible in the viewport (zoom-aware).
    private var visibleRect: CGRect {
        let cx = viewport.width / 2, cy = viewport.height / 2
        return CGRect(x: (0 - cx) / zoom + cx - pan.width,
                      y: (0 - cy) / zoom + cy - pan.height,
                      width: viewport.width / zoom,
                      height: viewport.height / zoom)
    }

    var body: some View {
        let size = CanvasView.minimapSize
        let region = boardRegion()
        let scale = min(size.width / region.width, size.height / region.height)
        // Center the mapped region inside the minimap box.
        let inset = CGSize(width: (size.width - region.width * scale) / 2,
                           height: (size.height - region.height * scale) / 2)
        func toMap(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - region.minX) * scale + inset.width,
                   y: (r.minY - region.minY) * scale + inset.height,
                   width: r.width * scale, height: r.height * scale)
        }
        return Canvas { ctx, _ in
            for panel in panels.sorted(by: { $0.z < $1.z }) {
                let r = toMap(panel.frame)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.5),
                         with: .color(minimapColor(panel.kind).opacity(0.55)))
            }
            let vp = toMap(visibleRect)
            ctx.stroke(Path(roundedRect: vp, cornerRadius: 2),
                       with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(width: size.width, height: size.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.small))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(DSColor.hairline, lineWidth: 1))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    // Map point → board point → pan that centers the viewport there.
                    let bx = (v.location.x - inset.width) / scale + region.minX
                    let by = (v.location.y - inset.height) / scale + region.minY
                    onMove(CGSize(width: viewport.width / 2 - bx,
                                  height: viewport.height / 2 - by))
                }
        )
        .accessibilityLabel("Canvas minimap")
    }

    /// The board area worth mapping: all panels plus the current viewport,
    /// padded so there's always a little context around the edges.
    private func boardRegion() -> CGRect {
        var r = visibleRect
        for p in panels { r = r.union(p.frame) }
        return r.insetBy(dx: -80, dy: -80)
    }

    private func minimapColor(_ kind: PanelKind) -> Color {
        switch kind {
        case .view(let tab):
            switch tab {
            case .tasks:  return .blue
            case .daily:  return .teal
            case .docs:   return .purple
            case .claude: return .pink
            default:      return .gray
            }
        case .preview:   return .green
        case .browser:   return .cyan
        case .simulator: return .indigo
        case .terminal:  return .orange
        }
    }
}

// MARK: - CanvasEventBridge

/// Invisible AppKit shim under the panels. It never participates in hit-testing
/// (all clicks/gestures still belong to SwiftUI and the panels' own NSViews);
/// instead it hosts local event monitors + does coordinate conversion to provide:
///  - two-finger scroll panning over empty canvas (panel content keeps its scroll)
///  - raise-on-click anywhere in a panel, without eating the click
///  - the right-click location for spawn placement (replaces per-mouse-move
///    hover tracking through @State, which re-rendered the canvas continuously)
///  - double-click empty canvas → fit all
private struct CanvasEventBridge: NSViewRepresentable {
    let panels: [CanvasPanel]
    let pan: CGSize
    let interactive: Bool
    let deadZone: CGRect
    let zoom: CGFloat
    let focusedPanel: UUID?
    let onScrollPan: (CGSize) -> Void
    let onFocusPanel: (UUID?) -> Void
    let onRightClickEmpty: (CGPoint) -> Void
    let onDoubleClickEmpty: () -> Void
    let onMagnify: (CGFloat) -> Void
    let onMagnifyEnded: () -> Void
    let onZoomClick: (CGPoint) -> Void
    let onZoomExit: () -> Void

    func makeNSView(context: Context) -> CanvasEventBridgeView {
        let v = CanvasEventBridgeView()
        apply(to: v)
        return v
    }

    func updateNSView(_ v: CanvasEventBridgeView, context: Context) { apply(to: v) }

    private func apply(to v: CanvasEventBridgeView) {
        v.panels = panels
        v.pan = pan
        v.interactive = interactive
        v.deadZone = deadZone
        v.zoom = zoom
        v.focusedPanel = focusedPanel
        v.onScrollPan = onScrollPan
        v.onFocusPanel = onFocusPanel
        v.onRightClickEmpty = onRightClickEmpty
        v.onDoubleClickEmpty = onDoubleClickEmpty
        v.onMagnify = onMagnify
        v.onMagnifyEnded = onMagnifyEnded
        v.onZoomClick = onZoomClick
        v.onZoomExit = onZoomExit
    }
}

final class CanvasEventBridgeView: NSView {
    var panels: [CanvasPanel] = []
    var pan: CGSize = .zero
    var interactive = true
    var deadZone: CGRect = .zero
    var zoom: CGFloat = 1
    var focusedPanel: UUID?
    var onScrollPan: ((CGSize) -> Void)?
    var onFocusPanel: ((UUID?) -> Void)?
    var onRightClickEmpty: ((CGPoint) -> Void)?
    var onDoubleClickEmpty: (() -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var onMagnifyEnded: (() -> Void)?
    var onZoomClick: ((CGPoint) -> Void)?
    var onZoomExit: (() -> Void)?

    private var monitors: [Any] = []

    override var isFlipped: Bool { true }   // top-left origin, matching SwiftUI/board coords

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitors()
        NSLog("[CanvasDebug] bridge viewDidMoveToWindow window=%@ bounds=%@",
              window.map { String(describing: $0) } ?? "nil", NSStringFromRect(bounds))
        guard window != nil else { return }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            self?.handleScroll(e) ?? e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp]) { [weak self] e in
            self?.handleMouseDown(e) ?? e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            self?.handleKey(e) ?? e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] e in
            self?.handleMagnify(e) ?? e
        } as Any)
    }

    private func handleMagnify(_ e: NSEvent) -> NSEvent? {
        guard interactive, let w = window, e.window === w else { return e }
        let p = convert(e.locationInWindow, from: nil)
        guard bounds.contains(p) else { return e }
        if e.phase == .ended || e.phase == .cancelled {
            onMagnifyEnded?()
            return nil
        }
        // Pinch-in at working scale belongs to the content under the cursor
        // (webviews may magnify themselves); pinch-out, or anything while
        // already zoomed, steers the overview.
        if zoom >= 1 && e.magnification > 0 { return e }
        onMagnify?(e.magnification)
        return nil
    }

    deinit { removeMonitors() }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        stopMoving()
    }

    // MARK: WASD navigation

    /// Keys currently held; a 60Hz timer pans while any are down (game-style).
    private var heldKeys: Set<String> = []
    private var moveTimer: Timer?
    private static let panSpeed: CGFloat = 1100   // pt/s

    /// WASD steers only in navigation mode (no focused panel), and never steals
    /// keys from an actively-editing text field (e.g. the toolbar ⌘K field).
    private func navigationOwnsKeys() -> Bool {
        guard let w = window, w.isKeyWindow, focusedPanel == nil else { return false }
        if let fr = w.firstResponder, fr is NSText || fr is NSTextField { return false }
        return true
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        if e.type == .keyDown, e.keyCode == 53 {   // Esc
            if zoom < 1 { onZoomExit?(); return nil }
            if focusedPanel != nil {
                // Leave the focused panel → navigation mode.
                window?.makeFirstResponder(nil)
                onFocusPanel?(nil)
                return nil
            }
            return e
        }
        guard let ch = e.charactersIgnoringModifiers?.lowercased(),
              ["w", "a", "s", "d"].contains(ch) else { return e }
        if e.type == .keyUp {
            // Always release a key we captured, even if focus moved mid-hold.
            if heldKeys.remove(ch) != nil { stopIfIdle(); return nil }
            return e
        }
        guard interactive, navigationOwnsKeys(),
              e.modifierFlags.intersection([.command, .option, .control]) == [] else { return e }
        guard !e.isARepeat else { return nil }   // timer drives motion, not key repeat
        heldKeys.insert(ch)
        if moveTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.moveTick() }
            RunLoop.main.add(t, forMode: .common)
            moveTimer = t
        }
        return nil
    }

    private func moveTick() {
        guard !heldKeys.isEmpty else { stopIfIdle(); return }
        // W shows what's above → board slides down → pan.height grows (and so on).
        var d = CGSize.zero
        if heldKeys.contains("w") { d.height += 1 }
        if heldKeys.contains("s") { d.height -= 1 }
        if heldKeys.contains("a") { d.width += 1 }
        if heldKeys.contains("d") { d.width -= 1 }
        guard d != .zero else { return }
        let mag = sqrt(d.width * d.width + d.height * d.height)   // normalize diagonals
        let step = Self.panSpeed / 60
        onScrollPan?(CGSize(width: d.width / mag * step, height: d.height / mag * step))
    }

    private func stopIfIdle() {
        guard heldKeys.isEmpty else { return }
        stopMoving()
    }

    private func stopMoving() {
        moveTimer?.invalidate()
        moveTimer = nil
        heldKeys.removeAll()
    }

    /// Event location in our (flipped, viewport-local) coords, or nil when the
    /// event belongs to another window, falls outside the canvas, or is over
    /// the minimap (`deadZone`), which handles its own interaction.
    private func localPoint(of e: NSEvent) -> CGPoint? {
        guard let w = window, e.window === w else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        guard bounds.contains(p), !deadZone.contains(p) else { return nil }
        return p
    }

    /// Topmost panel under a viewport-local point, if any.
    private func panel(at local: CGPoint) -> CanvasPanel? {
        let board = CGPoint(x: local.x - pan.width, y: local.y - pan.height)
        return panels.filter { $0.frame.contains(board) }.max { $0.z < $1.z }
    }

    /// Where the current scroll gesture is routed. Latched at gesture start and
    /// held through momentum: panning must not start scrolling a panel's content
    /// just because the board slid that panel under the cursor mid-gesture.
    private enum ScrollRoute { case pan, content }
    private var scrollRoute: ScrollRoute?

    private func routeForScroll(at p: CGPoint) -> ScrollRoute {
        guard bounds.contains(p), !deadZone.contains(p) else { return .content }
        // Navigation mode (no focused panel, or overview zoom) pans everywhere.
        // Only with a focused panel does scroll-under-cursor go to panel content.
        if zoom >= 1, focusedPanel != nil, panel(at: p) != nil { return .content }
        return .pan
    }

    private func handleScroll(_ e: NSEvent) -> NSEvent? {
        guard interactive, let w = window, e.window === w else { return e }
        let p = convert(e.locationInWindow, from: nil)

        let route: ScrollRoute
        if e.phase == .began {
            route = routeForScroll(at: p)          // gesture start → decide + latch
            scrollRoute = route
        } else if e.phase == [] && e.momentumPhase == [] {
            route = routeForScroll(at: p)          // classic wheel: per-event
        } else {
            route = scrollRoute ?? routeForScroll(at: p)   // mid-gesture/momentum → latched
        }
        if e.momentumPhase == .ended || e.phase == .cancelled { scrollRoute = nil }

        guard route == .pan else { return e }
        // Line-based (mouse wheel) deltas are tiny; scale to feel like pixels.
        let scale: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        onScrollPan?(CGSize(width: e.scrollingDeltaX * scale, height: e.scrollingDeltaY * scale))
        return nil
    }

    private func handleMouseDown(_ e: NSEvent) -> NSEvent? {
        guard let p = localPoint(of: e) else { return e }
        switch e.type {
        case .leftMouseDown:
            guard interactive else { break }
            if zoom < 1 {
                // Don't dive on press — a drag from here pans the overview. The
                // matching mouse-up decides (clean double-click = dive in).
                zoomClickStart = p
            } else if let hit = panel(at: p) {
                // Focus on mouse-UP, not here: focusing re-renders the board
                // (ring + raise), which resets the title bar's drag gesture
                // before it can start — panels became undraggable.
                panelClickID = hit.id
            } else {
                // Back to navigation mode. Also drop AppKit key focus so a
                // once-clicked terminal/webview doesn't keep swallowing keys.
                window?.makeFirstResponder(nil)
                onFocusPanel?(nil)
                if e.clickCount == 2 { onDoubleClickEmpty?() }
            }
        case .leftMouseUp:
            // Single clicks in the overview are inert (drag pans); only a clean
            // DOUBLE-click dives back to working scale. Esc / pinch-in also exit.
            if zoom < 1, e.clickCount == 2, let start = zoomClickStart,
               hypot(p.x - start.x, p.y - start.y) < 4 {
                onZoomClick?(p)
            }
            zoomClickStart = nil
            // Deferred panel focus (see leftMouseDown). Fires after a title-bar
            // drag completes too — the panel moved with the cursor, so focusing
            // what you just dragged is right.
            if let id = panelClickID { onFocusPanel?(id) }
            panelClickID = nil
        case .rightMouseDown:
            if zoom >= 1, panel(at: p) == nil { onRightClickEmpty?(p) }
        default:
            break
        }
        return e
    }

    /// Mouse-down location while zoomed out, pending click-vs-drag resolution.
    private var zoomClickStart: CGPoint?
    /// Panel pressed at working scale; focused on the matching mouse-up.
    private var panelClickID: UUID?
}

// MARK: - CanvasPanelView

/// Generic panel chrome: title bar (drag to move), resize corner, raise-on-click,
/// close, pin-to-project menu. Keeps a live frame in @State during interaction and
/// commits to the `CanvasStore` on end (mirrors `FloatingTerminalPanel`). Drag and
/// resize snap to an 8pt grid, with a stronger magnet to neighboring panel edges.
struct CanvasPanelView<Content: View>: View {
    let panel: CanvasPanel
    let projectPath: String
    let offscreen: Bool
    let isFocused: Bool
    let neighborFrames: [CGRect]
    let projectChoices: [PanelProjectChoice]
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var canvas: CanvasStore

    @State private var liveFrame: CGRect
    @State private var dragOrigin: CGPoint?
    /// Gesture-start size — the fixed baseline `DragGesture.translation` (always
    /// cumulative) is added to. Never reassigned mid-gesture.
    @State private var resizeStart: CGSize?
    /// What the content is currently laid out at while resizing (lags liveFrame
    /// on a throttle); nil when not resizing.
    @State private var frozenContentSize: CGSize?
    @State private var lastContentReflow = Date.distantPast

    private static var titleBarHeight: CGFloat { 28 }
    private static var snapGrid: CGFloat { 8 }
    private static var snapMagnet: CGFloat { 6 }

    /// True while moving or resizing — drop the (per-frame expensive) shadow so the
    /// drag stays smooth, same trick as FloatingTerminalPanel.
    private var isInteracting: Bool { dragOrigin != nil || resizeStart != nil }

    init(panel: CanvasPanel, projectPath: String, offscreen: Bool = false,
         isFocused: Bool = false,
         neighborFrames: [CGRect] = [], projectChoices: [PanelProjectChoice] = [],
         @ViewBuilder content: @escaping () -> Content) {
        self.panel = panel
        self.projectPath = projectPath
        self.offscreen = offscreen
        self.isFocused = isFocused
        self.neighborFrames = neighborFrames
        self.projectChoices = projectChoices
        self.content = content
        _liveFrame = State(initialValue: panel.frame)
    }

    var body: some View {
        // While resizing, content reflow is throttled (~150ms) instead of per-frame:
        // heavy bodies (the simulator/browser WKWebView) reflowing every frame starve
        // the drag. The chrome resizes live; content catches up in steps and lands
        // exactly on release. Content stays mounted throughout, so the running
        // simulator keeps its state.
        let contentSize = frozenContentSize ?? liveFrame.size
        VStack(spacing: 0) {
            titleBar
            Divider()
            content()
                .frame(width: contentSize.width, height: max(0, contentSize.height - Self.titleBarHeight - 1))
                .clipped()
        }
        .frame(width: liveFrame.width, height: liveFrame.height, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
        // Focused panel wears an accent ring — the visible cue for who owns
        // the keyboard (no ring = navigation mode).
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous)
            .stroke(isFocused ? Color.accentColor.opacity(0.75) : DSColor.hairline,
                    lineWidth: isFocused ? 2 : 1))
        .shadow(color: .black.opacity(isInteracting ? 0 : 0.18), radius: isInteracting ? 0 : 10, y: isInteracting ? 0 : 4)
        // Fade the shadow out/in instead of popping when a drag starts/ends.
        .animation(.easeOut(duration: 0.12), value: isInteracting)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        // Fully off-viewport: keep mounted (terminals/simulators stay alive) but
        // don't composite or hit-test.
        .opacity(offscreen ? 0 : 1)
        .allowsHitTesting(!offscreen)
        .offset(x: liveFrame.minX, y: liveFrame.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Resync if the stored frame changes from elsewhere while we're not interacting.
        .onChange(of: panel.frame) { _, new in
            if dragOrigin == nil && resizeStart == nil { liveFrame = new }
        }
        // NOTE: no panel-wide tap-to-raise gesture — it would eat clicks meant for
        // the panel's content. Raise-on-content-click comes from CanvasEventBridge's
        // non-consuming mouse monitor instead.
    }

    // MARK: Title bar

    private var pinnedName: String? {
        guard let p = panel.projectOverride else { return nil }
        return projectChoices.first { $0.path == p }?.name ?? (p as NSString).lastPathComponent
    }

    private var titleBar: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: panel.kind.systemImage)
                .font(DSFont.micro)
                .foregroundStyle(.secondary)
            Text(panel.kind.label)
                .font(DSFont.label.weight(.medium))
                .lineLimit(1)
            if let pinnedName {
                Text("· \(pinnedName)")
                    .font(DSFont.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let n = panel.shortcut {
                Text("⌘\(n)")
                    .font(DSFont.micro.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
            }
            Button {
                canvas.removePanel(panel.id, for: projectPath)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(panel.kind.label) panel")
        }
        .padding(.horizontal, DSSpace.sm)
        .frame(height: Self.titleBarHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(coordinateSpace: .named(canvasBoardSpace))
                .onChanged { v in
                    let start = dragOrigin ?? liveFrame.origin
                    if dragOrigin == nil { dragOrigin = start }
                    let raw = CGPoint(x: start.x + v.translation.width,
                                      y: start.y + v.translation.height)
                    liveFrame.origin = snappedOrigin(raw)
                }
                .onEnded { _ in
                    dragOrigin = nil
                    canvas.raise(panel.id, for: projectPath)
                    canvas.updateFrame(panel.id, frame: liveFrame, for: projectPath)
                }
        )
        // Click the title bar (without dragging) to bring the panel to the front.
        .onTapGesture { canvas.raise(panel.id, for: projectPath) }
        .contextMenu { titleBarMenu }
    }

    @ViewBuilder
    private var titleBarMenu: some View {
        Menu("Show Project") {
            Button {
                canvas.setProjectOverride(nil, panel: panel.id, for: projectPath)
            } label: {
                if panel.projectOverride == nil {
                    Label("Canvas Project", systemImage: "checkmark")
                } else {
                    Text("Canvas Project")
                }
            }
            Divider()
            ForEach(projectChoices) { choice in
                Button {
                    canvas.setProjectOverride(choice.path == projectPath ? nil : choice.path,
                                              panel: panel.id, for: projectPath)
                } label: {
                    if panel.projectOverride == choice.path {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
        }
        Menu("Keyboard Shortcut") {
            ForEach(1...9, id: \.self) { n in
                Button {
                    canvas.setShortcut(n, panel: panel.id, for: projectPath)
                } label: {
                    if panel.shortcut == n {
                        Label("⌘\(n)", systemImage: "checkmark")
                    } else {
                        Text("⌘\(n)")
                    }
                }
            }
            Divider()
            Button("None") { canvas.setShortcut(nil, panel: panel.id, for: projectPath) }
        }
        Divider()
        Button(role: .destructive) {
            canvas.removePanel(panel.id, for: projectPath)
        } label: {
            Label("Close Panel", systemImage: "xmark")
        }
    }

    // MARK: Resize

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(5)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(coordinateSpace: .named(canvasBoardSpace))
                    .onChanged { v in
                        let start = resizeStart ?? liveFrame.size
                        if resizeStart == nil {
                            resizeStart = start
                            frozenContentSize = start
                            lastContentReflow = Date()
                        }
                        let raw = CGSize(width: max(240, start.width + v.translation.width),
                                         height: max(160, start.height + v.translation.height))
                        liveFrame.size = snappedSize(raw)
                        if Date().timeIntervalSince(lastContentReflow) > 0.15 {
                            frozenContentSize = liveFrame.size
                            lastContentReflow = Date()
                        }
                    }
                    .onEnded { _ in
                        resizeStart = nil
                        frozenContentSize = nil
                        canvas.updateFrame(panel.id, frame: liveFrame, for: projectPath)
                    }
            )
    }

    // MARK: Snapping

    /// 8pt grid with a stronger magnet to neighboring panels' edges (edge-to-edge
    /// alignment and flush adjacency), so arrangements land crisp instead of ragged.
    private func snappedOrigin(_ raw: CGPoint) -> CGPoint {
        var x = (raw.x / Self.snapGrid).rounded() * Self.snapGrid
        var y = (raw.y / Self.snapGrid).rounded() * Self.snapGrid
        let w = liveFrame.width, h = liveFrame.height
        for f in neighborFrames {
            for edge in [f.minX, f.maxX] {
                if abs(raw.x - edge) < Self.snapMagnet { x = edge }
                if abs(raw.x + w - edge) < Self.snapMagnet { x = edge - w }
            }
            for edge in [f.minY, f.maxY] {
                if abs(raw.y - edge) < Self.snapMagnet { y = edge }
                if abs(raw.y + h - edge) < Self.snapMagnet { y = edge - h }
            }
        }
        return CGPoint(x: x, y: y)
    }

    private func snappedSize(_ raw: CGSize) -> CGSize {
        var w = (raw.width / Self.snapGrid).rounded() * Self.snapGrid
        var h = (raw.height / Self.snapGrid).rounded() * Self.snapGrid
        let ox = liveFrame.minX, oy = liveFrame.minY
        for f in neighborFrames {
            for edge in [f.minX, f.maxX] where abs(ox + raw.width - edge) < Self.snapMagnet {
                w = edge - ox
            }
            for edge in [f.minY, f.maxY] where abs(oy + raw.height - edge) < Self.snapMagnet {
                h = edge - oy
            }
        }
        return CGSize(width: max(240, w), height: max(160, h))
    }
}

// MARK: - PanelContentView

/// Maps a `PanelKind` to its view. Panels follow the canvas's project unless
/// pinned (`overridePath`); the pin flows to the shared tab views through the
/// `panelSelection` environment override, and directly to the simulator/terminal.
struct PanelContentView: View {
    let kind: PanelKind
    let project: Project
    var overridePath: String? = nil
    @EnvironmentObject private var store: DashboardStore

    private var effectiveProject: Project {
        guard let overridePath else { return project }
        return store.projects.first { $0.path == overridePath } ?? project
    }

    var body: some View {
        let proj = effectiveProject
        Group {
            switch kind {
            case .view(let tab):
                switch tab {
                case .info:    InfoTabView()
                case .claude:  ClaudeTabView()
                case .tasks:   TasksTabView()
                case .product: ProductTabView()
                case .docs:    DocsTabView()
                case .changes: ChangesTabView()
                case .logs:    LogsTabView()
                case .daily:   DailyTabView()
                }
            case .preview:
                PreviewTabView()
            case .simulator:
                SimulatorEmbedView(fixedProject: proj)
            case .terminal:
                TerminalPanel(project: proj)
            case .browser:
                BrowserPanel()
            }
        }
        // Only inject when pinned, so unpinned panels behave exactly as before
        // (following whatever the global selection resolves to).
        .environment(\.panelSelection, overridePath != nil ? .project(path: proj.path) : nil)
        // Re-mount content when the pin changes: the tab views cache per-project
        // state (webviews, scroll positions) that shouldn't leak across projects.
        .id(proj.path)
    }
}
