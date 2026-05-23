import SwiftUI

struct CommandBarView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var query: String = ""
    @FocusState private var isFocused: Bool

    private var projectPath: String { store.selection.flatMap { store.project(for: $0)?.path } ?? "" }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                searchField
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Divider()
                    actionList
                }
            }
            .frame(width: 420)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .padding(.top, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isFocused = true }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
            TextField("Create a task, idea, or search…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onSubmit { createTask() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var actionList: some View {
        VStack(spacing: 2) {
            actionRow(
                icon: "plus.circle.fill", color: .blue,
                label: "Create task: \(query)"
            ) { createTask() }
            actionRow(
                icon: "lightbulb.fill", color: .yellow,
                label: "Capture idea: \(query)"
            ) { captureIdea() }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private func actionRow(icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                Text("↵")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.0001))
    }

    private func createTask() {
        let t = query.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !projectPath.isEmpty else { dismiss(); return }
        store.addTask(projectPath: projectPath, title: t, linkedDocPath: store.activeDocPath)
        dismiss()
    }

    private func captureIdea() {
        let t = query.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !projectPath.isEmpty else { dismiss(); return }
        store.addTask(projectPath: projectPath, title: t, category: .other)
        dismiss()
    }

    private func dismiss() {
        query = ""
        store.isCommandBarVisible = false
    }
}
