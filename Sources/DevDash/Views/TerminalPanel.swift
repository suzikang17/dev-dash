import SwiftUI
import AppKit

/// Lets a placement container drive the floating panel's position via the header.
struct TerminalMoveHandler {
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void
}

/// Placement-agnostic terminal content: header (cwd, quick-run, placement, restart,
/// close) + the live shell. The three containers below wrap this and add resizing.
struct TerminalPanel: View {
    @EnvironmentObject var store: DashboardStore
    let project: Project
    /// Non-nil only in floating mode — makes the header a drag handle.
    var moveHandler: TerminalMoveHandler? = nil

    @State private var restartTick = 0
    @State private var isSearching = false
    @State private var searchTerm = ""
    @FocusState private var searchFieldFocused: Bool

    /// One command in a header dropdown. `run` auto-presses Enter; when false the
    /// command is pre-filled in the shell so the user can finish typing an argument.
    private struct QuickCommand {
        let label: String
        let text: String
        var run: Bool = true
    }
    private struct QuickGroup {
        let category: String
        let items: [QuickCommand]
    }
    /// Grouped header menus. Authoring (devlogs/tasks) happens in Claude Code, so the
    /// Lore menu is mechanical CLI ops only; git is intentionally omitted.
    private let quickGroups: [QuickGroup] = [
        QuickGroup(category: "Build", items: [
            QuickCommand(label: "Build & Run", text: "bash run.sh"),
            QuickCommand(label: "Build only", text: "swift build"),
            QuickCommand(label: "Release package", text: "bash dist.sh"),
            QuickCommand(label: "Clean", text: "swift package clean"),
        ]),
        QuickGroup(category: "Lore", items: [
            QuickCommand(label: "Reindex devlog", text: "lore reindex devlog"),
            QuickCommand(label: "Reindex all", text: "lore reindex"),
            QuickCommand(label: "Validate", text: "lore validate devlog"),
        ]),
        QuickGroup(category: "Claude", items: [
            QuickCommand(label: "Start", text: "claude --dangerously-skip-permissions"),
            QuickCommand(label: "Resume last", text: "claude --continue --dangerously-skip-permissions"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isSearching {
                searchBar
                Divider()
            }
            TerminalHostView(terminal: store.terminals.session(for: project.path))
                .id("\(project.path)#\(restartTick)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { store.terminals.focus(projectPath: project.path) }
        .background { zoomShortcuts }
    }

    private var header: some View {
        let row = HStack(spacing: DSSpace.sm) {
            titleRegion
            Spacer(minLength: DSSpace.sm)
            ForEach(quickGroups, id: \.category) { group in
                Menu(group.category) {
                    ForEach(group.items, id: \.label) { cmd in
                        Button(cmd.label) {
                            store.terminals.send(cmd.text + (cmd.run ? "\n" : ""), to: project.path)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("\(group.category) commands")
            }
            placementMenu
            Button { restart() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Restart shell").accessibilityLabel("Restart shell")
            Button { store.terminalOpen = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close terminal (⌘`)").accessibilityLabel("Close terminal")
        }
        .padding(.horizontal, DSSpace.sm)
        .padding(.vertical, DSSpace.xs)
        .background(DSColor.cardBg)
        .contentShape(Rectangle())   // the whole header row is the drag handle

        return Group {
            if let move = moveHandler {
                // Drag anywhere in the header (title + empty space) to move the panel.
                // Buttons still work: .gesture lets the child tap gestures win, and only a
                // real drag arms the move. .global avoids coordinate feedback as it moves.
                row.gesture(
                    DragGesture(coordinateSpace: .global)
                        .onChanged { move.onChanged($0.translation) }
                        .onEnded { _ in move.onEnded() }
                )
            } else {
                row
            }
        }
    }

    /// Find-in-terminal bar (Feature E). Visible only while searching; closing
    /// returns first-responder to the shell so keys never get stolen.
    private var searchBar: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: "magnifyingglass")
                .font(DSFont.micro).foregroundColor(.secondary)
            TextField("Find in terminal", text: $searchTerm)
                .textFieldStyle(.plain)
                .font(DSFont.mono(.caption))
                .focused($searchFieldFocused)
                .onSubmit { _ = store.terminals.findNext(searchTerm, in: project.path) }
            Button { _ = store.terminals.findPrevious(searchTerm, in: project.path) }
                label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).help("Previous (⇧↩)").accessibilityLabel("Previous")
            Button { _ = store.terminals.findNext(searchTerm, in: project.path) }
                label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).help("Next (↩)").accessibilityLabel("Next")
            Button { closeSearch() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close (esc)").accessibilityLabel("Close")
        }
        .padding(.horizontal, DSSpace.sm)
        .padding(.vertical, DSSpace.xs)
        .background(DSColor.cardBg)
        .onExitCommand { closeSearch() }
    }

    private func openSearch() {
        isSearching = true
        DispatchQueue.main.async { searchFieldFocused = true }
    }

    private func closeSearch() {
        isSearching = false
        searchTerm = ""
        store.terminals.clearSearch(in: project.path)
        store.terminals.focus(projectPath: project.path)  // return keys to the shell
    }

    private var titleRegion: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: "terminal").font(DSFont.micro).foregroundColor(.secondary)
            Text(project.name).font(DSFont.micro.weight(.semibold))
            Text(abbreviatedPath)
                .font(DSFont.mono(.caption2))
                .foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private var placementMenu: some View {
        Menu {
            Picker("Placement", selection: $store.terminalPlacement) {
                ForEach(TerminalPlacement.allCases, id: \.self) { p in
                    Label(p.label, systemImage: p.icon).tag(p)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Zoom In") { store.zoomTerminal(1) }
            Button("Zoom Out") { store.zoomTerminal(-1) }
            Button("Actual Size") { store.resetTerminalZoom() }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Terminal options")
        .accessibilityLabel("Terminal options")
    }

    /// Invisible buttons holding the zoom shortcuts while the terminal is visible.
    private var zoomShortcuts: some View {
        ZStack {
            Button("") { store.zoomTerminal(1) }.keyboardShortcut("=", modifiers: .command)
            Button("") { store.zoomTerminal(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("") { store.resetTerminalZoom() }.keyboardShortcut("0", modifiers: .command)
            Button("") { openSearch() }.keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0)
    }

    private func restart() {
        store.terminals.restart(projectPath: project.path)
        restartTick += 1
        store.terminals.focus(projectPath: project.path)
    }

    private var abbreviatedPath: String {
        let home = NSHomeDirectory()
        return project.path.hasPrefix(home)
            ? "~" + project.path.dropFirst(home.count)
            : project.path
    }
}

// MARK: - Resize handle

/// Self-balancing hover cursor: pushes on enter, pops on exit AND on disappear,
/// so a view removed mid-hover (placement switch, ⌘`) can't strand a resize cursor.
private struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var pushed = false
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed { cursor.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}
private extension View {
    func hoverCursor(_ cursor: NSCursor) -> some View { modifier(HoverCursor(cursor: cursor)) }
}

/// Shown in place of the live terminal during a resize drag so SwiftTerm isn't
/// forced to redraw every frame; the real terminal returns (one reflow) on end.
private struct TerminalResizePlaceholder: View {
    let label: String
    var body: some View {
        Color(NSColor.windowBackgroundColor)
            .overlay(
                Text(label)
                    .font(DSFont.mono(.caption2))
                    .foregroundColor(.secondary)
            )
    }
}

/// A thin draggable edge. `edge` picks cursor + which translation drives the delta.
private struct ResizeHandle: View {
    enum Edge { case top, leading, bottom }
    let edge: Edge
    let onChanged: (CGFloat) -> Void   // signed delta in points (positive = grow)
    let onEnded: () -> Void

    private var isVertical: Bool { edge == .top || edge == .bottom }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: edge == .leading ? 6 : nil, height: isVertical ? 6 : nil)
            .overlay(edge == .leading ? AnyView(Divider().rotationEffect(.degrees(90))) : AnyView(Divider()),
                     alignment: edge == .top ? .top : (edge == .bottom ? .bottom : .leading))
            .contentShape(Rectangle())
            .hoverCursor(isVertical ? .resizeUpDown : .resizeLeftRight)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        switch edge {
                        case .top: onChanged(-v.translation.height)
                        case .bottom: onChanged(v.translation.height)
                        case .leading: onChanged(-v.translation.width)
                        }
                    }
                    .onEnded { _ in onEnded() }
            )
    }
}

// MARK: - Bottom

struct BottomTerminalContainer: View {
    @EnvironmentObject var store: DashboardStore
    let project: Project
    @State private var height: CGFloat
    @State private var dragStart: CGFloat?

    init(project: Project, initialHeight: CGFloat) {
        self.project = project
        _height = State(initialValue: initialHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            ResizeHandle(edge: .top) { delta in
                let start = dragStart ?? height
                if dragStart == nil { dragStart = start }
                height = min(800, max(120, start + delta))
            } onEnded: {
                dragStart = nil
                store.terminalHeight = height
            }
            if dragStart != nil {
                TerminalResizePlaceholder(label: "\(Int(height)) pt")
            } else {
                TerminalPanel(project: project)
            }
        }
        .frame(height: height)
        .onDisappear { store.terminalHeight = height }
    }
}

// MARK: - Side

struct SideTerminalContainer: View {
    @EnvironmentObject var store: DashboardStore
    let project: Project
    @State private var width: CGFloat
    @State private var dragStart: CGFloat?

    init(project: Project, initialWidth: CGFloat) {
        self.project = project
        _width = State(initialValue: initialWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            ResizeHandle(edge: .leading) { delta in
                let start = dragStart ?? width
                if dragStart == nil { dragStart = start }
                width = min(900, max(320, start + delta))
            } onEnded: {
                dragStart = nil
                store.terminalWidth = width
            }
            if dragStart != nil {
                TerminalResizePlaceholder(label: "\(Int(width)) pt")
            } else {
                TerminalPanel(project: project)
            }
        }
        .frame(width: width)
        .onDisappear { store.terminalWidth = width }
    }
}

// MARK: - Floating

/// Minimal floating terminal: a compact card overlaid on the content (no backdrop,
/// so the content behind stays visible and usable). Slides in from the top on open,
/// draggable by its header, resizable from the bottom-right corner. Close via ✕.
struct FloatingTerminalPanel: View {
    @EnvironmentObject var store: DashboardStore
    let project: Project
    let containerSize: CGSize
    @State private var frame: CGRect
    @State private var moveStart: CGPoint?
    @State private var resizeStart: CGSize?

    init(project: Project, initialFrame: CGRect, containerSize: CGSize) {
        self.project = project
        self.containerSize = containerSize
        _frame = State(initialValue: initialFrame)
    }

    /// True while dragging/resizing — drop the blur shadow (it recomputes per frame).
    private var isInteracting: Bool { moveStart != nil || resizeStart != nil }

    var body: some View {
        Group {
            if resizeStart != nil {
                TerminalResizePlaceholder(label: "\(Int(frame.width))×\(Int(frame.height))")
            } else {
                TerminalPanel(project: project, moveHandler: TerminalMoveHandler(
                    onChanged: { t in
                        let start = moveStart ?? frame.origin
                        if moveStart == nil { moveStart = start }
                        frame.origin = clampOrigin(CGPoint(x: start.x + t.width, y: start.y + t.height),
                                                   size: frame.size)
                    },
                    onEnded: { moveStart = nil; store.terminalFloatingFrame = frame }
                ))
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous)
                .stroke(DSColor.hairline, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) { resizeCorner }
        .shadow(color: .black.opacity(0.22), radius: isInteracting ? 0 : 16, y: isInteracting ? 0 : 8)
        .offset(x: frame.origin.x, y: frame.origin.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Slides in from the top on open; no backdrop, so content stays usable.
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear { frame = clamped(frame) }
        .onChange(of: containerSize) { _, _ in frame = clamped(frame) }
        .onDisappear { store.terminalFloatingFrame = frame }
    }

    private var resizeCorner: some View {
        Image(systemName: "arrow.down.right")
            .font(DSFont.micro)
            .foregroundColor(.secondary)
            .padding(DSSpace.xs)
            .contentShape(Rectangle())
            .hoverCursor(.crosshair)
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { v in
                        let start = resizeStart ?? frame.size
                        if resizeStart == nil { resizeStart = start }
                        frame.size = clampSize(CGSize(width: start.width + v.translation.width,
                                                      height: start.height + v.translation.height))
                    }
                    .onEnded { _ in resizeStart = nil; store.terminalFloatingFrame = frame }
            )
    }

    // Keep the card on-screen so it can't be stranded off the edge.
    private func clamped(_ f: CGRect) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else { return f }
        var r = f
        r.size = clampSize(r.size)
        r.origin = clampOrigin(r.origin, size: r.size)
        return r
    }
    private func clampSize(_ s: CGSize) -> CGSize {
        let maxW = containerSize.width > 0 ? max(320, containerSize.width - 24) : 1000
        let maxH = containerSize.height > 0 ? max(180, containerSize.height - 24) : 800
        return CGSize(width: min(max(320, s.width), maxW), height: min(max(180, s.height), maxH))
    }
    private func clampOrigin(_ p: CGPoint, size: CGSize) -> CGPoint {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return CGPoint(x: max(8, p.x), y: max(8, p.y))
        }
        let maxX = max(8, containerSize.width - size.width - 12)
        let maxY = max(8, containerSize.height - size.height - 12)
        return CGPoint(x: min(max(8, p.x), maxX), y: min(max(8, p.y), maxY))
    }
}
