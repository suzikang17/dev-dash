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
                .font(DSFont.micro.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(linkedTasks.count)")
                .font(DSFont.monoDigits(.caption2))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DSSpace.sm)
        .padding(.vertical, DSSpace.sm)
    }

    private var emptyState: some View {
        Text("No linked tasks")
            .font(DSFont.micro)
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
            .padding(.vertical, DSSpace.xs)
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        Button {
            store.openTaskId = task.id
            store.openTaskProjectPath = projectPath
        } label: {
            HStack(spacing: DSSpace.xs) {
                statusDot(task.status)
                Text(task.title)
                    .font(DSFont.micro)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .strikethrough(task.status == .done, color: .secondary)
                    .foregroundStyle(task.status == .done ? .tertiary : .primary)
                Spacer()
            }
            .padding(.horizontal, DSSpace.sm)
            .padding(.vertical, DSSpace.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusDot(_ status: TaskStatus) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DSColor.success)
                .font(DSFont.micro)
        case .blocked:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(DSColor.warning)
                .font(DSFont.micro)
        default:
            Image(systemName: "circle")
                .foregroundStyle(DSColor.info)
                .font(DSFont.micro)
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
                .font(DSFont.micro)
                .foregroundStyle(DSColor.info)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DSSpace.sm)
                .padding(.vertical, DSSpace.sm)
        }
        .buttonStyle(.plain)
    }
}
