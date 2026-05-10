# AI Task Runner v2 — Design Spec
_2026-05-10_

## Overview

Enhance the existing AI task runner with three capabilities: live feedback (files and commands updating in real-time during a Claude run), dynamic per-task phases (AI-declared and human-editable), and a kanban board with a human↔AI ownership model. Two automatic post-completion artifacts round it out: AI-generated manual tests and release notes.

This is a **lightweight enhancement** — one `claude -p` run per task, no agent orchestration framework, no new backend. Phases are dynamic per task, not a fixed template applied uniformly.

---

## 1. Data Model

### 1.1 `TaskStatus` — stays lean, just lifecycle

```swift
enum TaskStatus: String, Codable, Hashable {
    case open        // in backlog, not yet handed to anyone
    case blocked     // needs human admin action (API key, config, etc.)
    case done
    case skipped
}
```

Old `inProgress` case removed. Migration is handled at the `TaskItem` decoder level (not `TaskStatus`) — see §7.

### 1.2 `TaskOwner` — new field on `TaskItem`

```swift
enum TaskOwner: String, Codable, Hashable {
    case human, ai, none
}
```

### 1.3 `TaskItem` additions

```swift
var owner: TaskOwner           // default: .none
var hasAIRun: Bool             // flipped true when a ClaudeTask for this id completes
var phases: [String]?          // nil until AI declares or human sets; dynamic per task
var completedPhases: [String]  // phases Claude has self-reported finishing; default []
```

### 1.4 Kanban column — computed, not stored

| `status` | `owner` | `hasAIRun` | → Column |
|---|---|---|---|
| `.open` | `.none` | any | Backlog |
| `.open` | `.human` | false | Speccing |
| `.open` | `.ai` | any | AI Working |
| `.blocked` | any | any | Blocked |
| `.open` | `.human` | true | Review & QA |
| `.done` | any | any | Done |

`kanbanColumn` is a computed var on `TaskItem`, not persisted.

### 1.5 `ClaudeTask` additions

```swift
var currentPhase: String?          // phase Claude just announced
var liveFiles: [LiveFileEvent]     // in-memory only, not persisted
var liveCommands: [String]         // in-memory only, not persisted
```

### 1.6 New `LiveFileEvent`

```swift
struct LiveFileEvent {
    let path: String
    let operation: Operation       // read, write, edit
    let timestamp: Date
    enum Operation { case read, write, edit }
}
```

Not `Codable` — lives only in memory for the duration of a run.

---

## 2. Live Streaming Layer

### 2.1 `ClaudeRunner` change

Switch `--output-format text` → `--output-format stream-json`. The `RunningProcess.lines` async stream is unchanged — still one `String` per line. JSON parsing happens in the consumer.

### 2.2 `DashboardStore.runClaude()` parsing loop

For each line in `proc.lines`:

```
parse as JSON →
  type == "assistant", content contains tool_use:
    name in ["Read", "Glob", "LS"]           → append LiveFileEvent(.read)
    name == "Write"                            → append LiveFileEvent(.write)
    name in ["Edit", "MultiEdit"]              → append LiveFileEvent(.edit)
    name == "Bash"                            → append to liveCommands
  type == "assistant", content contains text:
    contains "[PHASES: X, Y, Z]"             → parse phase list, save to task.phases,
                                               strip marker before display
    contains "[PHASE: X]"                    → set currentPhase = X,
                                               move previous phase to completedPhases,
                                               strip marker before display
    otherwise                                → append to output[] for display
  type == "result":
    capture exit code, mark task complete/failed
```

Lines that fail JSON parsing are treated as raw text and appended to `output[]` — graceful fallback if the CLI behaves unexpectedly.

### 2.3 Files tab and LogsTabView integration

Both tabs already observe `store.claudeTasks` via `@Published`. Add a computed property `store.runningTask(for projectPath:) -> ClaudeTask?` that returns the first `.running` task for the selected project. The Files tab shows a "Live" section at the top with `liveFiles` while a task is running; `LogsTabView` shows `liveCommands` in a similar live section at the top. These sections disappear when the task completes.

---

## 3. Dynamic Phase System

### 3.1 Philosophy

Every task gets its own phases. There is no fixed phase template applied universally. The AI analyzes the task and declares appropriate phases before starting work. A research-only task might declare `[Explore, Synthesize, Document]`; a bug fix `[Reproduce, Fix, Test]`; a config task `[Research, Configure, Verify]`. The human can override at any time.

### 3.2 Prompt injection — `runForTask()`

Every `runForTask` prompt begins with a phase-planning preamble:

```
Before starting, analyze this task and decide which phases make sense for it.
Not every task needs the same phases — choose what fits.
Announce your planned phases with exactly: [PHASES: Phase1, Phase2, ...]
Then begin executing. Announce each phase as you start it with: [PHASE: PhaseName]

If the task already has phases configured (listed below), use those instead.
```

If `task.phases` is already set (human-configured or from a prior run), those phases are listed and Claude uses them. If nil, Claude declares its own.

### 3.3 Phase defaults (AI suggestion seed, not enforcement)

When phases is nil and the task category is `.engineering`, the prompt includes a soft hint:
> "Common engineering phases: Explore, Code, Test, QA — adapt as needed."

For other categories no hint is given. This prevents over-fitting without removing AI autonomy.

### 3.4 Human editing

`TaskDetailSheet` gains a **Phases** section: a reorderable list of the current `task.phases`. The human can add, remove, reorder, or rename phases before running. Changes are saved immediately to `tasks.json`. If phases is nil, a "Let AI decide" placeholder is shown with an optional "Set phases manually" button.

### 3.5 Phase display in the task card (Board view)

The running `ClaudeTaskCard` shows a compact phase indicator:
- Completed phases: dimmed with ✓
- Current phase: highlighted with a pulse dot + elapsed time
- Upcoming phases: dimmed, no decoration

Uses the horizontal stepper layout (Option A from visual exploration) since it's compact and consistent with the existing stage stepper in `TasksTabView`.

---

## 4. AI-Generated Manual Tests

### 4.1 Trigger

Appended to every `runForTask` prompt when `allowEdits: true`:

```
Final step — always required:
[PHASE: Write Tests]
Write a manual test checklist to: .devdash/manual-tests/<taskId>.md

Cover: happy path, edge cases, things a human should click/verify.
Format: markdown checkbox list grouped by area.
If no UI is involved, cover API contracts, data correctness, and error paths instead.
```

This is a mandatory final phase on every edit-enabled run, not configurable — the human needs a test plan before QA.

### 4.2 Surface

- `TaskDetailSheet` shows a "Manual tests" section with an "Open" button when `.devdash/manual-tests/<taskId>.md` exists
- Task card in Review & QA column shows a `📋` badge when the file is present
- Check is a simple `FileManager.fileExists` call — no new scanner

---

## 5. Auto Release Notes

### 5.1 Trigger

`store.setTaskStatus(..., status: .done)` — when the human marks a task done. Fires a small read-only `claude -p` call automatically.

### 5.2 Prompt

```
Generate a concise release note (1–3 sentences) for this completed task.

Task: <title>
Category: <category>
Notes: <notes>
Phases completed: <completedPhases>
Git diff since task started:
<git diff --stat HEAD from task.startedAt>

Append to: .devdash/release-notes.md in this format:
## <title>
_<date> · <category>_

<1–3 sentence summary of what changed and why it matters>
```

If the git diff is empty (research or config task), Claude summarizes from notes and phases instead.

### 5.3 Surface

- Task card in Done column gets a `📝` badge when the release note entry exists
- `TaskDetailSheet` shows a "Release note" section with the text inline once generated
- The existing "Release notes" button in `ClaudeTabView` continues to work for project-wide generation; per-task notes in `.devdash/release-notes.md` are a separate artifact

---

## 6. Kanban UI

### 6.1 Location

`TasksTabView` gets a view-mode toggle in the header: `@AppStorage("taskViewMode")` with values `"board"` and `"queue"`. Defaults to `"board"`. The toggle replaces the existing grouped-by-stage list — stage grouping is still available as a filter within the board, not the primary organizer.

### 6.2 Board view (6 columns)

Horizontal `ScrollView` → `HStack` of `VStack` columns. Each column has a color-tinted header (green = human, blue = AI, amber = Blocked, purple = QA, gray = Backlog/Done) and a vertical list of task cards.

Drag to reorder within a column is supported. Drag between columns sets the appropriate `status` + `owner` combination via `store.setTaskOwner()` / `store.setTaskStatus()`.

Running task cards show a live phase badge: `⚡ Code · 3m`.

### 6.3 My Queue view

Plain `List` — human-owned tasks only, sorted by urgency: Blocked first, then Review & QA, then Speccing. A dimmed "AI handling" section below shows `.ai`-owned tasks with current phase. Backlog and Done are hidden.

### 6.4 New `DashboardStore` methods

```swift
func setTaskOwner(projectPath: String, id: String, owner: TaskOwner) throws
func kanbanColumn(for task: TaskItem) -> KanbanColumn  // computed, not stored
```

---

## 7. Migration

Existing `tasks.json` files with `"in_progress"` raw value: `TaskItem`'s custom `init(from:)` decoder reads the raw `status` string — if it equals `"in_progress"`, it sets `status = .open`, `owner = .ai`, `hasAIRun = true`. `TaskStatus` itself doesn't need a custom init. All other old values decode as-is. No file rewrite needed on load — migration happens transparently at decode time.

---

## 8. Files to Create / Modify

| File | Change |
|---|---|
| `Models.swift` | Add `TaskOwner`, `LiveFileEvent`; extend `TaskStatus`; add fields to `TaskItem`, `ClaudeTask` |
| `Scanners/ClaudeRunner.swift` | Switch to `--output-format stream-json` |
| `Scanners/TaskStore.swift` | Add `setTaskOwner()`; handle migration in decode |
| `DashboardStore.swift` | Parse stream-json events; add `runningTask(for:)`; auto-trigger tests + release notes on status change |
| `Views/Tabs/TasksTabView.swift` | Replace task list with board/queue toggle; add `KanbanBoardView` + `MyQueueView` |
| `Views/Tabs/FilesTabView.swift` | Add live files section when a task is running |
| `Views/Tabs/ClaudeTabView.swift` | Update `ClaudeTaskCard` with phase stepper |
| `Views/TaskDetailSheet.swift` | Add Phases section, Manual tests button, Release note display |
| `Views/Tabs/LogsTabView.swift` | Add live commands section at top when a task is running |

No new files for the kanban — `KanbanBoardView` and `MyQueueView` are private structs inside `TasksTabView.swift`.
