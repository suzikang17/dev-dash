import SwiftUI

struct DetailPaneView: View {
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var tabStore: TabStore

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
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if placement == .side, let project {
                    SideTerminalContainer(project: project, initialWidth: store.terminalWidth)
                }
            }
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
    }

    private var tabArea: some View {
        Group {
            switch store.selection {
            case .none, .some(.home):
                HomeView()
            case .some:
                switch tabStore.detailTab {
                case .preview: PreviewTabView()
                case .logs: LogsTabView()
                case .claude: ClaudeTabView()
                case .tasks: TasksTabView()
                case .info: InfoTabView()
                case .product: ProductTabView()
                case .files: FilesTabView()
                case .docs: DocsTabView()
                case .daily: DailyTabView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
