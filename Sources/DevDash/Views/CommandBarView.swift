import SwiftUI

/// One selectable row in the command palette. The list is built fresh on every
/// keystroke (`actions`), and `selectedIndex` tracks the vim-navigable highlight.
private struct PaletteAction: Identifiable {
    let id: String
    let icon: String
    let color: Color
    let label: String
    var subtitle: String? = nil
    let run: () -> Void
}

struct CommandBarView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    private var projectPath: String { store.selection.flatMap { store.project(for: $0)?.path } ?? "" }

    /// Repos whose name matches the query, for jump-to navigation. Mirrors the
    /// sidebar's case-insensitive name filter; capped so the palette stays short.
    private var matchingProjects: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let currentPath = projectPath
        return store.projects
            .filter { $0.name.lowercased().contains(q) && $0.path != currentPath }
            .prefix(6)
            .map { $0 }
    }

    /// The full, ordered list of actions for the current query. Repo jumps come
    /// first so the default highlight (index 0) lands on the top repo match.
    private var actions: [PaletteAction] {
        var result: [PaletteAction] = []
        for proj in matchingProjects {
            result.append(PaletteAction(
                id: "repo:\(proj.path)", icon: "folder.fill", color: .accentColor,
                label: "Go to \(proj.name)", subtitle: proj.path
            ) { navigate(to: proj) })
        }
        result.append(PaletteAction(
            id: "create", icon: "plus.circle.fill", color: .blue,
            label: "Create task: \(query)"
        ) { createTask() })
        result.append(PaletteAction(
            id: "idea", icon: "lightbulb.fill", color: .yellow,
            label: "Capture idea: \(query)"
        ) { captureIdea() })
        if matches("theme", "light", "dark", "appearance", "mode") {
            result.append(PaletteAction(
                id: "theme", icon: store.appTheme.toggled.icon, color: .purple,
                label: "Switch to \(store.appTheme.toggled.label) theme"
            ) { store.toggleTheme(); dismiss() })
        }
        if matches("settings", "preferences", "config") {
            result.append(PaletteAction(
                id: "settings", icon: "gearshape.fill", color: .gray,
                label: "Open settings"
            ) { dismiss(); store.isSettingsVisible = true })
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
            .frame(width: 560)
            .background(.ultraThickMaterial)
            // Square top edge so the panel reads as continuous with the toolbar
            // it drops out of; only the bottom corners are rounded.
            .clipShape(UnevenRoundedRectangle(
                bottomLeadingRadius: DSRadius.large,
                bottomTrailingRadius: DSRadius.large,
                style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            .padding(.trailing, DSSpace.lg)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isFocused = true }
        .onChange(of: query) { selectedIndex = 0 }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(phases: .down) { handleKey($0) }
    }

    /// Vim-style navigation over the action list. Bare j/k can't be used while
    /// the search field has focus (they'd type into it), so movement is bound to
    /// Ctrl-J/Ctrl-K (and Ctrl-N/P + arrow keys). Enter activates the highlight.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow: moveSelection(1); return .handled
        case .upArrow: moveSelection(-1); return .handled
        default: break
        }
        if press.modifiers.contains(.control) {
            switch press.characters.lowercased() {
            case "j", "n": moveSelection(1); return .handled
            case "k", "p": moveSelection(-1); return .handled
            default: break
            }
        }
        return .ignored
    }

    private func moveSelection(_ delta: Int) {
        let count = actions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func activateSelected() {
        let current = actions
        guard current.indices.contains(selectedIndex) else { dismiss(); return }
        current[selectedIndex].run()
    }

    private var searchField: some View {
        HStack(spacing: DSSpace.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
            TextField("Jump to a repo, or create a task or idea…", text: $query)
                .textFieldStyle(.plain)
                .font(DSFont.title)
                .focused($isFocused)
                .onSubmit { activateSelected() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
    }

    private var actionList: some View {
        VStack(spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                actionRow(action, isSelected: index == selectedIndex)
                    .onHover { hovering in if hovering { selectedIndex = index } }
            }
        }
        .padding(.vertical, DSSpace.sm)
        .padding(.horizontal, DSSpace.sm)
    }

    /// True if the query contains any of the given keywords (case-insensitive).
    private func matches(_ keywords: String...) -> Bool {
        let q = query.lowercased()
        return keywords.contains { q.contains($0) }
    }

    private func actionRow(_ action: PaletteAction, isSelected: Bool) -> some View {
        Button(action: action.run) {
            HStack(spacing: DSSpace.sm) {
                Image(systemName: action.icon)
                    .foregroundStyle(action.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.label)
                        .font(DSFont.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if let subtitle = action.subtitle {
                        Text(subtitle)
                            .font(DSFont.micro)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Text("↵")
                        .font(DSFont.micro)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DSSpace.sm)
            .padding(.vertical, DSSpace.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        )
    }

    private func navigate(to project: Project) {
        store.selection = .project(path: project.path)
        dismiss()
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
