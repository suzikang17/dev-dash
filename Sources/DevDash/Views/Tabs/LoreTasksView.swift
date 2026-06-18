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
        case .speccing:  return .green
        case .aiWorking: return .blue
        case .blocked:   return .orange
        case .reviewQA:  return .purple
        case .done:      return .green.opacity(0.6)
        }
    }
}

enum LoreViewMode: String { case kanban, needs }
enum LoreCommandMode { case status, owner, priority }

// MARK: - Main View

struct LoreTasksView: View {
    let projectPath: String

    @State private var tasks: [LoreTaskItem] = []
    @State private var selected: LoreTaskItem? = nil
    @State private var search = ""
    @State private var showDone = false
    @State private var viewMode: LoreViewMode = .kanban
    @State private var activeCommand: LoreCommandMode? = nil
    @State private var showNewTask = false
    @FocusState private var listFocused: Bool

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
        HSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $viewMode) {
                    Text("Kanban").tag(LoreViewMode.kanban)
                    Text("Needs").tag(LoreViewMode.needs)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(NSColor.windowBackgroundColor))
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search tasks…", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                            if viewMode == .kanban { kanbanContent }
                            else { needsContent }
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
                if let task = selected {
                    LoreTaskDetailPane(
                        task: task,
                        onStatusChange: { setStatus(task, to: $0) },
                        onFieldChange: { setField(task, key: $0, value: $1) }
                    )
                } else {
                    VStack(spacing: 8) {
                        Text("Select a task").font(.caption).foregroundColor(.secondary)
                        Text("↑↓ navigate  ·  Tab switch view  ·  S status  ·  A owner  ·  P priority  ·  Space done  ·  C new")
                            .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showNewTask) {
            NewLoreTaskSheet(projectPath: projectPath) { reload() }
        }
        .onAppear { reload(); listFocused = true }
        .onChange(of: projectPath) { _, _ in reload() }
        .onChange(of: viewMode) { _, _ in
            if let sel = selected, !flatTaskList.contains(where: { $0.id == sel.id }) {
                selected = flatTaskList.first
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
                        sectionHeader("Done today", color: .green, count: todayDone.count)
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
                            .font(.system(size: 11)).foregroundColor(.secondary.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 36).padding(.vertical, 8)
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
                Text("Drop here").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36).padding(.vertical, 8)
            } else {
                ForEach(yourTurnTasks) { taskRow($0, showColumn: true) }
            }
        } header: {
            sectionHeader("Your turn", color: .purple, count: yourTurnTasks.count)
                .dropDestination(for: String.self) { files, _ in
                    files.compactMap { findTask($0) }.forEach { applyColumnChange($0, to: .speccing) }
                    return true
                }
        }

        Section {
            if aiTurnTasks.isEmpty {
                Text("Drop here").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36).padding(.vertical, 8)
            } else {
                ForEach(aiTurnTasks) { taskRow($0) }
            }
        } header: {
            sectionHeader("AI's turn", color: .blue, count: aiTurnTasks.count)
                .dropDestination(for: String.self) { files, _ in
                    files.compactMap { findTask($0) }.forEach { applyColumnChange($0, to: .aiWorking) }
                    return true
                }
        }

        Section {
            if blockedNeedsTasks.isEmpty {
                Text("Drop here").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36).padding(.vertical, 8)
            } else {
                ForEach(blockedNeedsTasks) { taskRow($0) }
            }
        } header: {
            sectionHeader("Blocked", color: .orange, count: blockedNeedsTasks.count)
                .dropDestination(for: String.self) { files, _ in
                    files.compactMap { findTask($0) }.forEach { applyColumnChange($0, to: .blocked) }
                    return true
                }
        }
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
        Divider().padding(.leading, 36)
    }

    private func sectionHeader(_ label: String, color: Color, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Text(verbatim: "\(count)").font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
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
                Text("Done").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Text(verbatim: "\(count)").font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
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
        reload()
    }

    // MARK: - Data

    func reload() {
        let dir = "\(projectPath)/docs/tasks"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let todayStr = df.string(from: Date())
        let loaded = files
            .filter { $0.hasSuffix(".md") && $0 != "index.md" && $0 != "INDEX.md" }
            .sorted()
            .compactMap { file -> LoreTaskItem? in
                let path = "\(dir)/\(file)"
                guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                let fm = parseLoreFM(raw)
                let body = loreMDBody(raw)
                let completedToday = body.range(
                    of: "- \(todayStr)T[^\\n]*→ done", options: .regularExpression
                ) != nil
                return LoreTaskItem(
                    id: UUID(),
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
        tasks = loaded
        if let sel = selected { selected = tasks.first { $0.file == sel.file } }
    }

    private func setStatus(_ task: LoreTaskItem, to newStatus: String) {
        guard newStatus != task.status else { return }
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
        reload()
    }

    private func setField(_ task: LoreTaskItem, key: String, value: String) {
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
        reload()
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
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider()
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                Button { onSelect(opt) } label: {
                    HStack(spacing: 10) {
                        Text("\(i + 1)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 14, alignment: .center)
                        Text(opt.isEmpty ? "—" : opt.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            Text("Esc — dismiss")
                .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.6))
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
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
                        .foregroundColor(task.status == "done" ? .green : statusColor)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 13))
                        .strikethrough(task.status == "done" || task.status == "skipped")
                        .foregroundColor(task.status == "done" || task.status == "skipped" ? .secondary : .primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        if showColumn {
                            let col = task.kanbanColumn
                            Text(col.label).font(.system(size: 10))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(col.color.opacity(0.14)).foregroundColor(col.color)
                                .clipShape(Capsule())
                        } else if !task.category.isEmpty {
                            categoryChip(task.category)
                        }
                        if !task.priority.isEmpty {
                            Text(task.priority).font(.system(size: 10)).foregroundColor(priorityColor)
                        }
                        if !task.effort.isEmpty {
                            Text("·").foregroundColor(.secondary).font(.system(size: 10))
                            Text(task.effort).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        if task.owner != "none" && !task.owner.isEmpty {
                            Text("·").foregroundColor(.secondary).font(.system(size: 10))
                            Text(task.owner).font(.system(size: 10))
                                .foregroundColor(task.owner == "ai" ? .blue : .secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear)
                .padding(.horizontal, 4)
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
        case "blocked":     return .orange
        case "in_progress": return .blue
        default:            return .secondary
        }
    }
    private var priorityColor: Color {
        switch task.priority {
        case "high":   return .red.opacity(0.85)
        case "medium": return .orange.opacity(0.85)
        default:       return .secondary
        }
    }
    private func categoryChip(_ cat: String) -> some View {
        Text(cat).font(.system(size: 10))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(categoryColor(cat).opacity(0.14)).foregroundColor(categoryColor(cat))
            .clipShape(Capsule())
    }
    private func categoryColor(_ cat: String) -> Color {
        switch cat {
        case "engineering":  return .blue
        case "design":       return .pink
        case "qa":           return .red
        case "ops":          return .gray
        case "distribution": return .teal
        case "content":      return .purple
        case "marketing":    return .orange
        case "research":     return .indigo
        default:             return .secondary
        }
    }
}

// MARK: - Detail Pane

private struct LoreTaskDetailPane: View {
    let task: LoreTaskItem
    let onStatusChange: (String) -> Void
    let onFieldChange: (String, String) -> Void

    private let statuses   = ["open", "in_progress", "blocked", "done", "skipped"]
    private let owners     = ["none", "human", "ai"]
    private let categories = ["engineering", "design", "qa", "ops", "distribution", "content", "marketing", "research", "other"]
    private let priorities = ["", "high", "medium", "low"]
    private let efforts    = ["", "quick", "small", "medium", "large"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(task.title).font(.headline).lineLimit(3)

                HStack(spacing: 16) {
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
                    Spacer()
                }

                HStack(spacing: 16) {
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
                }

                if !task.notes.isEmpty {
                    Text(task.notes).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                }
                if !task.completed.isEmpty {
                    Text("Completed \(task.completed)").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            if task.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No body").font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownWebView(markdown: task.body)
            }
        }
    }

    @ViewBuilder
    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            content()
        }
    }
}

// MARK: - Helpers

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
