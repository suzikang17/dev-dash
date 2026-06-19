# Project One-Pager (Status Snapshot) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an auto-synthesized, always-current status snapshot to each project's living document, modeled as a reusable value type so a future cross-project roll-up is a trivial aggregation.

**Architecture:** A pure `ProjectStatus` value is synthesized from data the store already holds (tasks, commit heatmap, running services, health) plus two small lore reads (latest devlog, latest decision). Phase 1 renders it as an HTML block at the top of the living-doc Overview tab. lore is read, never written.

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit, SwiftPM executable target `DevDash`, no external test deps.

## Global Constraints

- Platform: macOS 14+, Swift tools 5.9.
- No new Swift package dependencies.
- Verification is `swift build` + `bash run.sh` (launch + observe) — the repo has no test target. Pure units are written as deterministic functions so they can be exercised directly.
- `ShellRunner.run()` for subprocesses; `LoreRunner` wraps `claude -p` — but this feature makes **no** AI calls (deterministic synthesis only).
- Commit messages: imperative mood, concise. Commit after each task.
- SourceKit "Cannot find X in scope" errors are stale-index noise — confirm with `swift build`.

---

### Task 1: `ProjectStatus` + `LoreRef` value types

**Files:**
- Create: `Sources/DevDash/ProjectStatus.swift`

**Interfaces:**
- Produces: `struct LoreRef: Codable, Hashable { let title: String; let date: Date? }`
- Produces: `struct ProjectStatus: Codable, Hashable` with fields:
  `projectName: String`, `tagline: String?`, `lastSession: LoreRef?`,
  `activeTaskCount: Int`, `blockedTaskCount: Int`, `recentDecision: LoreRef?`,
  `commits7d: Int`, `runningPorts: [Int]`, `health: HealthStatus`, `generatedAt: Date`.

- [ ] **Step 1: Create the value types**

```swift
import Foundation

/// A reference to a lore document (devlog, decision) — the trimmed fields the
/// status snapshot needs, not the whole entry.
struct LoreRef: Codable, Hashable {
    let title: String
    let date: Date?
}

/// Deterministic, always-current snapshot of one project. Synthesized from data
/// the store already holds plus lore reads — never persisted to lore, never AI.
/// Codable so the future cross-project board can serialize a list of these.
struct ProjectStatus: Codable, Hashable {
    let projectName: String
    let tagline: String?
    let lastSession: LoreRef?
    let activeTaskCount: Int
    let blockedTaskCount: Int
    let recentDecision: LoreRef?
    let commits7d: Int
    let runningPorts: [Int]
    let health: HealthStatus
    let generatedAt: Date
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!` (no errors). `HealthStatus` resolves from `Models.swift`.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/ProjectStatus.swift
git commit -m "add ProjectStatus value type for project snapshots"
```

---

### Task 2: `LoreReader` — latest devlog/decision reader

Relocate the frontmatter parser (currently `private func parseMdFrontmatter` in
`DailyTabView.swift:719`) into a shared `LoreReader` so both callers use one copy.

**Files:**
- Create: `Sources/DevDash/Scanners/LoreReader.swift`
- Modify: `Sources/DevDash/Views/Tabs/DailyTabView.swift` (delete the private `parseMdFrontmatter`, call `LoreReader.parseFrontmatter` instead)

**Interfaces:**
- Consumes: `LoreRef` (Task 1).
- Produces: `enum LoreReader` with
  `static func parseFrontmatter(_ content: String) -> [String: String]` and
  `static func latest(type: String, in projectPath: String) -> LoreRef?`.

- [ ] **Step 1: Read the existing parser to copy verbatim**

Run: `sed -n '719,760p' Sources/DevDash/Views/Tabs/DailyTabView.swift`
Expected: prints the body of `private func parseMdFrontmatter(_ content:) -> [String: String]`.

- [ ] **Step 2: Create `LoreReader` with the moved parser + `latest`**

`latest` walks `docs/<type>/`, parses each `.md` (skipping `index.md`), derives a
date from `created`/`date` frontmatter or a leading `YYYY-MM-DD` filename, and
returns the newest entry's title + date. Mirrors `DailyTabView.reload()` exactly.

```swift
import Foundation

/// Reads lore docs (devlogs, decisions, …) from `docs/<type>/`. Read-only — this
/// feature projects lore into a snapshot, it never writes lore.
enum LoreReader {
    /// Paste the EXACT body printed in Step 1 here (YAML-ish frontmatter parse).
    static func parseFrontmatter(_ content: String) -> [String: String] {
        // <-- body copied verbatim from DailyTabView.parseMdFrontmatter
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// The most recent doc of `type` under `<projectPath>/docs/<type>/`, or nil.
    static func latest(type: String, in projectPath: String) -> LoreRef? {
        let dir = "\(projectPath)/docs/\(type)"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

        var best: (date: String, ref: LoreRef)?
        for file in files {
            guard file.hasSuffix(".md"), file.lowercased() != "index.md" else { continue }
            guard let content = try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)
            else { continue }
            let front = parseFrontmatter(content)

            let dateStr: String
            if let raw = front["created"] ?? front["date"], raw.count >= 10 {
                dateStr = String(raw.prefix(10))
            } else if file.count >= 10, file.prefix(10).allSatisfy({ $0.isNumber || $0 == "-" }) {
                dateStr = String(file.prefix(10))
            } else {
                dateStr = ""
            }

            let title = front["title"] ?? file.replacingOccurrences(of: ".md", with: "")
            let ref = LoreRef(title: title, date: dateFormatter.date(from: dateStr))
            // Lexicographic compare of YYYY-MM-DD == chronological; "" sorts first.
            if best == nil || dateStr > best!.date {
                best = (dateStr, ref)
            }
        }
        return best?.ref
    }
}
```

- [ ] **Step 3: Point `DailyTabView` at the shared parser**

In `Sources/DevDash/Views/Tabs/DailyTabView.swift`: change the call site
`let fm = parseMdFrontmatter(content)` (inside `reload`) to
`let fm = LoreReader.parseFrontmatter(content)`, then delete the now-unused
`private func parseMdFrontmatter(_ content: String) -> [String: String] { … }`
function at line ~719.

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: `Build complete!` — no "cannot find parseMdFrontmatter" (the only caller now uses `LoreReader.parseFrontmatter`).

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Scanners/LoreReader.swift Sources/DevDash/Views/Tabs/DailyTabView.swift
git commit -m "add LoreReader; share frontmatter parser with DailyTabView"
```

---

### Task 3: `ProjectStatusSynthesizer` — pure synthesis

**Files:**
- Create: `Sources/DevDash/Scanners/ProjectStatusSynthesizer.swift`

**Interfaces:**
- Consumes: `ProjectStatus`, `LoreRef`, `LoreReader` (Tasks 1–2); `Project`,
  `TaskItem`, `Service`, `CommitHeatmapStore.Heatmap`, `ProjectMeta`,
  `HealthStatus` (existing).
- Produces:
  `enum ProjectStatusSynthesizer { static func synthesize(project: Project, meta: ProjectMeta, tasks: [TaskItem], heatmap: CommitHeatmapStore.Heatmap?, services: [Service], now: Date) -> ProjectStatus }`

Field rules (verbatim from the codebase):
- `activeTaskCount` = tasks where `kanbanColumn.ownerIsHuman && status != .done && status != .skipped` (matches `MyQueueView.humanTasks` filter).
- `blockedTaskCount` = tasks where `kanbanColumn == .blocked`.
- `commits7d` = `heatmap?.dayCounts.suffix(7).reduce(0, +) ?? 0` (`dayCounts[i]` is `today-(totalDays-1-i)`, so the suffix is the most recent days).
- `runningPorts` = `services.map(\.port).sorted()`.
- `tagline` = `meta.notes` first non-empty line if present, else `project.stack ?? project.framework`.
- `lastSession` = `LoreReader.latest(type: "devlog", in: project.path)`.
- `recentDecision` = `LoreReader.latest(type: "decisions", in: project.path)`.

- [ ] **Step 1: Create the synthesizer**

```swift
import Foundation

/// Builds a `ProjectStatus` from already-loaded store data + lore reads.
/// Pure and deterministic given its inputs (lore reads aside) — no AI, no store.
enum ProjectStatusSynthesizer {
    static func synthesize(
        project: Project,
        meta: ProjectMeta,
        tasks: [TaskItem],
        heatmap: CommitHeatmapStore.Heatmap?,
        services: [Service],
        now: Date
    ) -> ProjectStatus {
        let active = tasks.filter {
            $0.kanbanColumn.ownerIsHuman && $0.status != .done && $0.status != .skipped
        }.count
        let blocked = tasks.filter { $0.kanbanColumn == .blocked }.count
        let commits7d = heatmap?.dayCounts.suffix(7).reduce(0, +) ?? 0
        let ports = services.map(\.port).sorted()

        let tagline: String? = {
            if let firstLine = meta.notes?
                .split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }) {
                return firstLine
            }
            return project.stack ?? project.framework
        }()

        return ProjectStatus(
            projectName: project.name,
            tagline: tagline,
            lastSession: LoreReader.latest(type: "devlog", in: project.path),
            activeTaskCount: active,
            blockedTaskCount: blocked,
            recentDecision: LoreReader.latest(type: "decisions", in: project.path),
            commits7d: commits7d,
            runningPorts: ports,
            health: project.health,
            generatedAt: now
        )
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`. If "value of type 'Project' has no member 'stack'": confirm with `grep -n "let stack" Sources/DevDash/Models.swift` (it exists as `let stack: String?`).

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Scanners/ProjectStatusSynthesizer.swift
git commit -m "add ProjectStatusSynthesizer (deterministic snapshot synthesis)"
```

---

### Task 4: `store.projectStatus(for:)` accessor

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift` (add method near `runningPort`/`services`, ~line 250)

**Interfaces:**
- Consumes: `ProjectStatusSynthesizer.synthesize(...)`, existing store members
  `projects`, `meta(for:)`, `tasksV2(for:)`, `heatmaps`, `services(for:)`.
- Produces: `func projectStatus(for projectPath: String) -> ProjectStatus?`
  (nil when the path isn't a known project).

- [ ] **Step 1: Add the accessor**

```swift
/// Synthesize the current status snapshot for a project. Gathers already-loaded
/// store data + lore reads and hands them to the pure synthesizer. Returns nil
/// if `projectPath` isn't a known project.
func projectStatus(for projectPath: String) -> ProjectStatus? {
    guard let project = projects.first(where: { $0.path == projectPath }) else { return nil }
    return ProjectStatusSynthesizer.synthesize(
        project: project,
        meta: meta(for: projectPath),
        tasks: tasksV2(for: projectPath),
        heatmap: heatmaps[projectPath],
        services: services(for: projectPath),
        now: Date()
    )
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/DashboardStore.swift
git commit -m "add DashboardStore.projectStatus(for:)"
```

---

### Task 5: Render the snapshot HTML at the top of Overview

**Files:**
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift` (add `status:` param to `generate`; add `renderStatus`; inject into the `overview` tab)
- Modify: `Sources/DevDash/Views/Tabs/ProductTabView.swift:254` (pass `store.projectStatus(for:)`)
- Modify: `Sources/DevDash/DashboardStore.swift:614` (pass `projectStatus(for:)` in `regenerateRoadmap`)

**Interfaces:**
- Consumes: `ProjectStatus` (Task 1), `store.projectStatus(for:)` (Task 4).
- Produces: `ProductDocGenerator.generate(..., status: ProjectStatus?)` and
  `static func renderStatus(_ status: ProjectStatus) -> String`.

- [ ] **Step 1: Add `status:` to `generate` and inject into the overview tab**

In `ProductDocGenerator.generate`, add a trailing parameter
`status: ProjectStatus? = nil`. In the `for tab in tabs` loop, prepend the
rendered status to the overview pane:

```swift
for tab in tabs {
    var body = readSection(tab: tab, projectPath: projectPath)
    if tab.id == "overview", let status = status {
        body = renderStatus(status) + body
    }
    let active = (tab.id == "overview") ? " active" : ""
    sections.append("""
      <section id="tab-\(tab.id)" class="tab-pane\(active)">
        \(body)
      </section>
    """)
}
```

- [ ] **Step 2: Add `renderStatus`**

Deterministic HTML, escaped via the existing `escapeHTML`. Empty fields render
as `—`.

```swift
/// Render the auto-synthesized status snapshot as an HTML block. Deterministic;
/// shown at the top of the Overview tab so the page reads as a one-pager.
static func renderStatus(_ s: ProjectStatus) -> String {
    func row(_ label: String, _ value: String) -> String {
        "<div class=\"status-row\"><span class=\"status-k\">\(escapeHTML(label))</span>"
        + "<span class=\"status-v\">\(value)</span></div>"
    }
    let dash = "—"
    let lastSession = s.lastSession.map {
        "\($0.date.map(Self.shortDate) ?? "") \(escapeHTML($0.title))".trimmingCharacters(in: .whitespaces)
    } ?? dash
    let decision = s.recentDecision.map { escapeHTML($0.title) } ?? dash
    let tasks = "\(s.activeTaskCount) active"
        + (s.blockedTaskCount > 0 ? " · \(s.blockedTaskCount) blocked" : "")
    let ports = s.runningPorts.isEmpty
        ? "none"
        : s.runningPorts.map { ":\($0)" }.joined(separator: " ")
    let tagline = s.tagline.map(escapeHTML) ?? ""

    return """
    <div class="status-card">
      <div class="status-head">
        <span class="status-title">Snapshot</span>
        <span class="status-tag">\(tagline)</span>
      </div>
      \(row("Last session", lastSession))
      \(row("Tasks", escapeHTML(tasks)))
      \(row("Recent decision", decision))
      \(row("Commits / 7d", escapeHTML("\(s.commits7d)")))
      \(row("Running", escapeHTML(ports)))
      \(row("Health", escapeHTML(s.health.label)))
    </div>
    """
}

/// "Jun 19" style short date for the snapshot.
private static func shortDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f.string(from: d)
}
```

- [ ] **Step 3: Add minimal styles for the status card**

Append to the `sharedStyles` string (find it: `grep -n "sharedStyles" Sources/DevDash/Scanners/ProductDocGenerator.swift`) inside its `<style>` block:

```css
.status-card{border:1px solid var(--border,#2a2a2a);border-radius:10px;padding:14px 16px;margin:0 0 20px;background:rgba(255,255,255,0.02)}
.status-head{display:flex;align-items:baseline;gap:10px;margin-bottom:8px}
.status-title{font-weight:600;letter-spacing:.04em;text-transform:uppercase;font-size:11px;opacity:.7}
.status-tag{font-size:12px;opacity:.6}
.status-row{display:flex;justify-content:space-between;gap:12px;padding:3px 0;font-size:13px}
.status-k{opacity:.6}
.status-v{font-variant-numeric:tabular-nums;text-align:right}
```

- [ ] **Step 4: Pass the status from both `generate` callers**

In `Sources/DevDash/Views/Tabs/ProductTabView.swift` `regen(project:)` (call at line ~254), add the argument:

```swift
_ = ProductDocGenerator.generate(
    projectName: project.name,
    projectPath: project.path,
    meta: meta,
    template: template,
    tasks: tasks,
    status: store.projectStatus(for: project.path)
)
```

In `Sources/DevDash/DashboardStore.swift` `regenerateRoadmap` (call at line ~614), add `status: projectStatus(for: projectPath)` as the trailing argument to that `ProductDocGenerator.generate(...)` call.

- [ ] **Step 5: Build, launch, and observe**

Run: `bash run.sh`
Expected: app launches. Select a project, open the **Product** tab. The Overview
pane shows a "Snapshot" card at the top with Last session / Tasks / Recent
decision / Commits 7d / Running / Health. Switch to a project with no devlogs →
Last session / Recent decision show `—` (no crash).

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Scanners/ProductDocGenerator.swift Sources/DevDash/Views/Tabs/ProductTabView.swift Sources/DevDash/DashboardStore.swift
git commit -m "render auto status snapshot at top of living-doc Overview"
```

---

## Self-Review

**Spec coverage:**
- `ProjectStatus` value type → Task 1. ✓
- `LoreReader` (extract shared parser) → Task 2. ✓
- `ProjectStatusSynthesizer` (pure, deterministic) → Task 3. ✓
- `store.projectStatus(for:)` data-flow entry → Task 4. ✓
- HTML status block at top of Overview, regenerated on `regen()` → Task 5. ✓
- Coexists with manual "Status Reports" (Snapshot ≠ Status Reports) → Task 5 titles the card "Snapshot". ✓
- Error handling: missing lore → `nil` → `—`; no servers → "none"; no heatmap → 0. ✓ (Tasks 2,3,5)
- Phase 2 native board → intentionally **out of scope**; `ProjectStatus` is `Codable` to enable it later. ✓

**Type consistency:** `ProjectStatus`/`LoreRef` field names match across Tasks 1, 3, 5. `synthesize(...)` signature in Task 3 matches the call in Task 4. `generate(..., status:)` in Task 5 matches both call-site edits. `kanbanColumn`, `ownerIsHuman`, `dayCounts`, `health.label`, `escapeHTML`, `sharedStyles` all verified against current source.

**Placeholder scan:** Task 2 Step 2 intentionally instructs pasting the parser body copied in Step 1 (the source-of-truth is the existing function; reproducing it blindly risks drift) — this is a copy-from-current-source instruction, not a TODO.
