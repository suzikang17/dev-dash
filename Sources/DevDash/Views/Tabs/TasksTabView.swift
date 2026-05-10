import SwiftUI
import AppKit

struct TasksTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var newText = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        if let project = store.project(for: store.selection) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(project.name)
                            .font(.title2.bold())
                        Spacer()
                        Button {
                            Task { await store.refreshIssues() }
                        } label: {
                            Label("Sync issues", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.isLoadingIssues)
                    }

                    addBar(project: project)

                    if let err = store.todoError {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }

                    let group = store.tasks(for: project.path)
                    let openTodos = group?.todos.filter { !$0.done } ?? []
                    let doneTodos = group?.todos.filter { $0.done } ?? []
                    let issues = group?.issues ?? []

                    if !issues.isEmpty {
                        TaskGroupCard(title: "GitHub Issues", systemImage: "exclamationmark.bubble", count: issues.count) {
                            ForEach(issues) { iss in
                                IssueRow(issue: iss)
                                if iss.id != issues.last?.id { Divider() }
                            }
                        }
                    }

                    if !openTodos.isEmpty {
                        TaskGroupCard(title: "Todos", systemImage: "checklist", count: openTodos.count) {
                            ForEach(openTodos) { t in
                                TodoLine(todo: t, projectPath: project.path)
                                if t.id != openTodos.last?.id { Divider() }
                            }
                        }
                    }

                    if !doneTodos.isEmpty {
                        TaskGroupCard(title: "Done", systemImage: "checkmark.circle", count: doneTodos.count) {
                            ForEach(doneTodos) { t in
                                TodoLine(todo: t, projectPath: project.path)
                                if t.id != doneTodos.last?.id { Divider() }
                            }
                        }
                    }

                    if openTodos.isEmpty && doneTodos.isEmpty && issues.isEmpty {
                        Text("No tasks yet. Add a todo above, or this project has no open GitHub issues.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                }
                .padding(20)
            }
        } else {
            Text("Select a project to see tasks")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func addBar(project: Project) -> some View {
        HStack(spacing: 8) {
            TextField("Add a todo to \(project.name)…", text: $newText)
                .textFieldStyle(.roundedBorder)
                .focused($addFocused)
                .onSubmit { submit(project: project) }
            Button {
                submit(project: project)
            } label: {
                Text("Add")
                    .frame(minWidth: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit(project: Project) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let path = project.path
        newText = ""
        addFocused = true
        Task { await store.addTodo(projectPath: path, text: text) }
    }
}

private struct TaskGroupCard<Content: View>: View {
    let title: String
    let systemImage: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

private struct IssueRow: View {
    let issue: Issue

    var body: some View {
        Button {
            NSWorkspace.shared.open(issue.url)
        } label: {
            HStack(spacing: 10) {
                Text("#\(issue.number)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .leading)
                Text(issue.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
                if !issue.labels.isEmpty {
                    ForEach(issue.labels.prefix(2), id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(timeAgo(issue.updatedAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

private struct TodoLine: View {
    let todo: Todo
    let projectPath: String
    @EnvironmentObject var store: DashboardStore
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.toggleTodo(projectPath: projectPath, id: todo.id) }
            } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(todo.done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            Text(todo.text)
                .font(.system(size: 13))
                .strikethrough(todo.done)
                .foregroundColor(todo.done ? .secondary : .primary)
            Spacer()
            if hover {
                Button {
                    Task { await store.deleteTodo(projectPath: projectPath, id: todo.id) }
                } label: {
                    Image(systemName: "trash").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .onHover { hover = $0 }
    }
}
