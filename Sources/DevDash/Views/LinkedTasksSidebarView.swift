import SwiftUI

struct LinkedTasksSidebarView: View {
    @EnvironmentObject var store: DashboardStore
    let projectPath: String
    let docPath: String

    private var linkedTasks: [TaskItem] {
        store.tasksV2(for: projectPath).filter { $0.linkedDocPath == docPath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if linkedTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
            Divider()
            addButton
        }
        .frame(width: 180)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            Text("Linked tasks")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(linkedTasks.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        Text("No linked tasks")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding()
    }

    private var taskList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(linkedTasks) { task in
                    taskRow(task)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        Button {
            store.openTaskId = task.id
            store.openTaskProjectPath = projectPath
        } label: {
            HStack(spacing: 6) {
                statusDot(task.status)
                Text(task.title)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .strikethrough(task.status == .done, color: .secondary)
                    .foregroundStyle(task.status == .done ? .tertiary : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusDot(_ status: TaskStatus) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 10))
        case .blocked:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 10))
        default:
            Image(systemName: "circle")
                .foregroundStyle(.blue)
                .font(.system(size: 10))
        }
    }

    private var addButton: some View {
        Button {
            store.addTask(
                projectPath: projectPath,
                title: "New task",
                linkedDocPath: docPath
            )
        } label: {
            Label("Add task", systemImage: "plus")
                .font(.system(size: 11))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }
}
