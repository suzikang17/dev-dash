# AI Task Runner v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the AI task runner with live streaming feedback, dynamic per-task phases, a kanban board with human↔AI ownership, and auto-generated manual tests + release notes.

**Architecture:** Switch `ClaudeRunner` to `--output-format stream-json`, parse tool_use events to update `liveFiles`/`liveCommands` in real-time, parse `[PHASES:]`/`[PHASE:]` text markers for phase tracking. Kanban column is computed from `status + owner + hasAIRun` on `TaskItem` — nothing stored. Post-completion artifacts (manual tests, release notes) are triggered automatically by status transitions.

**Tech Stack:** Swift, SwiftUI, AppKit, Foundation, JSONSerialization (no new dependencies)

**Build command:** `swift build` from `/Users/suki/dev/dev-dash`
**Run command:** `pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash &`

---

## Task 1: Data models — TaskOwner, LiveFileEvent, KanbanColumn

**Files:**
- Modify: `Sources/DevDash/Models.swift`

Add the new types and extend `TaskStatus`, `TaskItem`, `ClaudeTask`.

- [ ] **Step 1: Add `TaskOwner` enum and `KanbanColumn` enum after `TaskStatus`**

In `Models.swift`, after the closing `}` of `TaskStatus`, add:

```swift
enum TaskOwner: String, Codable, Hashable {
    case human, ai, none
}

enum KanbanColumn: String, CaseIterable {
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

    var ownerIsHuman: Bool {
        switch self {
        case .backlog, .speccing, .blocked, .reviewQA: return true
        case .aiWorking, .done: return false
        }
    }
}
```

- [ ] **Step 2: Add `.blocked` to `TaskStatus` and keep `inProgress` for migration compat**

Replace the `TaskStatus` block with:

```swift
enum TaskStatus: String, Codable, Hashable {
    case open
    case inProgress = "in_progress"   // legacy — migrated to open+ai in TaskStore
    case blocked
    case done
    case skipped

    var label: String {
        switch self {
        case .open:       return "Open"
        case .inProgress: return "In Progress"
        case .blocked:    return "Blocked"
        case .done:       return "Done"
        case .skipped:    return "Skipped"
        }
    }
}
```

- [ ] **Step 3: Add new fields to `TaskItem`**

In the `TaskItem` struct, after `var parentId: String? = nil`, add:

```swift
var owner: TaskOwner = .none
var hasAIRun: Bool = false
var phases: [String]? = nil
var completedPhases: [String] = []

var kanbanColumn: KanbanColumn {
    switch (status, owner, hasAIRun) {
    case (.done, _, _):                      return .done
    case (.blocked, _, _):                   return .blocked
    case (.open, .ai, _), (.inProgress, _, _): return .aiWorking
    case (.open, .human, false):             return .speccing
    case (.open, .human, true):              return .reviewQA
    default:                                 return .backlog
    }
}
```

- [ ] **Step 4: Add `LiveFileEvent` struct after `TaskItem`**

```swift
struct LiveFileEvent: Identifiable {
    let id = UUID()
    let path: String
    let operation: Operation
    let timestamp: Date

    enum Operation {
        case read, write, edit
        var systemImage: String {
            switch self {
            case .read:  return "eye"
            case .write: return "square.and.pencil"
            case .edit:  return "pencil"
            }
        }
        var label: String {
            switch self { case .read: return "read"; case .write: return "write"; case .edit: return "edit" }
        }
    }
}
```

- [ ] **Step 5: Extend `ClaudeTask` with live feedback and phase fields**

In the `ClaudeTask` struct, after `var sessionId: String?`, add:

```swift
var currentPhase: String? = nil
var completedPhases: [String] = []   // phases Claude has finished during this run
var phases: [String]? = nil          // declared by Claude via [PHASES:] marker
var liveFiles: [LiveFileEvent] = []
var liveCommands: [String] = []
var linkedTaskId: String? = nil      // TaskItem.id this run was started for
```

- [ ] **Step 6: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -40
```

Expected: build succeeds. Fix any type errors before continuing.

- [ ] **Step 7: Commit**

```bash
git add Sources/DevDash/Models.swift
git commit -m "feat: add TaskOwner, LiveFileEvent, KanbanColumn; extend TaskItem + ClaudeTask"
```

---

## Task 2: TaskStore — migration pass + setTaskOwner

**Files:**
- Modify: `Sources/DevDash/Scanners/TaskStore.swift`

- [ ] **Step 1: Add migration pass to `TaskStore.read()`**

After tasks are decoded (before the `return migrated` / `return tasks` line), add:

```swift
// Migrate legacy in_progress tasks to open+ai ownership
let migrated2 = tasks.map { t -> TaskItem in
    guard t.status == .inProgress else { return t }
    var m = t
    m.status = .open
    if m.owner == .none { m.owner = .ai }
    m.hasAIRun = true
    return m
}
return migrated2
```

Apply this to both the primary decode path and the legacy migration path. The `read()` function has two return points — wrap both.

- [ ] **Step 2: Add `setTaskOwner()` to `TaskStore`**

After `setStatus()`:

```swift
static func setOwner(projectPath: String, id: String, owner: TaskOwner) throws {
    var tasks = read(projectPath)
    guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
    tasks[idx].owner = owner
    try write(projectPath, tasks: tasks)
}

static func setHasAIRun(projectPath: String, id: String) throws {
    var tasks = read(projectPath)
    guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
    tasks[idx].hasAIRun = true
    try write(projectPath, tasks: tasks)
}

static func setPhases(projectPath: String, id: String, phases: [String]) throws {
    var tasks = read(projectPath)
    guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
    tasks[idx].phases = phases
    try write(projectPath, tasks: tasks)
}

static func addCompletedPhase(projectPath: String, id: String, phase: String) throws {
    var tasks = read(projectPath)
    guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
    if !tasks[idx].completedPhases.contains(phase) {
        tasks[idx].completedPhases.append(phase)
    }
    try write(projectPath, tasks: tasks)
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -40
```

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/TaskStore.swift
git commit -m "feat: TaskStore migration for in_progress + setOwner/setPhases helpers"
```

---

## Task 3: ClaudeRunner — switch to stream-json

**Files:**
- Modify: `Sources/DevDash/Scanners/ClaudeRunner.swift`

- [ ] **Step 1: Replace `--output-format text` with `stream-json` in both code paths**

In `ClaudeRunner.run()`, find the two places where `--output-format text` appears and replace with `--output-format stream-json`. There is one in the `shellCmd` composition (zsh fallback path) and one in `args` (direct binary path):

```swift
// zsh fallback path — change:
let inner = "claude -p \(shellQuote(prompt)) --output-format stream-json"
    + (allowEdits ? " --dangerously-skip-permissions" : " --allowedTools \"Read,Glob,Grep,LS,Bash\"")

// direct binary path — args become:
args = ["-p", prompt, "--output-format", "stream-json"]
if allowEdits {
    args.append("--dangerously-skip-permissions")
} else {
    args.append(contentsOf: ["--allowedTools", "Read,Glob,Grep,LS,Bash"])
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -20
```

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Scanners/ClaudeRunner.swift
git commit -m "feat: switch ClaudeRunner to --output-format stream-json"
```

---

## Task 4: DashboardStore — stream-json parsing

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift`

Replace the raw line-append loop in `runClaude()` with a structured parser.

- [ ] **Step 1: Add `runningTask(for:)` computed method**

After `func tasks(forClaudeProject projectPath: String)`:

```swift
func runningTask(for projectPath: String) -> ClaudeTask? {
    claudeTasks[projectPath]?.first { $0.status == .running }
}
```

- [ ] **Step 2: Add private parsing helpers**

Add these private methods to `DashboardStore` (before or after `runClaude`):

```swift
private func parseStreamLine(_ line: String, taskId: UUID, path: String) {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else {
        appendOutputLine(line, taskId: taskId, path: path)
        return
    }
    switch type {
    case "assistant":
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        for item in content {
            let itemType = item["type"] as? String
            if itemType == "tool_use" {
                handleToolUse(item, taskId: taskId, path: path)
            } else if itemType == "text", let text = item["text"] as? String, !text.isEmpty {
                handleTextBlock(text, taskId: taskId, path: path)
            }
        }
    case "result":
        // Completion is handled by the stream ending; nothing to display here.
        break
    default:
        break
    }
}

private func handleToolUse(_ item: [String: Any], taskId: UUID, path: String) {
    guard let name = item["name"] as? String,
          let input = item["input"] as? [String: Any] else { return }
    let now = Date()
    switch name {
    case "Read", "Glob", "LS":
        let p = (input["file_path"] ?? input["pattern"] ?? input["path"]) as? String ?? "unknown"
        let event = LiveFileEvent(path: p, operation: .read, timestamp: now)
        appendLiveFile(event, taskId: taskId, projectPath: path)
    case "Write":
        let p = input["file_path"] as? String ?? "unknown"
        let event = LiveFileEvent(path: p, operation: .write, timestamp: now)
        appendLiveFile(event, taskId: taskId, projectPath: path)
    case "Edit", "MultiEdit":
        let p = input["file_path"] as? String ?? "unknown"
        let event = LiveFileEvent(path: p, operation: .edit, timestamp: now)
        appendLiveFile(event, taskId: taskId, projectPath: path)
    case "Bash":
        let cmd = input["command"] as? String ?? "unknown"
        appendLiveCommand(cmd, taskId: taskId, projectPath: path)
    default:
        break
    }
}

private func handleTextBlock(_ text: String, taskId: UUID, path: String) {
    var processed = text

    // Parse [PHASES: A, B, C] — save phase list back to the task item
    if let range = processed.range(of: #"\[PHASES:\s*([^\]]+)\]"#, options: .regularExpression) {
        let inner = String(processed[range])
            .replacingOccurrences(of: #"^\[PHASES:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "]", with: "")
        let phases = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !phases.isEmpty {
            setPhasesOnRunningTask(phases, taskId: taskId, projectPath: path)
        }
        processed = processed.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Parse [PHASE: Name] — advance current phase
    if let range = processed.range(of: #"\[PHASE:\s*([^\]]+)\]"#, options: .regularExpression) {
        let inner = String(processed[range])
            .replacingOccurrences(of: #"^\[PHASE:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces)
        if !inner.isEmpty {
            advancePhase(to: inner, taskId: taskId, projectPath: path)
        }
        processed = processed.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if !processed.isEmpty {
        appendOutputLine(processed, taskId: taskId, path: path)
    }
}

// MARK: - ClaudeTask mutation helpers

private func appendOutputLine(_ line: String, taskId: UUID, path: String) {
    guard var arr = claudeTasks[path],
          let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
    arr[idx].output.append(line)
    if arr[idx].sessionId == nil, let sid = captureSessionId(from: line) {
        arr[idx].sessionId = sid
    }
    claudeTasks[path] = arr
}

private func appendLiveFile(_ event: LiveFileEvent, taskId: UUID, projectPath: String) {
    guard var arr = claudeTasks[projectPath],
          let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
    arr[idx].liveFiles.append(event)
    claudeTasks[projectPath] = arr
}

private func appendLiveCommand(_ command: String, taskId: UUID, projectPath: String) {
    guard var arr = claudeTasks[projectPath],
          let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
    arr[idx].liveCommands.append(command)
    claudeTasks[projectPath] = arr
}

private func setPhasesOnRunningTask(_ phases: [String], taskId: UUID, projectPath: String) {
    guard var arr = claudeTasks[projectPath],
          let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
    arr[idx].phases = phases
    claudeTasks[projectPath] = arr
    // Also persist to TaskItem if this came from a runForTask call
    if let taskItemId = arr[idx].linkedTaskId {
        try? TaskStore.setPhases(projectPath: projectPath, id: taskItemId, phases: phases)
    }
}

private func advancePhase(to phase: String, taskId: UUID, projectPath: String) {
    guard var arr = claudeTasks[projectPath],
          let idx = arr.firstIndex(where: { $0.id == taskId }) else { return }
    if let prev = arr[idx].currentPhase, !arr[idx].completedPhases.contains(prev) {
        arr[idx].completedPhases.append(prev)
    }
    arr[idx].currentPhase = phase
    claudeTasks[projectPath] = arr
}
```

- [ ] **Step 3: Replace the streaming loop in `runClaude()` with `parseStreamLine`**

Find the `Task { [weak self] in` block inside `runClaude()`. Replace the inner loop body:

```swift
// OLD:
arr[idx].output.append(line)
if arr[idx].sessionId == nil,
   let sid = self.captureSessionId(from: line) {
    arr[idx].sessionId = sid
}
self.claudeTasks[path] = arr

// NEW — replace the entire for-await block body with:
for await line in proc.lines {
    guard let self = self else { return }
    await MainActor.run {
        self.parseStreamLine(line, taskId: taskId, path: path)
    }
}
```

- [ ] **Step 5: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -40
```

Fix any compiler errors (likely missing `linkedTaskId` references or type mismatches).

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Models.swift Sources/DevDash/DashboardStore.swift
git commit -m "feat: parse stream-json events for live files, commands, and phase markers"
```

---

## Task 5: Prompt updates — phases + manual tests + release notes trigger

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift`

- [ ] **Step 1: Update `runForTask()` with phase-planning preamble**

Replace `runForTask()` entirely:

```swift
func runForTask(_ task: TaskItem, projectPath: String, allowEdits: Bool) async {
    let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
    let actionLine = allowEdits
        ? "Investigate the codebase, design an approach, and make the changes."
        : "Investigate the codebase and explain what you'd change. Do NOT modify any files."

    // Phase planning preamble
    let phasePreamble: String
    if let existing = task.phases, !existing.isEmpty {
        let list = existing.joined(separator: ", ")
        phasePreamble = """
        This task has pre-configured phases: \(list)
        Use these phases in order. Announce each with exactly: [PHASE: <name>]
        """
    } else {
        let hint = task.category == .engineering
            ? "\nCommon engineering phases: Explore, Code, Test, QA — adapt as needed."
            : ""
        phasePreamble = """
        Before starting, decide which phases make sense for this specific task.\
        \(hint)
        Not every task needs the same phases. Choose what fits.
        Announce your planned phases with exactly: [PHASES: Phase1, Phase2, ...]
        Then begin executing. Announce each phase as you start it with: [PHASE: <name>]
        """
    }

    // Manual test generation — mandatory when edits are allowed
    let testPhase = allowEdits ? """

        Final step — always required:
        [PHASE: Write Tests]
        Write a manual test checklist to: .devdash/manual-tests/\(task.id).md
        Cover: happy path, edge cases, things a human should click/verify.
        Format: markdown checkbox list grouped by area.
        If no UI is involved, cover API contracts, data correctness, and error paths.
        """ : ""

    let prompt = """
    \(phasePreamble)

    I'm working on the project \(projectName). Help me complete this task.

    Task: \(task.title)
    Category: \(task.category.label)
    \(task.notes.map { "Notes: \($0)" } ?? "")

    \(actionLine)\(testPhase)
    """

    // Mark task as AI-owned and in-progress before starting
    try? TaskStore.setOwner(projectPath: projectPath, id: task.id, owner: .ai)
    try? TaskStore.setStatus(projectPath: projectPath, id: task.id, status: .open)

    // Run and link the ClaudeTask back to the TaskItem
    await runClaude(
        prompt: prompt,
        projectPath: projectPath,
        allowEdits: allowEdits,
        kind: .taskExecution,
        linkedTaskId: task.id
    )
}
```

- [ ] **Step 2: Thread `linkedTaskId` through `runClaude()`**

Add `linkedTaskId: String? = nil` parameter to `runClaude()`:

```swift
func runClaude(prompt: String, projectPath: String, allowEdits: Bool,
               kind: ClaudeTask.Kind = .general, linkedTaskId: String? = nil) async {
```

When building the initial `ClaudeTask` var, set `task.linkedTaskId = linkedTaskId`.

- [ ] **Step 3: After a task completes, flip `hasAIRun` and set owner back to human**

In `runClaude()`, inside the `await MainActor.run` after the stream ends:

```swift
// After arr[idx].status = .completed:
if let tid = arr[idx].linkedTaskId {
    try? TaskStore.setHasAIRun(projectPath: path, id: tid)
    try? TaskStore.setOwner(projectPath: path, id: tid, owner: .human)
}
```

- [ ] **Step 4: Add `markTaskDone()` async method for release notes trigger**

```swift
func markTaskDone(projectPath: String, taskId: String) async {
    try? TaskStore.setStatus(projectPath: projectPath, id: taskId, status: .done)
    try? TaskStore.setOwner(projectPath: projectPath, id: taskId, owner: .none)

    // Fire release notes generation
    guard let task = tasksV2(for: projectPath).first(where: { $0.id == taskId }) else { return }
    await generateTaskReleaseNote(task, projectPath: projectPath)
}

private func generateTaskReleaseNote(_ task: TaskItem, projectPath: String) async {
    let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
    let fmt = ISO8601DateFormatter()
    let since = fmt.string(from: task.startedAt ?? task.createdAt)
    let gitLog = await ShellRunner.run("/bin/zsh", args: ["-ic",
        "cd \(shellQuote(projectPath)) && git log --oneline --since='\(since)' | head -20"
    ]) ?? "(no commits)"

    let phases = task.completedPhases.isEmpty ? "none recorded" : task.completedPhases.joined(separator: " → ")
    let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)

    let prompt = """
    Generate a concise release note (1–3 sentences) for this completed task.
    Write ONLY the release note text — no preamble, no explanation.

    Task: \(task.title)
    Category: \(task.category.label)
    \(task.notes.map { "Notes: \($0)" } ?? "")
    Phases completed: \(phases)

    Recent commits since task started:
    \(gitLog)

    Then append the release note to .devdash/release-notes.md in this format (include the header):
    ## \(task.title)
    _\(dateStr) · \(task.category.label)_

    <your 1-3 sentence summary here>

    If no commits exist, summarize from the task notes and phases instead.
    """

    await runClaude(prompt: prompt, projectPath: projectPath, allowEdits: true,
                    kind: .releaseNotes, linkedTaskId: task.id)
}
```

- [ ] **Step 5: Add `shellQuote` access** — `shellQuote` is currently `private` in `ClaudeRunner`. Either make it `internal` or duplicate the one-liner in `DashboardStore`. Simplest: duplicate:

```swift
// In DashboardStore, add private helper:
private func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}
```

- [ ] **Step 6: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -40
```

- [ ] **Step 7: Commit**

```bash
git add Sources/DevDash/DashboardStore.swift
git commit -m "feat: phase-aware runForTask prompt + auto manual tests + release notes on done"
```

---

## Task 6: Live feedback in FilesTabView and LogsTabView

**Files:**
- Modify: `Sources/DevDash/Views/Tabs/FilesTabView.swift`
- Modify: `Sources/DevDash/Views/Tabs/LogsTabView.swift`

- [ ] **Step 1: Add a `LiveFilesSection` private view to `FilesTabView.swift`**

Add after the last private struct/function in the file:

```swift
private struct LiveFilesSection: View {
    let task: ClaudeTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Label("Live · \(task.currentPhase ?? "Running")", systemImage: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.blue)
                Spacer()
                Text(verbatim: "\(task.liveFiles.count) files")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.blue.opacity(0.08))

            ForEach(task.liveFiles.suffix(20)) { event in
                HStack(spacing: 8) {
                    Image(systemName: event.operation.systemImage)
                        .font(.system(size: 10))
                        .foregroundColor(event.operation == .read ? .secondary : .orange)
                        .frame(width: 14)
                    Text(URL(fileURLWithPath: event.path).lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Text(event.operation.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
                Divider()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.3), lineWidth: 0.5))
        .padding(10)
    }
}
```

- [ ] **Step 2: Insert `LiveFilesSection` at the top of `FilesTabView.body`**

In `FilesTabView.body`, inside the `if let project = ...` branch, before `HSplitView {`, wrap with a `VStack`:

```swift
VStack(spacing: 0) {
    if let running = store.runningTask(for: project.path), !running.liveFiles.isEmpty {
        LiveFilesSection(task: running)
    }
    HSplitView {
        // existing treePane + contentPane
    }
}
```

- [ ] **Step 3: Add `LiveCommandsSection` to `LogsTabView.swift`**

Add this private struct at the bottom of `LogsTabView.swift`:

```swift
private struct LiveCommandsSection: View {
    let task: ClaudeTask

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Label("Live commands · \(task.currentPhase ?? "Running")", systemImage: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.blue)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.blue.opacity(0.08))

            ForEach(Array(task.liveCommands.suffix(10).enumerated()), id: \.offset) { _, cmd in
                Text(cmd)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                Divider()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.3), lineWidth: 0.5))
        .padding(10)
    }
}
```

- [ ] **Step 4: Insert `LiveCommandsSection` at the top of `LogsTabView.body`**

In `LogsTabView.body`, inside `if let project = ...`, wrap the existing `VStack(spacing: 0)` content in an outer `VStack`:

```swift
VStack(spacing: 0) {
    if let running = store.runningTask(for: project.path), !running.liveCommands.isEmpty {
        LiveCommandsSection(task: running)
    }
    // existing VStack(spacing: 0) { header, Divider, log lines }
}
```

- [ ] **Step 5: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -40
```

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Views/Tabs/FilesTabView.swift Sources/DevDash/Views/Tabs/LogsTabView.swift
git commit -m "feat: live files + commands sections in Files and Logs tabs during AI runs"
```

---

## Task 7: Kanban board — TasksTabView rewrite

**Files:**
- Modify: `Sources/DevDash/Views/Tabs/TasksTabView.swift`

This is the largest task. `KanbanBoardView` and `MyQueueView` are private structs added to the same file.

- [ ] **Step 1: Add view-mode toggle to the header in `TasksTabView`**

Add to `TasksTabView`:

```swift
@AppStorage("taskViewMode") private var viewMode: String = "board"
```

In `headerRow(project:)`, add after the existing buttons:

```swift
Picker("View", selection: $viewMode) {
    Label("Board", systemImage: "square.grid.3x3").tag("board")
    Label("My Queue", systemImage: "person.fill").tag("queue")
}
.pickerStyle(.segmented)
.frame(width: 160)
.labelsHidden()
```

- [ ] **Step 2: Replace `taskList()` call in `body` with board/queue switch**

In `TasksTabView.body`, inside the `ScrollView`, replace the `taskList(project:)` call with:

```swift
if viewMode == "board" {
    KanbanBoardView(project: project)
        .environmentObject(store)
} else {
    MyQueueView(project: project)
        .environmentObject(store)
}
```

Remove the `taskList()` private function (or keep it private and unused for now — remove for cleanliness).

- [ ] **Step 3: Add `KanbanBoardView`**

Add at the bottom of `TasksTabView.swift` (before the final closing of the file):

```swift
private struct KanbanBoardView: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore

    private var allTasks: [TaskItem] { store.tasksV2(for: project.path) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(KanbanColumn.allCases, id: \.self) { col in
                    KanbanColumnView(
                        column: col,
                        tasks: allTasks.filter { $0.kanbanColumn == col },
                        projectPath: project.path
                    )
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct KanbanColumnView: View {
    let column: KanbanColumn
    let tasks: [TaskItem]
    let projectPath: String
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(columnColor)
                    .frame(width: 8, height: 8)
                Text(column.label)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                Spacer()
                Text(verbatim: "\(tasks.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(columnColor.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(spacing: 6) {
                ForEach(tasks.filter { $0.parentId == nil }) { task in
                    KanbanCard(task: task, projectPath: projectPath, columnColor: columnColor)
                        .environmentObject(store)
                }
            }

            if tasks.isEmpty {
                Text("Empty")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            }
        }
        .frame(width: 200)
        .padding(6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var columnColor: Color {
        switch column {
        case .backlog:   return .secondary
        case .speccing:  return .green
        case .aiWorking: return .blue
        case .blocked:   return .orange
        case .reviewQA:  return .purple
        case .done:      return .green.opacity(0.6)
        }
    }
}

private struct KanbanCard: View {
    let task: TaskItem
    let projectPath: String
    let columnColor: Color
    @EnvironmentObject var store: DashboardStore
    @State private var hover = false

    private var runningClaudeTask: ClaudeTask? {
        store.claudeTasks[projectPath]?.first {
            $0.linkedTaskId == task.id && $0.status == .running
        }
    }

    var body: some View {
        Button {
            store.openTaskId = task.id
            store.openTaskProjectPath = projectPath
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)

                // Live phase badge
                if let ct = runningClaudeTask, let phase = ct.currentPhase {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("⚡ \(phase)")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                    }
                }

                // Manual test badge
                if FileManager.default.fileExists(atPath: "\(projectPath)/.devdash/manual-tests/\(task.id).md") {
                    Label("Tests ready", systemImage: "checklist")
                        .font(.system(size: 9))
                        .foregroundColor(.purple)
                }

                HStack(spacing: 4) {
                    CategoryChip(category: task.category)
                    Spacer()
                    if task.status == .done {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 11))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                hover ? columnColor.opacity(0.6) : Color(NSColor.separatorColor),
                lineWidth: hover ? 1 : 0.5
            ))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Investigate (read-only)") {
                Task { await store.runForTask(task, projectPath: projectPath, allowEdits: false); store.detailTab = .claude }
            }
            Button("Run + edit files") {
                Task { await store.runForTask(task, projectPath: projectPath, allowEdits: true); store.detailTab = .claude }
            }
            Divider()
            Button("Move to Backlog") {
                try? TaskStore.setOwner(projectPath: projectPath, id: task.id, owner: .none)
                try? TaskStore.setStatus(projectPath: projectPath, id: task.id, status: .open)
                store.reloadTasks(for: projectPath)
            }
            Button("Mark Blocked") {
                try? TaskStore.setStatus(projectPath: projectPath, id: task.id, status: .blocked)
                try? TaskStore.setOwner(projectPath: projectPath, id: task.id, owner: .human)
                store.reloadTasks(for: projectPath)
            }
            Button("Mark Done") {
                Task { await store.markTaskDone(projectPath: projectPath, taskId: task.id) }
                store.reloadTasks(for: projectPath)
            }
            Divider()
            Button(role: .destructive) {
                store.deleteTask(projectPath: projectPath, id: task.id)
            } label: { Text("Delete") }
        }
        .onHover { hover = $0 }
    }
}
```

- [ ] **Step 4: Check `store.reloadTasks(for:)` exists**

Search DashboardStore for a method that refreshes tasks from disk. If it doesn't exist, add:

```swift
func reloadTasks(for projectPath: String) {
    let loaded = TaskStore.read(projectPath)
    // find the projectTasks entry and update it
    if let idx = allTasks.firstIndex(where: { $0.projectPath == projectPath }) {
        allTasks[idx].todos = []   // adapt to your actual tasks storage pattern
    }
    objectWillChange.send()
}
```

Check how `tasksV2(for:)` is implemented in `DashboardStore` and reload accordingly. The exact implementation depends on how tasks are cached — look for `@Published var` that holds task data and trigger re-read from disk.

- [ ] **Step 5: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -60
```

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Views/Tabs/TasksTabView.swift
git commit -m "feat: kanban board view with 6 columns and live phase badges"
```

---

## Task 8: My Queue view

**Files:**
- Modify: `Sources/DevDash/Views/Tabs/TasksTabView.swift`

- [ ] **Step 1: Add `MyQueueView` struct**

Add after `KanbanCard`:

```swift
private struct MyQueueView: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore

    private var allTasks: [TaskItem] { store.tasksV2(for: project.path) }

    private var humanTasks: [TaskItem] {
        allTasks
            .filter { $0.kanbanColumn.ownerIsHuman && $0.status != .done && $0.status != .skipped }
            .sorted { urgencyScore($0) > urgencyScore($1) }
    }

    private var aiTasks: [TaskItem] {
        allTasks.filter { $0.kanbanColumn == .aiWorking }
    }

    private func urgencyScore(_ t: TaskItem) -> Int {
        switch t.kanbanColumn {
        case .blocked:  return 3
        case .reviewQA: return 2
        case .speccing: return 1
        default:        return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if humanTasks.isEmpty && aiTasks.isEmpty {
                Text("Nothing needs your attention right now.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            }

            if !humanTasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Needs you (\(humanTasks.count))", systemImage: "person.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(.secondary)
                    ForEach(humanTasks) { task in
                        QueueRow(task: task, projectPath: project.path)
                            .environmentObject(store)
                    }
                }
            }

            if !aiTasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("AI handling (\(aiTasks.count))", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(.secondary)
                    ForEach(aiTasks) { task in
                        QueueRow(task: task, projectPath: project.path, dimmed: true)
                            .environmentObject(store)
                    }
                }
            }
        }
    }
}

private struct QueueRow: View {
    let task: TaskItem
    let projectPath: String
    var dimmed: Bool = false
    @EnvironmentObject var store: DashboardStore

    private var runningPhase: String? {
        store.claudeTasks[projectPath]?.first {
            $0.linkedTaskId == task.id && $0.status == .running
        }?.currentPhase
    }

    var body: some View {
        Button {
            store.openTaskId = task.id
            store.openTaskProjectPath = projectPath
        } label: {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(columnColor)
                    .frame(width: 3)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(dimmed ? .secondary : .primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(task.kanbanColumn.label)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        if let phase = runningPhase {
                            Text("· ⚡ \(phase)")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                        }
                    }
                }
                Spacer()
                CategoryChip(category: task.category)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
            .opacity(dimmed ? 0.5 : 1)
        }
        .buttonStyle(.plain)
    }

    private var columnColor: Color {
        switch task.kanbanColumn {
        case .blocked:   return .orange
        case .reviewQA:  return .purple
        case .speccing:  return .green
        case .aiWorking: return .blue
        default:         return .secondary
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -40
```

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Views/Tabs/TasksTabView.swift
git commit -m "feat: My Queue view — human-owned tasks sorted by urgency"
```

---

## Task 9: TaskDetailSheet — phases, manual tests, release note

**Files:**
- Modify: `Sources/DevDash/Views/TaskDetailSheet.swift`

- [ ] **Step 1: Add phases section to `TaskDetailSheet.body`**

In the `ScrollView` content, after `descriptionEditor`, add `phasesSection`.

Define the section:

```swift
@ViewBuilder
private var phasesSection: some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack {
            Text("PHASES")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)
            Spacer()
            Button("+ Add") {
                var t = task ?? TaskItem(/* won't be called if task is nil */)
                // handled below
                if var t = task {
                    t.phases = (t.phases ?? []) + ["New phase"]
                    store.updateTask(projectPath: projectPath, t)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(task == nil)
        }

        if let phases = task?.phases, !phases.isEmpty {
            ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
                HStack(spacing: 8) {
                    Image(systemName: (task?.completedPhases.contains(phase) == true) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor((task?.completedPhases.contains(phase) == true) ? .green : .secondary)
                        .frame(width: 14)
                    Text(phase)
                        .font(.system(size: 13))
                    Spacer()
                    Button {
                        if var t = task {
                            var p = t.phases ?? []
                            p.remove(at: i)
                            t.phases = p.isEmpty ? nil : p
                            store.updateTask(projectPath: projectPath, t)
                        }
                    } label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        } else {
            Text("Let AI decide phases for this task")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}
```

- [ ] **Step 2: Add manual tests + release note display**

After `phasesSection`, add:

```swift
@ViewBuilder
private var artifactsSection: some View {
    let testsPath = "\(projectPath)/.devdash/manual-tests/\(taskId).md"
    let hasTests = FileManager.default.fileExists(atPath: testsPath)

    if hasTests {
        VStack(alignment: .leading, spacing: 6) {
            Text("MANUAL TESTS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.secondary)
            Button {
                store.pendingFilePath = testsPath
                store.detailTab = .files
                dismiss()
            } label: {
                Label("Open test checklist", systemImage: "checklist")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
```

- [ ] **Step 3: Add both sections to the scroll view**

In `body`, inside the `ScrollView { VStack { ... } }`, add after `descriptionEditor`:

```swift
phasesSection
artifactsSection
```

- [ ] **Step 4: Update "Mark Done" to use `markTaskDone()`**

In `aiActions` section (or `footer`), the existing "Mark done" flow calls `store.setTaskStatus`. Replace that call with:

```swift
Task { await store.markTaskDone(projectPath: projectPath, taskId: taskId) }
```

Also update the `saveAndDismiss()` function: if `status == .done && t.status != .done`, call `markTaskDone` instead of saving directly.

- [ ] **Step 5: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -40
```

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Views/TaskDetailSheet.swift
git commit -m "feat: TaskDetailSheet phases editor + manual tests link + release note trigger"
```

---

## Task 10: ClaudeTaskCard phase stepper

**Files:**
- Modify: `Sources/DevDash/Views/Tabs/ClaudeTabView.swift`

- [ ] **Step 1: Add phase stepper to `ClaudeTaskCard`**

In `ClaudeTaskCard.body`, inside the `if expanded { ... }` block, add before the output text block:

```swift
if let phases = task.phases, !phases.isEmpty {
    PhaseStepperView(
        phases: phases,
        currentPhase: task.currentPhase,
        completedPhases: task.completedPhases
    )
    .padding(.bottom, 4)
}
```

- [ ] **Step 2: Add `PhaseStepperView`**

Add as a private struct in `ClaudeTabView.swift`:

```swift
private struct PhaseStepperView: View {
    let phases: [String]
    let currentPhase: String?
    let completedPhases: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
                    let isDone = completedPhases.contains(phase)
                    let isCurrent = phase == currentPhase

                    HStack(spacing: 4) {
                        Text(isDone ? "✓ \(phase)" : phase)
                            .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(
                                isDone ? Color.green.opacity(0.15) :
                                isCurrent ? Color.blue.opacity(0.18) :
                                Color.secondary.opacity(0.10)
                            )
                            .foregroundColor(
                                isDone ? .green :
                                isCurrent ? .blue :
                                .secondary
                            )
                            .clipShape(Capsule())
                            .overlay(isCurrent ? Capsule().stroke(Color.blue.opacity(0.4), lineWidth: 0.8) : nil)

                        if i < phases.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -40
```

- [ ] **Step 4: Run and manually test**

```bash
pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash &
```

Open DevDash → select a project → Tasks tab → run a task via "Run + edit files". Verify:
1. Claude tab shows phase stepper once `[PHASES:]` marker is parsed
2. Files tab shows live files as Claude reads/writes
3. Logs tab shows live commands as Claude runs bash
4. After completion, task moves to Review & QA column in Board view
5. `.devdash/manual-tests/<taskId>.md` exists after run

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Views/Tabs/ClaudeTabView.swift
git commit -m "feat: phase stepper in ClaudeTaskCard"
```

---

## Task 11: DashboardStore — wire setTaskStatus and tasksV2 reload

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift`

This task ensures that `setTaskStatus`, `setTaskParent`, `addTask`, and `updateTask` in DashboardStore also call `reloadTasks` so the board refreshes. It also wires `setTaskOwner` into DashboardStore.

- [ ] **Step 1: Add `setTaskOwner()` to `DashboardStore`**

```swift
func setTaskOwner(projectPath: String, id: String, owner: TaskOwner) {
    try? TaskStore.setOwner(projectPath: projectPath, id: id, owner: owner)
    reloadTasks(for: projectPath)
}
```

- [ ] **Step 2: Implement `reloadTasks(for:)` in `DashboardStore`**

Find how `tasksV2(for:)` is implemented. Look for `@Published` task storage. If tasks are stored in `allTasks: [ProjectTasks]` (the `ProjectTasks` struct), reload like:

```swift
func reloadTasks(for projectPath: String) {
    let fresh = TaskStore.read(projectPath)
    if let idx = allTasks.firstIndex(where: { $0.projectPath == projectPath }) {
        allTasks[idx].todos = fresh.map { Todo(id: $0.id, text: $0.title, done: $0.status == .done, createdAt: ISO8601DateFormatter().string(from: $0.createdAt), doneAt: nil) }
    }
    // Trigger tasksV2 refresh — look for how tasksV2 is backed
    objectWillChange.send()
}
```

**Note:** The exact implementation of `tasksV2(for:)` in `DashboardStore.swift` needs to be read first. Search for `func tasksV2` and adapt the reload to match the actual backing store. The pattern above is a guideline — match what's actually there.

- [ ] **Step 3: Build and verify**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | head -40
```

- [ ] **Step 4: Full manual smoke test**

```bash
pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash &
```

Run through the complete workflow:
1. Create a task → appears in Backlog column ✓
2. Run task with edits → moves to AI Working, phase stepper appears in Claude tab ✓
3. After run completes → moves to Review & QA, `.devdash/manual-tests/<id>.md` created ✓
4. Open TaskDetailSheet → shows Phases section with AI-declared phases, Manual tests button ✓
5. Mark task done → release notes call fires, `.devdash/release-notes.md` updated ✓
6. My Queue view → shows only human-owned tasks ✓
7. Files tab → shows live files section during a run ✓
8. Logs tab → shows live commands section during a run ✓

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/DashboardStore.swift
git commit -m "feat: wire setTaskOwner, reloadTasks, and task lifecycle into DashboardStore"
```

---

## Self-Review Notes

After all tasks are complete, verify:
- `linkedTaskId` is set on every `ClaudeTask` created by `runForTask()` (Task 5 Step 2)
- `hasAIRun` is flipped after a Claude run completes (Task 5 Step 3)
- `kanbanColumn` computed var handles the `inProgress` legacy case (Task 1 Step 3 — the `(.inProgress, _, _)` branch)
- `markTaskDone()` is called from all "done" trigger points: board context menu, TaskDetailSheet footer, TaskLine menu in the existing view
- `PhaseStepperView` handles `phases = nil` gracefully (guarded by `if let phases` in Task 10 Step 1)
