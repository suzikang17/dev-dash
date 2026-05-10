# Product tab — Alpine.js refactor

**Date:** 2026-05-10
**Status:** Approved, ready for implementation plan
**Affects:** `Sources/DevDash/Views/ProductWebView.swift`, `Sources/DevDash/Scanners/ProductDocGenerator.swift`, `docs/devdash/.assets/*` (new), every artifact template stub

## Goal

Replace the imperative DOM-injection layer in the Product tab's bridge JS with Alpine.js as the declarative interactivity layer. Shrink `ProductWebView.swift`'s bridge JS from ~370 lines doing four jobs (contenteditable attach, click delegation, template insertion, post-hoc + Add / ✕ button auto-injection) to ~80 lines doing one job (debounced auto-save). Move from a mixed paradigm where templates declare some affordances and the runtime invents others, to a single paradigm where every template declares its own affordances inline.

## Why

The imperative layer has bitten us repeatedly:
- Click-delegate ordering against the contenteditable focus model
- Buttons inside contenteditable needing `contenteditable="false"` on the button itself
- The `:nth-of-type(2)` selector trap matching by tag not class
- File:// fragment redirects looking like tab-revert bugs
- Auto-inject post-hoc decoration that creates buttons not present in the saved HTML

Alpine eliminates the auto-inject layer entirely (templates declare buttons inline) and gives us proper reactive state for the triage board (drag-drop becomes `cards.splice()` instead of manual DOM manipulation + count updates + filter classes).

## Architecture

### Three categories of section content, two save paths

| Category | Files | Interactivity model | Save model |
|---|---|---|---|
| **Static-derived** | `roadmap.html`, `initiatives.html` | None (regenerated from Swift state) | Not editable |
| **Contenteditable + Alpine handlers** | `overview.html`, `goals.html`, `ideas.html`, every artifact template | `contenteditable=true` on section; Alpine `@click` on inline + Add / ✕ buttons; buttons mutate DOM in place | Whole `innerHTML` to disk on debounced input (existing model) |
| **Alpine state-driven** | Triage boards | `x-data` component owns state; `x-for` renders cards from JSON; contenteditable scoped to card title only | Embedded `<script type="application/json" data-state="triage">` block; bridge regex-replaces the block on save |

### Triage file format

```html
<!-- managed: triage board -->
<div class="doc-head">
  <h2>Triage Board</h2>
  <span class="doc-status meta">Drag tickets between columns. Auto-saves.</span>
</div>

<script type="application/json" data-state="triage">
{ "cards": [ { "id":"t-abc", "col":"now", "title":"Fix login", "tags":["eng"] } ] }
</script>

<div data-section-file="triage/foo.html" data-section-format="alpine-triage"
     x-data="triageBoard()" x-init="init()">
  <div class="triage-controls">
    <button @click="addCard('now')" contenteditable="false" class="add-btn">+ Ticket</button>
    <button @click="copyMarkdown()" contenteditable="false" class="add-btn" x-text="copyLabel"></button>
  </div>
  <div class="triage-cols">
    <template x-for="col in cols" :key="col">
      <div class="triage-col" :data-col="col"
           @dragover.prevent @drop="drop($event, col)">
        <h4><span x-text="col"></span> <span class="meta tcount" x-text="cardsIn(col).length"></span></h4>
        <div class="triage-list">
          <template x-for="card in cardsIn(col)" :key="card.id">
            <div class="triage-card" draggable="true"
                 @dragstart="$event.dataTransfer.setData('id', card.id)">
              <div class="t-title" contenteditable="true"
                   x-init="$el.textContent = card.title"
                   @input.debounce.300ms="card.title = $el.textContent"></div>
              <div class="t-tags">
                <template x-for="t in card.tags" :key="t">
                  <span class="tag" x-text="t" @click="toggleFilter(t)"></span>
                </template>
              </div>
              <button class="rm-btn" @click="removeCard(card.id)" contenteditable="false">✕</button>
            </div>
          </template>
        </div>
      </div>
    </template>
  </div>
</div>
```

### `triageBoard()` factory shape

Lives in `docs/devdash/.assets/devdash-components.js`. Registers itself with Alpine:

```js
document.addEventListener('alpine:init', () => {
  Alpine.data('triageBoard', () => ({
    cols: ['now', 'next', 'later', 'cut'],
    cards: [],
    filter: '',
    copyLabel: 'Copy as Markdown',
    _saveTimer: null,

    init() {
      const stateEl = this.$el.previousElementSibling; // the JSON script
      try {
        const parsed = JSON.parse(stateEl.textContent);
        this.cards = parsed.cards || [];
      } catch (e) { this.cards = []; }
      this.$watch('cards', () => this.scheduleSave(), { deep: true });
    },

    cardsIn(col) {
      const f = this.filter;
      return this.cards.filter(c => c.col === col && (!f || c.tags.includes(f)));
    },

    addCard(col) {
      const id = 't-' + Math.random().toString(36).slice(2, 9);
      this.cards.push({ id, col, title: 'New ticket', tags: ['untagged'] });
    },

    removeCard(id) {
      this.cards = this.cards.filter(c => c.id !== id);
    },

    drop(ev, col) {
      const id = ev.dataTransfer.getData('id');
      const card = this.cards.find(c => c.id === id);
      if (card) card.col = col;
    },

    toggleFilter(tag) {
      this.filter = (this.filter === tag) ? '' : tag;
    },

    copyMarkdown() {
      const lines = ['# Triage'];
      for (const col of this.cols) {
        lines.push('', '## ' + col);
        for (const c of this.cardsIn(col)) lines.push('- ' + c.title);
      }
      navigator.clipboard?.writeText(lines.join('\n'));
      this.copyLabel = 'Copied!';
      setTimeout(() => { this.copyLabel = 'Copy as Markdown'; }, 1200);
    },

    scheduleSave() {
      clearTimeout(this._saveTimer);
      this._saveTimer = setTimeout(() => {
        const path = this.$el.dataset.sectionFile;
        const state = JSON.stringify({ cards: this.cards });
        window.devdashSaveAlpine(path, state);
      }, 800);
    }
  }));
});
```

### Bridge JS after the refactor

`ProductWebView.swift` bridge JS shrinks to roughly:

```js
(function() {
  function post(payload) {
    try { window.webkit.messageHandlers.devdash.postMessage(payload); }
    catch (e) { console.error('devdash bridge failed', e); }
  }

  // Contenteditable attach + debounced save (existing behavior, untouched)
  function attachEditing(root) {
    (root || document).querySelectorAll('[data-section-file]').forEach(function(el) {
      if (el.dataset.editingAttached) return;
      if (el.dataset.sectionFormat === 'alpine-triage') return; // Alpine-managed
      el.dataset.editingAttached = 'true';
      el.contentEditable = 'true';
      el.spellcheck = false;
      var saveTimer = null;
      el.addEventListener('input', function() {
        el.classList.add('is-dirty');
        clearTimeout(saveTimer);
        saveTimer = setTimeout(function() { saveHTML(el); }, 800);
      });
      el.addEventListener('blur', function() {
        if (el.classList.contains('is-dirty')) {
          clearTimeout(saveTimer);
          saveHTML(el);
        }
      });
      el.addEventListener('keydown', function(e) {
        if ((e.metaKey || e.ctrlKey) && e.key === 's') {
          e.preventDefault();
          clearTimeout(saveTimer);
          saveHTML(el);
        }
      });
    });
  }

  function saveHTML(el) {
    post({ action: 'save', path: el.dataset.sectionFile, html: el.innerHTML });
    el.classList.remove('is-dirty');
    el.classList.add('is-saved');
    setTimeout(function() { el.classList.remove('is-saved'); }, 1500);
  }

  // Helper exposed to inline Alpine handlers in templates: any @click that mutates
  // a contenteditable section's DOM should call this so the input event fires
  // and the debounced save kicks in.
  window.devdashMarkDirty = function(el) {
    var section = el.closest('[data-section-file]');
    if (!section) return;
    section.classList.add('is-dirty');
    section.dispatchEvent(new Event('input', { bubbles: true }));
  };

  // Save channel for Alpine-managed sections (currently triage only)
  window.devdashSaveAlpine = function(path, state) {
    post({ action: 'save-alpine', path: path, state: state });
    var sec = document.querySelector('[data-section-file="' + path + '"]');
    if (sec) {
      sec.classList.add('is-saved');
      setTimeout(function() { sec.classList.remove('is-saved'); }, 1500);
    }
  };

  // Native action passthrough (open-file, add-task, etc. — bridge stays a delegate
  // for any non-DOM action that needs Swift to handle it)
  document.addEventListener('click', function(e) {
    var btn = e.target.closest('[data-action]');
    if (!btn) return;
    e.preventDefault();
    var payload = { action: btn.dataset.action };
    Object.keys(btn.dataset).forEach(function(k) {
      if (k === 'action') return;
      payload[k] = btn.dataset[k];
    });
    post(payload);
  }, true);

  // Bridge style for dirty/saved indicators (unchanged from current)
  if (!document.getElementById('devdash-bridge-style')) {
    var style = document.createElement('style');
    style.id = 'devdash-bridge-style';
    style.textContent = '\n[data-section-file] { transition: box-shadow 0.18s; outline: none; border-radius: 6px; }' +
                        '\n[data-section-file]:focus { box-shadow: inset 0 0 0 1px var(--accent); }' +
                        '\n[data-section-file].is-dirty { box-shadow: inset 0 0 0 1px var(--orange); }' +
                        '\n[data-section-file].is-saved { box-shadow: inset 0 0 0 1px var(--green); }';
    document.head.appendChild(style);
  }

  attachEditing(document);
  document.querySelectorAll('nav.tabs .tab').forEach(function(b) {
    b.addEventListener('click', function() { setTimeout(function() { attachEditing(document); }, 30); });
  });
})();
```

Deleted from current bridge JS: `injectRemovesIn`, `findEditableAncestor`, the `dom-insert-template` / `dom-append-template` / `dom-remove-closest` / `triage-add` / `triage-export-md` cases, `autoInject`, `attachTriage`, `updateCounts`, `applyFilter`, the inline templates dictionary.

### Coordinator (Swift) save handling

In `ProductWebView.Coordinator.userContentController(_:didReceive:)`:

```swift
switch body["action"] as? String {
case "save":
    if let path = body["path"] as? String, let html = body["html"] as? String {
        onSave(path, html)
    }
case "save-alpine":
    if let path = body["path"] as? String, let state = body["state"] as? String {
        onSaveAlpine(path, state)
    }
default:
    onAction(body)
}
```

`onSaveAlpine` is a new closure on `ProductWebView`. Its implementation in `ProductTabView.swift` reads the existing file, regex-replaces only the contents of the `<script type="application/json" data-state="triage">…</script>` block with the new state, writes back. Body HTML is preserved byte-for-byte. If the script block is somehow missing (e.g. truncated file), fall back to regenerating the entire file from the triage template scaffold + the new state.

### Inline Alpine buttons in templates — pattern

Every artifact template needs its + Add buttons inlined with Alpine `@click`. The pattern looks like:

```html
<!-- Goals: + Add goal under a checklist -->
<ul class="checklist">
  <li>☐ <em>Goal 1</em></li>
</ul>
<button class="add-btn" contenteditable="false"
        @click="$el.previousElementSibling.insertAdjacentHTML('beforeend',
                '<li>☐ <em>New goal</em></li>'); window.devdashMarkDirty($el)">+ Add goal</button>
```

```html
<!-- Goals: + Add KPI tile -->
<div class="kpi-grid kpi-tracked">
  <div class="kpi">…</div>
</div>
<button class="add-btn" contenteditable="false"
        @click="$el.previousElementSibling.insertAdjacentHTML('beforeend',
                '<div class=\&quot;kpi\&quot;><div class=\&quot;k-label\&quot;>New KPI</div><div class=\&quot;k-value\&quot;>—</div><div class=\&quot;k-target\&quot;>target: —</div></div>');
                window.devdashMarkDirty($el)">+ Add KPI tile</button>
```

```html
<!-- Status report: ✕ remove on a checklist item -->
<li>☐ <em>New item</em>
  <button class="rm-btn" contenteditable="false"
          @click="$el.parentElement.remove(); window.devdashMarkDirty($el.closest('[data-section-file]'))">✕</button>
</li>
```

To keep template strings readable in Swift source, factor the repeated pattern as a small Swift helper. The button is always placed *immediately after* the element it appends into, so the click handler can reach the target via `$el.previousElementSibling`:

```swift
/// Renders a + Add button that appends `html` to its previous sibling element.
/// Place this button directly after the container (`<ul>`, `.kpi-grid`, `<tbody>`, etc.).
private static func addBtn(label: String, html: String) -> String {
  let escaped = html
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "'", with: "\\'")
    .replacingOccurrences(of: "\n", with: " ")
  return """
  <button class="add-btn" contenteditable="false" @click="$el.previousElementSibling.insertAdjacentHTML('beforeend', '\(escaped)'); window.devdashMarkDirty($el)">\(label)</button>
  """
}
```

Templates that need ✕ buttons on every dynamic item embed them in the inserted HTML string itself, so newly-added items always carry their own remove affordance. The ✕ pattern:

```html
<button class="rm-btn" contenteditable="false"
        @click="$el.parentElement.remove(); window.devdashMarkDirty($el.closest('[data-section-file]'))">✕</button>
```

For elements that need the button placed somewhere other than as a sibling (rare — e.g. + Idea inside `.board .col` instead of after it), use the explicit-target form inline rather than via the helper:

```html
<button @click="$el.parentElement.insertAdjacentHTML('beforeend', '...'); window.devdashMarkDirty($el)">+ Idea</button>
```

(Button is the last child of the column, so `$el.parentElement` is the column, and `insertAdjacentHTML('beforeend', ...)` appends inside it before the button. To keep the button at the bottom, use `'beforebegin'` from the button's perspective instead — see template details in the implementation plan.)

## Files touched

### New
- `docs/devdash/.assets/alpine.min.js` — vendored Alpine 3 build (~16KB minified)
- `docs/devdash/.assets/devdash-components.js` — `triageBoard()` factory + future Alpine components
- `docs/superpowers/specs/2026-05-10-product-tab-alpine-refactor-design.md` — this file

### Modified
- `Sources/DevDash/Views/ProductWebView.swift` — slim bridge JS, add `save-alpine` handler, add `onSaveAlpine` closure
- `Sources/DevDash/Scanners/ProductDocGenerator.swift` — write `.assets/` files, load Alpine in shell, rewrite triage template, rewrite goals/ideas/PRD/plan/status/decision/concept/retro templates with inline Alpine buttons, factor `addBtn` helper
- `Sources/DevDash/Views/Tabs/ProductTabView.swift` — wire `onSaveAlpine` to a Swift function that does the regex-replace-or-fallback

### Deleted
- `docs/devdash/triage/*.html` (in dev-dash and wnba-tracker test repos)
- `docs/devdash/sections/goals.html`, `docs/devdash/sections/ideas.html` (regenerated)

## Out of scope

- Front matter in templates (queued separately)
- Roadmap timeline component
- TOC sidebar
- Tasks → tickets work
- GitHub issues mirror
- Provider spending APIs
- Migrating non-test repos (no other users, only test projects exist)

## Risks

- **Alpine + WKWebView CSP:** Alpine 3 evaluates expressions via the Function constructor. WKWebView has no default CSP, but `loadFileURL` with file:// has bitten us before. Smoke test on first build; if blocked, set `WKWebpagePreferences.allowsContentJavaScript = true` (default true) and add `<meta http-equiv="Content-Security-Policy" content="script-src 'self' 'unsafe-eval'">` only if necessary.
- **Contenteditable inside Alpine x-for:** keyed `<template x-for>` reuses DOM nodes when the key matches. Combined with `x-init` (one-shot) for seeding text and `@input` for write-back, edits to card titles persist across re-renders. Verify by editing a card title, dragging another card to a different column, and confirming the edit survives.
- **Regex-replace fragility on save:** the `<script data-state="triage">…</script>` rewrite must not match nested script tags or malformed input. Use a non-greedy regex anchored on the `data-state="triage"` attribute. Fallback: if regex doesn't match, regenerate the full file from the triage template + new state.
- **Alpine load order:** Alpine must register `triageBoard()` before parsing the body that uses it. Load `alpine.min.js` with `defer`, load `devdash-components.js` before it (or use the `alpine:init` event pattern shown above to be order-independent — the spec uses this pattern).

## Build sequence

1. Vendor `alpine.min.js`. Author `devdash-components.js` with the `triageBoard()` factory.
2. Update `ProductDocGenerator.generate` to create `.assets/`, write both JS files (idempotent), and add the `<script defer src=".assets/alpine.min.js">` and `<script defer src=".assets/devdash-components.js">` tags to the shell HTML.
3. Rewrite the triage template (`DocType.triageBoard` case in `ProductDocGenerator.template`). Include the JSON script block scaffold with empty `cards: []`.
4. Rewrite `goals.html` and `ideas.html` stubs with inline Alpine + Add / ✕ buttons.
5. Rewrite each artifact template (PRD, implementation plan, status report, decision log, concept explainer, retrospective) with inline Alpine buttons on every dynamic table/list/grid.
6. Slim `ProductWebView.swift`'s bridge JS per the design above. Add `save-alpine` case in the coordinator.
7. Add `onSaveAlpine` closure on `ProductWebView`. Wire in `ProductTabView.swift` to a Swift function that regex-replaces the JSON block (or falls back to full regenerate).
8. Delete throwaway files: `docs/devdash/triage/*.html` and `docs/devdash/sections/{goals,ideas}.html` in dev-dash and wnba-tracker.
9. `swift build && pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash &`. Smoke test in the app: open dev-dash and wnba-tracker, switch through every tab, create a triage board, drag cards between columns, edit a title, refresh the project (regen), confirm state persists.

## Success criteria

- Bridge JS in `ProductWebView.swift` is ≤ 100 lines (down from ~370)
- Triage drag-drop works; card titles editable; tags filter; ✕ removes; export-as-markdown copies to clipboard; state survives close/reopen
- Goals tab + Add goal / + Add KPI tile / + Add metric all work without auto-inject
- Ideas tab + Idea works in each column
- Every artifact template (PRD, plan, status, decision, concept, retro) has working inline + Add / ✕ buttons where their structure warrants them
- Web Inspector shows zero JS errors on every tab
- Roadmap, initiatives, project meta, task tree, and stage Q&A are unchanged in behavior
