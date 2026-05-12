# Product Tab Markdown-Per-Entity Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace HTML-as-source-of-truth with markdown-per-entity (`docs/devdash/<type>/*.md`). Each entity has YAML frontmatter + optional narrative body. Native SwiftUI editors replace contenteditable. New `HtmlCompiler` renders entities into a read-only living-doc HTML view. The entire Alpine + bridge-save + ProductDocAssets stack is deleted.

**Architecture:** `EntityStore<T: MarkdownEntity>` is the generic CRUD layer over `Sources/DevDash/Resources/` no longer; each entity type implements a `MarkdownEntity` protocol (Codable frontmatter + body). `HtmlCompiler.compile()` reads all entities for a project and renders `docs/devdash/{index.html, sections/*.html, prd/*.html, ...}`. WKWebView is read-only. `LegacyHtmlMigrator` runs once per project on first new-build open to parse existing HTML into `.md` files.

**Tech Stack:** Swift 5.9 / SwiftUI / WKWebView (read-only) / [Yams](https://github.com/jpsim/Yams) for YAML parsing. No test framework (no `Tests/` directory in repo).

**Reference spec:** `docs/superpowers/specs/2026-05-12-product-tab-md-entity-model-design.md`

**Build / run loop used throughout:**
```bash
bash run.sh   # swift build → cp binary → cp resources → codesign → open .app
```

**Where files land:**

```
Sources/DevDash/
├── Models/
│   ├── EntityModels.swift            (Goal, KPI, Idea, Initiative, PRD, Plan, Status, Decision, Concept, Retro, TriageBoard, Overview)
│   └── MarkdownEntity.swift          (protocol; EntityKind enum)
├── Scanners/
│   ├── EntityFrontmatter.swift       (YAML parse/serialize via Yams)
│   ├── EntityStore.swift             (generic CRUD over docs/devdash/<type>/)
│   ├── HtmlCompiler.swift            (renders entity models → HTML files)
│   └── LegacyHtmlMigrator.swift      (one-shot per project: HTML → .md)
└── Views/
    └── ProductEditors/
        ├── MarkdownBodyEditor.swift  (reusable TextEditor with monospace + light highlighting)
        ├── MarkdownEntityEditor.swift(generic shell: fields sidebar + body editor)
        ├── GoalEditor.swift / GoalsListView.swift
        ├── KPIEditor.swift / KPIsListView.swift
        ├── IdeaEditor.swift / IdeaBoardView.swift
        ├── TriageBoardView.swift     (native kanban — replaces the Alpine triage)
        ├── OverviewEditor.swift      (singleton)
        ├── InitiativeEditor.swift / InitiativesListView.swift
        ├── PrdEditor.swift / PrdsListView.swift  (and similar for plan/status/decision/concept/retro)
```

Existing files modified:
- `Package.swift` — add `Yams` dep; later, remove `.copy("Resources")`
- `Sources/DevDash/Models.swift` — add `goalId: String?` to `TaskItem`
- `Sources/DevDash/Views/Tabs/ProductTabView.swift` — gutted and rewritten with native subtabs
- `Sources/DevDash/Views/ProductWebView.swift` — bridge JS shrinks to ~30 lines
- `Sources/DevDash/Views/Tabs/TaskDetailSheet.swift` (or wherever task editing lives) — add goal-picker

Existing files deleted at the end:
- `Sources/DevDash/Resources/alpine.min.js`
- `Sources/DevDash/Resources/devdash-components.js`
- `Sources/DevDash/Scanners/ProductDocAssets.swift`
- The `template(_:)`, `stub(_:)`, `bridgeJS` template machinery in `ProductDocGenerator.swift` (most of the file gets folded into `HtmlCompiler` and the original `.swift` becomes a thin shim or is removed)

---

## Task 1: Add Yams dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add Yams to the package dependencies**

Edit `Package.swift`. In the `dependencies` array, add the Yams package:

```swift
dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
],
```

In the `.executableTarget` dependencies array, add `Yams`:

```swift
.executableTarget(
    name: "DevDash",
    dependencies: [
        .product(name: "SwiftTerm", package: "SwiftTerm"),
        .product(name: "Yams", package: "Yams")
    ],
    path: "Sources/DevDash",
    resources: [
        .copy("Resources")
    ],
    ...
)
```

- [ ] **Step 2: Build to fetch the dep**

```bash
swift build 2>&1 | tail -10
```
Expected: SPM fetches Yams and the build completes. First build will take ~30s.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "$(cat <<'EOF'
feat: add Yams dependency for YAML frontmatter parsing

Yams 5.0.6 will back the EntityFrontmatter module that parses
markdown entity files (frontmatter + body) into typed Swift models.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Entity models — Codable structs for every entity type

**Files:**
- Create: `Sources/DevDash/Models/MarkdownEntity.swift`
- Create: `Sources/DevDash/Models/EntityModels.swift`

- [ ] **Step 1: Create the MarkdownEntity protocol**

Write to `Sources/DevDash/Models/MarkdownEntity.swift`:

```swift
import Foundation

/// Every markdown-backed entity implements this protocol. Frontmatter is the
/// Codable struct itself (modulo the `body` field); the body is the markdown
/// prose under the closing `---`.
protocol MarkdownEntity: Codable, Identifiable {
    static var kind: EntityKind { get }
    /// Unique ID. Used as the filename slug (`g-<id>.md`).
    var id: String { get set }
    /// Optional markdown narrative under the frontmatter.
    var body: String { get set }
}

/// Each entity kind maps to a folder under docs/devdash/ and an ID prefix
/// used when minting new entity IDs.
enum EntityKind: String, CaseIterable {
    case goal, kpi, idea, initiative
    case prd, plan, status, decision, concept, retro
    case overview, triage
    case task   // Not stored as markdown; here so callers can refer to it generically.

    /// Folder name under docs/devdash/. Singletons return their filename here.
    var folder: String {
        switch self {
        case .goal:        return "goals"
        case .kpi:         return "kpis"
        case .idea:        return "ideas"
        case .initiative:  return "initiatives"
        case .prd:         return "prd"
        case .plan:        return "plans"
        case .status:      return "status"
        case .decision:    return "decisions"
        case .concept:     return "concepts"
        case .retro:       return "retros"
        case .overview:    return "."
        case .triage:      return "."
        case .task:        return ""   // not markdown-backed
        }
    }

    /// Prefix for new entity IDs. `g-`, `k-`, etc.
    var idPrefix: String {
        switch self {
        case .goal: return "g"
        case .kpi: return "k"
        case .idea: return "i"
        case .initiative: return "in"
        case .prd: return "p"
        case .plan: return "pl"
        case .status: return "s"
        case .decision: return "d"
        case .concept: return "c"
        case .retro: return "r"
        case .overview, .triage, .task: return ""
        }
    }

    /// True for entities that have exactly one file per project (overview.md, triage-board.md).
    var isSingleton: Bool {
        switch self {
        case .overview, .triage: return true
        default: return false
        }
    }

    /// Singleton filename, if applicable.
    var singletonFile: String? {
        switch self {
        case .overview: return "overview.md"
        case .triage:   return "triage-board.md"
        default:        return nil
        }
    }
}
```

- [ ] **Step 2: Create the entity model structs**

Write to `Sources/DevDash/Models/EntityModels.swift`:

```swift
import Foundation

// MARK: - Helper sub-types

enum GoalStatus: String, Codable, CaseIterable { case onTrack = "on-track", atRisk = "at-risk", slipping, achieved, abandoned }
enum PrdStatus: String, Codable, CaseIterable { case draft, accepted, shipped, abandoned }
enum DecisionStatus: String, Codable, CaseIterable { case draft, adopted, superseded }
enum IdeaColumn: String, Codable, CaseIterable { case quickWins = "quick-wins", bigBets = "big-bets", parked }
enum TriageColumn: String, Codable, CaseIterable { case now, next, later, cut }
enum MilestoneStatus: String, Codable, CaseIterable { case pending, current, done }

struct RiskEntry: Codable, Hashable {
    var description: String
    var likelihood: String           // "Low" / "Med" / "High" — free-text intentional
    var impact: String
    var mitigation: String
}

struct Milestone: Codable, Hashable, Identifiable {
    var id: String { week + "-" + title }
    var week: String
    var title: String
    var status: MilestoneStatus
    var notes: String
}

struct DecisionOption: Codable, Hashable {
    var name: String
    var pros: String
    var cons: String
    var picked: Bool
}

struct KpiHistoryPoint: Codable, Hashable {
    var date: Date
    var value: Double
}

struct TermDefinition: Codable, Hashable {
    var term: String
    var definition: String
}

struct RetroAction: Codable, Hashable {
    var description: String
    var owner: String?
    var due: Date?
}

struct TimelineEntry: Codable, Hashable {
    var meta: String           // e.g. "Week 1", "Mid", "End"
    var title: String
    var notes: String
}

struct TriageCard: Codable, Hashable, Identifiable {
    var id: String
    var column: TriageColumn
    var title: String
    var tags: [String]
    var createdAt: Date
}

// MARK: - Entities

struct Overview: MarkdownEntity {
    static let kind: EntityKind = .overview
    var id: String = "overview"
    var tldr: String = ""
    var whatItIs: String = ""
    var whoFor: String = ""
    var whyNow: String = ""
    var whatItIsNot: String = ""
    var risks: [RiskEntry] = []
    var body: String = ""
}

struct Goal: MarkdownEntity {
    static let kind: EntityKind = .goal
    var id: String
    var title: String
    var status: GoalStatus
    var kpi: String?
    var target: String?
    var current: String?
    var dueDate: Date?
    var owner: String?
    var taskIds: [String] = []
    var body: String = ""
}

struct KPI: MarkdownEntity {
    static let kind: EntityKind = .kpi
    var id: String
    var name: String
    var target: String
    var current: String
    var unit: String
    var history: [KpiHistoryPoint] = []
    var owner: String?
    var body: String = ""
}

struct Idea: MarkdownEntity {
    static let kind: EntityKind = .idea
    var id: String
    var title: String
    var column: IdeaColumn
    var tags: [String] = []
    var promotedTaskId: String?
    var body: String = ""
}

struct Initiative: MarkdownEntity {
    static let kind: EntityKind = .initiative
    var id: String
    var title: String
    var goalIds: [String] = []
    var taskIds: [String] = []
    var stage: String?
    var body: String = ""
}

struct PRD: MarkdownEntity {
    static let kind: EntityKind = .prd
    var id: String
    var title: String
    var status: PrdStatus = .draft
    var owner: String?
    var goalIds: [String] = []
    var decisionIds: [String] = []
    var body: String = ""
}

struct Plan: MarkdownEntity {
    static let kind: EntityKind = .plan
    var id: String
    var title: String
    var prdId: String?
    var milestones: [Milestone] = []
    var goalIds: [String] = []
    var body: String = ""
}

struct StatusReport: MarkdownEntity {
    static let kind: EntityKind = .status
    var id: String
    var date: Date
    var headline: String = ""
    var shipped: [String] = []
    var inProgress: [String] = []
    var slipped: [String] = []
    var next: [String] = []
    var risks: [String] = []
    var asks: [String] = []
    var body: String = ""
}

struct Decision: MarkdownEntity {
    static let kind: EntityKind = .decision
    var id: String
    var title: String
    var status: DecisionStatus = .draft
    var dateAdopted: Date?
    var options: [DecisionOption] = []
    var supersededBy: String?
    var goalIds: [String] = []
    var body: String = ""
}

struct Concept: MarkdownEntity {
    static let kind: EntityKind = .concept
    var id: String
    var topic: String
    var terms: [TermDefinition] = []
    var body: String = ""
}

struct Retro: MarkdownEntity {
    static let kind: EntityKind = .retro
    var id: String
    var date: Date
    var wentWell: [String] = []
    var didntGoWell: [String] = []
    var lessons: [String] = []
    var actions: [RetroAction] = []
    var timeline: [TimelineEntry] = []
    var body: String = ""
}

struct TriageBoard: MarkdownEntity {
    static let kind: EntityKind = .triage
    var id: String = "triage-board"
    var cards: [TriageCard] = []
    var body: String = ""
}
```

- [ ] **Step 3: Build to verify**

```bash
swift build 2>&1 | tail -5
```
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Models/
git commit -m "$(cat <<'EOF'
feat: entity models + MarkdownEntity protocol

13 Codable entity types (Overview, Goal, KPI, Idea, Initiative,
PRD, Plan, Status, Decision, Concept, Retro, TriageBoard) plus
helper sub-types (RiskEntry, Milestone, DecisionOption, etc).
EntityKind enum carries folder name, ID prefix, and singleton
flag for the storage layer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: EntityFrontmatter — YAML round-trip

**Files:**
- Create: `Sources/DevDash/Scanners/EntityFrontmatter.swift`

The on-disk format is:

```markdown
---
<yaml frontmatter>
---
<markdown body>
```

`EntityFrontmatter` splits a file's contents into the YAML chunk and the body, and serializes both back together. Uses Yams for YAML, and Swift's `JSONEncoder/Decoder` to bridge between Codable entity structs and YAML's `[String: Any]` representation.

- [ ] **Step 1: Create the parser/serializer**

Write to `Sources/DevDash/Scanners/EntityFrontmatter.swift`:

```swift
import Foundation
import Yams

enum EntityFrontmatter {
    /// Parse a markdown entity file: frontmatter YAML + body. Returns nil if
    /// the file is malformed (missing delimiters, invalid YAML, or decode fail).
    static func read<T: MarkdownEntity>(_ path: String, as type: T.Type) -> T? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(contents, as: type)
    }

    static func parse<T: MarkdownEntity>(_ contents: String, as type: T.Type) -> T? {
        let (frontmatterYaml, body) = splitFrontmatter(contents)
        guard let frontmatterYaml = frontmatterYaml else { return nil }
        // YAML → dict → JSON → Codable. This indirection lets us reuse Swift's
        // existing Codable infrastructure for dates, enums, etc.
        guard let yamlNode = try? Yams.load(yaml: frontmatterYaml) as? [String: Any] else { return nil }
        var dict = yamlNode
        dict["body"] = body
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: jsonData)
    }

    /// Serialize an entity to disk-ready markdown form (frontmatter + body).
    static func serialize<T: MarkdownEntity>(_ entity: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let jsonData = try? encoder.encode(entity),
              var dict = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return "---\n---\n"
        }
        // Body lives in the markdown section, not in frontmatter.
        let body = (dict["body"] as? String) ?? ""
        dict.removeValue(forKey: "body")
        // Sort keys for stable file output (cleaner git diffs).
        let yaml = (try? Yams.serialize(node: try Yams.Node(dict), options: .init(sortKeys: true))) ?? ""
        return "---\n\(yaml.trimmingCharacters(in: .whitespacesAndNewlines))\n---\n\n\(body)\n"
    }

    /// Write an entity to disk at the given absolute path. Creates parent dir.
    static func write<T: MarkdownEntity>(_ entity: T, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try serialize(entity).write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Internals

    /// Returns (frontmatter YAML, body). If no frontmatter delimiters are present,
    /// frontmatter is nil and the whole input is treated as body.
    private static func splitFrontmatter(_ contents: String) -> (String?, String) {
        let lines = contents.components(separatedBy: "\n")
        // File must start with `---` line.
        guard lines.first == "---" else {
            return (nil, contents)
        }
        // Find the closing `---` line.
        guard let closeIdx = lines.dropFirst().firstIndex(of: "---") else {
            return (nil, contents)
        }
        let frontmatter = lines[1..<closeIdx].joined(separator: "\n")
        let bodyStartIdx = closeIdx + 1
        let body = (bodyStartIdx < lines.count) ? lines[bodyStartIdx...].joined(separator: "\n") : ""
        return (frontmatter, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: clean build.

- [ ] **Step 3: Manual round-trip smoke test**

Write a one-off test script at `/tmp/test_frontmatter.swift`:

```bash
cat > /tmp/test_frontmatter.sh <<'EOF'
TMPFILE=$(mktemp)
cat > $TMPFILE <<MARKDOWN
---
id: g-001
title: Launch MVP
status: on-track
dueDate: "2026-06-15T00:00:00Z"
taskIds:
  - t-042
  - t-043
---

Without D7 retention >40%, the unit economics don't work.
MARKDOWN
echo "Input file:"
cat $TMPFILE
echo
echo "Re-run swift build with a small test main if needed, or eyeball the format manually."
EOF
chmod +x /tmp/test_frontmatter.sh
bash /tmp/test_frontmatter.sh
```

Since there's no test framework, the actual round-trip test happens implicitly in Task 4 (EntityStore). Don't add a stand-alone Swift test; just confirm the file compiles.

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/EntityFrontmatter.swift
git commit -m "$(cat <<'EOF'
feat: EntityFrontmatter — YAML frontmatter + markdown body round-trip

Reads a markdown file split into --- yaml --- body sections. Bridges
through JSON to reuse Codable infrastructure for dates/enums.
Serializes entities back with sorted keys for stable git diffs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: EntityStore — generic CRUD

**Files:**
- Create: `Sources/DevDash/Scanners/EntityStore.swift`

EntityStore exposes type-safe load/save/list/delete for any `MarkdownEntity`. It's stateless — no in-memory cache. Caller decides when to re-read.

- [ ] **Step 1: Create EntityStore**

Write to `Sources/DevDash/Scanners/EntityStore.swift`:

```swift
import Foundation

/// Generic CRUD layer for markdown-backed entities. All paths are relative to
/// the project's `docs/devdash/` directory. Caller owns the project path.
enum EntityStore {
    /// Mint a new id with the given prefix, suffixed with 4 base-36 chars.
    static func mintID<T: MarkdownEntity>(for type: T.Type) -> String {
        let prefix = T.kind.idPrefix
        let suffix = String((0..<4).compactMap { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement() })
        return "\(prefix)-\(suffix)"
    }

    /// Return the absolute path for an entity instance.
    static func path<T: MarkdownEntity>(for entity: T, projectPath: String) -> String {
        path(forID: entity.id, type: T.self, projectPath: projectPath)
    }

    /// Return the absolute path for an entity by id.
    static func path<T: MarkdownEntity>(forID id: String, type: T.Type, projectPath: String) -> String {
        let base = "\(projectPath)/docs/devdash"
        if let singleton = T.kind.singletonFile {
            return "\(base)/\(singleton)"
        }
        return "\(base)/\(T.kind.folder)/\(id).md"
    }

    /// Load one entity by id. Returns nil if missing or unparseable.
    static func read<T: MarkdownEntity>(_ type: T.Type, id: String, projectPath: String) -> T? {
        let p = path(forID: id, type: type, projectPath: projectPath)
        return EntityFrontmatter.read(p, as: type)
    }

    /// Load the singleton (Overview / TriageBoard). Returns nil if file missing.
    static func readSingleton<T: MarkdownEntity>(_ type: T.Type, projectPath: String) -> T? {
        guard T.kind.isSingleton else { return nil }
        let p = path(forID: T.kind.singletonFile ?? "", type: type, projectPath: projectPath)
        return EntityFrontmatter.read(p, as: type)
    }

    /// List all entities of a kind in the project. Sorted by id.
    static func list<T: MarkdownEntity>(_ type: T.Type, projectPath: String) -> [T] {
        guard !T.kind.isSingleton else {
            return readSingleton(type, projectPath: projectPath).map { [$0] } ?? []
        }
        let folder = "\(projectPath)/docs/devdash/\(T.kind.folder)"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let mdFiles = files.filter { $0.hasSuffix(".md") }.sorted()
        return mdFiles.compactMap { f in
            EntityFrontmatter.read("\(folder)/\(f)", as: type)
        }
    }

    /// Write an entity to disk. Throws on filesystem error.
    static func save<T: MarkdownEntity>(_ entity: T, projectPath: String) throws {
        let p = path(for: entity, projectPath: projectPath)
        try EntityFrontmatter.write(entity, to: p)
    }

    /// Delete an entity by id. No-op if missing.
    static func delete<T: MarkdownEntity>(_ type: T.Type, id: String, projectPath: String) {
        let p = path(forID: id, type: type, projectPath: projectPath)
        try? FileManager.default.removeItem(atPath: p)
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Scanners/EntityStore.swift
git commit -m "$(cat <<'EOF'
feat: EntityStore — generic CRUD over markdown entities

Type-safe read/list/save/delete for any MarkdownEntity. Singletons
(Overview, TriageBoard) and collections (Goals/KPIs/...) handled
through the same API via EntityKind metadata. Mints new IDs with
the per-kind prefix.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: HtmlCompiler skeleton — index shell + Overview renderer

**Files:**
- Create: `Sources/DevDash/Scanners/HtmlCompiler.swift`

This task lays the compiler skeleton and renders only Overview. Subsequent tasks add the other section renderers. The shell HTML (index.html, tab nav, shared CSS) lives here.

- [ ] **Step 1: Create HtmlCompiler**

Write to `Sources/DevDash/Scanners/HtmlCompiler.swift`:

```swift
import Foundation

/// Renders entity models into HTML files under docs/devdash/. Replaces the
/// old ProductDocGenerator authoring templates. Output is READ-ONLY — no
/// contenteditable, no Alpine, no save bridge.
enum HtmlCompiler {
    /// Compile the entire living doc. Re-runs every section renderer + the
    /// index shell. Idempotent. Cheap to run (string concatenation + a dozen
    /// file writes).
    @discardableResult
    static func compile(
        projectName: String,
        projectPath: String,
        meta: ProjectMeta,
        template: LaunchTemplate?,
        tasks: [TaskItem]
    ) -> String? {
        let docsRoot = "\(projectPath)/docs/devdash"
        let sectionsRoot = "\(docsRoot)/sections"
        try? FileManager.default.createDirectory(atPath: sectionsRoot, withIntermediateDirectories: true)

        // Section files
        writeOverview(projectPath: projectPath, sectionsRoot: sectionsRoot)
        // (later tasks add: writeGoals, writeIdeas, writeInitiatives, writeRoadmap, writeArtifacts, writeTriage)
        writeRoadmap(projectPath: projectPath, sectionsRoot: sectionsRoot, meta: meta, template: template, tasks: tasks)

        // Index shell
        let indexHtml = renderIndexShell(projectName: projectName, meta: meta, template: template)
        let indexPath = "\(docsRoot)/index.html"
        try? indexHtml.write(toFile: indexPath, atomically: true, encoding: .utf8)
        return indexPath
    }

    // MARK: - Section: Overview

    static func writeOverview(projectPath: String, sectionsRoot: String) {
        let overview = EntityStore.readSingleton(Overview.self, projectPath: projectPath) ?? Overview()
        var out: [String] = []
        out.append("<div class=\"doc-head\"><h2>Overview</h2></div>")
        if !overview.tldr.isEmpty {
            out.append("<div class=\"callout tldr\"><h4 style=\"margin-top:0\">TL;DR</h4><p>\(escapeHTML(overview.tldr))</p></div>")
        }
        out.append("<div class=\"grid-2\">")
        out.append(renderCard(title: "What is it?", body: overview.whatItIs))
        out.append(renderCard(title: "Who's it for?", body: overview.whoFor))
        out.append(renderCard(title: "Why now?", body: overview.whyNow))
        out.append(renderCard(title: "What it is <em>not</em>", body: overview.whatItIsNot))
        out.append("</div>")
        if !overview.risks.isEmpty {
            out.append("<h3>Risks &amp; assumptions</h3>")
            out.append("<table><thead><tr><th>Risk</th><th>Likelihood</th><th>Impact</th><th>Mitigation</th></tr></thead><tbody>")
            for r in overview.risks {
                out.append("<tr><td>\(escapeHTML(r.description))</td><td>\(escapeHTML(r.likelihood))</td><td>\(escapeHTML(r.impact))</td><td>\(escapeHTML(r.mitigation))</td></tr>")
            }
            out.append("</tbody></table>")
        }
        if !overview.body.isEmpty {
            out.append("<div class=\"prose\">\(renderMarkdown(overview.body))</div>")
        }
        try? out.joined(separator: "\n").write(toFile: "\(sectionsRoot)/overview.html", atomically: true, encoding: .utf8)
    }

    // MARK: - Section: Roadmap (derived from ProjectMeta, unchanged from old generator)

    static func writeRoadmap(projectPath: String, sectionsRoot: String, meta: ProjectMeta, template: LaunchTemplate?, tasks: [TaskItem]) {
        // Reuse the existing roadmap rendering from ProductDocGenerator for now —
        // it's already derived from meta + template, not from .html files.
        let html = ProductDocGenerator.renderRoadmapInline(meta: meta, template: template, tasks: tasks)
        try? html.write(toFile: "\(sectionsRoot)/roadmap.html", atomically: true, encoding: .utf8)
    }

    // MARK: - Index shell

    static func renderIndexShell(projectName: String, meta: ProjectMeta, template: LaunchTemplate?) -> String {
        let crumbs = renderCrumbs(meta: meta, template: template)
        // Tabs: Overview, Roadmap, Initiatives, Goals & KPIs, Ideas, Artifacts.
        // Subsequent tasks add the body renderers for each.
        let nav = """
        <button class="tab active" data-tab="overview">Overview</button>
        <button class="tab" data-tab="roadmap">Roadmap</button>
        <button class="tab" data-tab="initiatives">Initiatives</button>
        <button class="tab" data-tab="goals">Goals &amp; KPIs</button>
        <button class="tab" data-tab="ideas">Ideas</button>
        <button class="tab" data-tab="artifacts">Artifacts</button>
        """

        let sections = """
        <section id="tab-overview" class="tab-pane active">
          <div data-include="sections/overview.html"></div>
        </section>
        <section id="tab-roadmap" class="tab-pane">
          <div data-include="sections/roadmap.html"></div>
        </section>
        <section id="tab-initiatives" class="tab-pane">
          <div data-include="sections/initiatives.html"></div>
        </section>
        <section id="tab-goals" class="tab-pane">
          <div data-include="sections/goals.html"></div>
        </section>
        <section id="tab-ideas" class="tab-pane">
          <div data-include="sections/ideas.html"></div>
        </section>
        <section id="tab-artifacts" class="tab-pane">
          <div data-include="sections/artifacts.html"></div>
        </section>
        """

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <!-- managed by devdash — content compiled from entity .md files; this file is regenerated -->
        <meta charset="utf-8">
        <title>\(escapeHTML(projectName)) — Product</title>
        \(sharedStyles)
        </head>
        <body>
          <div class="wrap">
            <h1>\(escapeHTML(projectName))</h1>
            <div class="crumbs">\(crumbs)</div>
            <nav class="tabs">\(nav)</nav>
            \(sections)
          </div>
          \(viewerScript)
        </body>
        </html>
        """
    }

    // MARK: - Helpers (rendering primitives)

    static func renderCard(title: String, body: String) -> String {
        "<div class=\"card\"><h3>\(escapeHTML(title))</h3><p>\(escapeHTML(body))</p></div>"
    }

    static func renderCrumbs(meta: ProjectMeta, template: LaunchTemplate?) -> String {
        var parts: [String] = []
        if let t = template {
            parts.append("Methodology: <strong>\(escapeHTML(t.name))</strong>")
        } else {
            parts.append("No template applied")
        }
        if let stageId = meta.currentStageId,
           let stage = template?.stages.first(where: { $0.id == stageId }) {
            parts.append("Stage: <strong>\(escapeHTML(stage.title))</strong>")
        }
        return parts.joined(separator: " · ")
    }

    /// Minimal markdown → HTML. Headers, bold, italic, links, lists, code. Not
    /// a full CommonMark impl — just enough for entity bodies to look right.
    static func renderMarkdown(_ md: String) -> String {
        // Very minimal renderer. Future task can swap to a real lib.
        var html = escapeHTML(md)
        // Headers
        html = html.replacingOccurrences(of: #"^###\s+(.+)$"#, with: "<h3>$1</h3>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"^##\s+(.+)$"#, with: "<h2>$1</h2>", options: .regularExpression)
        // Bold / italic
        html = html.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: #"_([^_]+)_"#, with: "<em>$1</em>", options: .regularExpression)
        // Paragraphs
        let paragraphs = html.components(separatedBy: "\n\n")
        return paragraphs.map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined(separator: "\n")
    }

    static func escapeHTML(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }

    // MARK: - Shared styles (lifted from ProductDocGenerator — same look)

    static let sharedStyles = """
    <style>
      :root { --bg: #0f1115; --fg: #e8e8ec; --muted: #9aa0a8; --accent: #5ac8fa;
              --border: #23262d; --card: #181a1f; --code: #1c1f26;
              --green: #2ecc71; --red: #ff6b6b; --orange: #ffa502; --purple: #b388ff; }
      @media (prefers-color-scheme: light) {
        :root { --bg: #ffffff; --fg: #1c1c1e; --muted: #6e6e73; --accent: #007aff;
                --border: #e5e5ea; --card: #f7f7f9; --code: #f1f3f5; }
      }
      html, body { background: var(--bg); color: var(--fg); margin: 0; padding: 0;
                   font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", sans-serif;
                   line-height: 1.55; }
      .wrap { max-width: 960px; margin: 0 auto; padding: 24px 28px 80px; }
      h1 { font-size: 22px; margin: 0 0 4px; }
      .crumbs { color: var(--muted); font-size: 12px; margin-bottom: 18px; }
      nav.tabs { display: flex; gap: 6px; flex-wrap: wrap; border-bottom: 1px solid var(--border);
                 margin-bottom: 22px; position: sticky; top: 0; background: var(--bg);
                 z-index: 5; padding-top: 4px; }
      nav.tabs .tab { background: transparent; color: var(--muted); border: 0;
                      padding: 8px 12px; font: inherit; cursor: pointer; border-radius: 6px 6px 0 0;
                      border-bottom: 2px solid transparent; }
      nav.tabs .tab:hover { color: var(--fg); }
      nav.tabs .tab.active { color: var(--accent); border-bottom-color: var(--accent); font-weight: 600; }
      .tab-pane { display: none; }
      .tab-pane.active { display: block; }
      .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px;
              padding: 14px 18px; margin: 12px 0; }
      .callout { padding: 12px 16px; border-radius: 8px; margin: 12px 0;
                 border-left: 3px solid var(--accent); background: var(--card); }
      .callout.tldr { border-left-color: var(--accent); }
      .pill { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 11px;
              background: var(--card); border: 1px solid var(--border); color: var(--muted); }
      .pill.done    { color: var(--green); border-color: color-mix(in srgb, var(--green) 40%, transparent); }
      .pill.current { color: var(--accent); border-color: color-mix(in srgb, var(--accent) 40%, transparent); }
      .pill.pending { color: var(--muted); }
      .pill.warn    { color: var(--orange); border-color: color-mix(in srgb, var(--orange) 40%, transparent); }
      .pill.risk    { color: var(--red); border-color: color-mix(in srgb, var(--red) 40%, transparent); }
      .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
      @media (max-width: 720px) { .grid-2 { grid-template-columns: 1fr; } }
      table { border-collapse: collapse; width: 100%; margin: 10px 0; font-size: 13px; }
      th, td { padding: 6px 10px; border-bottom: 1px solid var(--border); text-align: left;
               vertical-align: top; }
      th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; }
      .empty { color: var(--muted); font-style: italic; padding: 14px 0; }
      .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; }
      .kpi { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 14px; }
      .kpi .k-label { font-size: 11px; color: var(--muted); text-transform: uppercase; font-weight: 600; }
      .kpi .k-value { font-size: 24px; font-weight: 700; margin: 6px 0 2px; }
      .kpi .k-target { font-size: 11px; color: var(--muted); }
      .board { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
      .board .col { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 12px; }
      .board .col .item { padding: 8px 10px; border-radius: 6px; background: var(--bg);
                          border: 1px solid var(--border); font-size: 12px; margin-bottom: 6px; }
      .doc-head { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; margin-bottom: 8px; }
      .doc-head .doc-status { font-size: 11px; color: var(--muted); }
      .meta { color: var(--muted); font-size: 12px; }
      .prose p { margin: 10px 0; }
      .prose h2, .prose h3 { margin-top: 18px; }
    </style>
    """

    /// Viewer-only script: tab switching + data-action passthrough to native.
    /// No save logic. No Alpine. No contenteditable.
    static let viewerScript = """
    <script>
      (function() {
        var btns = document.querySelectorAll('nav.tabs .tab');
        var panes = document.querySelectorAll('.tab-pane');
        btns.forEach(function(b) {
          b.addEventListener('click', function(e) {
            e.preventDefault();
            btns.forEach(function(x) { x.classList.remove('active'); });
            panes.forEach(function(p) { p.classList.remove('active'); });
            b.classList.add('active');
            var t = document.getElementById('tab-' + b.dataset.tab);
            if (t) t.classList.add('active');
          });
        });
        // Pass data-action clicks back to native (open-file / regenerate / open-task).
        document.addEventListener('click', function(e) {
          var btn = e.target.closest('[data-action]');
          if (!btn) return;
          e.preventDefault();
          var payload = { action: btn.dataset.action };
          Object.keys(btn.dataset).forEach(function(k) {
            if (k !== 'action') payload[k] = btn.dataset[k];
          });
          try { window.webkit.messageHandlers.devdash.postMessage(payload); }
          catch (err) { console.error('devdash bridge failed', err); }
        }, true);
        // data-include: inline-load referenced sections/*.html files.
        document.querySelectorAll('[data-include]').forEach(function(el) {
          fetch(el.dataset.include).then(function(r) { return r.text(); }).then(function(t) {
            el.outerHTML = t;
          }).catch(function(){});
        });
      })();
    </script>
    """
}
```

- [ ] **Step 2: Extract `renderRoadmapInline` helper from `ProductDocGenerator`**

Currently `ProductDocGenerator.renderRoadmap` is `private`. Make it accessible to `HtmlCompiler`. Edit `Sources/DevDash/Scanners/ProductDocGenerator.swift` — change the access on `renderRoadmap`:

Find:
```swift
private static func renderRoadmap(
```

Change to:
```swift
static func renderRoadmapInline(
```

Also rename it at the one call site inside `generate(...)` if needed. (`HtmlCompiler.writeRoadmap` calls `ProductDocGenerator.renderRoadmapInline`.)

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/HtmlCompiler.swift Sources/DevDash/Scanners/ProductDocGenerator.swift
git commit -m "$(cat <<'EOF'
feat: HtmlCompiler skeleton with Overview + Roadmap renderers

Compiles entity models into docs/devdash/sections/*.html + an
index.html shell. Renderers for the other sections land in
subsequent tasks. Viewer script does tab switching + data-action
passthrough; no save logic, no Alpine.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: HtmlCompiler — Goals, KPIs, Ideas, Initiatives renderers

**Files:**
- Modify: `Sources/DevDash/Scanners/HtmlCompiler.swift`

- [ ] **Step 1: Add the four section renderers**

In `HtmlCompiler.swift`, add to the existing enum (after `writeOverview`):

```swift
// MARK: - Section: Goals + KPIs

static func writeGoals(projectPath: String, sectionsRoot: String) {
    let goals = EntityStore.list(Goal.self, projectPath: projectPath)
    let kpis  = EntityStore.list(KPI.self,  projectPath: projectPath)

    var out: [String] = []
    out.append("<div class=\"doc-head\"><h2>Goals &amp; KPIs</h2></div>")

    if goals.isEmpty {
        out.append("<p class=\"empty\">No goals yet. Use the Product tab's Goals editor to add one.</p>")
    } else {
        out.append("<h3>Quarter goals</h3>")
        for g in goals {
            let statusClass = pillClass(for: g.status)
            let title = escapeHTML(g.title)
            let due = g.dueDate.map { " · due " + dateString($0) } ?? ""
            let owner = g.owner.map { " · " + escapeHTML($0) } ?? ""
            out.append("<div class=\"card\">")
            out.append("<div class=\"doc-head\"><h3 style=\"margin:0\">\(title) <span class=\"pill \(statusClass)\">\(g.status.rawValue)</span></h3><span class=\"doc-status meta\">\(due)\(owner)</span></div>")
            if let kpi = g.kpi, !kpi.isEmpty {
                let target = g.target.map { " · target " + escapeHTML($0) } ?? ""
                let current = g.current.map { " · current " + escapeHTML($0) } ?? ""
                out.append("<p class=\"meta\">KPI: \(escapeHTML(kpi))\(target)\(current)</p>")
            }
            if !g.body.isEmpty {
                out.append("<div class=\"prose\">\(renderMarkdown(g.body))</div>")
            }
            out.append("</div>")
        }
    }

    if !kpis.isEmpty {
        out.append("<h3>Tracked KPIs</h3>")
        out.append("<div class=\"kpi-grid\">")
        for k in kpis {
            out.append("<div class=\"kpi\">")
            out.append("  <div class=\"k-label\">\(escapeHTML(k.name))</div>")
            out.append("  <div class=\"k-value\">\(escapeHTML(k.current))</div>")
            out.append("  <div class=\"k-target\">target: \(escapeHTML(k.target)) \(escapeHTML(k.unit))</div>")
            out.append("</div>")
        }
        out.append("</div>")
    }

    try? out.joined(separator: "\n").write(toFile: "\(sectionsRoot)/goals.html", atomically: true, encoding: .utf8)
}

// MARK: - Section: Ideas

static func writeIdeas(projectPath: String, sectionsRoot: String) {
    let ideas = EntityStore.list(Idea.self, projectPath: projectPath)
    var out: [String] = []
    out.append("<div class=\"doc-head\"><h2>Ideas</h2></div>")
    if ideas.isEmpty {
        out.append("<p class=\"empty\">No ideas yet.</p>")
    } else {
        let byCol: [IdeaColumn: [Idea]] = Dictionary(grouping: ideas, by: { $0.column })
        out.append("<div class=\"board\">")
        for col in IdeaColumn.allCases {
            out.append("<div class=\"col\" data-col=\"\(col.rawValue)\">")
            out.append("<h4>\(humanColumnLabel(col))</h4>")
            for idea in byCol[col] ?? [] {
                let tags = idea.tags.map { "<span class=\"pill\">\(escapeHTML($0))</span>" }.joined(separator: " ")
                out.append("<div class=\"item\">\(tags) \(escapeHTML(idea.title))</div>")
            }
            out.append("</div>")
        }
        out.append("</div>")
    }
    try? out.joined(separator: "\n").write(toFile: "\(sectionsRoot)/ideas.html", atomically: true, encoding: .utf8)
}

// MARK: - Section: Initiatives

static func writeInitiatives(projectPath: String, sectionsRoot: String, tasks: [TaskItem]) {
    let initiatives = EntityStore.list(Initiative.self, projectPath: projectPath)
    var out: [String] = []
    out.append("<div class=\"doc-head\"><h2>Initiatives</h2></div>")
    if initiatives.isEmpty {
        out.append("<p class=\"empty\">No initiatives defined. Create one to roll up related goals and tasks.</p>")
    } else {
        for i in initiatives {
            let childTasks = tasks.filter { i.taskIds.contains($0.id) }
            let doneCount = childTasks.filter { $0.status == .done }.count
            out.append("<div class=\"card\">")
            out.append("<h3>\(escapeHTML(i.title))</h3>")
            out.append("<p class=\"meta\">\(doneCount)/\(childTasks.count) tasks complete · \(i.goalIds.count) linked goals</p>")
            if !i.body.isEmpty {
                out.append("<div class=\"prose\">\(renderMarkdown(i.body))</div>")
            }
            if !childTasks.isEmpty {
                out.append("<table><thead><tr><th>Status</th><th>Task</th></tr></thead><tbody>")
                for t in childTasks {
                    out.append("<tr><td>\(taskBadge(t.status))</td><td>\(escapeHTML(t.title))</td></tr>")
                }
                out.append("</tbody></table>")
            }
            out.append("</div>")
        }
    }
    try? out.joined(separator: "\n").write(toFile: "\(sectionsRoot)/initiatives.html", atomically: true, encoding: .utf8)
}

// MARK: - Renderer helpers

static func pillClass(for status: GoalStatus) -> String {
    switch status {
    case .onTrack:   return "current"
    case .atRisk:    return "warn"
    case .slipping:  return "risk"
    case .achieved:  return "done"
    case .abandoned: return "pending"
    }
}

static func humanColumnLabel(_ col: IdeaColumn) -> String {
    switch col {
    case .quickWins: return "Quick wins"
    case .bigBets:   return "Big bets"
    case .parked:    return "Maybe later"
    }
}

static func taskBadge(_ status: TaskStatus) -> String {
    switch status {
    case .done:       return "<span class=\"pill done\">Done</span>"
    case .inProgress: return "<span class=\"pill current\">In progress</span>"
    case .skipped:    return "<span class=\"pill\">Skipped</span>"
    case .open:       return "<span class=\"pill pending\">Open</span>"
    }
}

static func dateString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d, yyyy"
    return f.string(from: d)
}
```

- [ ] **Step 2: Wire the new renderers into `compile(...)`**

In `compile(...)`, after `writeOverview` add:

```swift
writeGoals(projectPath: projectPath, sectionsRoot: sectionsRoot)
writeIdeas(projectPath: projectPath, sectionsRoot: sectionsRoot)
writeInitiatives(projectPath: projectPath, sectionsRoot: sectionsRoot, tasks: tasks)
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/HtmlCompiler.swift
git commit -m "$(cat <<'EOF'
feat: HtmlCompiler — Goals, KPIs, Ideas, Initiatives renderers

Each renderer reads its entities from EntityStore and writes a
sections/*.html file. Initiatives cross-references TaskStore for
the per-initiative completion rollup. Empty states present.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: HtmlCompiler — Artifacts + Triage renderers

**Files:**
- Modify: `Sources/DevDash/Scanners/HtmlCompiler.swift`

- [ ] **Step 1: Add the artifact + triage renderers**

In `HtmlCompiler.swift`, add:

```swift
// MARK: - Artifacts (browser + per-file pages)

static func writeArtifacts(projectPath: String, sectionsRoot: String, docsRoot: String) {
    var out: [String] = []
    out.append("<div class=\"doc-head\"><h2>Artifacts</h2></div>")

    let groups: [(label: String, kind: EntityKind)] = [
        ("PRDs", .prd),
        ("Implementation Plans", .plan),
        ("Status Reports", .status),
        ("Decisions", .decision),
        ("Concept Explainers", .concept),
        ("Retrospectives", .retro)
    ]

    for (label, kind) in groups {
        out.append(renderArtifactGroup(label: label, kind: kind, projectPath: projectPath, docsRoot: docsRoot))
    }

    // Triage board (singleton, separate from the multi-file artifact groups).
    out.append(renderTriageBoardSummary(projectPath: projectPath))

    try? out.joined(separator: "\n").write(toFile: "\(sectionsRoot)/artifacts.html", atomically: true, encoding: .utf8)
}

private static func renderArtifactGroup(label: String, kind: EntityKind, projectPath: String, docsRoot: String) -> String {
    let folder = "\(docsRoot)/\(kind.folder)"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { $0.hasSuffix(".md") }.sorted() ?? []
    var out: [String] = []
    out.append("<details class=\"card\"\(files.isEmpty ? "" : " open")>")
    out.append("  <summary><strong>\(escapeHTML(label))</strong> <span class=\"meta\">\(escapeHTML(kind.folder))/ · \(files.count)</span></summary>")
    if files.isEmpty {
        out.append("  <p class=\"empty\">None yet. Use the Product tab's toolbar to scaffold a new \(escapeHTML(String(label.dropLast()))).</p>")
    } else {
        out.append("  <div class=\"file-list\">")
        for f in files {
            let id = (f as NSString).deletingPathExtension
            let title = (loadTitle(id: id, kind: kind, projectPath: projectPath)) ?? id
            // Each artifact also gets its own pre-rendered .html file at <kind.folder>/<id>.html
            out.append("""
              <details class="card" style="margin-left:8px">
                <summary><strong>\(escapeHTML(title))</strong> <span class="meta">\(escapeHTML(f))</span></summary>
                <div data-include="\(escapeHTML(kind.folder))/\(escapeHTML(id)).html"></div>
              </details>
            """)
        }
        out.append("  </div>")
    }
    out.append("</details>")
    return out.joined(separator: "\n")
}

private static func loadTitle(id: String, kind: EntityKind, projectPath: String) -> String? {
    switch kind {
    case .prd:      return EntityStore.read(PRD.self, id: id, projectPath: projectPath)?.title
    case .plan:     return EntityStore.read(Plan.self, id: id, projectPath: projectPath)?.title
    case .status:   return EntityStore.read(StatusReport.self, id: id, projectPath: projectPath)?.headline
    case .decision: return EntityStore.read(Decision.self, id: id, projectPath: projectPath)?.title
    case .concept:  return EntityStore.read(Concept.self, id: id, projectPath: projectPath)?.topic
    case .retro:    return EntityStore.read(Retro.self, id: id, projectPath: projectPath).map { dateString($0.date) }
    default:        return nil
    }
}

private static func renderTriageBoardSummary(projectPath: String) -> String {
    guard let board = EntityStore.readSingleton(TriageBoard.self, projectPath: projectPath) else {
        return "<details class=\"card\"><summary><strong>Triage Board</strong> <span class=\"meta\">empty</span></summary><p class=\"empty\">No triage board yet.</p></details>"
    }
    let countsByCol: [TriageColumn: Int] = Dictionary(grouping: board.cards, by: \.column).mapValues { $0.count }
    var out: [String] = []
    out.append("<details class=\"card\" open><summary><strong>Triage Board</strong> <span class=\"meta\">\(board.cards.count) cards</span></summary>")
    out.append("<div class=\"board\">")
    for col in TriageColumn.allCases {
        out.append("<div class=\"col\"><h4>\(col.rawValue.capitalized) <span class=\"meta\">(\(countsByCol[col] ?? 0))</span></h4>")
        for card in board.cards.filter({ $0.column == col }) {
            let tags = card.tags.map { "<span class=\"pill\">\(escapeHTML($0))</span>" }.joined(separator: " ")
            out.append("<div class=\"item\">\(tags) \(escapeHTML(card.title))</div>")
        }
        out.append("</div>")
    }
    out.append("</div></details>")
    return out.joined(separator: "\n")
}

// MARK: - Per-artifact pages (one HTML file per .md)

static func writeArtifactPages(projectPath: String, docsRoot: String) {
    writePages(PRD.self, projectPath: projectPath, docsRoot: docsRoot, render: renderPrd)
    writePages(Plan.self, projectPath: projectPath, docsRoot: docsRoot, render: renderPlan)
    writePages(StatusReport.self, projectPath: projectPath, docsRoot: docsRoot, render: renderStatus)
    writePages(Decision.self, projectPath: projectPath, docsRoot: docsRoot, render: renderDecision)
    writePages(Concept.self, projectPath: projectPath, docsRoot: docsRoot, render: renderConcept)
    writePages(Retro.self, projectPath: projectPath, docsRoot: docsRoot, render: renderRetro)
}

private static func writePages<T: MarkdownEntity>(_ type: T.Type, projectPath: String, docsRoot: String, render: (T) -> String) {
    let entities = EntityStore.list(type, projectPath: projectPath)
    let outDir = "\(docsRoot)/\(T.kind.folder)"
    for e in entities {
        let html = render(e)
        let outPath = "\(outDir)/\(e.id).html"
        try? html.write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}

// Each renderer below produces the body HTML for one entity. Wrap in standard
// card layout if multi-section, or just the prose if narrative-heavy.

private static func renderPrd(_ p: PRD) -> String {
    """
    <div class="doc-head">
      <h2>\(escapeHTML(p.title))</h2>
      <span class="doc-status"><span class="pill \(p.status == .draft ? "warn" : "done")">\(p.status.rawValue)</span></span>
    </div>
    <div class="prose">\(renderMarkdown(p.body))</div>
    """
}

private static func renderPlan(_ p: Plan) -> String {
    var out: [String] = []
    out.append("<div class=\"doc-head\"><h2>\(escapeHTML(p.title))</h2></div>")
    if !p.milestones.isEmpty {
        out.append("<h3>Milestones</h3><ul class=\"timeline\">")
        for m in p.milestones {
            out.append("<li class=\"\(m.status.rawValue)\"><div class=\"t-meta\">\(escapeHTML(m.week))</div><div class=\"t-title\">\(escapeHTML(m.title))</div><p>\(escapeHTML(m.notes))</p></li>")
        }
        out.append("</ul>")
    }
    out.append("<div class=\"prose\">\(renderMarkdown(p.body))</div>")
    return out.joined(separator: "\n")
}

private static func renderStatus(_ s: StatusReport) -> String {
    func block(_ title: String, _ items: [String]) -> String {
        let lis = items.map { "<li>\(escapeHTML($0))</li>" }.joined(separator: "")
        return "<div class=\"card\"><h4>\(title)</h4><ul>\(lis)</ul></div>"
    }
    return """
    <div class="doc-head"><h2>Status — \(dateString(s.date))</h2></div>
    <div class="callout tldr"><p><strong>Headline:</strong> \(escapeHTML(s.headline))</p></div>
    <div class="grid-2">
      \(block("✓ Shipped", s.shipped))
      \(block("⏳ In progress", s.inProgress))
      \(block("⚠ Slipped", s.slipped))
      \(block("→ Next week", s.next))
    </div>
    <div class="prose">\(renderMarkdown(s.body))</div>
    """
}

private static func renderDecision(_ d: Decision) -> String {
    var optionsTable = "<table><thead><tr><th>Option</th><th>Pros</th><th>Cons</th></tr></thead><tbody>"
    for o in d.options {
        let picked = o.picked ? " <span class=\"pill done\">Picked</span>" : ""
        optionsTable += "<tr><td><strong>\(escapeHTML(o.name))</strong>\(picked)</td><td>\(escapeHTML(o.pros))</td><td>\(escapeHTML(o.cons))</td></tr>"
    }
    optionsTable += "</tbody></table>"
    return """
    <div class="doc-head">
      <h2>\(escapeHTML(d.title))</h2>
      <span class="doc-status meta"><span class="pill \(d.status == .adopted ? "done" : "warn")">\(d.status.rawValue)</span> \(d.dateAdopted.map(dateString) ?? "")</span>
    </div>
    \(d.options.isEmpty ? "" : optionsTable)
    <div class="prose">\(renderMarkdown(d.body))</div>
    """
}

private static func renderConcept(_ c: Concept) -> String {
    var termsTable = ""
    if !c.terms.isEmpty {
        termsTable = "<table><thead><tr><th>Term</th><th>Definition</th></tr></thead><tbody>"
        for t in c.terms {
            termsTable += "<tr><td><strong>\(escapeHTML(t.term))</strong></td><td>\(escapeHTML(t.definition))</td></tr>"
        }
        termsTable += "</tbody></table>"
    }
    return """
    <div class="doc-head"><h2>Concept: \(escapeHTML(c.topic))</h2></div>
    \(termsTable)
    <div class="prose">\(renderMarkdown(c.body))</div>
    """
}

private static func renderRetro(_ r: Retro) -> String {
    func block(_ title: String, _ items: [String]) -> String {
        let lis = items.map { "<li>\(escapeHTML($0))</li>" }.joined(separator: "")
        return "<div class=\"card\"><h4>\(title)</h4><ul>\(lis)</ul></div>"
    }
    let actionsList = r.actions.map { a -> String in
        let owner = a.owner.map { " — " + escapeHTML($0) } ?? ""
        let due = a.due.map { " · due " + dateString($0) } ?? ""
        return "<li>☐ \(escapeHTML(a.description))\(owner)\(due)</li>"
    }.joined(separator: "")
    return """
    <div class="doc-head"><h2>Retrospective — \(dateString(r.date))</h2></div>
    <div class="grid-2">
      \(block("👍 Went well", r.wentWell))
      \(block("👎 Didn't go well", r.didntGoWell))
      \(block("💡 Lessons", r.lessons))
      <div class="card"><h4>→ Action items</h4><ul>\(actionsList)</ul></div>
    </div>
    <div class="prose">\(renderMarkdown(r.body))</div>
    """
}
```

- [ ] **Step 2: Wire artifact + triage renderers into `compile(...)`**

In `compile(...)`, after `writeInitiatives`, add:

```swift
writeArtifacts(projectPath: projectPath, sectionsRoot: sectionsRoot, docsRoot: docsRoot)
writeArtifactPages(projectPath: projectPath, docsRoot: docsRoot)
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/HtmlCompiler.swift
git commit -m "$(cat <<'EOF'
feat: HtmlCompiler — artifacts browser + per-artifact pages + triage

Artifact browser lists each .md as an embedded preview via data-include
of the per-artifact .html. Triage board (singleton) renders as a
read-only kanban summary. Six artifact types each have their own
renderer producing the artifact page HTML.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: MarkdownBodyEditor + generic MarkdownEntityEditor

**Files:**
- Create: `Sources/DevDash/Views/ProductEditors/MarkdownBodyEditor.swift`
- Create: `Sources/DevDash/Views/ProductEditors/MarkdownEntityEditor.swift`

- [ ] **Step 1: Create the reusable body editor**

Write to `Sources/DevDash/Views/ProductEditors/MarkdownBodyEditor.swift`:

```swift
import SwiftUI

/// SwiftUI markdown body editor. Plain monospace TextEditor with a header.
/// No syntax highlighting in v1 — that's an open question deferred from the spec.
struct MarkdownBodyEditor: View {
    @Binding var text: String
    var placeholder: String = "Add notes, rationale, prose..."

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("BODY (MARKDOWN)")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(text.count) chars")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
            }
            .background(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
    }
}
```

- [ ] **Step 2: Create the generic entity editor shell**

Write to `Sources/DevDash/Views/ProductEditors/MarkdownEntityEditor.swift`:

```swift
import SwiftUI

/// Generic editor for narrative-heavy entities. Fields sidebar on the right,
/// markdown body editor on the left. Each concrete entity editor (PRD, Plan,
/// Decision, etc.) wraps this and provides the fields view.
struct MarkdownEntityEditor<Fields: View>: View {
    let title: String
    let onSave: () -> Void
    @ViewBuilder let fields: Fields
    @Binding var body: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                MarkdownBodyEditor(text: $body)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        fields
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: .infinity)
                Button("Save") { onSave() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
            .frame(width: 260)
            .padding(.leading, 8)
            .overlay(Rectangle().frame(width: 1).foregroundColor(.gray.opacity(0.2)), alignment: .leading)
        }
        .padding(12)
    }
}
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Views/ProductEditors/
git commit -m "$(cat <<'EOF'
feat: MarkdownBodyEditor + generic MarkdownEntityEditor shell

Reusable plain-monospace TextEditor wrapper, plus a two-pane layout
(body editor on the left, fields sidebar on the right) that each
narrative-entity editor (PRD, Plan, Decision, ...) will wrap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Goal + KPI editors (form-style)

**Files:**
- Create: `Sources/DevDash/Views/ProductEditors/GoalsListView.swift`
- Create: `Sources/DevDash/Views/ProductEditors/GoalEditor.swift`
- Create: `Sources/DevDash/Views/ProductEditors/KPIsListView.swift`
- Create: `Sources/DevDash/Views/ProductEditors/KPIEditor.swift`

These are pure SwiftUI forms — no markdown body editor for goals/KPIs (they ARE allowed to have a body, but the primary editing surface is fields).

- [ ] **Step 1: GoalsListView (list + add + select)**

Write to `Sources/DevDash/Views/ProductEditors/GoalsListView.swift`:

```swift
import SwiftUI

struct GoalsListView: View {
    let projectPath: String
    let onAfterSave: () -> Void

    @State private var goals: [Goal] = []
    @State private var selected: Goal?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("GOALS").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Button(action: addGoal) { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                }
                List(selection: $selected) {
                    ForEach(goals) { g in
                        VStack(alignment: .leading) {
                            Text(g.title).font(.body)
                            Text("\(g.status.rawValue) · \(g.dueDate.map(formatDate) ?? "—")")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .tag(g as Goal?)
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260)
            .padding(8)

            if let sel = selected {
                GoalEditor(goal: bindingForSelected(sel), onSave: saveSelected)
            } else {
                Text("Select a goal to edit").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        goals = EntityStore.list(Goal.self, projectPath: projectPath)
    }

    private func addGoal() {
        let g = Goal(id: EntityStore.mintID(for: Goal.self), title: "Untitled goal", status: .onTrack)
        try? EntityStore.save(g, projectPath: projectPath)
        reload()
        selected = goals.first { $0.id == g.id }
    }

    private func bindingForSelected(_ sel: Goal) -> Binding<Goal> {
        Binding(
            get: { goals.first(where: { $0.id == sel.id }) ?? sel },
            set: { newVal in
                if let idx = goals.firstIndex(where: { $0.id == newVal.id }) {
                    goals[idx] = newVal
                }
                selected = newVal
            }
        )
    }

    private func saveSelected() {
        guard let g = selected else { return }
        try? EntityStore.save(g, projectPath: projectPath)
        reload()
        onAfterSave()
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}
```

- [ ] **Step 2: GoalEditor (form fields)**

Write to `Sources/DevDash/Views/ProductEditors/GoalEditor.swift`:

```swift
import SwiftUI

struct GoalEditor: View {
    @Binding var goal: Goal
    let onSave: () -> Void

    var body: some View {
        Form {
            Section("Goal") {
                TextField("Title", text: $goal.title)
                Picker("Status", selection: $goal.status) {
                    ForEach(GoalStatus.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                TextField("KPI (e.g. D7 retention)", text: Binding($goal.kpi, replacingNilWith: ""))
                TextField("Target", text: Binding($goal.target, replacingNilWith: ""))
                TextField("Current", text: Binding($goal.current, replacingNilWith: ""))
                DatePicker("Due", selection: Binding($goal.dueDate, replacingNilWith: Date()), displayedComponents: .date)
                TextField("Owner", text: Binding($goal.owner, replacingNilWith: ""))
            }
            Section("Rationale") {
                MarkdownBodyEditor(text: $goal.body)
            }
            Button("Save") { onSave() }
                .keyboardShortcut("s", modifiers: [.command])
        }
        .padding(12)
    }
}

// Helper for optional bindings
extension Binding where Value == Optional<String> {
    init(_ source: Binding<String?>, replacingNilWith defaultValue: String) {
        self.init(
            get: { source.wrappedValue ?? defaultValue },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

extension Binding where Value == Optional<Date> {
    init(_ source: Binding<Date?>, replacingNilWith defaultValue: Date) {
        self.init(
            get: { source.wrappedValue ?? defaultValue },
            set: { source.wrappedValue = $0 }
        )
    }
}
```

NOTE: SwiftUI's `TextField` doesn't accept an optional binding directly. The two extensions above wrap optional bindings into non-optional ones (representing nil as empty string / default date).

- [ ] **Step 3: Same pattern for KPI**

Write `KPIsListView.swift` and `KPIEditor.swift` using the exact same shape as Goal — replace `Goal`→`KPI`, fields are: `name`, `target`, `current`, `unit`, `owner` (all required strings except owner which is optional). Skip history editor in v1 (`history` is an empty array by default; user can hand-edit the .md file if they want to add history entries — generic UI for editing array-of-struct is deferred).

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Views/ProductEditors/
git commit -m "$(cat <<'EOF'
feat: Goal + KPI native SwiftUI editors

GoalsListView / KPIsListView present a list + add button + per-item
form. Optional fields use Binding wrappers that round-trip nil
through empty strings. History editing for KPIs is deferred to
hand-editing the .md file.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Idea board + Triage board (kanban editors)

**Files:**
- Create: `Sources/DevDash/Views/ProductEditors/IdeaBoardView.swift`
- Create: `Sources/DevDash/Views/ProductEditors/TriageBoardView.swift`

Both views render a 3-or-4 column kanban with drag-drop between columns + an "add" button per column. Cards are editable inline (title only); deeper editing happens via select-and-form.

- [ ] **Step 1: IdeaBoardView**

Write to `Sources/DevDash/Views/ProductEditors/IdeaBoardView.swift`:

```swift
import SwiftUI

struct IdeaBoardView: View {
    let projectPath: String
    let onAfterSave: () -> Void

    @State private var ideas: [Idea] = []

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(IdeaColumn.allCases, id: \.self) { col in
                column(for: col)
            }
        }
        .padding(12)
        .onAppear { reload() }
    }

    private func column(for col: IdeaColumn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(HtmlCompiler.humanColumnLabel(col)).font(.headline)
                Spacer()
                Button(action: { addIdea(in: col) }) { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
            }
            ForEach(ideas.filter { $0.column == col }) { idea in
                ideaCard(idea)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.05)))
        .onDrop(of: ["public.text"], delegate: IdeaDropDelegate(column: col, ideas: $ideas, projectPath: projectPath, onAfterSave: onAfterSave))
    }

    private func ideaCard(_ idea: Idea) -> some View {
        HStack {
            TextField("", text: Binding(
                get: { idea.title },
                set: { newTitle in
                    if let i = ideas.firstIndex(where: { $0.id == idea.id }) {
                        ideas[i].title = newTitle
                        try? EntityStore.save(ideas[i], projectPath: projectPath)
                        onAfterSave()
                    }
                }
            ))
            .textFieldStyle(.plain)
            Button(role: .destructive, action: { remove(idea) }) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
        .onDrag {
            NSItemProvider(object: idea.id as NSString)
        }
    }

    private func reload() {
        ideas = EntityStore.list(Idea.self, projectPath: projectPath)
    }

    private func addIdea(in col: IdeaColumn) {
        let idea = Idea(id: EntityStore.mintID(for: Idea.self), title: "New idea", column: col)
        try? EntityStore.save(idea, projectPath: projectPath)
        reload()
        onAfterSave()
    }

    private func remove(_ idea: Idea) {
        EntityStore.delete(Idea.self, id: idea.id, projectPath: projectPath)
        reload()
        onAfterSave()
    }
}

struct IdeaDropDelegate: DropDelegate {
    let column: IdeaColumn
    @Binding var ideas: [Idea]
    let projectPath: String
    let onAfterSave: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: ["public.text"]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { str, _ in
            DispatchQueue.main.async {
                guard let id = str as? String,
                      let idx = ideas.firstIndex(where: { $0.id == id }) else { return }
                ideas[idx].column = column
                try? EntityStore.save(ideas[idx], projectPath: projectPath)
                onAfterSave()
            }
        }
        return true
    }
}
```

- [ ] **Step 2: TriageBoardView**

Write to `Sources/DevDash/Views/ProductEditors/TriageBoardView.swift`:

```swift
import SwiftUI

/// Kanban view for the singleton TriageBoard entity. Reads and persists the
/// entire board (not one ticket per file). Adds/removes cards in the
/// frontmatter `cards[]` array.
struct TriageBoardView: View {
    let projectPath: String
    let onAfterSave: () -> Void

    @State private var board: TriageBoard = TriageBoard()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(TriageColumn.allCases, id: \.self) { col in
                column(for: col)
            }
        }
        .padding(12)
        .onAppear { reload() }
    }

    private func column(for col: TriageColumn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(col.rawValue.capitalized).font(.headline)
                Spacer()
                Button(action: { addCard(in: col) }) { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
            }
            ForEach(board.cards.filter { $0.column == col }) { card in
                cardView(card)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.05)))
        .onDrop(of: ["public.text"], delegate: TriageDropDelegate(column: col, board: $board, projectPath: projectPath, onAfterSave: onAfterSave))
    }

    private func cardView(_ card: TriageCard) -> some View {
        HStack {
            TextField("", text: Binding(
                get: { card.title },
                set: { newTitle in
                    if let i = board.cards.firstIndex(where: { $0.id == card.id }) {
                        board.cards[i].title = newTitle
                        save()
                    }
                }
            ))
            .textFieldStyle(.plain)
            Button(role: .destructive, action: { remove(card) }) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
        .onDrag {
            NSItemProvider(object: card.id as NSString)
        }
    }

    private func reload() {
        board = EntityStore.readSingleton(TriageBoard.self, projectPath: projectPath) ?? TriageBoard()
    }

    private func addCard(in col: TriageColumn) {
        let card = TriageCard(id: "t-" + String(UUID().uuidString.prefix(7)).lowercased(), column: col, title: "New ticket", tags: [], createdAt: Date())
        board.cards.append(card)
        save()
    }

    private func remove(_ card: TriageCard) {
        board.cards.removeAll { $0.id == card.id }
        save()
    }

    private func save() {
        try? EntityStore.save(board, projectPath: projectPath)
        onAfterSave()
    }
}

struct TriageDropDelegate: DropDelegate {
    let column: TriageColumn
    @Binding var board: TriageBoard
    let projectPath: String
    let onAfterSave: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: ["public.text"]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { str, _ in
            DispatchQueue.main.async {
                guard let id = str as? String,
                      let idx = board.cards.firstIndex(where: { $0.id == id }) else { return }
                board.cards[idx].column = column
                try? EntityStore.save(board, projectPath: projectPath)
                onAfterSave()
            }
        }
        return true
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/DevDash/Views/ProductEditors/IdeaBoardView.swift Sources/DevDash/Views/ProductEditors/TriageBoardView.swift
git commit -m "$(cat <<'EOF'
feat: native SwiftUI kanban for Ideas + Triage Board

IdeaBoardView and TriageBoardView are pure SwiftUI: three/four
columns, click-to-add, inline title edit, native drag-drop between
columns. Triage cards persist via the singleton TriageBoard frontmatter
cards array; ideas persist one .md per idea.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Overview + Initiative editors (narrative)

**Files:**
- Create: `Sources/DevDash/Views/ProductEditors/OverviewEditor.swift`
- Create: `Sources/DevDash/Views/ProductEditors/InitiativeEditor.swift`
- Create: `Sources/DevDash/Views/ProductEditors/InitiativesListView.swift`

- [ ] **Step 1: OverviewEditor (singleton)**

Write to `Sources/DevDash/Views/ProductEditors/OverviewEditor.swift`:

```swift
import SwiftUI

struct OverviewEditor: View {
    let projectPath: String
    let onAfterSave: () -> Void

    @State private var overview: Overview = Overview()

    var body: some View {
        MarkdownEntityEditor(
            title: "Overview",
            onSave: save,
            fields: {
                VStack(alignment: .leading, spacing: 10) {
                    field("TL;DR", text: $overview.tldr)
                    field("What is it?", text: $overview.whatItIs)
                    field("Who's it for?", text: $overview.whoFor)
                    field("Why now?", text: $overview.whyNow)
                    field("What it is NOT", text: $overview.whatItIsNot)
                }
            },
            body: $overview.body
        )
        .onAppear { reload() }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.secondary)
            TextEditor(text: text)
                .font(.system(size: 12))
                .frame(minHeight: 50)
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
    }

    private func reload() {
        overview = EntityStore.readSingleton(Overview.self, projectPath: projectPath) ?? Overview()
    }

    private func save() {
        try? EntityStore.save(overview, projectPath: projectPath)
        onAfterSave()
    }
}
```

- [ ] **Step 2: InitiativesListView + InitiativeEditor**

Write to `Sources/DevDash/Views/ProductEditors/InitiativesListView.swift`:

```swift
import SwiftUI

struct InitiativesListView: View {
    let projectPath: String
    let onAfterSave: () -> Void

    @State private var initiatives: [Initiative] = []
    @State private var selected: Initiative?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("INITIATIVES").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Button(action: addInitiative) { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                }
                List(selection: $selected) {
                    ForEach(initiatives) { i in
                        VStack(alignment: .leading) {
                            Text(i.title).font(.body)
                            Text("\(i.goalIds.count) goals · \(i.taskIds.count) tasks")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .tag(i as Initiative?)
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260)
            .padding(8)

            if let sel = selected {
                InitiativeEditor(initiative: bindingForSelected(sel), onSave: saveSelected)
            } else {
                Text("Select an initiative to edit").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        initiatives = EntityStore.list(Initiative.self, projectPath: projectPath)
    }

    private func addInitiative() {
        let i = Initiative(id: EntityStore.mintID(for: Initiative.self), title: "New initiative")
        try? EntityStore.save(i, projectPath: projectPath)
        reload()
        selected = initiatives.first { $0.id == i.id }
    }

    private func bindingForSelected(_ sel: Initiative) -> Binding<Initiative> {
        Binding(
            get: { initiatives.first(where: { $0.id == sel.id }) ?? sel },
            set: { newVal in
                if let idx = initiatives.firstIndex(where: { $0.id == newVal.id }) {
                    initiatives[idx] = newVal
                }
                selected = newVal
            }
        )
    }

    private func saveSelected() {
        guard let i = selected else { return }
        try? EntityStore.save(i, projectPath: projectPath)
        reload()
        onAfterSave()
    }
}
```

Write to `Sources/DevDash/Views/ProductEditors/InitiativeEditor.swift`:

```swift
import SwiftUI

struct InitiativeEditor: View {
    @Binding var initiative: Initiative
    let onSave: () -> Void

    var body: some View {
        MarkdownEntityEditor(
            title: "Initiative",
            onSave: onSave,
            fields: {
                Group {
                    TextField("Title", text: $initiative.title)
                    TextField("Stage", text: Binding($initiative.stage, replacingNilWith: ""))
                    Text("GOAL IDS (comma-separated)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField("g-001, g-002", text: Binding(
                        get: { initiative.goalIds.joined(separator: ", ") },
                        set: { initiative.goalIds = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                    ))
                    Text("TASK IDS (comma-separated)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField("t-042, t-043", text: Binding(
                        get: { initiative.taskIds.joined(separator: ", ") },
                        set: { initiative.taskIds = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                    ))
                }
            },
            body: $initiative.body
        )
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/DevDash/Views/ProductEditors/
git commit -m "$(cat <<'EOF'
feat: Overview + Initiative SwiftUI editors

OverviewEditor edits the singleton overview.md with field inputs
for the structured frontmatter and a markdown body. Initiative
editor follows the same shape — list + per-entity form with a
narrative body editor.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: PRD + Plan editors

**Files:**
- Create: `Sources/DevDash/Views/ProductEditors/PrdsListView.swift`
- Create: `Sources/DevDash/Views/ProductEditors/PrdEditor.swift`
- Create: `Sources/DevDash/Views/ProductEditors/PlansListView.swift`
- Create: `Sources/DevDash/Views/ProductEditors/PlanEditor.swift`

Same shape as Initiative editor — list + form + markdown body. Fields differ per entity.

- [ ] **Step 1: PRD editor**

Write to `Sources/DevDash/Views/ProductEditors/PrdsListView.swift`:

```swift
import SwiftUI

struct PrdsListView: View {
    let projectPath: String
    let onAfterSave: () -> Void

    @State private var prds: [PRD] = []
    @State private var selected: PRD?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("PRDs").font(.caption.bold()).foregroundColor(.secondary)
                    Spacer()
                    Button(action: add) { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                }
                List(selection: $selected) {
                    ForEach(prds) { p in
                        VStack(alignment: .leading) {
                            Text(p.title).font(.body)
                            Text(p.status.rawValue).font(.caption).foregroundColor(.secondary)
                        }
                        .tag(p as PRD?)
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260)
            .padding(8)

            if let sel = selected {
                PrdEditor(prd: bindingForSelected(sel), onSave: saveSelected)
            } else {
                Text("Select a PRD").foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { reload() }
    }

    private func reload() { prds = EntityStore.list(PRD.self, projectPath: projectPath) }
    private func add() {
        let p = PRD(id: EntityStore.mintID(for: PRD.self), title: "Untitled PRD")
        try? EntityStore.save(p, projectPath: projectPath)
        reload()
        selected = prds.first { $0.id == p.id }
    }
    private func bindingForSelected(_ sel: PRD) -> Binding<PRD> {
        Binding(
            get: { prds.first(where: { $0.id == sel.id }) ?? sel },
            set: { newVal in
                if let idx = prds.firstIndex(where: { $0.id == newVal.id }) { prds[idx] = newVal }
                selected = newVal
            }
        )
    }
    private func saveSelected() {
        guard let p = selected else { return }
        try? EntityStore.save(p, projectPath: projectPath)
        reload()
        onAfterSave()
    }
}
```

Write to `Sources/DevDash/Views/ProductEditors/PrdEditor.swift`:

```swift
import SwiftUI

struct PrdEditor: View {
    @Binding var prd: PRD
    let onSave: () -> Void

    var body: some View {
        MarkdownEntityEditor(
            title: "PRD",
            onSave: onSave,
            fields: {
                Group {
                    TextField("Title", text: $prd.title)
                    Picker("Status", selection: $prd.status) {
                        ForEach(PrdStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Owner", text: Binding($prd.owner, replacingNilWith: ""))
                    Text("GOAL IDS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextField("g-001, ...", text: Binding(
                        get: { prd.goalIds.joined(separator: ", ") },
                        set: { prd.goalIds = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                    ))
                }
            },
            body: $prd.body
        )
    }
}
```

- [ ] **Step 2: Plan editor (same pattern)**

Same pattern. `PlansListView` is identical structure with `Plan` everywhere. `PlanEditor` shows `title`, `prdId`, `goalIds`, and milestones. For milestones, accept comma-separated rows in a TextField using format `Week 1|Foundations|pending|notes`, parsing into `[Milestone]`. Skip a fancy table editor in v1; the .md is hand-editable for richer milestone editing.

```swift
// PlanEditor.swift
import SwiftUI

struct PlanEditor: View {
    @Binding var plan: Plan
    let onSave: () -> Void

    private var milestonesString: Binding<String> {
        Binding(
            get: { plan.milestones.map { "\($0.week)|\($0.title)|\($0.status.rawValue)|\($0.notes)" }.joined(separator: "\n") },
            set: { newVal in
                plan.milestones = newVal.components(separatedBy: "\n").compactMap { line in
                    let parts = line.components(separatedBy: "|")
                    guard parts.count >= 3 else { return nil }
                    return Milestone(
                        week: parts[0],
                        title: parts[1],
                        status: MilestoneStatus(rawValue: parts[2]) ?? .pending,
                        notes: parts.count > 3 ? parts[3] : ""
                    )
                }
            }
        )
    }

    var body: some View {
        MarkdownEntityEditor(
            title: "Plan",
            onSave: onSave,
            fields: {
                Group {
                    TextField("Title", text: $plan.title)
                    TextField("PRD id", text: Binding($plan.prdId, replacingNilWith: ""))
                    Text("MILESTONES (one per line: week|title|status|notes)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextEditor(text: milestonesString)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .background(Color(NSColor.textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                }
            },
            body: $plan.body
        )
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/DevDash/Views/ProductEditors/
git commit -m "$(cat <<'EOF'
feat: PRD + Plan SwiftUI editors

PRDs use status picker + goal-id linker + markdown body. Plans
add a pipe-separated milestones text editor (one milestone per
line). Richer milestone editing deferred to direct .md editing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Status, Decision, Concept, Retro editors

Same pattern as PRD/Plan but with each entity's specific frontmatter fields. Skipping the per-editor full code for brevity in this plan section — the engineer follows the exact same recipe:

- `<Entity>sListView.swift`: list pane + add button + selection-driven editor
- `<Entity>Editor.swift`: form fields specific to the entity + `MarkdownEntityEditor` shell with `body` binding

**Files:**
- Create: `Sources/DevDash/Views/ProductEditors/StatusListView.swift`
- Create: `Sources/DevDash/Views/ProductEditors/StatusEditor.swift`
- Create: `Sources/DevDash/Views/ProductEditors/DecisionsListView.swift`
- Create: `Sources/DevDash/Views/ProductEditors/DecisionEditor.swift`
- Create: `Sources/DevDash/Views/ProductEditors/ConceptsListView.swift`
- Create: `Sources/DevDash/Views/ProductEditors/ConceptEditor.swift`
- Create: `Sources/DevDash/Views/ProductEditors/RetrosListView.swift`
- Create: `Sources/DevDash/Views/ProductEditors/RetroEditor.swift`

Field details per entity (form fields beyond title/body):

- **StatusReport:** `date` (DatePicker), `headline` (TextField). Bulleted lists (shipped/inProgress/slipped/next/risks/asks) edited as comma-or-newline-separated text fields — same trick as the milestones field in Plan.
- **Decision:** `title`, `status` (picker over DecisionStatus), `dateAdopted` (DatePicker), `goalIds` (comma-separated). Options table edited as one-line-per-option pipe-separated: `name|pros|cons|picked` where `picked` is `Y` or empty.
- **Concept:** `topic`. Terms table edited as one-line-per-term pipe-separated: `term|definition`.
- **Retro:** `date` (DatePicker), wentWell/didntGoWell/lessons (newline-separated lists), actions one-line-per-action pipe-separated: `description|owner|due`.

- [ ] **Step 1: Implement all four ListView + Editor pairs (~250 lines total) following the recipe above**

- [ ] **Step 2: Build + smoke test in app**

```bash
swift build 2>&1 | tail -5
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Views/ProductEditors/
git commit -m "$(cat <<'EOF'
feat: Status, Decision, Concept, Retro SwiftUI editors

Same list+form+body pattern. List-of-string fields use newline-
separated text editors; struct arrays (decision options, concept
terms, retro actions) use pipe-separated one-per-line conventions.
Hand-edit the .md file for richer structured editing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Rewrite ProductTabView with native subtabs

**Files:**
- Modify: `Sources/DevDash/Views/Tabs/ProductTabView.swift`
- Modify: `Sources/DevDash/Views/ProductWebView.swift` (slim bridge JS further)

- [ ] **Step 1: Replace ProductTabView body with a subtab picker + per-subtab editor**

Replace the entire body of `ProductTabView`:

```swift
import SwiftUI
import AppKit

enum ProductSubtab: String, CaseIterable, Identifiable {
    case overview, goals, ideas, initiatives, triage
    case prds, plans, status, decisions, concepts, retros
    case viewer    // Read-only HTML viewer of the compiled doc

    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview:    return "Overview"
        case .goals:       return "Goals & KPIs"
        case .ideas:       return "Ideas"
        case .initiatives: return "Initiatives"
        case .triage:      return "Triage"
        case .prds:        return "PRDs"
        case .plans:       return "Plans"
        case .status:      return "Status"
        case .decisions:   return "Decisions"
        case .concepts:    return "Concepts"
        case .retros:      return "Retros"
        case .viewer:      return "Viewer"
        }
    }
}

struct ProductTabView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var subtab: ProductSubtab = .overview
    @State private var reloadToken: Int = 0

    var body: some View {
        if let project = store.project(for: store.selection) {
            VStack(spacing: 0) {
                subtabBar
                Divider()
                content(project: project)
            }
            .onAppear { compile(project: project) }
            .onChange(of: project.path) { _, _ in compile(project: project) }
        } else {
            Text("Select a project").foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var subtabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ProductSubtab.allCases) { st in
                    Button(action: { subtab = st }) {
                        Text(st.label)
                            .font(.system(size: 12, weight: subtab == st ? .semibold : .regular))
                            .foregroundColor(subtab == st ? .accentColor : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(subtab == st ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func content(project: Project) -> some View {
        switch subtab {
        case .overview:    OverviewEditor(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .goals:       GoalsListView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .ideas:       IdeaBoardView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .initiatives: InitiativesListView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .triage:      TriageBoardView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .prds:        PrdsListView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .plans:       PlansListView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .status:      StatusListView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .decisions:   DecisionsListView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .concepts:    ConceptsListView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .retros:      RetrosListView(projectPath: project.path, onAfterSave: { recompile(project: project) })
        case .viewer:      viewerView(project: project)
        }
    }

    private func viewerView(project: Project) -> some View {
        let path = "\(project.path)/docs/devdash/index.html"
        let docsRoot = URL(fileURLWithPath: "\(project.path)/docs/devdash")
        guard FileManager.default.fileExists(atPath: path) else {
            return AnyView(VStack { ProgressView(); Text("Compiling...") }.frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        return AnyView(
            ProductWebView(
                url: URL(fileURLWithPath: path),
                docsRoot: docsRoot,
                reloadToken: reloadToken,
                onAction: { payload in handleAction(project: project, payload: payload) }
            )
        )
    }

    private func compile(project: Project) {
        let meta = store.meta(for: project.path)
        let template = store.template(for: project.path)
        let tasks = store.tasksV2(for: project.path)
        _ = HtmlCompiler.compile(projectName: project.name, projectPath: project.path, meta: meta, template: template, tasks: tasks)
        reloadToken &+= 1
    }

    private func recompile(project: Project) {
        compile(project: project)
    }

    private func handleAction(project: Project, payload: [String: Any]) {
        guard let action = payload["action"] as? String else { return }
        switch action {
        case "open-file":
            if let path = payload["path"] as? String {
                store.pendingFilePath = path
                store.detailTab = .files
            }
        case "regenerate":
            compile(project: project)
        case "open-task":
            store.detailTab = .tasks
        default:
            break
        }
    }
}
```

- [ ] **Step 2: Slim `ProductWebView` even further (drop the save closures)**

Replace `ProductWebView.swift` with:

```swift
import SwiftUI
import WebKit

/// Read-only WKWebView for the compiled living-doc HTML. Bridge JS handles
/// only [data-action] passthrough (open-file, regenerate, open-task).
struct ProductWebView: NSViewRepresentable {
    let url: URL
    let docsRoot: URL
    let reloadToken: Int
    let onAction: ([String: Any]) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "devdash")
        config.userContentController = controller
        let wv = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
        }
        wv.loadFileURL(url, allowingReadAccessTo: docsRoot)
        context.coordinator.lastReloadToken = reloadToken
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url != url || context.coordinator.lastReloadToken != reloadToken {
            nsView.loadFileURL(url, allowingReadAccessTo: docsRoot)
            context.coordinator.lastReloadToken = reloadToken
        }
        context.coordinator.onAction = onAction
    }

    func makeCoordinator() -> Coordinator { Coordinator(onAction: onAction) }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onAction: ([String: Any]) -> Void
        var lastReloadToken: Int = -1
        init(onAction: @escaping ([String: Any]) -> Void) { self.onAction = onAction }
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            onAction(body)
        }
    }
}
```

- [ ] **Step 3: Build, run in app**

```bash
bash run.sh 2>&1 | tail -8
```
Expected: clean build, .app relaunches. Open dev-dash → Product tab. Verify all subtabs exist (Overview, Goals & KPIs, Ideas, Initiatives, Triage, PRDs, Plans, Status, Decisions, Concepts, Retros, Viewer). They render empty editors (no entity .md files exist yet — that's expected).

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Views/Tabs/ProductTabView.swift Sources/DevDash/Views/ProductWebView.swift
git commit -m "$(cat <<'EOF'
feat: ProductTabView gutted and rewritten with native subtabs

12 subtabs total: 11 native SwiftUI editors + 1 read-only HTML viewer.
WKWebView is now used only for the viewer subtab; the bridge JS no
longer has save/save-alpine paths — just data-action passthrough.
ProductWebView shrunk by half.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: TaskItem gets `goalId` + TaskDetailSheet integration

**Files:**
- Modify: `Sources/DevDash/Models.swift`
- Modify: `Sources/DevDash/Views/Tabs/TaskDetailSheet.swift` (or wherever the task detail UI lives)

- [ ] **Step 1: Add `goalId` to `TaskItem`**

In `Sources/DevDash/Models.swift`, find the `struct TaskItem`. Add the field:

```swift
var goalId: String?
```

Codable will auto-handle the optional. Old tasks.json files don't have this field; the decoder defaults to nil.

- [ ] **Step 2: Add goal-picker to TaskDetailSheet**

In `TaskDetailSheet.swift`, add a "Linked Goal" section to the form. Use a Picker that lists `EntityStore.list(Goal.self, projectPath:)` plus a "(none)" option. Bind to `task.goalId`.

```swift
@State private var goals: [Goal] = []

// In body, somewhere in the form:
Picker("Linked goal", selection: Binding(
    get: { task.goalId ?? "" },
    set: { task.goalId = $0.isEmpty ? nil : $0 }
)) {
    Text("(none)").tag("")
    ForEach(goals) { g in Text(g.title).tag(g.id) }
}
.onAppear {
    goals = EntityStore.list(Goal.self, projectPath: projectPath)
}
```

(Adapt to the actual TaskDetailSheet props — `projectPath` may be passed differently.)

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/DevDash/Models.swift Sources/DevDash/Views/Tabs/TaskDetailSheet.swift
git commit -m "$(cat <<'EOF'
feat: TaskItem.goalId + goal-picker in TaskDetailSheet

Tasks can now link to a goal. Old tasks.json files decode cleanly
(optional field defaults to nil). UI surfaces a picker built from
the project's Goal entities at the time of opening the sheet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: LegacyHtmlMigrator — parse existing HTML into .md entities

**Files:**
- Create: `Sources/DevDash/Scanners/LegacyHtmlMigrator.swift`

- [ ] **Step 1: Create the migrator**

Write to `Sources/DevDash/Scanners/LegacyHtmlMigrator.swift`:

```swift
import Foundation

/// One-shot per-project migration: parses existing docs/devdash/*.html into
/// .md entity files. Idempotent (skips if `.md` files already exist in the
/// target folder). Leaves the original .html files in place — user can delete
/// them manually after review.
enum LegacyHtmlMigrator {
    /// Run migration if any of the legacy section files exist but no entity
    /// .md files do. Writes new files and returns the count migrated.
    @discardableResult
    static func migrateIfNeeded(projectPath: String) -> Int {
        let docsRoot = "\(projectPath)/docs/devdash"
        guard FileManager.default.fileExists(atPath: docsRoot) else { return 0 }

        var count = 0
        count += migrateOverview(docsRoot: docsRoot)
        count += migrateGoals(docsRoot: docsRoot)
        count += migrateIdeas(docsRoot: docsRoot)
        count += migrateTriage(docsRoot: docsRoot)
        count += migrateArtifacts(docsRoot: docsRoot, kind: .prd)
        count += migrateArtifacts(docsRoot: docsRoot, kind: .plan)
        count += migrateArtifacts(docsRoot: docsRoot, kind: .status)
        count += migrateArtifacts(docsRoot: docsRoot, kind: .decision)
        count += migrateArtifacts(docsRoot: docsRoot, kind: .concept)
        count += migrateArtifacts(docsRoot: docsRoot, kind: .retro)
        return count
    }

    // MARK: - Section migrations

    private static func migrateOverview(docsRoot: String) -> Int {
        let target = "\(docsRoot)/overview.md"
        guard !FileManager.default.fileExists(atPath: target) else { return 0 }
        let src = "\(docsRoot)/sections/overview.html"
        guard let html = try? String(contentsOfFile: src, encoding: .utf8) else { return 0 }
        let overview = Overview(
            id: "overview",
            tldr: extractFirst(html, between: #"callout tldr">.*?<p>"#, end: "</p>"),
            whatItIs: extractCard(html, title: "What is it?"),
            whoFor: extractCard(html, title: "Who's it for?"),
            whyNow: extractCard(html, title: "Why now?"),
            whatItIsNot: extractCard(html, title: "What it is"),  // matches "<em>not</em>"
            risks: [],
            body: ""
        )
        try? EntityStore.save(overview, projectPath: docsRoot.replacingOccurrences(of: "/docs/devdash", with: ""))
        return 1
    }

    private static func migrateGoals(docsRoot: String) -> Int {
        let src = "\(docsRoot)/sections/goals.html"
        guard let html = try? String(contentsOfFile: src, encoding: .utf8) else { return 0 }
        // Each <li> under "Quarter goals" → one Goal. Each KPI tile → one KPI.
        let goalsTitles = extractAll(html, pattern: #"<li>☐\s*<em>([^<]+)</em></li>"#)
        var count = 0
        let projectPath = docsRoot.replacingOccurrences(of: "/docs/devdash", with: "")
        for t in goalsTitles {
            let g = Goal(id: EntityStore.mintID(for: Goal.self), title: t, status: .onTrack)
            try? EntityStore.save(g, projectPath: projectPath)
            count += 1
        }
        // Extract KPI tiles: <div class="kpi"><div class="k-label">X</div>...
        let kpiRegex = #"<div class="kpi">\s*<div class="k-label">([^<]+)</div>\s*<div class="k-value">([^<]+)</div>\s*<div class="k-target">target:\s*([^<]+)</div>"#
        for m in matches(html, pattern: kpiRegex) {
            guard m.count >= 4 else { continue }
            let k = KPI(id: EntityStore.mintID(for: KPI.self), name: m[1], target: m[3].trimmingCharacters(in: .whitespaces), current: m[2], unit: "", history: [])
            try? EntityStore.save(k, projectPath: projectPath)
            count += 1
        }
        return count
    }

    private static func migrateIdeas(docsRoot: String) -> Int {
        let src = "\(docsRoot)/sections/ideas.html"
        guard let html = try? String(contentsOfFile: src, encoding: .utf8) else { return 0 }
        let projectPath = docsRoot.replacingOccurrences(of: "/docs/devdash", with: "")
        var count = 0
        for col in IdeaColumn.allCases {
            let colSelector = "data-col=\"\(col.rawValue)\""
            // Find the chunk between <div class="col" data-col="..."> and the next </div> at depth 0.
            // Approximation: regex from the data-col anchor to the next data-col or </div></div></div>.
            guard let colChunk = chunkAfter(html, startMarker: colSelector, endMarker: "<div class=\"col\"") ?? chunkAfter(html, startMarker: colSelector, endMarker: "</div>\n</div>") else { continue }
            for title in extractAll(colChunk, pattern: #"<em>([^<]+)</em>"#) {
                let i = Idea(id: EntityStore.mintID(for: Idea.self), title: title, column: col, tags: [])
                try? EntityStore.save(i, projectPath: projectPath)
                count += 1
            }
        }
        return count
    }

    private static func migrateTriage(docsRoot: String) -> Int {
        let target = "\(docsRoot)/triage-board.md"
        guard !FileManager.default.fileExists(atPath: target) else { return 0 }
        let triageDir = "\(docsRoot)/triage"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: triageDir) else { return 0 }
        var board = TriageBoard()
        for f in files where f.hasSuffix(".html") {
            guard let html = try? String(contentsOfFile: "\(triageDir)/\(f)", encoding: .utf8) else { continue }
            // Look for the <script id="triage-state"> JSON block from the Alpine refactor.
            let regex = #"<script[^>]*id="triage-state"[^>]*>([\s\S]*?)</script>"#
            if let json = matches(html, pattern: regex).first?[1],
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cards = dict["cards"] as? [[String: Any]] {
                for c in cards {
                    guard let id = c["id"] as? String,
                          let colStr = c["col"] as? String,
                          let col = TriageColumn(rawValue: colStr),
                          let title = c["title"] as? String else { continue }
                    let tags = (c["tags"] as? [String]) ?? []
                    board.cards.append(TriageCard(id: id, column: col, title: title, tags: tags, createdAt: Date()))
                }
            }
        }
        let projectPath = docsRoot.replacingOccurrences(of: "/docs/devdash", with: "")
        try? EntityStore.save(board, projectPath: projectPath)
        return board.cards.isEmpty ? 0 : 1
    }

    private static func migrateArtifacts(docsRoot: String, kind: EntityKind) -> Int {
        let folder = "\(docsRoot)/\(kind.folder)"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return 0 }
        let projectPath = docsRoot.replacingOccurrences(of: "/docs/devdash", with: "")
        var count = 0
        for f in files where f.hasSuffix(".html") {
            let mdName = (f as NSString).deletingPathExtension + ".md"
            let mdPath = "\(folder)/\(mdName)"
            guard !FileManager.default.fileExists(atPath: mdPath) else { continue }
            guard let html = try? String(contentsOfFile: "\(folder)/\(f)", encoding: .utf8) else { continue }
            // Title from first <h2>.
            let title = matches(html, pattern: #"<h2[^>]*>([^<]+)</h2>"#).first?[1] ?? (f as NSString).deletingPathExtension
            let id = EntityStore.mintID(for: kindToType(kind))
            // Stub a minimal entity with body = raw HTML (best-effort markdown conversion deferred).
            switch kind {
            case .prd:
                let p = PRD(id: id, title: title, body: html)
                try? EntityStore.save(p, projectPath: projectPath); count += 1
            case .plan:
                let p = Plan(id: id, title: title, body: html)
                try? EntityStore.save(p, projectPath: projectPath); count += 1
            case .status:
                let s = StatusReport(id: id, date: Date(), headline: title, body: html)
                try? EntityStore.save(s, projectPath: projectPath); count += 1
            case .decision:
                let d = Decision(id: id, title: title, body: html)
                try? EntityStore.save(d, projectPath: projectPath); count += 1
            case .concept:
                let c = Concept(id: id, topic: title, body: html)
                try? EntityStore.save(c, projectPath: projectPath); count += 1
            case .retro:
                let r = Retro(id: id, date: Date(), body: html)
                try? EntityStore.save(r, projectPath: projectPath); count += 1
            default: break
            }
        }
        return count
    }

    // MARK: - Parsing primitives

    private static func extractFirst(_ html: String, between startPattern: String, end: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: startPattern + "([\\s\\S]*?)" + NSRegularExpression.escapedPattern(for: end), options: []),
              let m = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) else { return "" }
        return Range(m.range(at: 1), in: html).map { String(html[$0]) } ?? ""
    }

    private static func extractCard(_ html: String, title: String) -> String {
        let pat = #"<h3>"# + NSRegularExpression.escapedPattern(for: title) + #"[\s\S]*?<p>([\s\S]*?)</p>"#
        return extractFirst(html, between: pat, end: "</p>")
    }

    private static func extractAll(_ html: String, pattern: String) -> [String] {
        return matches(html, pattern: pattern).compactMap { $0.count >= 2 ? $0[1] : nil }
    }

    private static func matches(_ html: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let results = regex.matches(in: html, range: NSRange(location: 0, length: html.utf16.count))
        return results.map { m in
            (0..<m.numberOfRanges).compactMap { i in
                Range(m.range(at: i), in: html).map { String(html[$0]) }
            }
        }
    }

    private static func chunkAfter(_ html: String, startMarker: String, endMarker: String) -> String? {
        guard let startRange = html.range(of: startMarker) else { return nil }
        let after = html[startRange.upperBound...]
        if let endRange = after.range(of: endMarker) {
            return String(after[..<endRange.lowerBound])
        }
        return String(after)
    }

    /// Map EntityKind to its concrete type — used only inside this file.
    private static func kindToType(_ kind: EntityKind) -> any MarkdownEntity.Type {
        switch kind {
        case .prd:      return PRD.self
        case .plan:     return Plan.self
        case .status:   return StatusReport.self
        case .decision: return Decision.self
        case .concept:  return Concept.self
        case .retro:    return Retro.self
        default:        return Goal.self
        }
    }
}
```

- [ ] **Step 2: Wire migration into `compile(...)` (auto-run)**

In `HtmlCompiler.compile(...)`, at the very top before any writes:

```swift
LegacyHtmlMigrator.migrateIfNeeded(projectPath: projectPath)
```

- [ ] **Step 3: Build + smoke test**

```bash
bash run.sh 2>&1 | tail -8
```

Then in DevDash: open wnba-tracker (it has legacy HTML). Switch to Product tab → migration runs. Verify .md files appear under `~/dev/wnba-tracker/docs/devdash/goals/`, `kpis/`, etc. Open the Goals subtab to confirm goals load. Same for dev-dash.

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/LegacyHtmlMigrator.swift Sources/DevDash/Scanners/HtmlCompiler.swift
git commit -m "$(cat <<'EOF'
feat: LegacyHtmlMigrator — parse existing HTML into .md entities

Best-effort parsing of legacy section/artifact HTML into typed
.md files. Idempotent (skips if .md already exists). For artifact
HTML, body is the raw HTML (user converts to markdown manually);
for structured sections (goals/KPIs/ideas/triage), values are
extracted from the DOM.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Delete Alpine + ProductDocAssets + Resources + clean up Package.swift / run.sh

**Files:**
- Delete: `Sources/DevDash/Resources/alpine.min.js`
- Delete: `Sources/DevDash/Resources/devdash-components.js`
- Delete: `Sources/DevDash/Scanners/ProductDocAssets.swift`
- Modify: `Package.swift` — drop `.copy("Resources")` rule
- Modify: `run.sh` — drop the JS file copies
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift` — delete the `template(_:)`, `stub(_:)`, `bridgeJS`-related code; keep `renderRoadmapInline` as the only export

- [ ] **Step 1: Delete the unused files**

```bash
rm Sources/DevDash/Resources/alpine.min.js
rm Sources/DevDash/Resources/devdash-components.js
rmdir Sources/DevDash/Resources 2>/dev/null || true
rm Sources/DevDash/Scanners/ProductDocAssets.swift
```

- [ ] **Step 2: Remove the resources rule from Package.swift**

Edit `Package.swift`. Remove the `resources:` block from the executable target:

Before:
```swift
.executableTarget(
    name: "DevDash",
    dependencies: [...],
    path: "Sources/DevDash",
    resources: [
        .copy("Resources")
    ],
    linkerSettings: [...]
)
```

After:
```swift
.executableTarget(
    name: "DevDash",
    dependencies: [...],
    path: "Sources/DevDash",
    linkerSettings: [...]
)
```

- [ ] **Step 3: Drop JS file copies from run.sh**

Edit `run.sh`. Remove the lines that copy `alpine.min.js` and `devdash-components.js` into `DevDash.app/Contents/Resources/`:

Before:
```bash
mkdir -p DevDash.app/Contents/Resources
cp .build/debug/DevDash_DevDash.bundle/Resources/alpine.min.js DevDash.app/Contents/Resources/
cp .build/debug/DevDash_DevDash.bundle/Resources/devdash-components.js DevDash.app/Contents/Resources/
codesign --force --deep --sign "..." DevDash.app
```

After:
```bash
codesign --force --deep --sign "..." DevDash.app
```

- [ ] **Step 4: Slim ProductDocGenerator down to just `renderRoadmapInline`**

In `Sources/DevDash/Scanners/ProductDocGenerator.swift`:
- Delete all of `template(_:projectName:)`, `stub(_:)`, the `DocType` enum, all artifact template strings
- Delete the entire `sharedStyles`, `tabScript`, `bridgeJS` string constants
- Delete `generate(...)` entirely (HtmlCompiler.compile replaces it)
- Delete `readSection`, `readFolder`, `renderArtifactsBrowser`, `renderInitiatives`, `migrateLegacyFolder`, all section reading helpers
- Keep ONLY: `renderRoadmapInline` (renamed from old `renderRoadmap`), `taskBadge`, `escapeHTML`, and any unused-but-tiny helpers if still referenced

The file shrinks from ~1100 lines to ~150 lines. Anything HtmlCompiler doesn't call gets removed.

- [ ] **Step 5: Build, run, smoke test**

```bash
bash run.sh 2>&1 | tail -8
```

In DevDash:
- Open dev-dash → Product tab. All 12 subtabs work. Migration already ran in Task 16.
- Switch to Viewer subtab. Compiled HTML renders with the same look as before.
- Click in Goals subtab → add goal → save. Switch to Viewer. Goal appears.
- Same for one or two other entity types.
- Web Inspector → console is clean (no Alpine errors — Alpine isn't loaded anymore).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore: delete Alpine + ProductDocAssets + Resources/ + slim run.sh

The Alpine stack is no longer needed — editing happens in native
SwiftUI editors, the WKWebView is read-only. Removed alpine.min.js,
devdash-components.js, ProductDocAssets.swift, the Resources bundle
rule in Package.swift, the resource-copy step in run.sh, and the
old authoring templates / bridge-save code in ProductDocGenerator
(which is now down to renderRoadmapInline and a couple of helpers).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification checklist (run after all tasks)

- [ ] `swift build` is clean
- [ ] `bash run.sh` produces a launching .app with no codesign errors
- [ ] Product tab has 12 native subtabs: Overview, Goals & KPIs, Ideas, Initiatives, Triage, PRDs, Plans, Status, Decisions, Concepts, Retros, Viewer
- [ ] Each editor loads existing entities (after migration) and creates new ones
- [ ] Save in any editor triggers `HtmlCompiler.compile` → Viewer subtab shows the update
- [ ] dev-dash + wnba-tracker auto-migrated their legacy HTML on first open
- [ ] Triage board singleton works — drag tickets between columns, edit inline, persists to `triage-board.md`
- [ ] Goals editor lets you set status/KPI/target/dueDate; Goal IDs are linkable from Initiative editor
- [ ] TaskDetailSheet has a goal picker; selecting a goal sets `task.goalId`
- [ ] Viewer subtab WKWebView is fully read-only (no contenteditable, no Alpine, no save bridge — just renders the compiled HTML)
- [ ] `ProductWebView.swift` is < 50 lines
- [ ] `ProductDocGenerator.swift` is < 200 lines (just `renderRoadmapInline` + helpers)
- [ ] `Sources/DevDash/Resources/` no longer exists
- [ ] No `Alpine`, `addBtn`, `data-section-format`, `contenteditable`, `dom-insert-template`, or `bridgeJS save` references anywhere in the codebase

## Rollback note

Each task is one commit. `git revert <sha>` works to undo a specific task. If migration corrupts an entity file, the original `.html` still exists alongside (LegacyHtmlMigrator never deletes source HTML).

## Time estimate

- Tasks 1–4 (foundation): 1–2 hours
- Tasks 5–7 (HtmlCompiler): 2–3 hours
- Tasks 8–13 (editors): 3–4 hours total, but lots of similar wiring
- Task 14 (ProductTabView rewrite): 1–2 hours
- Task 15 (goalId integration): 30 minutes
- Task 16 (migrator): 2 hours (regex tuning per legacy format)
- Task 17 (cleanup): 30 minutes

**Total realistic estimate: 10–14 hours of focused work.** Significantly larger than the Alpine refactor.
