import SwiftUI

/// One selectable row in the command palette. The list is rebuilt on every
/// keystroke (`makeCommandActions`); `CommandBarModel.selectedIndex` tracks the
/// vim-navigable highlight.
struct PaletteAction: Identifiable {
    let id: String
    let icon: String
    let color: Color
    let label: String
    var subtitle: String? = nil
    let run: () -> Void
}

/// Shared state for the toolbar-integrated command line. The input field lives
/// in the toolbar while the results render as a window overlay beneath it, so
/// both halves observe this single object rather than passing bindings around.
@MainActor
final class CommandBarModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedIndex: Int = 0

    var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func reset() {
        query = ""
        selectedIndex = 0
    }
}

/// Builds the ordered action list for the current query. Used by both the
/// toolbar field (for Enter / vim navigation) and the results overlay (for
/// rendering), so the two never drift. Repo jumps come first so the default
/// highlight (index 0) lands on the top repo match.
@MainActor
func makeCommandActions(query: String, store: DashboardStore, dismiss: @escaping () -> Void) -> [PaletteAction] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let q = trimmed.lowercased()
    guard !q.isEmpty else { return [] }

    let currentPath = store.selection.flatMap { store.project(for: $0)?.path } ?? ""
    func matches(_ keywords: String...) -> Bool { keywords.contains { q.contains($0) } }

    var result: [PaletteAction] = []

    let repos = store.projects
        .filter { $0.name.lowercased().contains(q) && $0.path != currentPath }
        .prefix(6)
    for proj in repos {
        result.append(PaletteAction(
            id: "repo:\(proj.path)", icon: "folder.fill", color: .accentColor,
            label: "Go to \(proj.name)", subtitle: proj.path
        ) {
            store.selection = .project(path: proj.path)
            dismiss()
        })
    }

    result.append(PaletteAction(
        id: "create", icon: "plus.circle.fill", color: .blue,
        label: "Create task: \(trimmed)"
    ) {
        if !currentPath.isEmpty {
            store.addTask(projectPath: currentPath, title: trimmed, linkedDocPath: store.activeDocPath)
        }
        dismiss()
    })
    result.append(PaletteAction(
        id: "idea", icon: "lightbulb.fill", color: .yellow,
        label: "Capture idea: \(trimmed)"
    ) {
        if !currentPath.isEmpty {
            store.addTask(projectPath: currentPath, title: trimmed, category: .other)
        }
        dismiss()
    })
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

/// The results dropdown shown beneath the toolbar command field. Purely
/// presentational: it reads the query/highlight from the model and renders the
/// action rows. Activation and keyboard navigation happen in the toolbar field
/// (where focus lives); rows here are click/hover targets.
struct CommandResultsView: View {
    @EnvironmentObject var store: DashboardStore
    @ObservedObject var model: CommandBarModel
    let dismiss: () -> Void

    var body: some View {
        let actions = makeCommandActions(query: model.query, store: store, dismiss: dismiss)
        VStack(spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                row(action, isSelected: index == model.selectedIndex)
                    .onHover { hovering in if hovering { model.selectedIndex = index } }
            }
        }
        .padding(DSSpace.sm)
        .frame(width: 460)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.large, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
    }

    private func row(_ action: PaletteAction, isSelected: Bool) -> some View {
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
}
