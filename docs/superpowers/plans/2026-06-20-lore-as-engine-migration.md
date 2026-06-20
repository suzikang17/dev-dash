# Lore-as-Engine Migration — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `lore` the engine (storage, schema, index) behind the Product-tab "living document," which becomes a pure render+edit frontend over lore markdown — retiring the parallel `docs/devdash/` content world and the homegrown `DocIndexGenerator`.

**Architecture:** Generalize the proven Decisions spike into a reusable "lore section": render `docs/<type>/*.md` → HTML, edit the markdown source inline (byte-exact via `<textarea>`), write back to the `.md` (frontmatter preserved), `lore validate` + `lore reindex`, live re-render on save via the Swift→JS callback. Content lives in lore; the living doc owns presentation.

**Tech Stack:** Swift 5.9 / SwiftUI / WKWebView; `lore` CLI (`~/.local/bin/lore`); no new Swift deps.

## Global Constraints

- macOS 14+, Swift tools 5.9. No new Swift package dependencies.
- **Verification is `swift build` + `bash run.sh` (launch + observe).** No test target.
- **Editing/WebView changes cannot be verified headlessly** — those steps require a human to type in the app and confirm. Each such task ends with an explicit "hand to user" checkpoint. (Learned the hard way in the spike: a save can succeed on disk while looking broken on screen.)
- **lore CLI fact (verified):** the type argument is the schema's SINGULAR `name` (`decision`, `idea`, `task`), NOT the plural directory. `docs/<dir>` is plural (`docs/decisions`, `docs/ideas`). `lore reindex decisions` → `unknown type`; `lore reindex decision` → ok. So every model/CLI call must distinguish `dir` (path) from `loreType` (CLI arg).
- **lore validate fact (verified):** validates **frontmatter only** (required/enum/reference fields). It does NOT check that a `sections`-body doc contains its required H2s — a decision missing `## Tradeoffs` still validates. Section-completeness, if wanted, is a Swift-side check reading the schema's `sections:` list.
- **lore add fact (verified):** `lore add <singularType> --title "X"` writes frontmatter `lore_type`/`created`/`title` only — it omits other required fields, so the doc fails validation immediately. Authoring must supply required fields via `--field key=value` (e.g. idea needs `--field status=raw`; decision needs `--field date=<today>`). `--field` is supported by `lore add`.
- Required frontmatter per type (from `~/dev/lore/packages/core/schemas/*.schema.yaml`): **decision** → `title`, `date` (+ optional category, revisit); body `sections`: Why this choice / Options considered / Tradeoffs. **idea** → `title`, `status∈{raw,promising,promoted,parked}` (+ optional category, effort, created); body `free`.
- Resolve the lore binary explicitly (`lore` on PATH, else `node ~/.local/bin/lore`) — don't assume PATH inside the WKWebView host process.
- The Decisions spike is the **starting point**, already in the tree: `ProductDocGenerator.renderLoreDecisions` + `stripFrontmatter`, the `data-lore-file`/`lore-src`/`lore-edit-toggle` markup, `ProductWebView.loreEditJS` + `save-lore` bridge + `onSaveLore` callback, `ProductTabView.saveLoreDoc`. **The spike has live bugs Task 0 fixes** (see below). Phase 1 generalizes these — it does not start from scratch.
- Commit per task, imperative mood. SourceKit "cannot find X" on new same-module types is stale-index noise; trust `swift build`.

---

## Migration Roadmap (decomposition)

Four sub-projects. Only **Phase 1** is detailed below; 2–4 are scoped here and get their own plans when reached (they depend on Phase 1 learnings and on confirming retirement is safe).

- **Phase 1 — Harden the spike, generalize the engine, ship Decisions + Ideas.** Fix the spike's live bugs (Task 0), then turn the one-off Decisions renderer/editor into a reusable `LoreSection` (with `dir`≠`loreType`). Byte-exact `<textarea>` editing. Validation on save (frontmatter via `lore validate`, surfaced as a warning — never blocks). New-doc authoring with required fields + delete. Apply to **Decisions** (`sections` schema, tested against cliphy's 42 real decisions) and **Ideas** (`free` schema, seeded via authoring first).
- **Phase 2 — The `note` type + freeform sections.** Add a `note` lore schema (`body: free`, frontmatter `title`+`date`). Render/edit Overview, Notes, Concepts, Goals as `note` docs. One-time migrate existing `sections/*.html` prose → lore markdown.
- **Phase 3 — Retire the homegrown engine.** Confirm nothing reads `.index.json` (Blocks reads the DOM; search reads `TaskStore` — so likely safe). Remove `DocIndexGenerator` + the `<!-- devdash:meta -->` format + the parallel `docs/devdash/<type>` artifact folders. Point any remaining query at lore's `index.md` / a thin Swift query over lore docs.
- **Phase 4 — Tasks ↔ lore (separate plan).** Reconcile `.devdash/tasks.json` (structured store powering the kanban/roadmap) with `docs/tasks/` lore. Complex and orthogonal; do not couple it to Phases 1–3.

---

## Phase 1 Tasks

### Task 0: Harden the spike's write path (fix live bugs the review found)

These bugs are live in the uncommitted spike. Fix them before generalizing.

**Files:** Modify `Sources/DevDash/Views/Tabs/ProductTabView.swift` (`saveLoreDoc`).

- [ ] **Step 1: Robust frontmatter split.** Replace `lines.first?.hasPrefix("---")` with a scan for the first line whose **trimmed value `== "---"`** (tolerate a leading blank/BOM), then the closing fence whose trimmed value `== "---"` (exact, not `hasPrefix`). If a doc starts with frontmatter but no closing fence is found, **abort the write** and return an error — never write a body-only file (that silently drops frontmatter).
- [ ] **Step 2: Correct the reindex type + resolve the binary.** The current `lore reindex <lastPathComponent>` passes the **plural** folder (`decisions`) → `unknown type` (verified failing). Map dir→singular `loreType` (Task 1 supplies the mapping) and call `lore reindex <loreType>`. Resolve the binary: try `lore`, else `node ~/.local/bin/lore`.
- [ ] **Step 3: Await + surface reindex/validate failures** instead of fire-and-forget `Task.detached` with no error handling. Return the outcome so the card can show it (Task 3 consumes this).
- [ ] **Step 4: Build + HAND TO USER.** Edit a cliphy decision, save, confirm the `.md` changed AND `docs/decisions/index.md` regenerated (mtime fresh) — proving reindex now actually runs.
- [ ] **Step 5: Commit** — `git commit -m "harden lore write-back: frontmatter safety, correct reindex type"`

---

### Task 1: `LoreSection` model (dir ≠ loreType) + generalize the renderer

**Files:**
- Create: `Sources/DevDash/Scanners/LoreSection.swift`
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift` (replace `renderLoreDecisions` with a type-parameterized `renderLoreSection(type:projectPath:)`; keep `stripFrontmatter`)

**Interfaces:**
- Produces: `struct LoreSection { let dir: String; let loreType: String; let label: String; let bodyIsFree: Bool; let requiredSections: [String]; let newDocFields: [String] }`
  and `static let all: [LoreSection]` (initially decisions, ideas).
- Produces: `static func renderLoreSection(_ section: LoreSection, projectPath: String) -> String`.

- [ ] **Step 1: Define the section list** — `dir` (plural, for `docs/<dir>`) is distinct from `loreType` (singular, for every `lore` CLI call). `requiredSections` drives the optional H2 check (Task 3); `newDocFields` are the `--field` args that make a new doc valid (Task 4).

```swift
// LoreSection.swift
import Foundation

/// A lore doc type surfaced as an editable section in the living document.
/// `dir` ≠ `loreType`: the folder is plural (docs/decisions), the lore CLI type
/// is the schema's singular `name` (decision). Mixing them breaks every CLI call.
struct LoreSection: Hashable {
    let dir: String              // docs/<dir> — plural folder
    let loreType: String         // lore CLI type — singular schema name
    let label: String            // tab label
    let bodyIsFree: Bool         // true = `free` schema, false = `sections`
    let requiredSections: [String]   // required H2s (sections schema) — for the Swift section check
    let newDocFields: [String]       // `--field k=v` args so an authored doc validates

    static let all: [LoreSection] = [
        LoreSection(dir: "decisions", loreType: "decision", label: "Decisions",
                    bodyIsFree: false,
                    requiredSections: ["Why this choice", "Options considered", "Tradeoffs"],
                    newDocFields: []),   // decision also needs `date`; supplied as today at create time
        LoreSection(dir: "ideas", loreType: "idea", label: "Ideas",
                    bodyIsFree: true,
                    requiredSections: [],
                    newDocFields: ["status=raw"]),
    ]
}
```

- [ ] **Step 2: Generalize the renderer** — rename `renderLoreDecisions(projectPath:)` → `renderLoreSection(_ section:projectPath:)`: read `docs/\(section.dir)`; empty-state command string uses the **singular** `section.loreType` (`Run \`lore add \(section.loreType)\``); banner/label use `section.label`. Card markup (`data-lore-file`, `.lore-body`, `.lore-src`, `.lore-edit-toggle`) unchanged. Add `data-lore-type="\(section.loreType)"` to each card so the save/delete/new paths know the CLI type without re-deriving it from the folder.

- [ ] **Step 3: Generate per-type section files + tabs, and resolve the Ideas collision** — in `generate()`, loop `LoreSection.all` writing `sections/lore-\(section.dir).html`; **stop emitting the spike's `sections/decisions.html`** and delete the stale file if present. Add a `DocTab` per section with `id: "lore-\(section.dir)"` (distinct id avoids colliding with the existing `.userHtml(file:"ideas.html")` Ideas tab). **Remove the old `.userHtml` Ideas tab** (the lore Ideas section replaces it; the kanban-ideas/`promote-idea` flow is unaffected — it reads `TaskStore`, not this tab). Note (not fixed in Phase 1): the Artifacts browser still lists the bespoke `docs/devdash/decisions` folder — a temporary duplicate, retired in Phase 3.

- [ ] **Step 4: Build + launch + open the tabs** — `bash run.sh` → cliphy → Product. Expect **Decisions** (42 real docs) and **Ideas** tabs. Decisions renders content; Ideas is empty until Task 4 authoring (expected — its empty-state shows the `lore add idea` hint).

- [ ] **Step 5: Commit** — `git commit -m "generalize lore-backed sections (dir vs loreType)"`

---

### Task 2: Byte-exact editing via `<textarea>`

**Files:**
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift` (card markup: `<textarea>` not `<pre>`)
- Modify: `Sources/DevDash/Views/ProductWebView.swift` (`loreEditJS`: read `.value`, not `.innerText`)

**Why:** the spike's contenteditable `<pre>` + `innerText` normalized whitespace (a blank line collapsed — observed in the spike). A `<textarea>`'s `.value` round-trips byte-exact.

- [ ] **Step 1: Render an editable textarea** — replace `<pre class="lore-src" …>\(escapeHTML(bodyMd))</pre>` with `<textarea class="lore-src" style="display:none">\(escapeHTML(bodyMd))</textarea>`.

- [ ] **Step 2: Update `loreEditJS`** — toggle shows/hides the textarea (no `contentEditable`); `wire()` attaches `input`/`blur`/⌘S; `save()` reads `el.value`; auto-size (`el.style.height = el.scrollHeight + 'px'`).

- [ ] **Step 3: Build, launch — HAND TO USER.** Edit a cliphy decision, save → (a) formatted view updates, (b) `git -C ~/dev/cliphy diff docs/decisions/<file>.md` shows ONLY the intended change, zero whitespace drift. Agent verifies the diff.

- [ ] **Step 4: Commit** — `git commit -m "byte-exact lore editing via textarea"`

---

### Task 3: Validation feedback on save (frontmatter + optional section check)

**Corrected premise:** `lore validate` checks **frontmatter only** — it does NOT flag a `sections` doc missing a required H2 (verified). So this task surfaces (a) real `lore validate` frontmatter errors, and (b) a **Swift-side** required-H2 check driven by `LoreSection.requiredSections`. Never blocks the save.

**Files:** `ProductTabView.swift` (`saveLoreDoc`), `ProductWebView.swift` (callback payload), `ProductDocGenerator.swift` (card status slot).

- [ ] **Step 1: Validate after write** — in `saveLoreDoc`, after the (Task 0-hardened) write: run `lore validate <loreType>` (resolved binary, awaited per Task 0) and capture any frontmatter error; AND if `!section.bodyIsFree`, check each `requiredSections` H2 (`## <name>`) is present in the body, collecting any missing. Return `(html: String, warning: String?)` where `warning` combines both (nil when clean).

- [ ] **Step 2: Thread through the callback** — `onSaveLore` returns the tuple; the `save-lore` case resolves `["html": ..., "warning": ...]`; `loreEditJS` shows a small inline `⚠` chip on the card when `warning` is non-null, clears it when null.

- [ ] **Step 3: Build, launch — HAND TO USER.** (a) Remove a decision's `## Tradeoffs` → save still writes; `⚠ missing section: Tradeoffs` chip appears (Swift check). (b) Corrupt a frontmatter field if easy → `lore validate` error shows. Restore → chip clears. Agent confirms the `.md` wrote in every case.

- [ ] **Step 4: Commit** — `git commit -m "surface validation (frontmatter + required sections) on save"`

---

### Task 4: Authoring (+ new) and delete, per section

**Files:** `ProductDocGenerator.swift` (+ new / delete buttons), `ProductTabView.swift` (`handleAction`: `lore-new`, `lore-delete`).

**Why:** lore can only be "the engine" if you can create and remove docs from the living doc, not just edit existing ones. `lore add <type> --title` alone yields an INVALID doc (omits required fields) — must pass `--field`.

- [ ] **Step 1: Add buttons** — top of `renderLoreSection`: `<button data-action="lore-new" data-lore-type="\(section.loreType)">+ new \(escapeHTML(section.label))</button>`. Per card: a small `<button data-action="lore-delete" data-lore-file="…">✕</button>`. (Bridge already routes `[data-action]` → `onAction`.)

- [ ] **Step 2: Create** — `handleAction` case `lore-new`: look up the `LoreSection` by `loreType`; ensure `docs/<dir>` exists (`FileManager.createDirectory`); run `lore add <loreType> --title "Untitled"` plus a `--field` per `newDocFields`, AND for a `sections` type pass `--field date=<today>` (decision needs `date`) — i.e. supply every required frontmatter field so the new doc validates immediately. Then `lore reindex <loreType>` + `regen`. (If `lore add` can't satisfy a required field, fall back to writing a complete stub: compute next id = max leading `NNNN` in the dir + 1, zero-pad 4, full required frontmatter + empty required H2s for `sections` types, then reindex.)

- [ ] **Step 3: Delete** — case `lore-delete`: remove the file at `data-lore-file`, `lore reindex <loreType>`, `regen`.

- [ ] **Step 4: Build, launch — HAND TO USER.** "+ new Idea" → new card; the new `docs/ideas/<id>-untitled.md` has `title`+`status=raw` and **passes `lore validate idea`** (agent verifies). Edit + save it; then delete it → file gone, card gone, reindex ran.

- [ ] **Step 5: Commit** — `git commit -m "author + delete lore docs from the living document"`

---

## Phase 1 Self-Review

**Spec coverage:** spike hardening incl. the live reindex/frontmatter bugs (Task 0); generalized engine with `dir`≠`loreType` (Task 1); byte-exact editing — the real flaw the spike surfaced (Task 2); validation feedback re-scoped to what lore actually checks + a Swift section check (Task 3); authoring with valid required fields + delete (Task 4). Applies to a `sections` type (decisions, against cliphy's real corpus) and a `free` type (ideas, seeded by Task 4).

**Plan-review fixes folded in:** singular `loreType` vs plural `dir` everywhere; `lore validate` is frontmatter-only (Task 3 re-scoped); `lore add` needs `--field` for a valid doc (Task 4); Ideas tab-id collision resolved (Task 1 Step 3); ordering — Decisions tested on cliphy, Ideas editing tested after Task 4 authoring; frontmatter-write safety + awaited reindex + explicit binary path (Task 0); delete affordance added; orphaned `decisions.html` cleaned up.

**Deferred deliberately:** `note` type + freeform prose (Phase 2); retiring `DocIndexGenerator`/`devdash:meta`/parallel folders incl. the Artifacts-browser duplicate (Phase 3, gated on confirming `.index.json` has no live reader — the ordering lens verified Blocks reads the DOM and search reads `TaskStore`, so the assumption holds); tasks reconciliation (Phase 4, separate).

**Verification honesty:** every editing/authoring task ends with a user-in-the-loop checkpoint (WKWebView typing isn't headlessly verifiable); the agent verifies the resulting `.md` + `lore validate` on disk.
