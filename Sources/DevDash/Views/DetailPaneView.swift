import SwiftUI

struct DetailPaneView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var tabStore: TabStore
    @EnvironmentObject var canvasStore: CanvasStore

    var body: some View {
        let project = store.terminalOpen ? store.project(for: store.selection) : nil
        let placement = store.terminalPlacement

        // tabArea keeps a single, stable identity across placements (the terminal
        // attaches via safeAreaInset/overlay), so switching placement doesn't tear
        // down and rebuild the heavy tab content (WebViews, scroll state, etc.).
        tabArea
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if placement == .bottom, let project {
                    BottomTerminalContainer(project: project, initialHeight: store.terminalHeight)
                }
            }
            // Side placement is rendered beside the NavigationSplitView in ContentView,
            // not here, so it doesn't fight the detail/toolbar for width.
            .overlay {
                if placement == .floating, let project {
                    GeometryReader { geo in
                        FloatingTerminalPanel(project: project,
                                              initialFrame: store.terminalFloatingFrame,
                                              containerSize: geo.size)
                    }
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
            // Animate the floating drop-down's slide-in/out (and other placement swaps).
            .animation(.easeOut(duration: 0.25), value: store.terminalOpen)
    }

    private var tabArea: some View {
        Group {
            switch store.selection {
            case .none, .some(.home):
                HomeView()
            case .some(.simulator):
                SimulatorView()
            case .some:
                // Canvas mode replaces the tab body for a project that's in it.
                if let project = store.project(for: store.selection),
                   canvasStore.isCanvasMode(project.path) {
                    CanvasView(project: project)
                } else {
                    switch tabStore.detailTab {
                    case .logs: LogsTabView()
                    case .claude: ClaudeTabView()
                    case .tasks: TasksTabView()
                    case .info: InfoTabView()
                    case .product: ProductTabView()
                    case .docs: DocsTabView()
                    case .changes: ChangesTabView()
                    case .daily: DailyTabView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
