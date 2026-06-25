import SwiftUI
import AppKit

/// Linear integration settings — API key management and group-level team binding.
/// Embedded as the "Linear" tab in SettingsView's side-tab navigation.
struct LinearSettingsView: View {
    @EnvironmentObject var store: DashboardStore

    @State private var apiKeyDraft: String = ""
    @State private var isSavingKey = false
    @State private var teams: [LinearTeam] = []
    @State private var isLoadingTeams = false
    @State private var teamsError: String?
    @State private var projectsForTeam: [String: [LinearProject]] = [:]
    @State private var isLoadingProjects: Set<String> = []
    @State private var showNewGroupSheet = false
    @State private var editingGroupName: String? = nil   // groupId being renamed
    @State private var groupNameDraft: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.xl) {
                apiKeySection
                Divider()
                if store.isLinearKeyPresent {
                    teamLoaderSection
                    Divider()
                    groupsSection
                }
            }
            .padding(DSSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showNewGroupSheet) {
            NewGroupSheet(projectPath: nil, onCreated: nil)
                .environmentObject(store)
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            SectionHeader("Personal API Key")
            Text("Generate a key at linear.app → Settings → API. The key is stored in your macOS Keychain.")
                .font(DSFont.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isLinearKeyPresent {
                HStack(spacing: DSSpace.sm) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(DSColor.success)
                    Text("Connected")
                        .font(DSFont.label)
                        .foregroundStyle(DSColor.success)
                    Spacer()
                    Button("Clear key") {
                        store.clearLinearAPIKey()
                        teams = []
                        teamsError = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(DSColor.danger)
                }
                .padding(DSSpace.sm)
                .cardSurface(DSRadius.small)
            } else {
                HStack(spacing: DSSpace.sm) {
                    SecureField("Paste API key…", text: $apiKeyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                    Button("Save") {
                        isSavingKey = true
                        store.setLinearAPIKey(apiKeyDraft)
                        apiKeyDraft = ""
                        isSavingKey = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingKey)
                }
            }
        }
    }

    // MARK: - Team loader

    private var teamLoaderSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            SectionHeader("Teams")
            HStack(spacing: DSSpace.sm) {
                Button {
                    isLoadingTeams = true
                    teamsError = nil
                    Task {
                        let fetched = await LinearScanner.fetchTeams()
                        teams = fetched
                        isLoadingTeams = false
                        if fetched.isEmpty { teamsError = "No teams found (check key permissions)." }
                    }
                } label: {
                    Label("Load teams", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoadingTeams)

                if isLoadingTeams { ProgressView().controlSize(.small) }
            }

            if let err = teamsError {
                Text(err).font(DSFont.micro).foregroundStyle(DSColor.danger)
            }

            if !teams.isEmpty {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    ForEach(teams) { team in
                        HStack(spacing: DSSpace.sm) {
                            Image(systemName: "rhombus")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(team.name)
                                .font(DSFont.label)
                            Text("[\(team.key)]")
                                .font(DSFont.monoDigits(.caption2))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Groups management

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack {
                SectionHeader("Groups")
                Spacer()
                Button {
                    showNewGroupSheet = true
                } label: {
                    Label("New group", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Each group binds a set of repos to one Linear team or project. Issues are fetched once per group and appear in all member repos' task views.")
                .font(DSFont.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.projectGroups.isEmpty {
                Text("No groups yet. Create one to start syncing Linear issues.")
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DSSpace.xs)
            } else {
                ForEach(store.projectGroups.sorted(by: { $0.createdAt < $1.createdAt })) { grp in
                    GroupSettingsRow(
                        group: grp,
                        teams: teams,
                        projectsForTeam: $projectsForTeam,
                        isLoadingProjects: $isLoadingProjects,
                        editingGroupName: $editingGroupName,
                        groupNameDraft: $groupNameDraft
                    )
                    .environmentObject(store)
                    if grp.id != store.projectGroups.last?.id { Divider() }
                }
            }
        }
    }
}

// MARK: - Group settings row

private struct GroupSettingsRow: View {
    let group: ProjectGroup
    let teams: [LinearTeam]
    @Binding var projectsForTeam: [String: [LinearProject]]
    @Binding var isLoadingProjects: Set<String>
    @Binding var editingGroupName: String?
    @Binding var groupNameDraft: String

    @EnvironmentObject var store: DashboardStore

    @State private var selectedTeamId: String = ""
    @State private var selectedProjectId: String = ""

    private var memberProjects: [Project] {
        group.projectPaths.compactMap { path in
            store.projects.first { $0.path == path }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            // Group name (editable inline)
            if editingGroupName == group.id {
                HStack(spacing: DSSpace.sm) {
                    TextField("Group name…", text: $groupNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename() }
                    Button("Save") { commitRename() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Cancel") { editingGroupName = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: DSSpace.sm) {
                    Image(systemName: "rhombus")
                        .foregroundStyle(DSColor.info)
                        .frame(width: 14)
                    Text(group.name)
                        .font(DSFont.label.weight(.semibold))
                    Text(verbatim: "(\(group.projectPaths.count) repos)")
                        .font(DSFont.micro)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rename") {
                        groupNameDraft = group.name
                        editingGroupName = group.id
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Button(role: .destructive) {
                        store.deleteGroup(id: group.id)
                    } label: { Text("Delete") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(DSColor.danger)
                }
            }

            // Linear binding
            if let teamName = group.linearTeamName {
                HStack(spacing: DSSpace.xs) {
                    Image(systemName: "link")
                        .foregroundStyle(DSColor.success)
                        .font(DSFont.micro)
                    Text(teamName)
                        .font(DSFont.micro)
                        .foregroundStyle(DSColor.success)
                    if let projName = group.linearProjectName {
                        Text("/ \(projName)")
                            .font(DSFont.micro)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unbind") {
                        store.setGroupLinearBinding(id: group.id, teamId: nil, teamName: nil,
                                                    projectId: nil, projectName: nil)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(DSColor.danger)
                }
            } else if !teams.isEmpty {
                HStack(spacing: DSSpace.sm) {
                    Picker("Team", selection: $selectedTeamId) {
                        Text("— choose team —").tag("")
                        ForEach(teams) { t in Text(t.name).tag(t.id) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .onChange(of: selectedTeamId) { _, teamId in
                        selectedProjectId = ""
                        guard !teamId.isEmpty else { return }
                        isLoadingProjects.insert(teamId)
                        Task {
                            let projs = await LinearScanner.fetchProjects(teamId: teamId)
                            projectsForTeam[teamId] = projs
                            isLoadingProjects.remove(teamId)
                        }
                    }

                    if !selectedTeamId.isEmpty {
                        let projs = projectsForTeam[selectedTeamId] ?? []
                        if isLoadingProjects.contains(selectedTeamId) {
                            ProgressView().controlSize(.small)
                        } else if !projs.isEmpty {
                            Picker("Project", selection: $selectedProjectId) {
                                Text("— all issues —").tag("")
                                ForEach(projs) { p in Text(p.name).tag(p.id) }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                    }

                    Button("Bind") {
                        guard let team = teams.first(where: { $0.id == selectedTeamId }) else { return }
                        let proj = projectsForTeam[selectedTeamId]?.first { $0.id == selectedProjectId }
                        store.setGroupLinearBinding(
                            id: group.id,
                            teamId: team.id,
                            teamName: team.name,
                            projectId: proj?.id,
                            projectName: proj?.name
                        )
                        selectedTeamId = ""
                        selectedProjectId = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedTeamId.isEmpty)
                }
            } else {
                Text("Load teams above to bind this group.")
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
            }

            // Member list
            if !memberProjects.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(memberProjects) { proj in
                        HStack(spacing: DSSpace.xs) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.secondary)
                            Text(proj.name)
                                .font(DSFont.micro)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                store.removeProjectFromGroup(projectPath: proj.path)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.secondary)
                                    .font(DSFont.micro)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(proj.name) from group")
                        }
                    }
                }
                .padding(.leading, DSSpace.md)
            }
        }
        .padding(.vertical, DSSpace.xs)
    }

    private func commitRename() {
        let trimmed = groupNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { store.renameGroup(id: group.id, name: trimmed) }
        editingGroupName = nil
    }
}
