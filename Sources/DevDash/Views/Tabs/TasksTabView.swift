import SwiftUI

/// Tasks tab. Renders the lore-sourced ticket/task view for the selected project.
struct TasksTabView: View {
    @EnvironmentObject var store: DashboardStore
    // Canvas panels pinned to another project inject this override (see PanelContentView).
    @Environment(\.panelSelection) private var panelSelection

    var body: some View {
        if let project = store.project(for: panelSelection ?? store.selection) {
            LoreTasksView(projectPath: project.path)
        } else {
            Text("Select a project to see tasks")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
