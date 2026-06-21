# Daily-page docs entry (Roam × Tana, lore-native)

**Date:** 2026-06-21
**Status:** Design — approved for planning
**Scope:** Enhance the existing **Today** (`DailyTabView`) tab into a streamlined, editable
daily-page entry into docs. Keep navigation otherwise as-is, but build it as a hub that reaches
the other docs so a future merge of Product/Tasks/Browse is a natural next step.

## Concept

The **Today** tab becomes an **infinite vertical scroll of daily pages**, newest on top. Each day
is a single `note` lore doc (`docs/notes/YYYY-MM-DD.md`) rendered as an **editable bullet outline**.
You land on today with the cursor ready — just start typing. Claude Code appends bullets to the same
files during normal CLI work, and the app live-updates.

This is Roam's Daily Notes Page (one page per day, just type) crossed with Tana's supertags (tag a
node to give it a type), kept lore-native (a tagged bullet becomes a real typed lore doc that shows
up in Tasks/Product/Browse automatically).

## Storage model

- **One file per day.** The day's outline lives in `docs/notes/YYYY-MM-DD.md` as a markdown bullet
  list. Frontmatter: `title` (the date), `created` (the date). Body is the nested list.
- **Each bullet is a node.** Nesting = markdown list indentation. Reordering/indenting is just list
  structure in the one file — no cross-file ordering index needed.
- **Lazy creation.** Today's file is created on the first keystroke, not before (no empty-file noise).
- This reconciles the earlier "note per note" instinct: the *day* is the note doc; individual
  thoughts are bullets within it. Granular typed docs appear only when a bullet is supertagged.

## Supertags (V1: single type, extract-on-tag)

The valid supertags map to existing lore types that make sense at bullet altitude:
`#task` → `docs/tasks/`, `#idea` → `docs/ideas/`, `#kpi` → `docs/kpis/`, `#decision` → `docs/decisions/`.
Untagged bullets stay plain note bullets (default, no-op).

Note: only `task`, `note`, `kpi`, `overview` schemas are *ejected* locally
(`docs/.lore/types/`); `idea` and `decision` are package-provided types. So extraction must not
assume hand-written frontmatter for every type — it goes through a **lore-aware writer** that
derives each type's required fields from its schema (planning task: confirm required fields per
type; `task` can reuse the known field logic from `NewLoreTaskSheet`, others resolve via the lore
schema / CLI).

**Applying a supertag to a focused bullet** (via inline `#type` token *or* a "Turn into ▸" action):
1. Extract that bullet's text + its subtree.
2. Create a new doc in the type's dir with required frontmatter resolved from that type's schema
   (the bullet text becomes the title; the subtree becomes the body).
3. Replace the original bullet in the outline with a `[[backlink]]` to the new doc.
4. Run `lore reindex <type>` so the doc joins its collection.

Designed so multi-tag-per-node and fields-per-supertag can be added later, but **V1 ships single
type per bullet**.

## Components

1. **`DayNode` model** — `struct DayNode { let id: UUID; var text: String; var children: [DayNode];
   var collapsed: Bool }`. The in-memory outline tree.
2. **`DailyPageStore`** — resolves `docs/notes/YYYY-MM-DD.md` for a day; parses the markdown list into
   `[DayNode]`; serializes the tree back to a markdown list (consistent indentation); debounced,
   atomic writes. Knows how to create today's file lazily. One store per project path.
3. **Outliner view (native SwiftUI)** — renders a day's `[DayNode]` as focusable bullet rows.
   Each row wraps an `NSTextField` (via `NSViewRepresentable`) whose field-editor key handling is
   intercepted through `control(_:textView:doCommandBy:)`:
   - **Enter** → split/new sibling bullet below (cursor moves into it).
   - **Shift+Enter** → soft line break within the bullet.
   - **Tab / Shift+Tab** → indent / outdent (re-parent in the tree).
   - **Backspace at start of empty bullet** → merge into previous / outdent.
   - **Up / Down** → move focus to adjacent bullet.
   - `[[` → trigger the existing lore-link autocomplete; `#` → supertag type picker popover.
   Focus is tracked by node `id` and driven programmatically (first-responder management).
   Fold/unfold via a disclosure affordance. Drag-reorder via `.onDrag`/`.onDrop` (degrade
   gracefully — keyboard indent/outdent is the primary reordering path; drag is polish).
4. **`NotesFileWatcher`** — FSEvents/`DispatchSource` on `docs/notes/`. When a file changes on disk
   (Claude/editor appended bullets), re-parse and refresh **non-focused** days only, so an
   in-progress local edit is never clobbered. The focused day reconciles on blur.
5. **Reach-out navigation** — kept lightweight for the future merge: the existing **Browse** mode
   stays for "all docs by type," and `[[backlinks]]` are clickable to open any doc. This is the seam
   the eventual Product/Tasks merge grows from.

## Data flow

- **Local edit:** keystroke → mutate `[DayNode]` → debounced serialize → atomic write
  `notes/YYYY-MM-DD.md`.
- **Supertag:** focused bullet → extract subtree → write new typed doc (schema frontmatter) +
  rewrite bullet to `[[backlink]]` → `lore reindex <type>`.
- **External write:** FileWatcher fires → re-parse changed file → update that day's outline if it's
  not the focused day.

## What stays / what changes

- **Stays:** Browse-by-type mode; the per-day Claude sessions band (kept, de-emphasized, collapsible);
  the "summarize day" wand; the `NewLoreTaskSheet` field logic (reused by the task supertag).
- **Changes:** the Daily mode goes from a read-only timeline → an editable, infinite daily-page
  outliner. The read-only `NotePanel` is no longer the primary path for notes (still usable for
  reading non-note docs opened via backlinks).

## Error handling

- Write failures (atomic write throws) surface inline and keep the in-memory tree intact for retry.
- Parse of a malformed/hand-edited note file degrades to a single bullet containing the raw body
  rather than dropping content.
- Supertag extraction is transactional-ish: only rewrite the source bullet to a backlink **after**
  the new typed doc is written successfully; otherwise leave the bullet untouched and show an error.
- FileWatcher refresh never touches the focused day's buffer.

## Testing

- **`DailyPageStore` round-trip:** markdown list → `[DayNode]` → markdown list is stable
  (idempotent) across nesting depths, soft line breaks, and `[[links]]`.
- **Outline ops:** indent/outdent/merge/split produce the expected tree and re-serialize correctly.
- **Supertag extraction:** produces a valid typed doc with required frontmatter, correct backlink,
  and a reindex; source bullet untouched on failure.
- **FileWatcher:** external append to a non-focused day refreshes it; external change to the focused
  day does not clobber local edits.

## Out of scope (V1)

- Multiple supertags per node; per-supertag custom fields (Tana fields).
- Cross-file outline nesting (bullets spanning multiple docs).
- Tab consolidation (merging Product/Tasks into this surface) — designed-around, deferred.
- App-side AI note generation (notes come from CLI Claude Code via convention + file-watch).
