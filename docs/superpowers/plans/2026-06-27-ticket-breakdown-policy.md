# Ticket Breakdown + Policy Lore Type Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users break a ticket into child tasks on demand (Claude suggests, user reviews inline before write), driven by a reusable `policy` lore type the app reads and injects into prompts.

**Architecture:** A new `policy` lore doc type holds agent-behavior policies as data; its frontmatter (`applies_to`/`trigger`/`status`/`priority`) is routing metadata. A `PolicyStore` scanner reads policy docs; `DashboardStore` queries active policies by scope+trigger and injects their bodies into (a) a new on-demand `suggestTasksForTicket` run and (b) the existing `launchClaudeForTicket` seed prompt. The ticket context menu triggers breakdown; suggestions are reviewed in an inline checklist inside the expanded ticket and accepted into child tasks via the existing `addTask`.

**Tech Stack:** Swift / SwiftUI (macOS 14+), no external deps. Lore CLI for doc indexing. Headless self-tests via `--selftest-*` CLI flags (no XCTest).

## Global Constraints

- No external Swift dependencies — stdlib + AppKit/WebKit only.
- Lore frontmatter must be single-line scalars/inline lists so both `lore` (gray-matter) and the app's line-based parser read them.
- Reuse existing helpers: `TaskStore.parseTaskFrontmatter`, `TaskStore.yamlStr`, `TaskStore.setOrAddFrontmatterKey`, `parseSuggestedTasks`, `addTask(...:ticket:)`. DRY.
- Tests are headless enums with `runIfRequested()` wired in `App.swift`, run via `swift build` then `.build/debug/DevDash --selftest-<name>`, printing `ok`/`FAIL` lines and exiting non-zero on failure.
- Commit directly to main, imperative mood, concise messages.
- Launch-template is intentionally excluded from the breakdown prompt.

---

### Task 1: Policy lore type + first policy doc

**Files:**
- Create: `docs/.lore/types/policy.schema.yaml`
- Create: `docs/policies/0001-ticket-breakdown.md`

**Interfaces:**
- Produces: a `policy` lore type (dir `policies`, list fields `applies_to`/`trigger`, enum `status`, int `priority`) and one active policy doc `0001-ticket-breakdown.md` with `applies_to: [ticket]`, `trigger: [on_demand, on_work]`, `status: active`.

- [ ] **Step 1: Create the policy schema**

Create `docs/.lore/types/policy.schema.yaml`:

```yaml
name: policy
dir: policies
heading: Policies
id: { strategy: sequential, pad: 4 }
body: free
groupBy: { field: status, order: [active, draft, deprecated] }
frontmatter:
  - { name: title,      type: string,  required: true }
  - { name: applies_to, type: list,    required: true }   # lore types or scopes: ticket, task, project, pr, release, session, any
  - { name: trigger,    type: list }                       # core wired: on_demand, on_work, always
  - { name: status,     type: enum, values: [draft, active, deprecated], required: true }
  - { name: priority,   type: int }
index:
  - { header: "#", source: id }
  - { header: Policy, source: title, link: true }
  - { header: Applies to, source: applies_to }
  - { header: Trigger, source: trigger }
  - { header: Status, source: status }
```

- [ ] **Step 2: Create the first policy doc**

Create `docs/policies/0001-ticket-breakdown.md`:

```markdown
---
lore_type: policy
title: Break tickets into tasks
applies_to: [ticket]
trigger: [on_demand, on_work]
status: active
---
Break a ticket into child tasks when it implies more than one distinct
deliverable, can't be finished in a single focused sitting, or spans multiple
files or stages. Don't break down a ticket that is already a single concrete
unit of work.

Produce 3–6 tasks. Each must be specific to *this* ticket — not generic
best-practice boilerplate. Don't duplicate tasks the ticket already has.

Output each task on its own line as exactly: `TASK: <title>`
```

- [ ] **Step 3: Reindex and validate the new type**

Run: `lore reindex policy && lore validate policy`
Expected: reindex writes `docs/policies/index.md`; validate reports no errors for the `policy` type.

(If `lore` isn't found in a non-interactive shell, use `node ~/.local/bin/lore reindex policy && node ~/.local/bin/lore validate policy`.)

- [ ] **Step 4: Commit**

```bash
git add docs/.lore/types/policy.schema.yaml docs/policies/
git commit -m "feat(lore): add policy doc type + ticket-breakdown policy"
```

---

### Task 2: PolicyStore — model, read, list parsing

**Files:**
- Create: `Sources/DevDash/Scanners/PolicyStore.swift`
- Create: `Sources/DevDash/PolicySelfTest.swift`
- Modify: `Sources/DevDash/App.swift:11-14` (add `PolicySelfTest.runIfRequested()`)

**Interfaces:**
- Produces:
  - `struct Policy { let id: String; let title: String; let appliesTo: [String]; let trigger: [String]; let status: PolicyStatus; let priority: Int?; let body: String }`
  - `enum PolicyStatus: String { case draft, active, deprecated }`
  - `enum PolicyStore { static func dir(for projectPath: String) -> String; static func read(_ projectPath: String) -> [Policy] }`
  - `enum PolicySelfTest { static func runIfRequested() }` triggered by `--selftest-policy`.

- [ ] **Step 1: Write the failing test**

Create `Sources/DevDash/PolicySelfTest.swift`:

```swift
import Foundation

/// Headless deterministic checks for PolicyStore + policy querying.
///   DevDash --selftest-policy
/// Runs entirely in a fresh temp directory, prints PASS/FAIL per check, exits.
enum PolicySelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-policy") else { return }
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { print("  ok   \(label)") }
            else     { failures.append(label); print("  FAIL \(label)") }
        }

        checkPolicyReadRoundTrip(check)

        let msg = failures.isEmpty
            ? "policy-selftest: ALL PASS"
            : "policy-selftest: \(failures.count) FAILURE(S)"
        print(msg)
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func makeTempProject(_ suffix: String) -> String {
        let dir = NSTemporaryDirectory() + "devdash-policy-selftest-\(suffix)"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writePolicy(_ projectPath: String, filename: String, contents: String) {
        let dir = "\(projectPath)/docs/policies"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? contents.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    private static func checkPolicyReadRoundTrip(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("read")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        writePolicy(proj, filename: "0001-breakdown.md", contents: """
        ---
        lore_type: policy
        title: Break tickets into tasks
        applies_to: [ticket, task]
        trigger: [on_demand, on_work]
        status: active
        priority: 10
        ---
        Break a ticket into child tasks when appropriate.
        Output each as: `TASK: <title>`
        """)

        let policies = PolicyStore.read(proj)
        guard let p = policies.first(where: { $0.id == "0001" }) else {
            check(false, "read: policy 0001 not found"); return
        }
        check(p.title == "Break tickets into tasks", "read: title round-trip")
        check(p.appliesTo == ["ticket", "task"],     "read: applies_to list parsed")
        check(p.trigger == ["on_demand", "on_work"], "read: trigger list parsed")
        check(p.status == .active,                    "read: status parsed")
        check(p.priority == 10,                       "read: priority parsed")
        check(p.body.contains("TASK: <title>"),       "read: body captured")
    }
}
```

- [ ] **Step 2: Wire the self-test into App.swift**

Modify `Sources/DevDash/App.swift` — add the line after the existing self-test calls (around line 14):

```swift
        TaskStoreSelfTest.runIfRequested()  // exits early when launched with --selftest-taskstore
        PolicySelfTest.runIfRequested()     // exits early when launched with --selftest-policy
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — compile error, `cannot find 'PolicyStore' in scope`.

- [ ] **Step 4: Write minimal implementation**

Create `Sources/DevDash/Scanners/PolicyStore.swift`:

```swift
import Foundation

/// Status of a policy doc. Only `.active` policies are injected into prompts.
enum PolicyStatus: String, Codable, Hashable {
    case draft, active, deprecated
}

/// A single agent-behavior policy, backed by a lore `policy` doc
/// (`docs/policies/<id>-<slug>.md`). `id` is the numeric filename prefix.
///
/// Mirrors `TicketStore`'s lore-adapter pattern: same frontmatter helpers,
/// numeric-id tolerance. `applies_to` / `trigger` are inline YAML lists
/// (`[a, b]`) parsed by `parseList` below.
struct Policy: Identifiable, Hashable {
    let id: String
    let title: String
    let appliesTo: [String]
    let trigger: [String]
    let status: PolicyStatus
    let priority: Int?
    let body: String
}

enum PolicyStore {

    static func dir(for projectPath: String) -> String {
        "\(projectPath)/docs/policies"
    }

    static func read(_ projectPath: String) -> [Policy] {
        let policyDir = dir(for: projectPath)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: policyDir) else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".md") && $0.lowercased() != "index.md" }
            .sorted()
            .compactMap { filename -> Policy? in
                let numericPrefix = String(filename.prefix(while: { $0.isNumber }))
                guard !numericPrefix.isEmpty,
                      let raw = try? String(contentsOfFile: "\(policyDir)/\(filename)", encoding: .utf8)
                else { return nil }
                return parsePolicy(id: numericPrefix, raw: raw)
            }
    }

    /// Parse an inline YAML list value (`[a, b, c]`) into trimmed, non-empty
    /// strings. Tolerates a bare scalar (`a`) → `["a"]`.
    static func parseList(_ rawValue: String?) -> [String] {
        guard var v = rawValue?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return [] }
        if v.hasPrefix("[") && v.hasSuffix("]") {
            v = String(v.dropFirst().dropLast())
        }
        return v.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }

    private static func parsePolicy(id: String, raw: String) -> Policy? {
        let fm = TaskStore.parseTaskFrontmatter(raw)
        guard let title = fm["title"], !title.isEmpty else { return nil }
        let status = PolicyStatus(rawValue: fm["status"] ?? "") ?? .draft
        return Policy(
            id: id,
            title: title,
            appliesTo: parseList(fm["applies_to"]),
            trigger: parseList(fm["trigger"]),
            status: status,
            priority: fm["priority"].flatMap { Int($0) },
            body: extractBody(from: raw)
        )
    }

    /// Body = everything after the closing frontmatter fence, trimmed.
    private static func extractBody(from raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var fences = 0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("---") {
                fences += 1
                if fences == 2 {
                    return lines[(i + 1)...].joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return ""
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift build 2>&1 | tail -3 && .build/debug/DevDash --selftest-policy`
Expected: all `ok` lines, final line `policy-selftest: ALL PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Scanners/PolicyStore.swift Sources/DevDash/PolicySelfTest.swift Sources/DevDash/App.swift
git commit -m "feat: PolicyStore reads policy lore docs (list-field parsing)"
```

---

### Task 3: DashboardStore — load + query policies

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift` (add `projectPolicies`, `reloadPolicies`, `policies(for:appliesTo:trigger:)`)
- Modify: `Sources/DevDash/PolicySelfTest.swift` (add `checkPolicyQuery`)

**Interfaces:**
- Consumes: `PolicyStore.read`, `Policy`, `PolicyStatus` (Task 2).
- Produces:
  - `@Published var projectPolicies: [String: [Policy]]`
  - `func reloadPolicies(for projectPath: String)`
  - `func policies(for projectPath: String, appliesTo scope: String, trigger: String) -> [Policy]`
    — returns `status == .active` policies whose `appliesTo` contains `scope` **or** `"any"`, **and** whose `trigger` contains `trigger`, sorted by `(priority ?? Int.max, numeric id)`.

- [ ] **Step 1: Write the failing test**

Add to `Sources/DevDash/PolicySelfTest.swift` — register the call in `runIfRequested()` right after `checkPolicyReadRoundTrip(check)`:

```swift
        checkPolicyReadRoundTrip(check)
        checkPolicyQuery(check)
```

And add the method:

```swift
    @MainActor
    private static func checkPolicyQuery(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("query")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        // active ticket policy, priority 20
        writePolicy(proj, filename: "0001-a.md", contents: """
        ---
        lore_type: policy
        title: A
        applies_to: [ticket]
        trigger: [on_demand]
        status: active
        priority: 20
        ---
        body A
        """)
        // active ticket policy, priority 5 (should sort first)
        writePolicy(proj, filename: "0002-b.md", contents: """
        ---
        lore_type: policy
        title: B
        applies_to: [any]
        trigger: [on_demand, on_work]
        status: active
        priority: 5
        ---
        body B
        """)
        // draft — must be excluded
        writePolicy(proj, filename: "0003-c.md", contents: """
        ---
        lore_type: policy
        title: C
        applies_to: [ticket]
        trigger: [on_demand]
        status: draft
        ---
        body C
        """)
        // wrong trigger — excluded for on_demand
        writePolicy(proj, filename: "0004-d.md", contents: """
        ---
        lore_type: policy
        title: D
        applies_to: [ticket]
        trigger: [always]
        status: active
        ---
        body D
        """)

        let store = DashboardStore()
        let onDemand = store.policies(for: proj, appliesTo: "ticket", trigger: "on_demand")
        check(onDemand.map { $0.id } == ["0002", "0001"],
              "query: active+scope+trigger, ordered by priority (B before A)")
        check(!onDemand.contains { $0.id == "0003" }, "query: draft excluded")
        check(!onDemand.contains { $0.id == "0004" }, "query: wrong-trigger excluded")
        check(onDemand.contains { $0.id == "0002" },  "query: 'any' scope matches ticket")

        let onWork = store.policies(for: proj, appliesTo: "ticket", trigger: "on_work")
        check(onWork.map { $0.id } == ["0002"], "query: on_work matches only B")
    }
```

Note: `DashboardStore` is `@MainActor`; the check method is annotated to construct it.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `value of type 'DashboardStore' has no member 'policies'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/DevDash/DashboardStore.swift`, near the other `@Published` project dictionaries (e.g. by `projectTickets`), add:

```swift
    @Published var projectPolicies: [String: [Policy]] = [:]
```

Add these methods (place near `reloadTickets`):

```swift
    /// Re-read policy docs for a project into `projectPolicies`.
    func reloadPolicies(for projectPath: String) {
        projectPolicies[projectPath] = PolicyStore.read(projectPath)
    }

    /// Active policies whose scope contains `scope` (or "any") and whose
    /// trigger list contains `trigger`, ordered by (priority ?? max, numeric id).
    func policies(for projectPath: String, appliesTo scope: String, trigger: String) -> [Policy] {
        let all = projectPolicies[projectPath] ?? PolicyStore.read(projectPath)
        return all
            .filter { $0.status == .active }
            .filter { $0.appliesTo.contains(scope) || $0.appliesTo.contains("any") }
            .filter { $0.trigger.contains(trigger) }
            .sorted { lhs, rhs in
                let lp = lhs.priority ?? Int.max
                let rp = rhs.priority ?? Int.max
                if lp != rp { return lp < rp }
                return (Int(lhs.id) ?? 0) < (Int(rhs.id) ?? 0)
            }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build 2>&1 | tail -3 && .build/debug/DevDash --selftest-policy`
Expected: `policy-selftest: ALL PASS`, exit 0.

- [ ] **Step 5: Load policies during project scan**

Find where `reloadTickets(for:)` is called during a project scan/refresh (grep: `reloadTickets(for:`). Add a sibling `reloadPolicies(for:)` call at each scan site so `projectPolicies` is populated alongside tickets.

Run: `swift build 2>&1 | tail -3`
Expected: Build complete.

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/DashboardStore.swift Sources/DevDash/PolicySelfTest.swift
git commit -m "feat: DashboardStore policy loading + scope/trigger query"
```

---

### Task 4: Pure prompt helpers — policy text + breakdown prompt

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift` (add `ticketPolicyText`, `buildTicketBreakdownPrompt`)
- Modify: `Sources/DevDash/PolicySelfTest.swift` (add `checkBreakdownPrompt`)

**Interfaces:**
- Consumes: `policies(for:appliesTo:trigger:)` (Task 3), `Ticket`, `tasksV2(for:)`.
- Produces:
  - `func ticketPolicyText(projectPath: String, trigger: String) -> String` — joined bodies of `ticket`-scoped active policies for `trigger`, separated by blank lines; `""` if none.
  - `func buildTicketBreakdownPrompt(ticket: Ticket, existingTaskTitles: [String], projectPath: String, deep: Bool) -> String` — assembles the breakdown prompt from policy text + ticket title/notes/category + existing task titles. Includes the literal `TASK:` instruction. Excludes launch-template. When `deep`, adds a line inviting the agent to read relevant code first.

- [ ] **Step 1: Write the failing test**

Add to `Sources/DevDash/PolicySelfTest.swift` — register in `runIfRequested()`:

```swift
        checkPolicyQuery(check)
        checkBreakdownPrompt(check)
```

Add the method:

```swift
    @MainActor
    private static func checkBreakdownPrompt(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("prompt")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        writePolicy(proj, filename: "0001-breakdown.md", contents: """
        ---
        lore_type: policy
        title: Break tickets into tasks
        applies_to: [ticket]
        trigger: [on_demand, on_work]
        status: active
        ---
        POLICY_MARKER produce 3-6 tasks. Output each as: `TASK: <title>`
        """)

        let store = DashboardStore()
        store.reloadPolicies(for: proj)

        let ticket = Ticket(
            id: "0007", title: "Implement login", status: .open, owner: .none,
            category: .engineering, pr: nil, createdAt: Date(), completedAt: nil,
            notes: "Email + password.", priority: nil, effort: nil
        )

        let quick = store.buildTicketBreakdownPrompt(
            ticket: ticket, existingTaskTitles: ["Add form UI"], projectPath: proj, deep: false)
        check(quick.contains("POLICY_MARKER"),        "prompt: injects policy body")
        check(quick.contains("Implement login"),       "prompt: includes ticket title")
        check(quick.contains("Email + password."),     "prompt: includes ticket notes")
        check(quick.contains("Add form UI"),           "prompt: lists existing tasks (dedupe)")
        check(quick.contains("TASK:"),                 "prompt: carries TASK: instruction")

        let deep = store.buildTicketBreakdownPrompt(
            ticket: ticket, existingTaskTitles: [], projectPath: proj, deep: true)
        check(deep.lowercased().contains("read"),      "prompt: deep mode invites reading code")

        let policyText = store.ticketPolicyText(projectPath: proj, trigger: "on_work")
        check(policyText.contains("POLICY_MARKER"),    "policyText: on_work returns body")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: FAIL — `has no member 'buildTicketBreakdownPrompt'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/DevDash/DashboardStore.swift`, add near the other prompt builders (e.g. by `suggestTasksForStage`):

```swift
    /// Joined bodies of active `ticket`-scoped policies for a trigger.
    /// Empty string when none match.
    func ticketPolicyText(projectPath: String, trigger: String) -> String {
        policies(for: projectPath, appliesTo: "ticket", trigger: trigger)
            .map { $0.body }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Build the on-demand ticket-breakdown prompt. Policy text first, then
    /// ticket context, then existing tasks to avoid duplicates. Launch-template
    /// is intentionally not included.
    func buildTicketBreakdownPrompt(ticket: Ticket,
                                    existingTaskTitles: [String],
                                    projectPath: String,
                                    deep: Bool) -> String {
        let policy = ticketPolicyText(projectPath: projectPath, trigger: "on_demand")
        let existing = existingTaskTitles.isEmpty
            ? "(none yet)"
            : existingTaskTitles.map { "- \($0)" }.joined(separator: "\n")
        let deepLine = deep
            ? "\nFirst read the relevant code in this project to ground your suggestions.\n"
            : ""
        return """
        \(policy.isEmpty ? "Break this ticket into concrete child tasks." : policy)
        \(deepLine)
        Ticket: \(ticket.title)
        Category: \(ticket.category.rawValue)
        Notes: \(ticket.notes ?? "(none)")

        Existing tasks on this ticket (don't duplicate these):
        \(existing)

        Output each suggested task on its own line as exactly: `TASK: <title>`
        """
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build 2>&1 | tail -3 && .build/debug/DevDash --selftest-policy`
Expected: `policy-selftest: ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/DashboardStore.swift Sources/DevDash/PolicySelfTest.swift
git commit -m "feat: ticket-breakdown prompt builder + policy-text injection"
```

---

### Task 5: Generation run + launch-prompt injection

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift` (add `suggestTasksForTicket`; inject policy text into `launchClaudeForTicket`)

**Interfaces:**
- Consumes: `buildTicketBreakdownPrompt`, `ticketPolicyText` (Task 4), `runClaude(prompt:projectPath:allowEdits:kind:)`, `tasksV2(for:)`, `projectTickets`, existing `parseSuggestedTasks(from:projectPath:)`.
- Produces:
  - `func suggestTasksForTicket(ticketId: String, projectPath: String, deep: Bool) async` — resolves the ticket + its existing child task titles, builds the prompt, runs `claude -p` with `kind: .taskSuggestion`. (Results are read by the UI via `parseSuggestedTasks`.)

- [ ] **Step 1: Add the generation method**

In `Sources/DevDash/DashboardStore.swift`, near `suggestTasksForStage`:

```swift
    /// Ask claude -p to suggest child tasks for a ticket, guided by the active
    /// ticket-breakdown policy. Output is `TASK: <title>` lines parsed later by
    /// `parseSuggestedTasks`. `deep` invites the agent to read code first.
    func suggestTasksForTicket(ticketId: String, projectPath: String, deep: Bool) async {
        guard let ticket = (projectTickets[projectPath] ?? [])
            .first(where: { TicketStore.numEq($0.id, ticketId) }) else { return }

        let existingTitles = tasksV2(for: projectPath)
            .filter { t in (t.ticket).map { TicketStore.numEq($0, ticketId) } ?? false }
            .map { $0.title }

        let prompt = buildTicketBreakdownPrompt(
            ticket: ticket, existingTaskTitles: existingTitles,
            projectPath: projectPath, deep: deep)

        await runClaude(prompt: prompt, projectPath: projectPath,
                        allowEdits: false, kind: .taskSuggestion)
    }
```

(`TaskItem.ticket` is `String?` — Models.swift:309 — so the `.map { … } ?? false` above is correct as written.)

- [ ] **Step 2: Inject policy text into the launch prompt**

The launch prompt is assembled in `launchClaudeInDirectory` (DashboardStore.swift:2665). Gate the injection on `task.ticket != nil` so standalone (non-ticket) task launches are unaffected. Replace the existing `let prompt = """ … """` block (lines 2665-2676) with a policy-preamble-prefixed version:

```swift
        let policyPreamble: String
        if task.ticket != nil {
            let text = ticketPolicyText(projectPath: projectPath, trigger: "on_work")
            policyPreamble = text.isEmpty ? "" : text + "\n\n"
        } else {
            policyPreamble = ""
        }

        let prompt = """
        \(policyPreamble)Task \(task.id): \(task.title)
        Category: \(task.category.label)
        \(task.notes.map { "Notes:\n\($0)" } ?? "")\(branchLine)

        Work on this task in this project.

        As you work, report progress to the dashboard with the `lore` CLI:
        - Update this task's status:  lore set-status task \(task.id) <new-status>
        - If you open a PR, file a review task:  lore add task --title "Review: <desc>" --field pr=<PR_URL> --field category=qa
        - Record an artifact (summary, test plan, report):  lore add artifact --title "<name>" --field task=\(task.id) --field kind=summary
        """
```

(Only the `policyPreamble` lines and the leading `\(policyPreamble)` interpolation are new; the rest is the existing prompt verbatim.)

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete.

- [ ] **Step 4: Re-run the policy self-test (no regressions)**

Run: `.build/debug/DevDash --selftest-policy`
Expected: `policy-selftest: ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/DashboardStore.swift
git commit -m "feat: suggestTasksForTicket + on_work policy injection on launch"
```

---

### Task 6: Ticket UI — context menu + inline checklist review

**Files:**
- Modify: `Sources/DevDash/Views/Tabs/LoreTasksView.swift` (context menu items on `ticketHeader`; suggestion state; inline checklist in the expanded ticket body)

**Interfaces:**
- Consumes: `store.suggestTasksForTicket(ticketId:projectPath:deep:)` (Task 5), `store.parseSuggestedTasks(from:projectPath:)`, `store.addTask(projectPath:title:ticket:)`, `store.claudeTasks`.
- Produces: a `@State private var ticketSuggestions: [String: [SuggestedDraft]]` keyed by ticket id, plus a running/awaiting id; the inline checklist rendered in the expanded ticket body.

- [ ] **Step 1: Add suggestion state + draft model**

In `LoreTasksView` (the view struct holding `ticketHeader`/`reload`), add state and a small model:

```swift
    struct SuggestedDraft: Identifiable {
        let id = UUID()
        var title: String
        var checked: Bool = true
    }
    @State private var ticketSuggestions: [String: [SuggestedDraft]] = [:]
    @State private var suggestingTicketId: String? = nil
    @State private var suggestRunId: UUID? = nil
```

- [ ] **Step 2: Add the context-menu trigger**

In `ticketHeader`, extend the existing `.contextMenu` (the `Section("Claude")` block) with:

```swift
            Section("Break down") {
                Button {
                    startBreakdown(ticketId: ticket.id, deep: false)
                } label: { Label("Break into tasks", systemImage: "list.bullet.indent") }
                Button {
                    startBreakdown(ticketId: ticket.id, deep: true)
                } label: { Label("Break into tasks (read code)", systemImage: "doc.text.magnifyingglass") }
            }
```

- [ ] **Step 3: Add the breakdown driver methods**

Add to `LoreTasksView`:

```swift
    private func startBreakdown(ticketId: String, deep: Bool) {
        suggestingTicketId = ticketId
        ticketSuggestions[ticketId] = nil
        expandedTickets.insert(ticketId)
        Task {
            await store.suggestTasksForTicket(ticketId: ticketId, projectPath: projectPath, deep: deep)
            // runClaude is awaited, so the run has finished. Pick the most recent
            // task-suggestion run by kind (robust against other concurrent runs).
            let runs = store.claudeTasks[projectPath] ?? []
            guard let run = runs.last(where: { $0.kind == .taskSuggestion }) else {
                suggestingTicketId = nil; return
            }
            let titles = store.parseSuggestedTasks(from: run.id, projectPath: projectPath)
            ticketSuggestions[ticketId] = titles.map { SuggestedDraft(title: $0) }
            suggestingTicketId = nil
        }
    }

    private func acceptSuggestions(ticketId: String) {
        let drafts = (ticketSuggestions[ticketId] ?? []).filter { $0.checked }
        for d in drafts where !d.title.trimmingCharacters(in: .whitespaces).isEmpty {
            store.addTask(projectPath: projectPath, title: d.title, ticket: ticketId)
        }
        ticketSuggestions[ticketId] = nil
        store.reloadTickets(for: projectPath)
        reload()
    }
```

(If `ClaudeTask` exposes a completion flag/status, prefer matching the run by `kind == .taskSuggestion && status == .done` over `runs.last`. Grep `struct ClaudeTask` to confirm fields.)

- [ ] **Step 4: Render the inline checklist in the expanded ticket body**

Find where the expanded ticket's child tasks are listed (the `if isExpanded { ... }` body that renders task rows and the quick-create row). Add, above the task rows:

```swift
            if suggestingTicketId == ticket.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Suggesting tasks…").font(DSFont.micro).foregroundColor(.secondary)
                }
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
            } else if let drafts = ticketSuggestions[ticket.id] {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    Text("Suggested tasks (Claude)").font(DSFont.micro).foregroundColor(.secondary)
                    if drafts.isEmpty {
                        Text("No tasks suggested — try “read code” mode or add manually.")
                            .font(DSFont.micro).foregroundColor(.secondary)
                    } else {
                        ForEach(Array(drafts.enumerated()), id: \.element.id) { idx, _ in
                            HStack(spacing: 6) {
                                Toggle("", isOn: Binding(
                                    get: { ticketSuggestions[ticket.id]?[idx].checked ?? false },
                                    set: { ticketSuggestions[ticket.id]?[idx].checked = $0 }
                                )).labelsHidden().toggleStyle(.checkbox)
                                TextField("Task title", text: Binding(
                                    get: { ticketSuggestions[ticket.id]?[idx].title ?? "" },
                                    set: { ticketSuggestions[ticket.id]?[idx].title = $0 }
                                )).textFieldStyle(.plain).font(DSFont.micro)
                            }
                        }
                    }
                    HStack(spacing: DSSpace.sm) {
                        let n = drafts.filter { $0.checked }.count
                        Button("Add \(n) task\(n == 1 ? "" : "s")") { acceptSuggestions(ticketId: ticket.id) }
                            .disabled(n == 0)
                        Button("Cancel") { ticketSuggestions[ticket.id] = nil }
                    }
                }
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.xs)
            }
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete (Swift-6 concurrency *warnings* OK; no errors).

- [ ] **Step 6: Manual verification (SwiftUI — no headless test)**

Run: `bash run.sh`
Then in the app:
1. Open the Lore Tasks tab; right-click a **draft** ticket header → **Break into tasks**.
2. Confirm the ticket expands and shows "Suggesting tasks…", then a checklist of `TASK:` titles.
3. Uncheck one, edit another's title, click **Add N tasks**.
4. Confirm N child tasks appear under the ticket, the "draft" pill disappears (rollup → derived), and the task `.md` files have `ticket:` set:

```bash
ls docs/tasks/ && grep -l "ticket:" docs/tasks/*.md
```

Expected: new task files exist with the ticket id in frontmatter; ticket now shows a progress count instead of "draft".

- [ ] **Step 7: Commit**

```bash
git add Sources/DevDash/Views/Tabs/LoreTasksView.swift
git commit -m "feat: ticket context-menu breakdown + inline suggestion review"
```

---

### Task 7: ADR + devlog

**Files:**
- Create: `docs/decisions/0012-agent-native-policy-lore-type.md`
- Create: a devlog entry via the `/devlog` command

**Interfaces:** none (docs only).

- [ ] **Step 1: Write the ADR**

Create `docs/decisions/0012-agent-native-policy-lore-type.md` capturing: the decision to add a `policy` lore type + app-side prompt injection; options considered (lore schema `prompt:`, project CLAUDE.md prose, app-injected policy docs); why open-list `applies_to`/`trigger` (the 16-policy stress test); and that policy docs are living instructions while ADRs are history. Reference the spec at `docs/superpowers/specs/2026-06-27-ticket-breakdown-policy-design.md`.

- [ ] **Step 2: Reindex + validate decisions**

Run: `lore reindex decisions && lore validate decisions`
Expected: no errors.

- [ ] **Step 3: Write the devlog**

Invoke the `/devlog` command to record this session's work (policy type + ticket breakdown + the earlier draft-ticket status feature). Then:

Run: `lore reindex devlog && lore validate devlog`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add docs/decisions/ docs/devlog/
git commit -m "docs: ADR 0012 policy lore type + devlog"
```

---

## Notes for the implementer

- **Verified facts (already confirmed against the code):** `TaskItem.ticket` is `String?` (Models.swift:309); `ClaudeTask` has `id: UUID`, `kind: Kind`, `status: ClaudeTaskStatus`, `output: [String]` (Models.swift:731); the ticket launch prompt is built in `launchClaudeInDirectory` (DashboardStore.swift:2665), and a ticket launch always sets `task.ticket` before reaching it (`launchClaudeForTicket`, 2233).
- **SourceKit "Cannot find X in scope"** errors are stale-index noise — trust `swift build`.
- The only task without an automated test is Task 6 (SwiftUI) — follow its manual steps exactly and paste the `grep` output as evidence.
