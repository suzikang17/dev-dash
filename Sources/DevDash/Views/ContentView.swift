import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var tabStore: TabStore
    @EnvironmentObject var canvasStore: CanvasStore
    @StateObject private var cmd = CommandBarModel()
    @FocusState private var cmdFocused: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        HStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    // Fixed (not flexible) width so detail tabs with large minimum
                    // widths can't squeeze the sidebar — it stays identical on every tab.
                    .navigationSplitViewColumnWidth(260)
                    // NavigationSplitView auto-adds its own sidebar-toggle button; we
                    // ship our own in the toolbar group below, so drop the built-in one
                    // to avoid showing two toggles.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                DetailPaneView()
            }
            .navigationTitle(store.selection.map(titleFor) ?? "Dev Dashboard")
            .toolbar { toolbarContent }
            .background { tabShortcuts }
            .background { commandShortcut }
            .background { previewDockShortcut }
            // Results drop from the top bar as a same-window overlay (not a popover)
            // so the toolbar field keeps key focus while you type and navigate.
            .overlay(alignment: .topTrailing) {
                if cmd.isActive {
                    CommandResultsView(model: cmd, dismiss: dismissCommand)
                        .environmentObject(store)
                        .padding(.trailing, DSSpace.md)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: cmd.isActive)
            // Hook event banner: appears at top-center when a Claude SessionStart arrives.
            .overlay(alignment: .top) {
                if let banner = store.lastHookBanner {
                    Text(banner)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, DSSpace.lg)
                        .padding(.vertical, DSSpace.sm)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, DSSpace.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(banner)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.lastHookBanner)

            // Preview dock lives BESIDE the split view (not inside the detail), so it
            // can't starve the toolbar/detail and collapse the sidebar. Resizable from
            // narrow up to nearly full-width; follows the current project selection.
            if store.previewDockOpen, store.project(for: store.selection) != nil {
                Divider()
                PreviewDockContainer(initialWidth: store.previewDockWidth)
            }
        }
    }

    /// Hidden ⌘P button toggling the right-side Preview dock (only when a
    /// project/service is selected — Preview is project-scoped).
    private var previewDockShortcut: some View {
        Button("") {
            if store.project(for: store.selection) != nil {
                store.previewDockOpen.toggle()
            }
        }
        .keyboardShortcut("p", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    /// Hidden buttons binding ⌘1–9. Normally they select the detail tabs; when
    /// the selected project is in canvas mode (which covers the tab body, making
    /// tab switching inert) a number assigned to a canvas panel jumps to that
    /// panel instead. ⌘0 is Home.
    @ViewBuilder
    private var tabShortcuts: some View {
        if let sel = store.selection, sel != .home, sel != .simulator {
            ForEach(1...9, id: \.self) { n in
                Button("") { fireNumberShortcut(n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        }
    }

    private func fireNumberShortcut(_ n: Int) {
        if let project = store.project(for: store.selection),
           canvasStore.isCanvasMode(project.path),
           let panelID = canvasStore.panelID(forShortcut: n, in: project.path) {
            canvasStore.requestJump(to: panelID, in: project.path)
        } else if n <= DetailTab.allCases.count {
            tabStore.detailTab = DetailTab.allCases[n - 1]
        }
    }

    /// ⌘K focuses the toolbar command field. SwiftUI `@FocusState` doesn't
    /// reliably reach a `TextField` hosted in the toolbar (separate titlebar
    /// context), so we make it first responder via AppKit.
    private var commandShortcut: some View {
        Button("") { focusCommandField() }
            .keyboardShortcut("k", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
    }

    private func focusCommandField() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            let root = window.contentView?.superview ?? window.contentView
            if let field = Self.findCommandField(in: root) {
                window.makeFirstResponder(field)
            }
        }
    }

    /// The toolbar command field is the only editable text field with this
    /// placeholder; the sidebar search field uses a different one.
    private static func findCommandField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField, tf.isEditable,
           (tf.placeholderString ?? "").contains("Jump to a repo") {
            return tf
        }
        for sub in view.subviews {
            if let found = findCommandField(in: sub) { return found }
        }
        return nil
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: .command)
            .help("Toggle sidebar (⌘S)")
            .accessibilityLabel("Toggle sidebar")

            Button {
                store.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!store.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")
            .accessibilityLabel("Back")

            Button {
                store.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!store.canGoForward)
            .keyboardShortcut("]", modifiers: .command)
            .help("Forward (⌘])")
            .accessibilityLabel("Forward")
        }
        ToolbarItem(placement: .principal) {
            if let sel = store.selection, sel != .home, sel != .simulator {
                let project = store.project(for: sel)
                let canvasOn = project.map { canvasStore.isCanvasMode($0.path) } ?? false
                HStack(spacing: DSSpace.sm) {
                    if canvasOn {
                        Label("Canvas", systemImage: "rectangle.3.group")
                            .font(DSFont.bodyEmphasized)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Mode", selection: $tabStore.detailTab) {
                            ForEach(DetailTab.allCases) { tab in
                                Label(tab.label, systemImage: tab.systemImage).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 460)
                    }
                    if let project {
                        Button {
                            canvasStore.toggleCanvasMode(project.path)
                        } label: {
                            Image(systemName: canvasOn ? "rectangle.3.group.fill" : "rectangle.3.group")
                                .foregroundStyle(canvasOn ? Color.accentColor : .secondary)
                        }
                        .help(canvasOn ? "Exit Canvas" : "Open Canvas")
                        .accessibilityLabel(canvasOn ? "Exit Canvas" : "Open Canvas")
                    }
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            NotificationBellButton()
        }
        ToolbarItem(placement: .primaryAction) {
            commandField
        }
    }

    /// The command line, integrated into the toolbar. Keyboard navigation and
    /// activation are handled here (where focus lives); the results render in
    /// the window overlay above.
    private var commandField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Jump to a repo, or create a task or idea…", text: $cmd.query)
                .textFieldStyle(.plain)
                .frame(width: 320)
                .focused($cmdFocused)
                .onSubmit { activateCommand() }
                .onKeyPress(phases: .down) { handleCommandKey($0) }
                .onKeyPress(.escape) { dismissCommand(); return .handled }
                .onChange(of: cmd.query) { cmd.selectedIndex = 0 }
            if !cmd.query.isEmpty {
                Button { cmd.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, DSSpace.sm)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func dismissCommand() {
        cmd.reset()
        cmdFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Vim-style navigation over the results. Bare j/k can't be used while the
    /// field has focus (they'd type), so movement is Ctrl-J/Ctrl-K (and
    /// Ctrl-N/P + arrows). Enter (onSubmit) activates the highlight.
    private func handleCommandKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow: moveCommand(1); return .handled
        case .upArrow: moveCommand(-1); return .handled
        default: break
        }
        if press.modifiers.contains(.control) {
            switch press.characters.lowercased() {
            case "j", "n": moveCommand(1); return .handled
            case "k", "p": moveCommand(-1); return .handled
            default: break
            }
        }
        return .ignored
    }

    private func moveCommand(_ delta: Int) {
        let count = makeCommandActions(query: cmd.query, store: store, dismiss: dismissCommand).count
        guard count > 0 else { return }
        // Clamp at the ends rather than wrapping around.
        cmd.selectedIndex = min(max(cmd.selectedIndex + delta, 0), count - 1)
    }

    private func activateCommand() {
        let actions = makeCommandActions(query: cmd.query, store: store, dismiss: dismissCommand)
        guard actions.indices.contains(cmd.selectedIndex) else { dismissCommand(); return }
        actions[cmd.selectedIndex].run()
    }

    private func titleFor(_ selection: Selection) -> String {
        switch selection {
        case .home:
            return "Dev Dashboard"
        case .simulator:
            return "Simulator"
        case .service(let id):
            return store.services.first { $0.id == id }?.name ?? "Service"
        case .project(let path):
            return store.projects.first { $0.path == path }?.name ?? "Project"
        }
    }
}

// MARK: - Preview dock

/// Right-side resizable dock hosting the project's Preview surface (`PreviewTabView`).
/// Mirrors the old side-terminal container: a leading `ResizeHandle` writes the width
/// back to the store, and a lightweight placeholder stands in during the drag so the
/// embedded WebView/simulator isn't relaid out every frame.
struct PreviewDockContainer: View {
    @EnvironmentObject var store: DashboardStore
    @State private var width: CGFloat
    @State private var dragStart: CGFloat?

    init(initialWidth: CGFloat) {
        _width = State(initialValue: initialWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            ResizeHandle(edge: .leading) { delta in
                let start = dragStart ?? width
                if dragStart == nil { dragStart = start }
                // Min keeps the panel usable; max lets it grow to nearly full-width.
                width = min(2000, max(360, start + delta))
            } onEnded: {
                dragStart = nil
                store.previewDockWidth = width
            }
            // Keep PreviewTabView mounted across the resize — swapping it out for a
            // placeholder (the terminal's trick) would tear down the simulator's
            // BaguetteRunner and stop the server on every drag. Only the width changes.
            PreviewTabView()
        }
        .frame(width: width)
        .onDisappear { store.previewDockWidth = width }
    }
}

/// Last-refreshed indicator, also used in the sidebar footer.
struct TimeAgoLabel: View {
    @EnvironmentObject var store: DashboardStore
    @State private var secondsAgo = 0
    @State private var timer: Timer?

    var body: some View {
        Text(secondsAgo == 0 ? "just now" : "\(secondsAgo)s ago")
            .font(DSFont.monoDigits(.caption2))
            .foregroundColor(.secondary)
            .onAppear { start() }
            .onChange(of: store.lastUpdated) { _ in secondsAgo = 0 }
    }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in secondsAgo += 1 }
        }
    }
}
