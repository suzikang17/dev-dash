import SwiftUI
import AppKit

/// App preferences modal. Opened via ⌘, or the command bar.
/// Presented as an overlay so a click outside (or Esc) dismisses it.
struct SettingsView: View {
    @EnvironmentObject var store: DashboardStore

    // MARK: - Tab navigation
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case appearance, folders, claude, document, terminal
        var id: String { rawValue }
        var label: String {
            switch self {
            case .appearance: return "Appearance"
            case .folders:    return "Project folders"
            case .claude:     return "Claude integration"
            case .document:   return "Document"
            case .terminal:   return "Terminal"
            }
        }
        var systemImage: String {
            switch self {
            case .appearance: return "paintbrush"
            case .folders:    return "folder"
            case .claude:     return "sparkles"
            case .document:   return "doc.text"
            case .terminal:   return "terminal"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .appearance

    // MARK: - Claude integration section state
    @State private var installed: Set<String> = []
    @State private var hookError: String? = nil

    var body: some View {
        ZStack {
            // Dimmed backdrop — tapping anywhere outside the card dismisses.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            card
                // Swallow taps on the card so they don't reach the backdrop.
                .onTapGesture {}
                .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                // LEFT: sidebar nav
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            HStack(spacing: DSSpace.sm) {
                                Image(systemName: tab.systemImage)
                                    .frame(width: 16, alignment: .center)
                                    .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                                Text(tab.label)
                                    .font(DSFont.label)
                                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                                Spacer()
                            }
                            .padding(.horizontal, DSSpace.md)
                            .padding(.vertical, DSSpace.sm)
                            .background(
                                RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous)
                                    .fill(selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(DSSpace.sm)
                .frame(width: 180)
                .frame(maxHeight: .infinity)
                .background(Color.primary.opacity(0.03))

                Divider()

                // RIGHT: content pane
                ScrollView {
                    Group {
                        switch selectedTab {
                        case .appearance: appearanceSection
                        case .folders:    foldersSection
                        case .claude:     claudeIntegrationSection
                        case .document:   documentSection
                        case .terminal:   terminalSection
                        }
                    }
                    .padding(DSSpace.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 720, height: 640)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous))
    }

    private func dismiss() { store.isSettingsVisible = false }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(DSFont.title)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close settings")
        }
        .padding(.horizontal, DSSpace.xl)
        .padding(.vertical, 14)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        section(title: "Appearance") {
            HStack(spacing: DSSpace.md) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    themeOption(theme)
                }
            }
        }
    }

    private func themeOption(_ theme: AppTheme) -> some View {
        let isSelected = store.appTheme == theme
        return Button {
            store.appTheme = theme
        } label: {
            VStack(spacing: DSSpace.sm) {
                Image(systemName: theme.icon)
                    .font(DSFont.sectionTitle)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(height: 28)
                Text(theme.label)
                    .font(.system(.caption).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(width: 96, height: 76)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Project folders (scan roots)

    private var foldersSection: some View {
        section(title: "Project folders") {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                Text("DevDash scans these folders for projects. Each immediate subfolder with a recognizable stack appears in the sidebar.")
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.devRoots.isEmpty {
                    Text("No folders — DevDash won't find any projects.")
                        .font(DSFont.micro)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(store.devRoots, id: \.self) { root in
                        rootRow(root)
                    }
                }

                HStack(spacing: DSSpace.sm) {
                    Button { addFolder() } label: {
                        Label("Add folder…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Button("Reset to defaults") { store.resetDevRoots() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
    }

    private func rootRow(_ root: String) -> some View {
        HStack(spacing: DSSpace.sm) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(DevRoots.shortenPath(root))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(root)
            Spacer(minLength: DSSpace.sm)
            Button { store.removeDevRoot(root) } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove folder \(DevRoots.shortenPath(root))")
        }
        .padding(.vertical, 2)
    }

    /// Native directory picker — adding via a panel avoids typo'd paths.
    /// We store the raw path; that's fine because DevDash isn't sandboxed. Under
    /// App Sandbox (e.g. Mac App Store) this would need a security-scoped bookmark
    /// to keep scanning the folder across launches.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder that contains your projects"
        panel.directoryURL = URL(fileURLWithPath: DevRoots.home)
        if panel.runModal() == .OK, let url = panel.url {
            store.addDevRoot(url.path)
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        section(title: "Terminal") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: DSSpace.sm) {
                    Text("Placement")
                        .font(DSFont.label)
                        .frame(width: 76, alignment: .leading)
                    Picker("", selection: $store.terminalPlacement) {
                        ForEach(TerminalPlacement.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack(spacing: DSSpace.sm) {
                    Text("Font size")
                        .font(DSFont.label)
                        .frame(width: 76, alignment: .leading)
                    Button { store.zoomTerminal(-1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("Decrease terminal font size")
                    Text("\(Int(store.terminalFontSize)) pt")
                        .font(DSFont.monoDigits(.caption))
                        .frame(width: 40)
                    Button { store.zoomTerminal(1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("Increase terminal font size")
                    Button("Reset") { store.resetTerminalZoom() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                HStack(spacing: DSSpace.sm) {
                    Text("Font")
                        .font(DSFont.label)
                        .frame(width: 76, alignment: .leading)
                    Picker("", selection: $store.terminalFontFamily) {
                        ForEach(TerminalFontFamily.allCases, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                HStack(spacing: DSSpace.sm) {
                    Text("Cursor")
                        .font(DSFont.label)
                        .frame(width: 76, alignment: .leading)
                    Picker("", selection: $store.terminalCursorStyle) {
                        ForEach(TerminalCursorStyle.allCases, id: \.self) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack(spacing: DSSpace.sm) {
                    Text("Scrollback")
                        .font(DSFont.label)
                        .frame(width: 76, alignment: .leading)
                    Stepper(value: $store.terminalScrollback, in: 1000...50000, step: 1000) {
                        Text("\(store.terminalScrollback) lines")
                            .font(DSFont.monoDigits(.caption))
                    }
                }
                Text("Background and foreground follow the app theme; ANSI colors are tuned per theme.")
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Document (living-doc appearance)

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    private var documentSection: some View {
        section(title: "Document") {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                // Accent hue — drives the whole generated palette.
                SectionHeader("Accent")
                HStack(spacing: DSSpace.sm) {
                    ForEach(DocAccent.allCases, id: \.self) { accent in
                        accentSwatch(accent)
                    }
                    Spacer(minLength: 0)
                }
                Text("Tints the whole living-doc palette — neutrals included.")
                    .font(DSFont.micro).foregroundStyle(.secondary)

                // Type pairing presets.
                SectionHeader("Type pairing")
                    .padding(.top, 2)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84), spacing: 8)],
                    alignment: .leading, spacing: 8
                ) {
                    ForEach(DocFontPreset.allCases, id: \.self) { preset in
                        presetChip(preset)
                    }
                }

                // Live picker over installed fonts — choosing one flips to Custom.
                SectionHeader("Fonts — any installed on your Mac")
                    .padding(.top, 2)
                fontPicker("Display", binding: customBinding(\.docFontDisplay))
                fontPicker("Body", binding: customBinding(\.docFontBody))
                fontPicker("Mono", binding: customBinding(\.docFontMono))
            }
        }
    }

    private func accentColor(_ a: DocAccent) -> Color {
        switch a {
        case .amber:      return Color(red: 0.83, green: 0.57, blue: 0.14)
        case .terracotta: return Color(red: 0.76, green: 0.39, blue: 0.25)
        case .ochre:      return Color(red: 0.78, green: 0.60, blue: 0.17)
        case .olive:      return Color(red: 0.49, green: 0.54, blue: 0.25)
        }
    }

    private func accentSwatch(_ accent: DocAccent) -> some View {
        let isSel = store.docAccent == accent
        return Button { store.docAccent = accent } label: {
            VStack(spacing: DSSpace.sm) {
                Circle()
                    .fill(accentColor(accent))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle().stroke(Color.primary.opacity(isSel ? 0 : 0.12), lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(.caption).weight(.bold))
                            .foregroundStyle(.white)
                            .opacity(isSel ? 1 : 0)
                    )
                Text(accent.label)
                    .font(.system(.caption2).weight(isSel ? .semibold : .regular))
                    .foregroundStyle(isSel ? .primary : .secondary)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func presetChip(_ preset: DocFontPreset) -> some View {
        let isSel = store.docFontPreset == preset
        return Button { store.docFontPreset = preset } label: {
            Text(preset.label)
                .font(.system(.caption).weight(isSel ? .semibold : .regular))
                .foregroundStyle(isSel ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous)
                        .fill(Color.primary.opacity(isSel ? 0.10 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous)
                        .stroke(isSel ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: isSel ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func fontPicker(_ label: String, binding: Binding<String>) -> some View {
        HStack(spacing: DSSpace.sm) {
            Text(label)
                .font(DSFont.label).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Picker("", selection: binding) {
                Text("— preset default —").tag("")
                ForEach(fontFamilies, id: \.self) { fam in
                    Text(fam).font(.custom(fam, size: 13)).tag(fam)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    /// Edits a custom font override directly; selecting a real family flips the
    /// preset to `.custom` so the override takes effect.
    private func customBinding(
        _ keyPath: ReferenceWritableKeyPath<DashboardStore, String>
    ) -> Binding<String> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { value in
                store[keyPath: keyPath] = value
                if !value.isEmpty { store.docFontPreset = .custom }
            }
        )
    }

    // MARK: - Claude Code integration

    @State private var showHowItWorks = false

    private var claudeIntegrationSection: some View {
        section(title: "Claude Code integration") {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                Text("Wire Claude Code into dev-dash. Install hooks for a project so any `claude` session there reports activity, refreshes git on commits, and receives your current tasks as context.")
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Server status
                HStack(spacing: DSSpace.sm) {
                    let port = store.eventServerPort
                    Circle()
                        .fill(port > 0 ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    if port > 0 {
                        Text("Listening on ")
                            .font(DSFont.micro)
                            .foregroundStyle(.secondary)
                        + Text("127.0.0.1:\(port)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Starting…")
                            .font(DSFont.micro)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)

                // Behavior toggles — these are GLOBAL defaults; per-project overrides below.
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Inject project context into sessions", isOn: $store.injectProjectContext)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Text("Adds your open tasks and latest devlog to each Claude prompt in installed projects.")
                            .font(DSFont.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Auto-write a devlog when a session ends", isOn: $store.autoDevlogOnSessionEnd)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Text("Runs Claude to summarize meaningful sessions. Off by default — this spawns a `claude` process on session end.")
                            .font(DSFont.micro)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Defaults for all projects — override per project below.")
                        .font(DSFont.micro)
                        .foregroundStyle(.tertiary)
                        .italic()

                    // Global default event set
                    HStack(spacing: DSSpace.sm) {
                        Text("Events installed by default")
                            .font(DSFont.label)
                        globalEventsMenu
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 4)

                // Per-project hook list
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    Text("Hooks are installed per project in its .claude/settings.json.")
                        .font(DSFont.micro)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    if store.projects.isEmpty {
                        Text("No projects — add a project folder above.")
                            .font(DSFont.micro)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(store.projects, id: \.path) { project in
                            hookProjectRow(project)
                        }
                    }

                    if !store.projects.isEmpty {
                        HStack(spacing: DSSpace.sm) {
                            Button {
                                hookError = nil
                                var errors: [String] = []
                                for project in store.projects {
                                    guard !installed.contains(project.path) else { continue }
                                    do {
                                        try store.installHooks(for: project.path)
                                        installed.insert(project.path)
                                    } catch {
                                        errors.append(project.name)
                                    }
                                }
                                if !errors.isEmpty {
                                    hookError = "Failed to install for: \(errors.joined(separator: ", "))"
                                }
                            } label: {
                                Label("Install for all", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }
                        .padding(.top, 2)
                    }

                    if let err = hookError {
                        Text(err)
                            .font(DSFont.micro)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // "How it works" transparency panel
                howItWorksDisclosure
            }
            .onAppear {
                installed = Set(store.projects.filter { store.hooksInstalled(for: $0.path) }.map { $0.path })
            }
        }
    }

    private var howItWorksDisclosure: some View {
        DisclosureGroup(isExpanded: $showHowItWorks) {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                Text("When a session runs in an installed project, Claude fires these hooks back to dev-dash:")
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DSSpace.sm)

                ForEach(HookInstaller.hookSpecs) { spec in
                    hookSpecRow(spec)
                }

                // Files installed subsection
                VStack(alignment: .leading, spacing: 4) {
                    Text("Files installed")
                        .font(DSFont.micro)
                        .foregroundStyle(.secondary)
                        .padding(.top, DSSpace.sm)
                    Group {
                        Text("~/.devdash/bin/devdash-hook")
                        Text("<project>/.claude/settings.json")
                        Text("~/.devdash/event-endpoint.json")
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("How it works — events & what they trigger")
                .font(DSFont.micro)
                .foregroundStyle(.secondary)
        }
        .padding(.top, DSSpace.sm)
    }

    private func hookSpecRow(_ spec: HookInstaller.HookEventSpec) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.event)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
            Text(spec.firesWhen)
                .font(DSFont.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(spec.reaction)
                .font(DSFont.micro)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let gatedBy = spec.gatedBy {
                Text("Only when '\(gatedBy)' is on")
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, DSSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func hookProjectRow(_ project: Project) -> some View {
        let isInstalled = installed.contains(project.path)
        let isLive = store.liveSessions.values.contains {
            $0.projectPath == project.path && $0.status == .active
        }
        let eventCount = store.recentEvents.filter { $0.projectPath == project.path }.count

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DSSpace.sm) {
                // Live-status dot
                Circle()
                    .fill(isLive ? Color.green : Color.clear)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle().stroke(isLive ? Color.green : Color.secondary.opacity(0.4), lineWidth: 1)
                    )

                Text(project.name)
                    .font(DSFont.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(project.path)

                if eventCount > 0 {
                    Text("\(eventCount) recent")
                        .font(DSFont.micro)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: DSSpace.sm)

                if isInstalled {
                    Button("Remove") {
                        store.uninstallHooks(for: project.path)
                        installed.remove(project.path)
                        hookError = nil
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Install") {
                        do {
                            hookError = nil
                            try store.installHooks(for: project.path)
                            installed.insert(project.path)
                        } catch {
                            hookError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Per-project override pickers — only shown when hooks are installed.
            if isInstalled {
                HStack(spacing: DSSpace.md) {
                    hookOverridePicker(
                        label: "Context",
                        globalDefault: store.injectProjectContext,
                        current: store.projectHookConfigs[project.path]?.injectContext
                    ) { newValue in
                        store.setInjectContextOverride(newValue, for: project.path)
                    }
                    hookOverridePicker(
                        label: "Devlog",
                        globalDefault: store.autoDevlogOnSessionEnd,
                        current: store.projectHookConfigs[project.path]?.autoDevlog
                    ) { newValue in
                        store.setAutoDevlogOverride(newValue, for: project.path)
                    }
                    hookEventsPicker(projectPath: project.path)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 3)
    }

    /// A compact Menu listing all 6 hook events as checkmark toggles for a specific project.
    /// Shows the count of enabled events vs total. Includes "Reset to default" to clear override.
    private func hookEventsPicker(projectPath: String) -> some View {
        let hookSpecs = HookInstaller.hookSpecs
        let effective = store.effectiveEnabledEvents(for: projectPath)
        let hasOverride = store.projectHookConfigs[projectPath]?.enabledEvents != nil
        let label = "Events \(effective.count)/\(hookSpecs.count)"

        return Menu {
            ForEach(hookSpecs) { spec in
                let isOn = effective.contains(spec.event)
                Button {
                    // Read live (not the captured snapshot) so rapid re-toggles don't
                    // write back a stale set.
                    var newSet = store.effectiveEnabledEvents(for: projectPath)
                    if newSet.contains(spec.event) { newSet.remove(spec.event) } else { newSet.insert(spec.event) }
                    store.setEnabledEventsOverride(newSet, for: projectPath)
                } label: {
                    HStack {
                        if isOn {
                            Image(systemName: "checkmark")
                        }
                        Text(spec.event)
                    }
                }
            }
            if hasOverride {
                Divider()
                Button("Reset to default") {
                    store.setEnabledEventsOverride(nil, for: projectPath)
                }
            }
        } label: {
            Text(label)
                .font(DSFont.micro)
                .foregroundStyle(hasOverride ? .primary : .tertiary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    /// Global default events menu — a compact checklist of all 6 events bound to `store.defaultEnabledEvents`.
    private var globalEventsMenu: some View {
        let hookSpecs = HookInstaller.hookSpecs
        let current = store.defaultEnabledEvents
        let label = "\(current.count)/\(hookSpecs.count)"

        return Menu {
            ForEach(hookSpecs) { spec in
                let isOn = current.contains(spec.event)
                Button {
                    // Decide from the live set, not the captured snapshot.
                    var newSet = store.defaultEnabledEvents
                    if newSet.contains(spec.event) { newSet.remove(spec.event) } else { newSet.insert(spec.event) }
                    store.defaultEnabledEvents = newSet
                } label: {
                    HStack {
                        if isOn {
                            Image(systemName: "checkmark")
                        }
                        Text(spec.event)
                    }
                }
            }
        } label: {
            Text(label)
                .font(DSFont.micro)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    /// A compact tri-state Menu (Default / On / Off) for a single per-project hook override.
    private func hookOverridePicker(
        label: String,
        globalDefault: Bool,
        current: Bool?,
        onChange: @escaping (Bool?) -> Void
    ) -> some View {
        let defaultLabel = "Default (\(globalDefault ? "On" : "Off"))"
        let selectionLabel: String = {
            switch current {
            case nil:   return defaultLabel
            case true:  return "On"
            case false: return "Off"
            }
        }()

        return Menu {
            Button(defaultLabel) { onChange(nil) }
            Divider()
            Button("On")  { onChange(true) }
            Button("Off") { onChange(false) }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
                Text(selectionLabel)
                    .font(DSFont.micro)
                    .foregroundStyle(current == nil ? .tertiary : .primary)
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: - Helpers

    private func section<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            SectionHeader(title)
            content()
        }
    }
}
