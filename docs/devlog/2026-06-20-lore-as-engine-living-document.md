---
lore_type: devlog
created: 2026-06-20
title: "Lore-as-engine: the living document runs on lore"
date: 2026-06-20
day: 3
---

**Made lore the storage/schema/index engine behind the Product-tab living document — the doc became a render+edit frontend over lore markdown — shipped across Phases 1–4a + structured KPIs, each verified by build+launch and several adversarial multi-agent ("ultracode") review workflows whose confirmed findings were all fixed.**

## What got done

- **Phase 1 — generalized lore-section engine.** `LoreSection` (with `dir` ≠ `loreType`) → `renderLoreSection` renders `docs/<dir>/*.md` as cards (`Markdown.bodyHTML`); byte-exact source editing via `<textarea>`; live re-render on save (Swift→JS callback); authoring (+new via `lore add` with required `--field`) + delete. Applied to **Decisions** + **Ideas**.
- **Phase 2 — `note` type** (`docs/.lore/types/note.schema.yaml`, `body: free`) → a **Knowledge** tab.
- **Phase 3 — retired the homegrown engine.** Deleted `DocIndexGenerator` + `.index.json` + the `devdash:meta` format; `lore reindex` is now the only index engine.
- **Structured KPIs** — a `kpi` type with `number` frontmatter (current/target/unit/direction); a KPIs grid with inline number inputs that write back to **frontmatter** (new `save-kpi` bridge + `saveKPIFields`); progress bar + delta in JS. Proof lore-as-engine handles typed data, not just markdown.
- **Phase 4a — TaskStore → lore migrator.** Extended the `task` schema with every TaskStore field; `TaskLoreMigrator` does an idempotent (`devdash_id`-keyed) export of `.devdash/tasks.json` → `docs/tasks/*.md`, porting all fields and remapping parent UUIDs → lore ids; "Migrate → Lore" button.
- **Sidebar toggle (⌘S)** via `NavigationSplitView` `columnVisibility` + a toolbar button.

## Decisions

- **lore = content/engine, living doc = presentation.** Declined migrating Overview/Goals to lore — they're rich HTML (KPI grids, callouts) markdown can't hold *and* are already losslessly editable as HTML. They're the presentation layer; markdown-izing them would regress.
- **Schemas kept local** (`docs/.lore/types/note|kpi|task`) by choice — self-contained to this repo. Promote to the lore package later for cross-project use.
- **Phase 4a (data migration) before 4b (retire TaskStore).** Get the data into lore losslessly first; rewiring the kanban/MyQueue to lore is a separate pass.
- **Reviewed data-writing code before running it.** Ran the migrator's ultracode review *before* touching real tasks.

## Issues

- **`lore reindex decisions` silently failed** ("unknown type") — lore's type arg is the singular schema `name` (`decision`), the folder is plural (`decisions`). Live bug in the spike; fixed by splitting `dir` from `loreType`.
- **`<textarea>` ate a leading newline** (HTML spec) → deleted the blank line after frontmatter on every save, breaking byte-exactness. Fixed with a sentinel newline. (The earlier contenteditable `<pre>` + `innerText` had the same class of whitespace loss.)
- **`Markdown.bodyHTML` didn't escape literal text** — an HTML/script injection vector into the bridge-enabled webview. Now escapes.
- **Migrator review (14 findings):** hand-rolled YAML quoting crashed `lore reindex` on values with `:` `#` `\` `"` (→ proper escaped double-quoting); wrote `hasAIRun` but the app reads `ai_run` (→ renamed); bare `parent: 0003` lost leading zeros (→ quoted); `try?` write overcounted + could dangle parent refs (→ do/catch).
- **`saveLoreDoc`** dropped frontmatter on CRLF/BOM files and silently discarded edits on unterminated frontmatter (→ normalize + surface a warning).

## What to remember

- **Adding a lore-backed section is now ~one `LoreSection` line + a schema** (collection types). KPIs needed a custom renderer (`isKPI` flag) since they're structured, not markdown cards.
- **The app's `LoreReader.parseFrontmatter` is line-based** (not real YAML) — it strips outer quotes but doesn't un-escape. So migrated frontmatter uses single-line scalars; a title literally containing `"`/`\` shows the escape chars in the app (cosmetic; lore reads it right).
- **Migrated tasks must use the keys the existing `LoreTasksView` reads** (`ai_run`, `category`, etc.), not invented ones — that's where the migrator review caught the most.
- **Native `.keyboardShortcut` on hidden `.background` buttons does NOT fire** in this `NavigationSplitView`+webview setup (⌘1–9, ⌘⌥N parked). Toolbar-button shortcuts (⌘[, ⌘], ⌘R, ⌘S) DO fire. The real fix for in-doc/global shortcuts is a `CommandMenu` in the App scene.
- **Phase 4b** (rewire kanban/MyQueue/tree to lore, delete TaskStore) is the remaining big piece — deep in the actively-evolving task code.

---

## Commits

- f132ae6 lore-as-engine Phase 1 (Tasks 0-2): lore-backed sections, byte-exact editing, hardened write-back
- 922f845 add keyboard shortcuts + lore-as-engine Phase 1 Tasks 3-4
- 84a8f2c lore-engine: fix data-loss + injection bugs from full review
- 3455dfb lore-engine cleanup pass (LOW review findings)
- 3ebecef lore-engine Phase 2 + 3: note type + retire DocIndexGenerator
- 88a08b2 lore-engine Phase 2/3 review fixes
- 4476421 lore-engine: structured KPI tracking (new KPIs tab)
- 4953830 lore-engine Phase 4a: TaskStore -> lore migrator (data migration)
