import SwiftUI

/// Stable coordinate space for panel drag/resize math (see CanvasView/CanvasPanelView).
private let canvasBoardSpace = "canvasBoard"

// MARK: - CanvasView

/// Per-project freeform workspace: a pannable board of draggable/resizable panels.
/// No global zoom (panels render at native scale). Layout persists per project via
/// `CanvasStore`.
struct CanvasView: View {
    let project: Project
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var canvas: CanvasStore

    @State private var pan: CGSize = .zero
    @State private var panAccum: CGSize = .zero

    private static let boardSize = CGSize(width: 4000, height: 3000)

    private var layout: CanvasLayout { canvas.layout(for: project.path) }

    var body: some View {
        // Base fills the viewport (and drives layout). The board is an overlay so its
        // 4000×3000 size can't expand/center the stack and shove controls off-screen.
        Color(NSColor.underPageBackgroundColor)
            .contentShape(Rectangle())
            .gesture(panGesture)
            // Right-click empty canvas to add a panel.
            .contextMenu { addPanelMenuItems }
            // Panels board — anchored to the viewport's top-left, panned via offset.
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    gridBackground
                    ForEach(layout.panels) { panel in
                        CanvasPanelView(panel: panel, projectPath: project.path) {
                            PanelContentView(kind: panel.kind, project: project)
                        }
                        .zIndex(Double(panel.z))
                    }
                }
                .frame(width: Self.boardSize.width, height: Self.boardSize.height, alignment: .topLeading)
                .offset(pan)
                // Stable reference for panel drags: measuring translation in a panel's
                // own (moving) local space feeds back on itself → drift + flicker.
                .coordinateSpace(name: canvasBoardSpace)
            }
            .overlay { if layout.panels.isEmpty { emptyHint } }
            .overlay(alignment: .topLeading) { toolbar }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear { pan = layout.pan; panAccum = layout.pan }
            .onChange(of: project.path) { _, _ in pan = layout.pan; panAccum = layout.pan }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                pan = CGSize(width: panAccum.width + v.translation.width,
                             height: panAccum.height + v.translation.height)
            }
            .onEnded { _ in
                panAccum = pan
                canvas.setPan(pan, for: project.path)
            }
    }

    // MARK: Toolbar (＋ spawn menu)

    private var toolbar: some View {
        Menu { addPanelMenuItems } label: {
            Label("Add panel", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, DSSpace.sm)
        .padding(.vertical, DSSpace.xs)
        .background(.bar, in: Capsule())
        .padding(DSSpace.md)
    }

    /// Shared menu items for both the toolbar "Add panel" button and the
    /// right-click context menu.
    @ViewBuilder
    private var addPanelMenuItems: some View {
        Section("Views") {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    canvas.addPanel(kind: .view(tab), for: project.path)
                } label: { Label(tab.label, systemImage: tab.systemImage) }
            }
        }
        Divider()
        Button { canvas.addPanel(kind: .preview, for: project.path) } label: {
            Label("Preview", systemImage: "globe")
        }
        Button { canvas.addPanel(kind: .simulator, for: project.path) } label: {
            Label("Simulator", systemImage: "iphone")
        }
        Button { canvas.addPanel(kind: .terminal(id: UUID()), for: project.path) } label: {
            Label("Terminal", systemImage: "terminal")
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
            Text("Use \u{201C}Add panel\u{201D} to drop the preview, simulator, tasks, terminal, and more here — then drag and resize them however you like.")
                .font(DSFont.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var gridBackground: some View {
        Canvas { ctx, size in
            let step: CGFloat = 40
            var p = Path()
            var x: CGFloat = 0
            while x < size.width { p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y < size.height { p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)); y += step }
            ctx.stroke(p, with: .color(.gray.opacity(0.10)), lineWidth: 1)
        }
        .frame(width: Self.boardSize.width, height: Self.boardSize.height)
        .allowsHitTesting(false)
    }
}

// MARK: - CanvasPanelView

/// Generic panel chrome: title bar (drag to move), resize corner, raise-on-click,
/// close. Keeps a live frame in @State during interaction and commits to the
/// `CanvasStore` on end (mirrors `FloatingTerminalPanel`).
struct CanvasPanelView<Content: View>: View {
    let panel: CanvasPanel
    let projectPath: String
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var canvas: CanvasStore

    @State private var liveFrame: CGRect
    @State private var dragOrigin: CGPoint?
    @State private var resizeOrigin: CGSize?

    private static var titleBarHeight: CGFloat { 28 }

    /// True while moving or resizing — drop the (per-frame expensive) shadow so the
    /// drag stays smooth, same trick as FloatingTerminalPanel.
    private var isInteracting: Bool { dragOrigin != nil || resizeOrigin != nil }

    init(panel: CanvasPanel, projectPath: String, @ViewBuilder content: @escaping () -> Content) {
        self.panel = panel
        self.projectPath = projectPath
        self.content = content
        _liveFrame = State(initialValue: panel.frame)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            content()
                .frame(width: liveFrame.width, height: max(0, liveFrame.height - Self.titleBarHeight - 1))
                .clipped()
        }
        .frame(width: liveFrame.width, height: liveFrame.height)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous).stroke(DSColor.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(isInteracting ? 0 : 0.18), radius: isInteracting ? 0 : 10, y: isInteracting ? 0 : 4)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .offset(x: liveFrame.minX, y: liveFrame.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Resync if the stored frame changes from elsewhere while we're not interacting.
        .onChange(of: panel.frame) { _, new in
            if dragOrigin == nil && resizeOrigin == nil { liveFrame = new }
        }
        .onTapGesture { canvas.raise(panel.id, for: projectPath) }
    }

    private var titleBar: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: panel.kind.systemImage)
                .font(DSFont.micro)
                .foregroundStyle(.secondary)
            Text(panel.kind.label)
                .font(DSFont.label.weight(.medium))
                .lineLimit(1)
            Spacer()
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
                    liveFrame.origin = CGPoint(x: start.x + v.translation.width,
                                               y: start.y + v.translation.height)
                }
                .onEnded { _ in
                    dragOrigin = nil
                    canvas.raise(panel.id, for: projectPath)
                    canvas.updateFrame(panel.id, frame: liveFrame, for: projectPath)
                }
        )
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(5)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(coordinateSpace: .named(canvasBoardSpace))
                    .onChanged { v in
                        let start = resizeOrigin ?? liveFrame.size
                        if resizeOrigin == nil { resizeOrigin = start }
                        liveFrame.size = CGSize(width: max(240, start.width + v.translation.width),
                                                height: max(160, start.height + v.translation.height))
                    }
                    .onEnded { _ in
                        resizeOrigin = nil
                        canvas.updateFrame(panel.id, frame: liveFrame, for: projectPath)
                    }
            )
    }
}

// MARK: - PanelContentView

/// Maps a `PanelKind` to its view. The existing tab views read the current
/// selection from the store, which on the canvas is this project.
struct PanelContentView: View {
    let kind: PanelKind
    let project: Project

    var body: some View {
        switch kind {
        case .view(let tab):
            switch tab {
            case .info:    InfoTabView()
            case .claude:  ClaudeTabView()
            case .tasks:   TasksTabView()
            case .product: ProductTabView()
            case .changes: ChangesTabView()
            case .logs:    LogsTabView()
            case .daily:   DailyTabView()
            }
        case .preview:
            PreviewTabView()
        case .simulator:
            SimulatorEmbedView(fixedProject: project)
        case .terminal:
            TerminalPanel(project: project)
        }
    }
}
