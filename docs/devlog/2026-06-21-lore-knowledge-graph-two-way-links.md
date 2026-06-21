---
lore_type: devlog
created: 2026-06-21
title: "Lore knowledge graph: 2-way links (Roam/Tana)"
date: 2026-06-21
day: 4
---

**Built the lore knowledge-graph layer — Roam/Tana-style `[[wikilinks]]` + rendered backlinks across every lore doc type — after the user clarified the real goal is a backlinkable, referenceable 2-way-link graph, not just editable markdown. Plus: Overview as editable md cards, atlas removal, and a headless verification harness born from a painful "I was verifying against stale output" lesson.**

## What got done

- **Knowledge graph (slice 1).** `LoreLinkIndex` (Swift) computes the link/backlink graph across all lore docs (the lore CLI doesn't expose lore-core's). `renderLoreSection` linkifies `[[token]]` → a clickable link (dim if unresolved) + a "↩ N linked references" backlinks footer per card; clicking a link/backlink switches to the target's tab and flashes its card.
- **Slice 2 — `[[` autocomplete** over lore docs in the card source editor (`searchLore` bridge → `LoreLinkIndex.allDocs`); dropdown renders titles via `textContent` (no injection), inserts plain `[[title]]`; arrow/Enter/Esc handler registered before the Esc-finishes-editing handler so it wins while open.
- **Graph reach.** The graph now spans **all** lore dirs incl. `tasks` (`LoreLinkIndex.allDirs`) — tasks aren't a `LoreSection`, so they were silently excluded, breaking task/parent links. Added reference-frontmatter backlinks (`task parent: <id>` → backlink on the parent), and backlinks footers on **KPI cards** + the native **LoreTasksView** detail pane.
- **Overview as cards-from-md (hybrid).** New `overview` lore type; the Overview tab renders `docs/overview/*.md` as editable cards (replacing bespoke `overview.html`), with 7 fixed slots scaffolded on first run + add/delete extras. Snapshot stays pinned (kept the static `overview` tab id). `LoreSection.newestFirst` added (overview sorts ascending).
- **Removed the atlas integration** — `ensureAtlasRunning` auto-start + `atlasPath/atlasPort`; deleted the Docs detail tab + `DocsTabView` (it was purely an atlas `localhost` webview).
- **Markdown:** single newlines now render as `<br>` (notes/PKM expectation) — paragraph lines were joined with a space, collapsing intentional breaks.
- **Editable task body** in the LoreTasksView detail pane (Edit/Done → `TextEditor` → `setBody` rewrites the `.md`, frontmatter preserved).
- **Headless verification harness:** `DevDash --regen <path>` (render `index.html`, exit) and `--graph <path>` (dump the backlink graph), run in `App.init` before the GUI.

## Decisions

- **lore = engine for authored prose; structured/derived views stay generated.** The **Roadmap was deliberately NOT migrated** — it's generated from the launch template + meta; turning it into md cards would throw away the guided-launch structure (stages/questions/exit-criteria). KPIs likewise stay structured. lore-as-engine ≠ "everything becomes markdown cards."
- **The Roam/Tana keystone was backlink *rendering*** — lore-core can compute backlinks but neither the CLI nor the app surfaced them. Forward `[[links]]` alone aren't the feature.
- **Hardcode the `parent` reference edge** instead of a full schema-driven `reference`-field walk — dev-dash has no `type: reference` fields and `parent` is the only reference edge it needs (documented as a deliberate divergence from lore-core).
- Overview tradeoff (chosen): the old 2-col grid + Risks **table** become markdown cards (the renderer has no tables).

## Issues

- **Biggest: I was verifying against STALE output and restarted the app ~10×.** GUI regen only runs when the Product tab is shown, and the app restored to the **Files** tab — so `ProductTabView` never regenerated. Worse, `defaults write … -dict-add` won't overwrite an existing key, so my attempts to force the Product tab silently no-op'd. Fix: the headless `--regen`/`--graph` harness. Lesson the user named directly — *"make sure you're actually set up to verify."*
- **The graph didn't scan `docs/tasks`** (tasks aren't a `LoreSection`) → task/parent links silently failed. Fixed with `allDirs`. Only caught because `--graph` made it visible.
- **`--regen` MUTATES the working tree** (full `generate()`: scaffolds folders/stubs, rewrites generated HTML with *empty* meta). During the review, agents' (and my own) `--regen` runs on dev-dash clobbered tracked `index.html`/`roadmap.html` (restored via `git checkout`) and removed the untracked migrated task `.md` copies (source `.devdash/tasks.json` intact). Reframed `--regen` as mutating; `--graph` is the read-only verifier; only run `--regen` against temp dirs.
- **Two ultracode reviews.** Graph slice 1 (11/11 confirmed: non-deterministic resolution w/o sort; linkify rewriting `[[ ]]` inside `<code>`; inline-save stripping links). Graph reach (20 confirmed, 1 medium + 19 low: the `--regen` footgun; `parent: 1` not matching `0001-*.md`; `idIndex` last-write-wins; lore-core parity nuances). Fixed the real ones; deferred parity + perf (premature at ~15 docs).
- `linkifyWikilinks` runs AFTER markdown escaping (brackets survive), so it must skip `<code>`/`<pre>`; the backlink scanner skips fenced + inline code to stay consistent with what's rendered.

## What to remember

- **Verify headlessly:** `.build/debug/DevDash --graph <abs-path>` dumps backlinks (read-only, `target ← source(via)`); `--regen <abs-path>` regenerates but **MUTATES** — temp dirs only. Don't trust GUI regen for verification (tab-dependent → stale).
- The graph spans every lore dir via `LoreLinkIndex.allDirs` (LoreSection dirs + `tasks`). Tokens resolve by lowercased **title** or **filename base**; `parent` resolves by **normalized numeric id** within the same dir.
- Structured/derived views (Roadmap, KPIs) are intentionally NOT lore-md cards.
- **Phase 4b still pending** — tasks now participate in the graph, but the two task systems (`.devdash/tasks.json` + `docs/tasks/*.md`) still coexist; retiring TaskStore + rewiring the kanban to lore is the remaining big rock.

---

## Commits

- 79b5211 remove atlas integration
- d3ad8f0 lore-engine: Overview as editable md cards (hybrid fixed slots + extras)
- 6abd011 lore graph: [[wikilinks]] + backlinks across all lore docs (slice 1)
- efe4b10 lore graph: fix ultracode review findings (7 of 11)
- 27e7590 lore graph slice 2: [[ autocomplete over lore docs
- 7b13445 markdown: preserve single newlines as <br> (notes/PKM expectation)
- 30b53b7 add headless --regen / --graph CLI for deterministic verification
- 9e77477 lore graph reach: backlinks on KPI + task cards, reference/parent links
- 9cc8364 graph-reach review fixes (7 of 20; rest deferred/documented)
