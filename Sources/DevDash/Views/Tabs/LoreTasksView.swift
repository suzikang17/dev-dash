import SwiftUI

// MARK: - Model

struct LoreTaskItem: Identifiable {
    let id: UUID
    let file: String
    let path: String
    var title: String
    var status: String
    var owner: String
    var aiRun: Bool
    var category: String
    var priority: String
    var effort: String
    var notes: String
    var completed: String
    var body: String
    var completedToday: Bool

    var kanbanColumn: LoreKanbanColumn {
        switch (status, owner, aiRun) {
        case ("done", _, _), ("skipped", _, _):         return .done
        case ("blocked", _, _):                         return .blocked
        case ("open", "ai", _), ("in_progress", _, _):  return .aiWorking
        case ("open", "human", false):                  return .speccing
        case ("open", "human", true):                   return .reviewQA
        default:                                        return .backlog
        }
    }
}

enum LoreKanbanColumn: String, CaseIterable {
    case backlog, speccing, aiWorking, blocked, reviewQA, done

    var label: String {
        switch self {
        case .backlog:   return "Backlog"
        case .speccing:  return "Speccing"
        case .aiWorking: return "AI Working"
        case .blocked:   return "Blocked"
        case .reviewQA:  return "Review & QA"
        case .done:      return "Done"
        }
    }

    var color: Color {
        switch self {
        case .backlog:   return .secondary
        case .speccing:  return DSColor.success
        case .aiWorking: return DSColor.info
        case .blocked:   return DSColor.warning
        case .reviewQA:  return DSColor.assistant
        case .done:      return DSColor.success.opacity(0.6)
        }
    }
}

enum LoreViewMode: String { case kanban, needs, ideas }
enum LoreCommandMode { case status, owner, priority }

struct LoreIdeaItem: Identifiable {
    let id = UUID()
    let file: String
    let path: String
    let title: String
    let status: String   // raw, promising, promoted, parked
    let category: String
    let body: String
}

// MARK: - Main View

struct LoreTasksView: View {
    let projectPath: String

    @EnvironmentObject private var store: DashboardStore

    @State private var tasks: [LoreTaskItem] = []
    @State private var selected: LoreTaskItem? = nil
    @State private var search = ""
    @State private var showDone = false
    @State private var viewMode: LoreViewMode = .kanban
    @State private var activeCommand: LoreCommandMode? = nil
    @State private var showNewTask = false
    @State private var showListDeleteConfirm = false
    @State private var newTaskTitle = ""
    @FocusState private var listFocused: Bool
    @State private var ideas: [LoreIdeaItem] = []
    @State private var selectedIdea: LoreIdeaItem? = nil
    @State private var generatingIdeaFile: String? = nil
    @State private var loreInitialized = true
    @State private var graph: LoreLinkIndex.Graph? = nil
    @State private var graphWork: DispatchWorkItem? = nil

    private var filtered: [LoreTaskItem] {
        guard !search.isEmpty else { return tasks }
        return tasks.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func tasksFor(_ col: LoreKanbanColumn) -> [LoreTaskItem] {
        filtered.filter { $0.kanbanColumn == col }
    }

    private var yourTurnTasks: [LoreTaskItem] {
        filtered.filter { $0.kanbanColumn == .speccing || $0.kanbanColumn == .reviewQA }
    }
    private var aiTurnTasks: [LoreTaskItem] {
        filtered.filter { $0.kanbanColumn == .aiWorking }
    }
    private var blockedNeedsTasks: [LoreTaskItem] {
        filtered.filter { $0.kanbanColumn == .blocked }
    }

    private var flatTaskList: [LoreTaskItem] {
        if viewMode == .kanban {
            return LoreKanbanColumn.allCases
                .filter { $0 != .done || showDone }
                .flatMap { tasksFor($0) }
        } else {
            return yourTurnTasks + aiTurnTasks + blockedNeedsTasks
        }
    }

    var body: some View {
        Group {
            if loreInitialized {
                mainBody
            } else {
                LoreInitView(projectPath: projectPath) { refreshLoreState() }
            }
        }
        .onAppear { refreshLoreState() }
        .onChange(of: projectPath) { _, _ in refreshLoreState() }
    }

    private func refreshLoreState() {
        // mainBody's own .onAppear runs reload() when it enters the hierarchy.
        loreInitialized = LoreRunner.isInitialized(projectPath: projectPath)
    }

    private var mainBody: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $viewMode) {
                    Text("Kanban").tag(LoreViewMode.kanban)
                    Text("Needs").tag(LoreViewMode.needs)
                    Text("Ideas").tag(LoreViewMode.ideas)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                .background(Color(NSColor.windowBackgroundColor))
                Divider()

                if viewMode != .ideas {
                    HStack(spacing: DSSpace.sm) {
                        Image(systemName: "plus.circle.fill").foregroundColor(.accentColor)
                        TextField("New task — type a title, press ↩", text: $newTaskTitle)
                            .textFieldStyle(.plain)
                            .onSubmit { quickCreateTask() }
                    }
                    .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                    .background(Color(NSColor.windowBackgroundColor))
                    Divider()
                }

                HStack(spacing: DSSpace.sm) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search tasks…", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                .background(DSColor.cardBg)
                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                            if viewMode == .kanban { kanbanContent }
                            else if viewMode == .needs { needsContent }
                            else { ideasContent }
                            // Linear group tasks — always shown below lore content when bound.
                            if viewMode != .ideas { linearGroupContent }
                        }
                    }
                    .focusable()
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onTapGesture { listFocused = true }
                    .onChange(of: selected?.id) { _, id in
                        if let id { withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onKeyPress { handleKey($0) }
                }
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            .confirmationDialog("Delete this task?", isPresented: $showListDeleteConfirm, titleVisibility: .visible) {
                Button("Delete task", role: .destructive) { if let t = selected { deleteTask(t) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the task file. This can't be undone.")
            }
            .overlay(alignment: .center) {
                if let cmd = activeCommand, selected != nil {
                    LoreCommandPalette(mode: cmd) { value in
                        applyCommand(cmd, value: value)
                        activeCommand = nil
                    } onDismiss: { activeCommand = nil }
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.1), value: activeCommand != nil)

            ZStack {
                if viewMode == .ideas {
                    if let idea = selectedIdea {
                        LoreIdeaDetailPane(idea: idea, isGenerating: generatingIdeaFile == idea.file) {
                            promoteIdea(idea)
                        }
                    } else {
                        VStack(spacing: DSSpace.sm) {
                            Text("Select an idea").font(.caption).foregroundColor(.secondary)
                            Text("P promotes to a task via Claude")
                                .font(DSFont.micro).foregroundColor(.secondary.opacity(0.6))
                        }
                        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let task = selected {
                    LoreTaskDetailPane(
                        task: task,
                        projectPath: projectPath,
                        backlinks: backlinks(for: task),
                        onStatusChange: { setStatus(task, to: $0) },
                        onFieldChange: { setField(task, key: $0, value: $1) },
                        onBodyChange: { setBody(task, body: $0) },
                        onDelete: { deleteTask(task) }
                    )
                    .id(task.file)   // stable per task (id is a fresh UUID each reload); avoids losing focus on autosave
                } else {
                    VStack(spacing: DSSpace.sm) {
                        Text("Select a task").font(.caption).foregroundColor(.secondary)
                        Text("↑↓ navigate  ·  Tab switch view  ·  S status  ·  A owner  ·  P priority  ·  Space done  ·  C new")
                            .font(DSFont.micro).foregroundColor(.secondary.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NebulaBackground())
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showNewTask) {
            NewLoreTaskSheet(projectPath: projectPath) { reload() }
        }
        .onAppear { reload(); reloadIdeas(); listFocused = true }
        .onChange(of: projectPath) { _, _ in reload(); reloadIdeas() }
        .onChange(of: viewMode) { _, newMode in
            if newMode == .ideas {
                reloadIdeas()
            } else {
                if let sel = selected, !flatTaskList.contains(where: { $0.id == sel.id }) {
                    selected = flatTaskList.first
                }
            }
            listFocused = true
        }
    }

    // MARK: - List sections

    @ViewBuilder
    private var kanbanContent: some View {
        ForEach(LoreKanbanColumn.allCases, id: \.self) { col in
            let colTasks = tasksFor(col)
            if col == .done {
                let todayDone = colTasks.filter { $0.completedToday }
                let olderDone = colTasks.filter { !$0.completedToday }
                if !todayDone.isEmpty {
                    Section {
                        ForEach(todayDone) { taskRow($0) }
                    } header: {
                        sectionHeader("Done today", color: DSColor.success, count: todayDone.count)
                            .dropDestination(for: String.self) { files, _ in
                                files.compactMap { findTask($0) }.forEach { applyColumnChange($0, to: col) }
                                return true
                            }
                    }
                }
                Section {
                    if showDone { ForEach(olderDone) { taskRow($0) } }
                } header: {
                    doneHeader(count: olderDone.count)
                        .dropDestination(for: String.self) { files, _ in
                            files.compactMap { findTask($0) }.forEach { applyColumnChange($0, to: col) }
                            return true
                        }
                }
            } else {
                Section {
                    if colTasks.isEmpty {
                        Text("Drop here")
                            .font(DSFont.micro).foregroundColor(.secondary.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 36).padding(.vertical, DSSpace.sm)
                    } else {
                        ForEach(colTasks) { taskRow($0) }
                    }
                } header: {
                    sectionHeader(col.label, color: col.color, count: colTasks.count)
                        .dropDestination(for: String.self) { files, _ in
                            files.compactMap { findTask($0) }.forEach { applyColumnChange($0, to: col) }
                            return true
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var needsContent: some View {
        Section {
            if yourTurnTasks.isEmpty {
                Text("Drop here").font(DSFont.micro).foregroundColor(.secondary.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36).padding(.vertical, DSSpace.sm)
            } else {
                ForEach(yourTurnTasks) { taskRow($0, showColumn: true) }
            }
        } header: {
            sectionHeader("Your turn", color: DSColor.assistant, count: yourTurnTasks.count)
                .dropDestination(for: String.self) { files, _ in
                    files.compactMap { findTask($0) }.forEach { applyColumnChange($0, to: .speccing) }
                    return true
                }
        }

        Section {
            if aiTurnTasks.isEmpty {
                Text("Drop here").font(DSFont.micro).foregroundColor(.secondary.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36).padding(.vertical, DSSpace.sm)
            } else {
                ForEach(aiTurnTasks) { taskRow($0) }
            }
        } header: {
            sectionHeader("AI's turn", color: DSColor.info, count: aiTurnTasks.count)
                .dropDestination(for: String.self) { files, _ in
                    files.compactMap { findTask($0) }.forEach { applyColumnChange($0, to: .aiWorking) }
                    return true
                }
        }

        Section {
            if blockedNeedsTasks.isEmpty {
                Text("Drop here").font(DSFont.micro).foregroundColor(.secondary.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36).padding(.vertical, DSSpace.sm)
            } else {
                ForEach(blockedNeedsTasks) { taskRow($0) }
            }
        } header: {
            sectionHeader("Blocked", color: DSColor.warning, count: blockedNeedsTasks.count)
                .dropDestination(for: String.self) { files, _ in
                    files.compactMap { findTask($0) }.forEach { applyColumnChange($0, to: .blocked) }
                    return true
                }
        }
    }

    // MARK: - Linear group tasks

    /// Renders the group's shared Linear issues below the lore task list.
    /// Only visible when the repo belongs to a group that has a Linear team
    /// bound and has cached issues in store.groupLinearTasks.
    @ViewBuilder
    private var linearGroupContent: some View {
        if let grp = store.group(for: projectPath),
           let linearTasks = store.groupLinearTasks[grp.id],
           !linearTasks.isEmpty {
            let headerLabel = grp.linearTeamName.map { "Linear — \($0)" } ?? "Linear"
            let activeTasks = linearTasks.filter { $0.status != .done && $0.status != .skipped }
            let doneTasks   = linearTasks.filter { $0.status == .done || $0.status == .skipped }

            // Active issues
            Section {
                ForEach(activeTasks) { task in
                    LinearGroupTaskRow(task: task, projectPath: projectPath)
                    Divider().padding(.leading, 36)
                }
                if activeTasks.isEmpty {
                    Text("No open issues")
                        .font(DSFont.micro).foregroundColor(.secondary.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 36).padding(.vertical, DSSpace.sm)
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "rhombus")
                        .font(.system(size: 7))
                        .foregroundColor(DSColor.info)
                    Text(headerLabel)
                        .font(DSFont.sectionHeader).foregroundColor(.secondary)
                    Text(verbatim: "\(activeTasks.count)")
                        .font(DSFont.monoDigits(.caption2)).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
                .background(Color(NSColor.windowBackgroundColor))
            }

            // Done Linear issues (collapsed under the lore done section pattern)
            if !doneTasks.isEmpty {
                Section {
                    ForEach(doneTasks) { task in
                        LinearGroupTaskRow(task: task, projectPath: projectPath)
                        Divider().padding(.leading, 36)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "rhombus")
                            .font(.system(size: 7))
                            .foregroundColor(DSColor.info.opacity(0.5))
                        Text("Linear — done")
                            .font(DSFont.sectionHeader).foregroundColor(.secondary)
                        Text(verbatim: "\(doneTasks.count)")
                            .font(DSFont.monoDigits(.caption2)).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
                    .background(Color(NSColor.windowBackgroundColor))
                }
            }
        }
    }

    // MARK: - Ideas

    @ViewBuilder
    private var ideasContent: some View {
        if ideas.isEmpty {
            VStack(spacing: DSSpace.sm) {
                Text("No ideas yet").font(.caption).foregroundColor(.secondary)
                Text("lore add idea --title \"...\"")
                    .font(DSFont.mono(.caption2))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            ForEach(ideas) { idea in
                Button {
                    selectedIdea = idea
                    listFocused = true
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: DSSpace.xs) {
                            Text(idea.title)
                                .font(DSFont.body)
                                .lineLimit(2).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundColor(idea.status == "promoted" || idea.status == "parked" ? .secondary : .primary)
                                .strikethrough(idea.status == "parked")
                            HStack(spacing: DSSpace.xs) {
                                Text(idea.status).font(DSFont.micro)
                                    .padding(.horizontal, DSSpace.xs).padding(.vertical, 1)
                                    .background(ideaStatusColor(idea.status).opacity(0.14))
                                    .foregroundColor(ideaStatusColor(idea.status))
                                    .clipShape(Capsule())
                                if !idea.category.isEmpty {
                                    Text(idea.category).font(DSFont.micro).foregroundColor(.secondary)
                                }
                            }
                        }
                        if idea.status != "promoted" && idea.status != "parked" {
                            if generatingIdeaFile == idea.file {
                                ProgressView().scaleEffect(0.6).frame(width: 20)
                            } else {
                                Button { promoteIdea(idea) } label: {
                                    Image(systemName: "arrow.up.right.circle")
                                        .foregroundColor(DSColor.info)
                                }
                                .buttonStyle(.plain)
                                .help("Promote to task via Claude")
                                .accessibilityLabel("Promote to task via Claude")
                            }
                        }
                    }
                    .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.small)
                        .fill(selectedIdea?.id == idea.id ? Color.accentColor.opacity(0.13) : Color.clear)
                        .padding(.horizontal, DSSpace.xs)
                )
                Divider().padding(.leading, 36)
            }
        }
    }

    private func ideaStatusColor(_ status: String) -> Color {
        switch status {
        case "promising": return DSColor.success
        case "promoted":  return DSColor.info
        case "parked":    return .secondary
        default:          return DSColor.warning
        }
    }

    private func reloadIdeas() {
        let ideasDir = "\(projectPath)/docs/ideas"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: ideasDir) else { return }
        ideas = files
            .filter { $0.hasSuffix(".md") && $0 != "index.md" && $0 != "INDEX.md" }
            .sorted()
            .compactMap { file -> LoreIdeaItem? in
                let path = "\(ideasDir)/\(file)"
                guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                let fm = parseLoreFM(raw)
                return LoreIdeaItem(
                    file: file, path: path,
                    title: fm["title"] ?? file.replacingOccurrences(of: ".md", with: ""),
                    status: fm["status"] ?? "raw",
                    category: fm["category"] ?? "",
                    body: loreMDBody(raw)
                )
            }
    }

    private func promoteIdea(_ idea: LoreIdeaItem) {
        guard generatingIdeaFile == nil else { return }
        generatingIdeaFile = idea.file
        Task {
            let taskPrompt = LoreRunner.schemaPrompt(type: "task", projectPath: projectPath) ?? ""
            let userMsg = "Title: \(idea.title)\n\nContext from idea:\n\(idea.body)"
            guard let body = await LoreRunner.generate(systemPrompt: taskPrompt, userMessage: userMsg, projectPath: projectPath) else {
                await MainActor.run { generatingIdeaFile = nil }
                return
            }
            let taskDir = "\(projectPath)/docs/tasks"
            let nextId = LoreRunner.nextId(in: taskDir)
            let slug = LoreRunner.slug(from: idea.title)
            let filename = "\(nextId)-\(slug).md"
            let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            let escapedTitle = idea.title.replacingOccurrences(of: "\"", with: "\\\"")
            let cat = idea.category.isEmpty ? "other" : idea.category
            let content = "---\ntitle: \"\(escapedTitle)\"\nstatus: open\nowner: human\ncategory: \(cat)\ncreated: \"\(today)\"\n---\n\n# \(idea.title)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            try? content.write(toFile: "\(taskDir)/\(filename)", atomically: true, encoding: .utf8)
            rewriteIdeaFrontmatter(idea, status: "promoted", promotedTo: filename)
            await MainActor.run {
                generatingIdeaFile = nil
                reloadIdeas()
                reload()
            }
        }
    }

    private func rewriteIdeaFrontmatter(_ idea: LoreIdeaItem, status: String, promotedTo: String) {
        guard let raw = try? String(contentsOfFile: idea.path, encoding: .utf8) else { return }
        var lines = raw.components(separatedBy: "\n")
        var hasPromotedTo = false
        lines = lines.map { l in
            if l.hasPrefix("status:") { return "status: \(status)" }
            if l.hasPrefix("promoted_to:") { hasPromotedTo = true; return "promoted_to: \(promotedTo)" }
            return l
        }
        if !hasPromotedTo {
            var fences = 0
            for i in 0..<lines.count {
                if lines[i].hasPrefix("---") { fences += 1; if fences == 2 { lines.insert("promoted_to: \(promotedTo)", at: i); break } }
            }
        }
        try? lines.joined(separator: "\n").write(toFile: idea.path, atomically: true, encoding: .utf8)
    }

    @ViewBuilder
    private func taskRow(_ task: LoreTaskItem, showColumn: Bool = false) -> some View {
        LoreTaskRow(task: task, selectedId: Binding(get: { selected?.id }, set: { _ in }), showColumn: showColumn) {
            selected = task
            listFocused = true
        } onToggle: {
            setStatus(task, to: task.status == "done" ? "open" : "done")
        }
        .id(task.id)
        .draggable(task.file)
        .contextMenu { taskContextMenu(task) }
        Divider().padding(.leading, 36)
    }

    @ViewBuilder
    private func taskContextMenu(_ task: LoreTaskItem) -> some View {
        Button {
            setStatus(task, to: task.status == "done" ? "open" : "done")
        } label: {
            Label(task.status == "done" ? "Mark Open" : "Mark Done",
                  systemImage: task.status == "done" ? "circle" : "checkmark.circle.fill")
        }
        Divider()
        Section("Claude") {
            Button {
                if let nid = numericId(from: task.file) {
                    store.launchClaudeForTask(taskId: nid, projectPath: projectPath)
                    reload()
                }
            } label: {
                Label("Launch with Claude", systemImage: "play.circle")
            }
            Button {
                if let nid = numericId(from: task.file) {
                    Task { await store.runForTask(taskId: nid, projectPath: projectPath, allowEdits: true); reload() }
                }
            } label: {
                Label("Run (allow edits)", systemImage: "wand.and.stars")
            }
        }
        Divider()
        Button(role: .destructive) {
            deleteTask(task)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func sectionHeader(_ label: String, color: Color, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(DSFont.sectionHeader).foregroundColor(.secondary)
            Text(verbatim: "\(count)").font(DSFont.monoDigits(.caption2)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func doneHeader(count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showDone.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showDone ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Circle().fill(LoreKanbanColumn.done.color).frame(width: 7, height: 7)
                Text("Done").font(DSFont.sectionHeader).foregroundColor(.secondary)
                Text(verbatim: "\(count)").font(DSFont.monoDigits(.caption2)).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if let cmd = activeCommand {
            if let char = press.characters.first, let n = char.wholeNumberValue, n >= 1 {
                let opts = commandOptions(for: cmd)
                if n - 1 < opts.count { applyCommand(cmd, value: opts[n - 1]); activeCommand = nil; return .handled }
            }
            if press.key == .escape { activeCommand = nil; return .handled }
            return .ignored
        }

        let key = press.key
        let ch  = press.characters

        if key == .tab { viewMode = viewMode == .kanban ? .needs : .kanban; return .handled }
        if key == .downArrow || ch == "j" { moveSelection(by: +1); return .handled }
        if key == .upArrow   || ch == "k" { moveSelection(by: -1); return .handled }
        if ch == " " { guard selected != nil else { return .ignored }; toggleDone(); return .handled }
        if ch == "s" { guard selected != nil else { return .ignored }; activeCommand = .status;   return .handled }
        if ch == "a" { guard selected != nil else { return .ignored }; activeCommand = .owner;    return .handled }
        if ch == "p" { guard selected != nil else { return .ignored }; activeCommand = .priority; return .handled }
        if ch == "c" { showNewTask = true; return .handled }
        if key == .delete { guard selected != nil else { return .ignored }; showListDeleteConfirm = true; return .handled }
        return .ignored
    }

    private func moveSelection(by delta: Int) {
        let flat = flatTaskList
        guard !flat.isEmpty else { return }
        if let sel = selected, let idx = flat.firstIndex(where: { $0.id == sel.id }) {
            selected = flat[max(0, min(flat.count - 1, idx + delta))]
        } else {
            selected = flat.first
        }
    }

    private func toggleDone() {
        guard let task = selected else { return }
        setStatus(task, to: task.status == "done" ? "open" : "done")
    }

    private func commandOptions(for mode: LoreCommandMode) -> [String] {
        switch mode {
        case .status:   return ["open", "in_progress", "blocked", "done", "skipped"]
        case .owner:    return ["none", "human", "ai"]
        case .priority: return ["high", "medium", "low", ""]
        }
    }

    private func applyCommand(_ mode: LoreCommandMode, value: String) {
        guard let task = selected else { return }
        switch mode {
        case .status:             setStatus(task, to: value)
        case .owner, .priority:   setField(task, key: mode == .owner ? "owner" : "priority", value: value)
        }
    }

    // MARK: - Drag & drop

    private func findTask(_ file: String) -> LoreTaskItem? {
        tasks.first { $0.file == file }
    }

    private func applyColumnChange(_ task: LoreTaskItem, to col: LoreKanbanColumn) {
        guard let raw = try? String(contentsOfFile: task.path, encoding: .utf8) else { return }

        var newStatus = task.status
        var newOwner  = task.owner
        var newAiRun  = task.aiRun

        switch col {
        case .backlog:   newStatus = "open";    newOwner = "none";  newAiRun = false
        case .speccing:  newStatus = "open";    newOwner = "human"; newAiRun = false
        case .aiWorking: newStatus = "open";    newOwner = "ai"
        case .blocked:   newStatus = "blocked"
        case .reviewQA:  newStatus = "open";    newOwner = "human"; newAiRun = true
        case .done:      newStatus = "done"
        }

        var lines = raw.components(separatedBy: "\n")
        var foundOwner = false, foundAiRun = false
        lines = lines.map { line -> String in
            if line.hasPrefix("status:") { return "status: \(newStatus)" }
            if line.hasPrefix("owner:")  { foundOwner  = true; return "owner: \(newOwner)" }
            if line.hasPrefix("ai_run:") { foundAiRun  = true; return "ai_run: \(newAiRun)" }
            return line
        }
        if !foundOwner || !foundAiRun {
            var fences = 0
            for (i, line) in lines.enumerated() {
                if line.hasPrefix("---") { fences += 1; if fences == 2 {
                    if !foundAiRun { lines.insert("ai_run: \(newAiRun)", at: i) }
                    if !foundOwner { lines.insert("owner: \(newOwner)", at: i) }
                    break
                }}
            }
        }

        var result = lines.joined(separator: "\n")
        if newStatus != task.status {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let entry = "- \(df.string(from: Date())) \(task.status) → \(newStatus)"
            let header = "\n## Status history\n"
            result = result.contains(header)
                ? result.trimmingCharacters(in: .newlines) + "\n" + entry + "\n"
                : result.trimmingCharacters(in: .newlines) + header + entry + "\n"
        }

        try? result.write(toFile: task.path, atomically: true, encoding: .utf8)
        updateInPlace(file: task.file)
    }

    // MARK: - Data

    /// Inline quick-add: write a minimal task doc, reload, and select it so you drop
    /// straight into editing its body. Mirrors how reload() reads files directly, so
    /// no reindex is needed for it to appear.
    private func quickCreateTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let dir = "\(projectPath)/docs/tasks"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = LoreRunner.nextId(in: dir)
        let slug = LoreRunner.slug(from: title)
        let file = "\(id)-\(slug).md"
        let content = """
        ---
        title: "\(title.replacingOccurrences(of: "\"", with: "'"))"
        status: open
        owner: human
        category: engineering
        ---

        """
        guard (try? content.write(toFile: "\(dir)/\(file)", atomically: true, encoding: .utf8)) != nil else { return }
        newTaskTitle = ""
        reload()
        selected = tasks.first { $0.file == file }
    }

    /// Full reload — re-reads every task file. Use only for structural changes
    /// (appear, project switch, create/delete). The graph rebuild is deferred
    /// off-main; per-edit saves use `updateInPlace` instead.
    func reload() {
        let dir = "\(projectPath)/docs/tasks"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let loaded = files
            .filter { $0.hasSuffix(".md") && $0 != "index.md" && $0 != "INDEX.md" }
            .sorted()
            .compactMap { loadTask(file: $0) }
        tasks = loaded
        if let sel = selected { selected = tasks.first { $0.file == sel.file } }
        scheduleGraphRefresh()
    }

    /// Re-read a single task file and swap it into `tasks`/`selected` in place,
    /// preserving its list identity. Cheap — no directory scan, no synchronous
    /// graph rebuild. This is what edit-saves call so typing stays smooth.
    private func updateInPlace(file: String) {
        let reuseId = tasks.first { $0.file == file }?.id
        guard let item = loadTask(file: file, reusingId: reuseId) else { return }
        if let idx = tasks.firstIndex(where: { $0.file == file }) { tasks[idx] = item }
        else { tasks.append(item) }
        if selected?.file == file { selected = item }
        scheduleGraphRefresh()
    }

    private func loadTask(file: String, reusingId: UUID? = nil) -> LoreTaskItem? {
        let path = "\(projectPath)/docs/tasks/\(file)"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let todayStr = df.string(from: Date())
        let fm = parseLoreFM(raw)
        let body = loreMDBody(raw)
        let completedToday = body.range(
            of: "- \(todayStr)T[^\\n]*→ done", options: .regularExpression
        ) != nil
        return LoreTaskItem(
            id: reusingId ?? UUID(),
            file: file,
            path: path,
            title: fm["title"] ?? file.replacingOccurrences(of: ".md", with: ""),
            status: fm["status"] ?? "open",
            owner: fm["owner"] ?? "none",
            aiRun: fm["ai_run"] == "true",
            category: fm["category"] ?? fm["type"] ?? "",
            priority: fm["priority"] ?? "",
            effort: fm["effort"] ?? "",
            notes: fm["notes"] ?? "",
            completed: fm["completed"] ?? "",
            body: body,
            completedToday: completedToday
        )
    }

    /// Rebuild the backlink graph off the main thread, coalesced — it walks every
    /// doc in every lore dir twice, far too heavy to run synchronously on each save.
    private func scheduleGraphRefresh() {
        graphWork?.cancel()
        let p = projectPath
        let item = DispatchWorkItem {
            let g = LoreLinkIndex.build(projectPath: p, dirs: LoreLinkIndex.allDirs)
            DispatchQueue.main.async { graph = g }
        }
        graphWork = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Backlinks pointing at a task ([[wikilinks]] + `parent:` references).
    private func backlinks(for task: LoreTaskItem) -> [LoreLinkIndex.Backlink] {
        graph?.backlinks["tasks/\(task.file)"] ?? []
    }

    private func deleteTask(_ task: LoreTaskItem) {
        try? FileManager.default.removeItem(atPath: task.path)
        if selected?.file == task.file { selected = nil }
        reload()
    }

    /// Derive the numeric lore id (leading digits) from a task filename like "0042-slug.md".
    private func numericId(from file: String) -> String? {
        let digits = file.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : String(digits)
    }

    private func setStatus(_ task: LoreTaskItem, to newStatus: String) {
        guard newStatus != task.status else { return }

        // Route through TaskStore (sentinel-delimited history format) when the
        // status maps to a known TaskStatus case. Fall back to direct file write
        // for any unknown value so nothing is silently dropped.
        if let nid = numericId(from: task.file),
           store.setTaskStatusByLoreId(projectPath: projectPath, taskId: nid, loreStatus: newStatus) {
            updateInPlace(file: task.file)
            return
        }

        // Fallback: direct file write for unrecognised status values.
        guard let raw = try? String(contentsOfFile: task.path, encoding: .utf8) else { return }
        let statusUpdated = raw.components(separatedBy: "\n").map { line in
            line.hasPrefix("status:") ? "status: \(newStatus)" : line
        }.joined(separator: "\n")
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let entry = "- \(df.string(from: Date())) \(task.status) → \(newStatus)"
        let historyHeader = "\n## Status history\n"
        let withHistory: String
        if statusUpdated.contains(historyHeader) {
            withHistory = statusUpdated.trimmingCharacters(in: .newlines) + "\n" + entry + "\n"
        } else {
            withHistory = statusUpdated.trimmingCharacters(in: .newlines) + historyHeader + entry + "\n"
        }
        try? withHistory.write(toFile: task.path, atomically: true, encoding: .utf8)
        updateInPlace(file: task.file)
    }

    private func setField(_ task: LoreTaskItem, key: String, value: String) {
        // Route owner mutations through TaskStore for consistency.
        if key == "owner",
           let nid = numericId(from: task.file),
           store.setTaskOwnerByLoreId(projectPath: projectPath, taskId: nid, loreOwner: value) {
            updateInPlace(file: task.file)
            return
        }

        guard let raw = try? String(contentsOfFile: task.path, encoding: .utf8) else { return }
        var lines = raw.components(separatedBy: "\n")
        var found = false
        lines = lines.map { line -> String in
            if line.hasPrefix("\(key):") { found = true; return "\(key): \(value)" }
            return line
        }
        if !found {
            var fences = 0
            for (i, line) in lines.enumerated() {
                if line.hasPrefix("---") { fences += 1; if fences == 2 { lines.insert("\(key): \(value)", at: i); break } }
            }
        }
        try? lines.joined(separator: "\n").write(toFile: task.path, atomically: true, encoding: .utf8)
        updateInPlace(file: task.file)
    }

    /// Replace the markdown body (everything after the frontmatter), preserving
    /// the `--- … ---` frontmatter block, then reload.
    private func setBody(_ task: LoreTaskItem, body: String) {
        guard let raw = try? String(contentsOfFile: task.path, encoding: .utf8) else { return }
        let lines = raw.components(separatedBy: "\n")
        var fences = 0, closeIdx = -1
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "---" {
            fences += 1
            if fences == 2 { closeIdx = i; break }
        }
        let header = closeIdx >= 0 ? lines[0...closeIdx].joined(separator: "\n") : ""
        let newBody = body.hasSuffix("\n") ? body : body + "\n"
        let content = header.isEmpty ? newBody : header + "\n" + newBody
        try? content.write(toFile: task.path, atomically: true, encoding: .utf8)
        updateInPlace(file: task.file)
    }
}

// MARK: - Command Palette

private struct LoreCommandPalette: View {
    let mode: LoreCommandMode
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(DSFont.sectionHeader).foregroundColor(.secondary)
                .padding(.horizontal, DSSpace.md).padding(.top, DSSpace.sm).padding(.bottom, DSSpace.xs)
            Divider()
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                Button { onSelect(opt) } label: {
                    HStack(spacing: 10) {
                        Text("\(i + 1)")
                            .font(DSFont.monoDigits(.caption))
                            .foregroundColor(.secondary)
                            .frame(width: 14, alignment: .center)
                        Text(opt.isEmpty ? "—" : opt.replacingOccurrences(of: "_", with: " "))
                            .font(DSFont.body)
                        Spacer()
                    }
                    .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            Text("Esc — dismiss")
                .font(DSFont.micro).foregroundColor(.secondary.opacity(0.6))
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
        }
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private var title: String {
        switch mode {
        case .status:   return "Set status  (S)"
        case .owner:    return "Set owner  (A)"
        case .priority: return "Set priority  (P)"
        }
    }

    private var options: [String] {
        switch mode {
        case .status:   return ["open", "in_progress", "blocked", "done", "skipped"]
        case .owner:    return ["none", "human", "ai"]
        case .priority: return ["high", "medium", "low", ""]
        }
    }
}

// MARK: - Row

private struct LoreTaskRow: View {
    let task: LoreTaskItem
    @Binding var selectedId: UUID?
    let showColumn: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    private var isSelected: Bool { selectedId == task.id }

    init(task: LoreTaskItem, selectedId: Binding<UUID?>, showColumn: Bool = false,
         onSelect: @escaping () -> Void, onToggle: @escaping () -> Void) {
        self.task = task; self._selectedId = selectedId; self.showColumn = showColumn
        self.onSelect = onSelect; self.onToggle = onToggle
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Button(action: onToggle) {
                    Image(systemName: task.status == "done" ? "checkmark.circle.fill" : statusIcon)
                        .foregroundColor(task.status == "done" ? DSColor.success : statusColor)
                        .font(DSFont.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.status == "done" ? "Mark task open" : "Mark task done")

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(DSFont.body)
                        .strikethrough(task.status == "done" || task.status == "skipped")
                        .foregroundColor(task.status == "done" || task.status == "skipped" ? .secondary : .primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: DSSpace.xs) {
                        if showColumn {
                            let col = task.kanbanColumn
                            Text(col.label).font(DSFont.micro)
                                .padding(.horizontal, DSSpace.xs).padding(.vertical, 1)
                                .background(col.color.opacity(0.14)).foregroundColor(col.color)
                                .clipShape(Capsule())
                        } else if !task.category.isEmpty {
                            categoryChip(task.category)
                        }
                        if !task.priority.isEmpty {
                            Text(task.priority).font(DSFont.micro).foregroundColor(priorityColor)
                        }
                        if !task.effort.isEmpty {
                            Text("·").foregroundColor(.secondary).font(DSFont.micro)
                            Text(task.effort).font(DSFont.micro).foregroundColor(.secondary)
                        }
                        if task.owner != "none" && !task.owner.isEmpty {
                            Text("·").foregroundColor(.secondary).font(DSFont.micro)
                            Text(task.owner).font(DSFont.micro)
                                .foregroundColor(task.owner == "ai" ? DSColor.info : .secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .workingShimmer(active: task.kanbanColumn == .aiWorking)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.small)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear)
                .padding(.horizontal, DSSpace.xs)
        )
    }

    private var statusIcon: String {
        switch task.status {
        case "blocked":     return "exclamationmark.circle"
        case "in_progress": return "circle.dotted"
        default:            return "circle"
        }
    }
    private var statusColor: Color {
        switch task.status {
        case "blocked":     return DSColor.warning
        case "in_progress": return DSColor.info
        default:            return .secondary
        }
    }
    private var priorityColor: Color {
        switch task.priority {
        case "high":   return DSColor.danger.opacity(0.85)
        case "medium": return DSColor.warning.opacity(0.85)
        default:       return .secondary
        }
    }
    private func categoryChip(_ cat: String) -> some View {
        Text(cat).font(DSFont.micro)
            .padding(.horizontal, DSSpace.xs).padding(.vertical, 1)
            .background(categoryColor(cat).opacity(0.14)).foregroundColor(categoryColor(cat))
            .clipShape(Capsule())
    }
    private func categoryColor(_ cat: String) -> Color {
        switch cat {
        case "engineering":  return DSColor.info
        case "design":       return .pink
        case "qa":           return DSColor.danger
        case "ops":          return .gray
        case "distribution": return DSColor.gitMeta
        case "content":      return DSColor.assistant
        case "marketing":    return DSColor.warning
        case "research":     return .indigo
        default:             return .secondary
        }
    }
}

// MARK: - Linear group task row

/// Read-only-ish row for a group's Linear TaskItem shown inside LoreTasksView.
/// Status changes route through store.setTaskStatus (group-aware push-back path).
private struct LinearGroupTaskRow: View {
    let task: TaskItem
    let projectPath: String
    @EnvironmentObject private var store: DashboardStore

    var body: some View {
        HStack(spacing: 10) {
            // Status toggle button (done ↔ open)
            Button {
                let next: TaskStatus = (task.status == .done || task.status == .skipped) ? .open : .done
                store.setTaskStatus(projectPath: projectPath, id: task.id, status: next)
            } label: {
                Image(systemName: task.status == .done || task.status == .skipped
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(task.status == .done || task.status == .skipped
                        ? DSColor.success : .secondary)
                    .font(DSFont.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.status == .done ? "Mark open" : "Mark done")

            VStack(alignment: .leading, spacing: 2) {
                // Linear identifier badge — tapping opens the issue in browser.
                if let identifier = task.linearIdentifier, let urlStr = task.linearURL,
                   let url = URL(string: urlStr) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "rhombus").font(.system(size: 8))
                            Text(identifier).font(DSFont.monoDigits(.caption2))
                        }
                        .foregroundStyle(DSColor.info)
                    }
                    .buttonStyle(.plain)
                }
                Text(task.title)
                    .font(DSFont.body)
                    .strikethrough(task.status == .done || task.status == .skipped)
                    .foregroundColor(task.status == .done || task.status == .skipped ? .secondary : .primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(DSFont.micro).foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail Pane

private struct LoreTaskDetailPane: View {
    let task: LoreTaskItem
    let projectPath: String
    var backlinks: [LoreLinkIndex.Backlink] = []
    let onStatusChange: (String) -> Void
    let onFieldChange: (String, String) -> Void
    var onBodyChange: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}

    @State private var showDeleteConfirm = false
    @State private var nodes: [DayNode] = []
    @State private var loadedBody = ""
    @State private var saveWork: DispatchWorkItem? = nil
    @State private var titleDraft = ""
    @State private var titleSaveWork: DispatchWorkItem? = nil

    private let statuses   = ["open", "in_progress", "blocked", "done", "skipped"]
    private let owners     = ["none", "human", "ai"]
    private let categories = ["engineering", "design", "qa", "ops", "distribution", "content", "marketing", "research", "other"]
    private let priorities = ["", "high", "medium", "low"]
    private let efforts    = ["", "quick", "small", "medium", "large"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                TextField("Task title", text: $titleDraft, axis: .vertical)
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .onChange(of: titleDraft) { _, _ in scheduleTitleSave() }

                HStack(spacing: DSSpace.lg) {
                    field("Status") {
                        Picker("", selection: Binding(get: { task.status }, set: { onStatusChange($0) })) {
                            ForEach(statuses, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    field("Owner") {
                        Picker("", selection: Binding(get: { task.owner }, set: { onFieldChange("owner", $0) })) {
                            ForEach(owners, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    field("AI run") {
                        Toggle("", isOn: Binding(
                            get: { task.aiRun },
                            set: { onFieldChange("ai_run", $0 ? "true" : "false") }
                        ))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    field("Category") {
                        Picker("", selection: Binding(get: { task.category }, set: { onFieldChange("category", $0) })) {
                            ForEach(categories, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    field("Priority") {
                        Picker("", selection: Binding(get: { task.priority }, set: { onFieldChange("priority", $0) })) {
                            ForEach(priorities, id: \.self) { Text($0.isEmpty ? "—" : $0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    field("Effort") {
                        Picker("", selection: Binding(get: { task.effort }, set: { onFieldChange("effort", $0) })) {
                            ForEach(efforts, id: \.self) { Text($0.isEmpty ? "—" : $0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Spacer()
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash").foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete task")
                    .confirmationDialog("Delete this task?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button("Delete task", role: .destructive) { onDelete() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes the task file. This can't be undone.")
                    }
                }

                if !task.notes.isEmpty {
                    Text(task.notes).font(DSFont.label).foregroundColor(.secondary).lineLimit(2)
                }
                if !task.completed.isEmpty {
                    Text("Completed \(task.completed)").font(DSFont.micro).foregroundColor(.secondary)
                }
                if !backlinks.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("↩ \(backlinks.count) LINKED REFERENCE\(backlinks.count == 1 ? "" : "S")")
                            .font(DSFont.micro).foregroundColor(.secondary).tracking(0.5)
                        ForEach(backlinks, id: \.fromPath) { bl in
                            HStack(spacing: 5) {
                                Text(bl.fromTitle).font(DSFont.label)
                                Text(bl.fromType).font(DSFont.micro).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, DSSpace.md)

            HStack {
                Text("CONTENT").font(DSFont.micro).foregroundColor(.secondary).tracking(1)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            Divider()

            ScrollView {
                OutlinerView(nodes: $nodes, projectPath: projectPath, autofocus: true)
                    .padding(DSSpace.md)
            }
            .onChange(of: nodes) { _, _ in scheduleBodySave() }
        }
        .onAppear { loadBody() }
    }

    private func loadBody() {
        var parsed = Self.parseBody(task.body)
        if parsed.isEmpty { parsed = [DayNode(text: "")] }   // ready to type immediately
        nodes = parsed
        loadedBody = DayOutline.serialize(parsed)             // baseline — opening must not write
        titleDraft = task.title
    }

    private func scheduleTitleSave() {
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != task.title else { return }
        titleSaveWork?.cancel()
        let item = DispatchWorkItem {
            onFieldChange("title", "\"\(t.replacingOccurrences(of: "\"", with: "'"))\"")
        }
        titleSaveWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func scheduleBodySave() {
        let body = DayOutline.serialize(nodes)
        guard body != loadedBody else { return }   // ignore the change from load/autofocus
        loadedBody = body
        saveWork?.cancel()
        let item = DispatchWorkItem { onBodyChange(body) }
        saveWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// Everything is bullets: bulletize any non-list body line so a task's content
    /// edits as an outline and round-trips.
    private static func parseBody(_ body: String) -> [DayNode] {
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let leading = line.prefix { $0 == " " }
            let rest = line.drop { $0 == " " }
            if rest.hasPrefix("- ") || rest == "-" { lines.append(line) }
            else { lines.append("\(leading)- \(rest)") }
        }
        return DayOutline.parse(lines.joined(separator: "\n"))
    }

    @ViewBuilder
    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(DSFont.micro).foregroundColor(.secondary)
            content()
        }
    }
}

// MARK: - Helpers

// MARK: - Idea Detail Pane

private struct LoreIdeaDetailPane: View {
    let idea: LoreIdeaItem
    let isGenerating: Bool
    let onPromote: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    Text(idea.title).font(.headline)
                    HStack(spacing: DSSpace.sm) {
                        Text(idea.status)
                            .font(DSFont.micro)
                            .padding(.horizontal, DSSpace.xs).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                        if !idea.category.isEmpty {
                            Text(idea.category).font(DSFont.micro).foregroundColor(.secondary)
                        }
                    }
                }
                Divider()
                if !idea.body.isEmpty {
                    Text(idea.body)
                        .font(DSFont.label)
                        .foregroundColor(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if idea.status != "promoted" && idea.status != "parked" {
                    Divider()
                    Button {
                        onPromote()
                    } label: {
                        if isGenerating {
                            HStack(spacing: DSSpace.xs) {
                                ProgressView().scaleEffect(0.7)
                                Text("Generating task…").font(DSFont.label)
                            }
                        } else {
                            Label("Promote to task", systemImage: "arrow.up.right.circle.fill")
                                .font(DSFont.label)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isGenerating)
                }
            }
            .padding(DSSpace.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private func parseLoreFM(_ raw: String) -> [String: String] {
    var result: [String: String] = [:]
    guard raw.hasPrefix("---") else { return result }
    let lines = raw.components(separatedBy: "\n")
    var fences = 0; var i = 0
    while i < lines.count {
        let line = lines[i]; i += 1
        if line.hasPrefix("---") { fences += 1; if fences == 2 { break }; continue }
        guard fences == 1, let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if value == ">-" || value == ">" || value == "|-" || value == "|" {
            // YAML block scalar — collect indented continuation lines
            let fold = value.hasPrefix(">")
            var parts: [String] = []
            while i < lines.count {
                let next = lines[i]
                if next.hasPrefix("---") { break }
                if next.hasPrefix(" ") || next.hasPrefix("\t") {
                    parts.append(next.trimmingCharacters(in: .whitespaces)); i += 1
                } else if next.isEmpty { i += 1 } else { break }
            }
            value = fold ? parts.joined(separator: " ") : parts.joined(separator: "\n")
        } else if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        if !key.isEmpty { result[key] = value }
    }
    return result
}

private func loreMDBody(_ raw: String) -> String {
    guard raw.hasPrefix("---") else { return raw }
    let lines = raw.components(separatedBy: "\n")
    var fences = 0; var start = 0
    for (i, line) in lines.enumerated() {
        if line.hasPrefix("---") { fences += 1; if fences == 2 { start = i + 1; break } }
    }
    return lines.dropFirst(start).joined(separator: "\n").trimmingCharacters(in: .newlines)
}
