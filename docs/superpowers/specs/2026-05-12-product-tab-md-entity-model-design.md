# Product Tab — Markdown-Per-Entity Architecture

**Date:** 2026-05-12
**Status:** Approved (brainstorm), ready for implementation plan
**Supersedes:** The "HTML-as-source-of-truth" model crystallized in `docs/superpowers/specs/2026-05-10-product-tab-alpine-refactor-design.md` and codified in the user's memory at `devdash_living_doc_alpine_refactor.md`. This spec replaces that authoring model entirely. The Alpine refactor's commits (Tasks 1–10, May 10–11) remain in git history but most of their runtime payload is deleted by this change.

## Why

After implementing the Alpine refactor, two structural problems became unavoidable:

1. **Editing UX is janky.** The `contenteditable + Alpine + bridge JS + auto-save` dance has too many escape layers (Swift → JS → HTML attribute → JS string) and too many integration points (Alpine scope rules, contenteditable focus traps, save protocols differing per section). The user spent hours debugging issues like `@click` directives silently not binding because there was no `x-data` ancestor.

2. **HTML strings can't model relationships.** The user wants Goals to drive Tasks (via `goalId`), KPIs to be tracked over time, Initiatives to roll up Goals and Tasks. HTML-with-embedded-JSON works for the leaf nodes (triage cards) but doesn't scale to a relational model.

The HTML-living-doc remains valuable as a **read artifact** — humans like the rendered view, AI tools can grep it, it's shareable. But it's a bad **write surface** for structured data.

## Decision

Flip the model: structured data is the source of truth, HTML is a compiled view.

- **One markdown file per entity** at known paths under `docs/devdash/`
- **YAML frontmatter** carries structured fields; **markdown body** carries narrative
- **Native SwiftUI editors** per entity type — no more contenteditable, no more bridge JS for editing
- **HTML compiler** (`HtmlCompiler.swift`) renders entities into static HTML for viewing
- **WKWebView is read-only** — the bridge JS shrinks to `[data-action]` pass-through for native callbacks only (open-file, regenerate)

## Entity model

All entity files live under `<project>/docs/devdash/`. Each section gets its own folder (or singleton file).

### Singletons

| Entity | File | Frontmatter | Body |
|---|---|---|---|
| Overview | `overview.md` | `tldr`, `whatItIs`, `whoFor`, `whyNow`, `whatItIsNot`, `risks[]` (each `{description, likelihood, impact, mitigation}`) | optional notes |
| Triage Board | `triage-board.md` | `cards[]` (each `{id, column, title, tags[], createdAt}`) | optional notes |

### Collections

| Entity | Files | Required frontmatter | Optional frontmatter | Body |
|---|---|---|---|---|
| Goal | `goals/g-*.md` | `id`, `title`, `status` | `kpi`, `target`, `current`, `dueDate`, `owner`, `taskIds[]` | rationale, why, risks |
| KPI | `kpis/k-*.md` | `id`, `name`, `target`, `current`, `unit` | `history[]` (each `{date, value}`), `owner` | how measured, definitions |
| Idea | `ideas/i-*.md` | `id`, `title`, `column` (quick-wins / big-bets / parked) | `tags[]`, `promotedTaskId` | description |
| Initiative | `initiatives/i-*.md` | `id`, `title` | `goalIds[]`, `taskIds[]`, `stage` | strategy / why-now |
| PRD | `prd/p-*.md` | `id`, `title`, `status` (draft / accepted / shipped / abandoned) | `owner`, `goalIds[]`, `decisionIds[]` | full PRD body (problem / goals / approach / risks / open questions / metrics) |
| Plan | `plans/p-*.md` | `id`, `title` | `prdId`, `milestones[]` (each `{week, title, status, notes}`), `goalIds[]` | data flow / key code paths / risks / rollout |
| Status Report | `status/s-YYYY-MM-DD.md` | `date`, `headline` | `shipped[]`, `inProgress[]`, `slipped[]`, `next[]`, `risks[]`, `asks[]` | (mostly frontmatter — body for narrative if needed) |
| Decision | `decisions/d-*.md` | `id`, `title`, `status` (draft / adopted / superseded), `dateAdopted` | `options[]` (each `{name, pros, cons, picked}`), `supersededBy`, `goalIds[]` | context, decision rationale, consequences |
| Concept Explainer | `concepts/c-*.md` | `id`, `topic` | `terms[]` (each `{term, definition}`) | mental model, how-it-works, gotchas, FAQ |
| Retrospective | `retros/r-YYYY-MM-DD.md` | `date` | `wentWell[]`, `didntGoWell[]`, `lessons[]`, `actions[]` (each `{description, owner, due}`), `timeline[]` | additional reflections |

### Stays as-is (not migrated)

| Entity | Current storage | Why not markdown |
|---|---|---|
| **Tasks** | `<project>/.devdash/tasks.json` (single JSON array via `TaskStore`) | Tasks mutate constantly (status, owner, AI runs); JSON-array beats N markdown files for bulk reads and programmatic writes. **Add one field: `goalId: String?` on `TaskItem`.** |
| **Roadmap** | `ProjectMeta` (via `ProjectMetaStore`) — stage answers, exit criteria, current stage | Already derived from `LaunchTemplate` + meta; no user-authored content lives here independent of meta. Stays in Swift state. |
| **Initiatives derivation** | Currently derived from tasks-with-children | After this change, Initiative becomes an explicit entity (`initiatives/i-*.md`) that *references* taskIds. The auto-derived "tasks with children" rollup goes away. |

## Editor UX

Hybrid approach — pick per entity type based on whether it's structured-heavy or narrative-heavy.

### Structured-heavy (form editor)

Native SwiftUI form with typed pickers (status enum, date picker, owner picker, etc.) and one optional `TextEditor` for the body. No markdown editor.

Applies to: **Goal, KPI, Idea, Triage ticket**.

### Narrative-heavy (markdown editor + fields sidebar)

Two-pane layout: small fields sidebar on the right showing frontmatter inputs (built generically from Codable reflection or hand-written per entity), main pane is a markdown editor for the body. The user spends most of their time in the prose; fields are quick taps.

Applies to: **Overview, PRD, Plan, Status, Decision, Concept, Retro, Initiative**.

### Markdown editor implementation

Use SwiftUI's built-in `TextEditor` with markdown syntax highlighting (write a small attributed-string highlighter — Swift's `AttributedString` supports it). Don't pull in a heavyweight editor (Monaco, ProseMirror). Plain text editing is fine for markdown bodies.

## Module structure (Swift)

### New files

```
Sources/DevDash/
├── Models/
│   ├── EntityModels.swift          — Goal, KPI, Idea, Initiative, etc. as Codable structs
│   ├── MarkdownEntity.swift        — Protocol: any markdown-backed entity (frontmatter + body)
│   └── EntityID.swift              — Typed id wrapper (avoids stringly typed FKs)
├── Scanners/
│   ├── EntityStore.swift           — Generic load/save for any MarkdownEntity. CRUD + list per folder.
│   ├── EntityFrontmatter.swift     — YAML parse/serialize (via Yams dependency)
│   ├── HtmlCompiler.swift          — Reads all entities, writes index.html + per-section .html files
│   ├── LegacyHtmlMigrator.swift    — One-shot: parses existing .html into .md files
│   └── (existing scanners stay)
├── Views/
│   ├── ProductEditors/
│   │   ├── GoalEditor.swift        — SwiftUI form
│   │   ├── KPIEditor.swift         — SwiftUI form
│   │   ├── IdeaEditor.swift        — SwiftUI form
│   │   ├── TriageTicketEditor.swift— SwiftUI form (single ticket)
│   │   ├── TriageBoardView.swift   — Kanban with drag-drop
│   │   ├── MarkdownEntityEditor.swift — Generic editor for narrative entities
│   │   └── MarkdownBodyEditor.swift   — Reusable markdown TextEditor with highlighting
│   └── Tabs/
│       └── ProductTabView.swift    — Rewritten: subtabs per section, native editors, HTML viewer only for read-only views
```

### Existing files modified

- `Sources/DevDash/Models.swift` — add `goalId: String?` to `TaskItem`. Keep everything else.
- `Sources/DevDash/Views/Tabs/ProductTabView.swift` — gutted and rewritten. WKWebView still appears but only as a read-only viewer for the compiled HTML (Artifacts tab, "preview" mode).
- `Sources/DevDash/Views/ProductWebView.swift` — bridge JS shrinks to ~30 lines: `[data-action]` pass-through only. Auto-save, contenteditable, Alpine — all gone.
- `Sources/DevDash/Scanners/ProductDocGenerator.swift` — most of this dies. The `template(_:projectName:)` factory functions move into `HtmlCompiler.swift` (now rendering from entity models, not authoring templates). The Alpine + addBtn + contenteditable stuff disappears entirely.

### Existing files removed

- `Sources/DevDash/Resources/alpine.min.js` — no longer needed
- `Sources/DevDash/Resources/devdash-components.js` — no longer needed
- `Sources/DevDash/Scanners/ProductDocAssets.swift` — no longer needed
- Update `Package.swift` to drop the `resources: [.copy("Resources")]` rule
- Update `run.sh` to drop the `cp` of JS files into `.app/Contents/Resources/`

## HTML compiler

`HtmlCompiler.swift` is the new render layer. Replaces `ProductDocGenerator.generate(...)`.

```swift
enum HtmlCompiler {
    /// Reads all entities under <project>/docs/devdash/, renders the living
    /// doc HTML files. Idempotent. Cheap to re-run.
    static func compile(projectPath: String, meta: ProjectMeta, template: LaunchTemplate?, tasks: [TaskItem]) -> URL?
    /// Re-render a single section (cheap path for after one entity edit).
    static func recompileSection(_ section: ProductSection, projectPath: String) -> URL?
}
```

The output paths stay the same as today:

- `docs/devdash/index.html` — shell with tabbed nav
- `docs/devdash/sections/overview.html` — rendered from `overview.md`
- `docs/devdash/sections/goals.html` — rendered from `goals/*.md` + `kpis/*.md`
- `docs/devdash/sections/ideas.html` — rendered from `ideas/*.md`
- `docs/devdash/sections/initiatives.html` — rendered from `initiatives/*.md` + cross-ref to tasks
- `docs/devdash/sections/roadmap.html` — derived from `ProjectMeta` + `LaunchTemplate` (unchanged)
- `docs/devdash/{prd,plans,status,decisions,concepts,retros}/*.html` — one HTML file per source `.md` for the artifacts browser

Compile trigger:
- **Explicit:** click the regenerate button in the toolbar
- **Implicit:** every entity save in `EntityStore` triggers `recompileSection` for that section (only that section's HTML rewrites)
- **Initial:** `compile()` runs once on project open if `index.html` is missing or older than the most recent `.md` mtime

WKWebView reload is decoupled: the viewer reloads when `reloadToken` bumps (already wired). After a save, bump the token so the viewer refreshes — but the SwiftUI editor stays focused (no scroll jump in the editor pane).

## WKWebView role after this change

The WKWebView remains for **viewing** the compiled HTML (handy for: screenshot/share, see the page as the team would see it, navigate the living doc as a reader). It's no longer for editing. The bridge JS shrinks to ~30 lines:

```js
// Pass-through for [data-action] clicks → native handlers (open-file, regenerate, open-task)
document.addEventListener('click', function(e) {
  var btn = e.target.closest('[data-action]');
  if (!btn) return;
  e.preventDefault();
  var payload = { action: btn.dataset.action };
  Object.keys(btn.dataset).forEach(function(k) {
    if (k !== 'action') payload[k] = btn.dataset[k];
  });
  try { window.webkit.messageHandlers.devdash.postMessage(payload); }
  catch (e) { console.error('devdash bridge failed', e); }
}, true);
```

No `save`, no `save-alpine`, no contenteditable, no Alpine load, no `.assets/` folder, no `addBtn`. Clean.

## Migration (`LegacyHtmlMigrator`)

One-shot per-project migration that runs the first time the new build opens a project that has `docs/devdash/index.html` but no entity .md files.

### Migration rules

| From | To | Strategy |
|---|---|---|
| `sections/overview.html` | `overview.md` | Best-effort parse: pull TL;DR / what-is-it / who-for / why-now / what-it-is-not from div classes; risks table → frontmatter array; rest → body |
| `sections/goals.html` | `goals/g-*.md` + `kpis/k-*.md` | Each `<li>` under "Quarter goals" → one Goal. Each KPI tile → one KPI. Detailed metrics table rows → KPIs without dashboard tile |
| `sections/ideas.html` | `ideas/i-*.md` | Each `<div class="item">` → one Idea, column inferred from parent `.col[data-col]` |
| `sections/initiatives.html` | (derived from tasks; no migration) | The auto-rollup goes away. User can create real Initiative .md files explicitly |
| `prd/*.html` | `prd/p-*.md` | Parse `<h2>` title; status from pill; body becomes the markdown body verbatim (with HTML→md conversion via best-effort tag mapping) |
| `plans/*.html` | `plans/p-*.md` | Same as PRD |
| `status/*.html` | `status/s-*.md` | Date from filename slug; lists for shipped / in-progress / slipped / next from card sections |
| `decisions/*.html` | `decisions/d-*.md` | Each `<div class="card">` decision → one file |
| `concepts/*.html` | `concepts/c-*.md` | Topic from `<h2>`; terms table → frontmatter array; rest → body |
| `retros/*.html` | `retros/r-*.md` | Date from filename slug; the four card lists into frontmatter; timeline into frontmatter |
| `triage/*.html` | (merge into singleton `triage-board.md`) | Parse the JSON state block (already exists from Alpine refactor) → `cards[]` frontmatter |

### Migration safety

- Migrator writes new `.md` files but does NOT delete the old `.html` files. User can compare and delete manually after review.
- Migrator skips folders that already have `.md` files (idempotent).
- If parsing fails for a specific file, log to stderr and create a stub `.md` with the original HTML body embedded — user fixes manually.

### Scope of automatic migration

- **dev-dash** and **wnba-tracker** get auto-migrated on first new-build open (they're the test projects).
- Other projects (basketball-tournament, appgardn, etc.) auto-migrate too when first opened with the new build, with the same skip-if-md-exists guard.

## What stays the same

- Roadmap tab (`roadmap.html`) — same derivation from template + meta
- Tasks tab — unchanged except `goalId` field added
- Sessions tab, Logs tab, Claude tab, Files tab, Info tab, Preview tab — unchanged
- ProjectMeta, TaskStore, LaunchTemplate — unchanged storage
- The "Edit overview / goals / ideas" toolbar menu in the Product tab disappears (editing happens in the new SwiftUI subtabs)
- The "New PRD / Plan / Status / etc." toolbar menu adapts to create `.md` entities and open them in the new SwiftUI editor

## Out of scope (deliberately deferred)

- Multi-section cross-entity queries / dashboards
- Cross-project rollups
- A search UI across all entities
- Markdown editor improvements beyond basic syntax highlighting (no slash menu, no autocomplete, no link helper)
- Per-entity revision history (git already handles this)
- Real-time collaboration

## Risks

- **Migration parsing fidelity.** Some artifact HTML in dev-dash / wnba-tracker may have user edits the parser misses. Mitigation: keep `.html` files alongside `.md` files until the user manually deletes them; surface parse failures with stub files containing raw HTML.
- **HTML compiler bugs cause data loss visibility.** Source of truth is the `.md` files, so a bad compile run can't lose data — at worst the rendered HTML is wrong. User re-runs compile to fix.
- **Native SwiftUI editor surface area is large.** ~7 form editors + 7 narrative editors. Mitigation: generic form-from-Codable reflection where possible; ship one or two polished editors first, others can use a generic fallback temporarily during dev (but ship-blocker says all entity types must have a working editor before merge).
- **Yams dependency adds compile time.** Yams is the standard Swift YAML library (~10s of seconds to first build). Acceptable.
- **dev-dash and wnba-tracker have throwaway test content.** Migration on them is low-stakes; the user can `rm -rf docs/devdash/{prd,plans,status,…}/*.html` after migration to keep the repo clean.

## Success criteria

- All 13 entity types load from `.md` files and round-trip through their editors without data loss
- The Product tab opens to native SwiftUI subtabs (Overview, Goals & KPIs, Ideas, Initiatives, Artifacts) — no contenteditable
- The "Viewer" subtab (or toolbar button) opens the compiled HTML in WKWebView for read-only browsing
- `swift build` is clean
- dev-dash + wnba-tracker auto-migrate from existing HTML to `.md` files on first new-build open
- Bridge JS in `ProductWebView.swift` is ≤ 30 lines
- The Alpine + addBtn + contenteditable + bridge save logic is entirely deleted
- `Sources/DevDash/Resources/` and `ProductDocAssets.swift` are deleted; `Package.swift` drops the resources rule; `run.sh` drops the JS copy

## Open implementation questions (to be resolved in the plan)

- Does the markdown body editor need syntax highlighting in v1, or plain `TextEditor`?
- Should there be an "import" path for bringing markdown from outside the project (clipboard / drop file)?
- How are entity IDs minted? (`g-001` sequential per type, or `g-<nanoid>`?)
- What's the precise YAML library — `Yams` (most common) or another?
- For the narrative editors, should the fields sidebar be auto-generated from Codable, or hand-written per entity for polish?

These get answered in the implementation plan; not load-bearing for the spec.
