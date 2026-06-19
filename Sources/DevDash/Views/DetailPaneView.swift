import SwiftUI

struct DetailPaneView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var terminalHeight: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch store.selection {
                case .none, .some(.home):
                    HomeView()
                case .some:
                    switch store.detailTab {
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

            if store.terminalOpen, let project = store.project(for: store.selection) {
                TerminalDrawer(project: project, height: $terminalHeight)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct EmptySelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Select a server or project")
                .font(.title2)
            Text("Choose an item from the sidebar to preview it, see tasks, or browse docs.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
