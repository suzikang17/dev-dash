# Product Tab Alpine.js Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the imperative DOM-injection layer in the Product tab's bridge JS with Alpine.js. Triage gets full reactive `x-data` with embedded JSON state. Goals/ideas/artifact templates keep `contenteditable` but use Alpine `@click` for inline + Add / ✕ buttons. Auto-inject layer is deleted entirely.

**Architecture:** Alpine 3 ships as an SPM resource and is copied to `docs/devdash/.assets/` on each generate. The triage board uses an `<script type="application/json" data-state="triage">` block as its source of truth — bridge JS regex-replaces just that block on save instead of writing the whole file. Bridge JS shrinks from ~370 lines to ~80 lines, doing only contenteditable auto-save + a thin save-alpine pass-through.

**Tech Stack:** Swift 5.9 / SwiftUI / WKWebView / Alpine.js 3.x. No test framework (no `Tests/` directory exists, Package.swift has no test target) — verification is via `swift build` and manual smoke tests in the running app.

**Reference spec:** `docs/superpowers/specs/2026-05-10-product-tab-alpine-refactor-design.md`

**Build / run loop used throughout:**
```bash
swift build && pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash >/dev/null 2>&1 &
```

---

## Task 1: Vendor Alpine.js as an SPM resource

**Files:**
- Create: `Sources/DevDash/Resources/alpine.min.js`
- Create: `Sources/DevDash/Resources/devdash-components.js`
- Modify: `Package.swift`

- [ ] **Step 1: Create the resources directory and download Alpine 3**

```bash
mkdir -p Sources/DevDash/Resources
curl -fsSL "https://cdn.jsdelivr.net/npm/alpinejs@3.13.10/dist/cdn.min.js" -o Sources/DevDash/Resources/alpine.min.js
ls -la Sources/DevDash/Resources/alpine.min.js
```

Expected: file size ~44KB (Alpine 3.13.10 minified is around that size; if much smaller the download failed).

- [ ] **Step 2: Author `devdash-components.js` with the `triageBoard()` factory**

Write to `Sources/DevDash/Resources/devdash-components.js`:

```js
// devdash Alpine components. Loaded after alpine.min.js. Components register
// themselves via the alpine:init event so script load order does not matter.
document.addEventListener('alpine:init', function () {
  Alpine.data('triageBoard', function () {
    return {
      cols: ['now', 'next', 'later', 'cut'],
      cards: [],
      filter: '',
      copyLabel: 'Copy as Markdown',
      _saveTimer: null,

      init: function () {
        // The JSON state block is the previous sibling of this x-data root.
        // See the triage template body in ProductDocGenerator.swift.
        var stateEl = this.$el.previousElementSibling;
        if (stateEl && stateEl.id === 'triage-state') {
          try {
            var parsed = JSON.parse(stateEl.textContent);
            this.cards = Array.isArray(parsed.cards) ? parsed.cards : [];
          } catch (e) {
            console.warn('[devdash] triage state JSON parse failed', e);
            this.cards = [];
          }
        }
        this.$watch('cards', function () { this.scheduleSave(); }.bind(this), { deep: true });
      },

      cardsIn: function (col) {
        var f = this.filter;
        return this.cards.filter(function (c) {
          return c.col === col && (!f || (c.tags || []).indexOf(f) !== -1);
        });
      },

      addCard: function (col) {
        var id = 't-' + Math.random().toString(36).slice(2, 9);
        this.cards.push({ id: id, col: col, title: 'New ticket', tags: ['untagged'] });
      },

      removeCard: function (id) {
        this.cards = this.cards.filter(function (c) { return c.id !== id; });
      },

      drop: function (ev, col) {
        ev.preventDefault();
        var id = ev.dataTransfer.getData('id');
        var card = this.cards.find(function (c) { return c.id === id; });
        if (card) card.col = col;
      },

      toggleFilter: function (tag) {
        this.filter = (this.filter === tag) ? '' : tag;
      },

      copyMarkdown: function () {
        var lines = ['# Triage'];
        var self = this;
        this.cols.forEach(function (col) {
          lines.push('');
          lines.push('## ' + col);
          self.cardsIn(col).forEach(function (c) { lines.push('- ' + c.title); });
        });
        if (navigator.clipboard) navigator.clipboard.writeText(lines.join('\n'));
        this.copyLabel = 'Copied!';
        var self2 = this;
        setTimeout(function () { self2.copyLabel = 'Copy as Markdown'; }, 1200);
      },

      scheduleSave: function () {
        clearTimeout(this._saveTimer);
        var self = this;
        this._saveTimer = setTimeout(function () {
          var path = self.$el.dataset.sectionFile;
          var state = JSON.stringify({ cards: self.cards });
          if (window.devdashSaveAlpine) window.devdashSaveAlpine(path, state);
        }, 800);
      }
    };
  });
});
```

- [ ] **Step 3: Update `Package.swift` to include the resources**

Edit `Package.swift`. Replace the `.executableTarget` block:

```swift
.executableTarget(
    name: "DevDash",
    dependencies: [
        .product(name: "SwiftTerm", package: "SwiftTerm")
    ],
    path: "Sources/DevDash",
    resources: [
        .copy("Resources")
    ],
    linkerSettings: [
        .unsafeFlags([
            "-Xlinker", "-sectcreate",
            "-Xlinker", "__TEXT",
            "-Xlinker", "__info_plist",
            "-Xlinker", "Info.plist"
        ])
    ]
)
```

- [ ] **Step 4: Verify the build still compiles and resources are bundled**

Run:
```bash
swift build 2>&1 | tail -20
```
Expected: Build complete with no errors. (SPM warning about resource bundling for executable targets is OK if shown.)

Verify resources are bundled:
```bash
find .build -name "alpine.min.js" | head
```
Expected: at least one path under `.build/debug/DevDash_DevDash.bundle/` (or similar).

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Resources/ Package.swift
git commit -m "$(cat <<'EOF'
feat: vendor Alpine 3 + devdash-components.js as SPM resources

Alpine 3.13.10 ships as a bundled resource and a hand-authored
devdash-components.js declares the triageBoard() factory via the
alpine:init event so load order does not matter.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `ProductDocAssets.swift` — write resources to disk + addBtn helper

**Files:**
- Create: `Sources/DevDash/Scanners/ProductDocAssets.swift`

- [ ] **Step 1: Create the new helper file**

Write to `Sources/DevDash/Scanners/ProductDocAssets.swift`:

```swift
import Foundation

/// Manages the `.assets/` folder under each project's living-doc tree.
/// Copies bundled JS (Alpine + devdash-components) to disk so the WKWebView
/// can load them via file://. Also exposes the addBtn helper used by every
/// template to render an Alpine + Add button.
enum ProductDocAssets {
    static let assetsRel = ".assets"

    /// Names of resource files (Sources/DevDash/Resources/) that get copied
    /// into each project's .assets/ folder.
    private static let assetFiles = ["alpine.min.js", "devdash-components.js"]

    /// Copy bundled JS into <project>/docs/devdash/.assets/. Idempotent —
    /// overwrites if contents differ; skips if identical. Called every regen.
    static func writeAssets(to docsRoot: String) {
        let assetsDir = "\(docsRoot)/\(assetsRel)"
        try? FileManager.default.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)
        for name in assetFiles {
            guard let src = Bundle.module.url(forResource: name, withExtension: nil) else {
                NSLog("[devdash] missing bundled resource: \(name)")
                continue
            }
            let dst = "\(assetsDir)/\(name)"
            // Overwrite-if-different to keep file mtime stable when nothing changed.
            if let srcData = try? Data(contentsOf: src),
               let dstData = try? Data(contentsOf: URL(fileURLWithPath: dst)),
               srcData == dstData {
                continue
            }
            try? FileManager.default.removeItem(atPath: dst)
            try? FileManager.default.copyItem(atPath: src.path, toPath: dst)
        }
    }

    /// Render an Alpine + Add button. The button is placed *immediately after*
    /// the container element it appends into, so the click handler reaches
    /// the target via $el.previousElementSibling. Pattern:
    ///
    ///   <ul class="checklist">…</ul>
    ///   <button class="add-btn" @click="...">+ Add item</button>
    ///
    /// `html` is single-quote-escaped + newline-stripped so it can be embedded
    /// inline in the Alpine expression attribute value.
    static func addBtn(label: String, html: String) -> String {
        let escaped = html
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        return """
        <button class="add-btn" contenteditable="false" @click="$el.previousElementSibling.insertAdjacentHTML('beforeend', '\(escaped)'); window.devdashMarkDirty($el)">\(label)</button>
        """
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
swift build 2>&1 | tail -10
```
Expected: Build complete. If it errors on `Bundle.module`, the resource bundle declaration in Task 1 didn't take — re-check Package.swift.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Scanners/ProductDocAssets.swift
git commit -m "$(cat <<'EOF'
feat: ProductDocAssets — copy bundled JS + addBtn template helper

Copies alpine.min.js and devdash-components.js from Bundle.module
into each project's docs/devdash/.assets/ on every regen, idempotent.
Exposes addBtn(label:html:) used by templates to render Alpine + Add
buttons that append into their previous sibling element.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire ProductDocGenerator to emit `.assets/` and load Alpine in the shell

**Files:**
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift`

- [ ] **Step 1: Call `ProductDocAssets.writeAssets` at the start of `generate(...)`**

In `ProductDocGenerator.swift`, locate the `generate(...)` function (line 58–152). Just after the line `let folder = folderPath(for: projectPath)` and the section folder creation, add:

```swift
// Vendor JS (Alpine + components) into <project>/docs/devdash/.assets/.
// Idempotent — only writes when bundled resource differs from disk.
ProductDocAssets.writeAssets(to: folder)
```

- [ ] **Step 2: Add the Alpine script tags to the shell HTML**

In the same file, locate the `let html = """` block (around line 119–140). Insert two new `<script defer>` lines right after the `\(sharedStyles)` line in the `<head>`:

Before:
```swift
\(sharedStyles)
</head>
<body>
```

After:
```swift
\(sharedStyles)
<script defer src=".assets/devdash-components.js"></script>
<script defer src=".assets/alpine.min.js"></script>
</head>
<body>
```

(devdash-components.js is loaded BEFORE alpine.min.js so the `alpine:init` listener is attached before Alpine fires it. Both use `defer` so they execute after HTML parsing in document order.)

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: Build succeeded.

- [ ] **Step 4: Smoke test that Alpine loads in the running app**

Restart and verify:
```bash
pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash >/dev/null 2>&1 &
```

In DevDash, open the dev-dash project, switch to the Product tab. Verify:
1. `docs/devdash/.assets/alpine.min.js` and `docs/devdash/.assets/devdash-components.js` now exist on disk:
   ```bash
   ls -la docs/devdash/.assets/
   ```
2. Right-click the WKWebView → Inspect Element (or Safari → Develop → DevDash). In the JS console, type `window.Alpine` — expected: an object, not undefined.
3. The console shows no errors.
4. Existing tabs (Overview, Roadmap, Initiatives, Goals & KPIs, Ideas, Artifacts) all still render unchanged. Existing + Add buttons still work (they're using the old `data-action` handler at this point, which still exists).

If `window.Alpine` is undefined: check that the `<script>` tags are in the rendered HTML (`view-source:` or curl the file), and that the `.assets/` files exist.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Scanners/ProductDocGenerator.swift
git commit -m "$(cat <<'EOF'
feat: load Alpine.js + devdash-components in living doc shell

generate() now calls ProductDocAssets.writeAssets to copy bundled
JS into the project's .assets/ folder, and the shell HTML includes
<script defer> tags that load components first then Alpine, so the
alpine:init listener attaches before Alpine fires it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Rewrite `goals.html` stub with inline Alpine buttons

**Files:**
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift` (the `.goals` case in `stub(_:)`)

- [ ] **Step 1: Replace the `.goals` case body**

In `ProductDocGenerator.swift`, locate `case .goals(let name):` inside `stub(_:)` (around line 451–508). Replace the entire returned string with:

```swift
case .goals(let name):
    return """
    <div class="doc-head">
      <h2>\(escapeHTML(name)) — Goals &amp; KPIs</h2>
      <span class="doc-status"><code>sections/goals.html</code></span>
    </div>

    <h3>North-star metric</h3>
    <div class="kpi-grid">
      <div class="kpi">
        <div class="k-label">North-star</div>
        <div class="k-value">—</div>
        <div class="k-target">target: —</div>
        <div class="k-delta">vs. last week: —</div>
      </div>
    </div>

    <h3>Quarter goals</h3>
    <ul class="checklist">
      <li>☐ <em>Goal 1</em></li>
      <li>☐ <em>Goal 2</em></li>
      <li>☐ <em>Goal 3</em></li>
    </ul>
    \(ProductDocAssets.addBtn(label: "+ Add goal", html: "<li>☐ <em>New goal</em></li>"))

    <h3>Tracked KPIs</h3>
    <div class="kpi-grid kpi-tracked">
      <div class="kpi">
        <div class="k-label">Activation</div>
        <div class="k-value">—</div>
        <div class="k-target">target: —</div>
        <div class="k-delta">—</div>
      </div>
      <div class="kpi">
        <div class="k-label">D7 retention</div>
        <div class="k-value">—</div>
        <div class="k-target">target: —</div>
        <div class="k-delta">—</div>
      </div>
      <div class="kpi">
        <div class="k-label">Weekly active</div>
        <div class="k-value">—</div>
        <div class="k-target">target: —</div>
        <div class="k-delta">—</div>
      </div>
    </div>
    \(ProductDocAssets.addBtn(label: "+ Add KPI tile", html: "<div class=\"kpi\"><div class=\"k-label\">New KPI</div><div class=\"k-value\">—</div><div class=\"k-target\">target: —</div><div class=\"k-delta\">—</div></div>"))

    <h3>Detailed metrics</h3>
    <table>
      <thead><tr><th>Metric</th><th>Current</th><th>Target</th><th>Notes</th></tr></thead>
      <tbody>
        <tr><td><em>weekly active users</em></td><td>—</td><td>—</td><td>—</td></tr>
        <tr><td><em>activation rate</em></td><td>—</td><td>—</td><td>—</td></tr>
      </tbody>
    </table>
    \(ProductDocAssets.addBtn(label: "+ Add metric", html: "<tr><td><em>new metric</em></td><td>—</td><td>—</td><td>—</td></tr>"))
    """
```

Note: the `addBtn` helper places the button as the next sibling of the previous element. For the table case, `$el.previousElementSibling` is the `<table>`, but we want to append to `<tbody>`. Since `insertAdjacentHTML('beforeend', ...)` on a `<table>` element with a `<tr>` works in browsers (the row goes into the existing tbody), this is correct.

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: Build succeeded.

- [ ] **Step 3: Smoke test**

Delete the existing goals stub so the new one scaffolds:
```bash
rm -f docs/devdash/sections/goals.html
```

Restart DevDash:
```bash
pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash >/dev/null 2>&1 &
```

Open dev-dash → Product → Goals & KPIs tab. Verify:
1. + Add goal: clicking appends a new `☐ <em>New goal</em>` line under the checklist
2. + Add KPI tile: clicking appends a new KPI tile under the tracked KPI grid
3. + Add metric: clicking appends a new row in the metrics table
4. Each click flashes the section orange (dirty) → green (saved) edge
5. After save, the new content persists in `docs/devdash/sections/goals.html`
6. Web Inspector console shows no errors

If a button doesn't fire: check that the button has `contenteditable="false"`. Check the click expression is well-formed (no HTML entity escaping issues with the embedded `'`).

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/ProductDocGenerator.swift docs/devdash/sections/goals.html
git commit -m "$(cat <<'EOF'
refactor: goals.html stub uses inline Alpine + Add buttons

Replaces data-action="dom-insert-template" buttons with Alpine
@click handlers via the new addBtn helper. Buttons live in the
saved HTML so they survive without auto-inject.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Rewrite `ideas.html` stub with inline Alpine buttons

**Files:**
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift` (the `.ideas` case in `stub(_:)`)

- [ ] **Step 1: Replace the `.ideas` case body**

The ideas board buttons need to live INSIDE each column (so the button stays at the bottom of the column when new ideas are appended). For this we use `$el.insertAdjacentHTML('beforebegin', ...)` so the new item is inserted right before the button.

Locate `case .ideas:` inside `stub(_:)`. Replace the returned string with:

```swift
case .ideas:
    let ideaCardHTML = "<div class=\"item\"><span class=\"tag\">new</span> <em>New idea — describe it</em></div>"
    func ideaBtn() -> String {
        let esc = ideaCardHTML
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        <button class="add-btn" contenteditable="false" @click="$el.insertAdjacentHTML('beforebegin', '\(esc)'); window.devdashMarkDirty($el)">+ Idea</button>
        """
    }
    return """
    <div class="doc-head">
      <h2>Ideas</h2>
      <span class="doc-status">Parking lot · <code>sections/ideas.html</code></span>
    </div>

    <p class="meta">Promote to a task (Tasks tab) or a PRD (Product → New PRD) when an idea is ripe.</p>

    <div class="board">
      <div class="col" data-col="quick-wins">
        <h4>Quick wins <span class="meta">low effort, real value</span></h4>
        <div class="item"><span class="tag">eng</span> <em>Idea 1</em></div>
        <div class="item"><span class="tag">design</span> <em>Idea 2</em></div>
        \(ideaBtn())
      </div>
      <div class="col" data-col="big-bets">
        <h4>Big bets <span class="meta">larger investment</span></h4>
        <div class="item"><span class="tag">research</span> <em>Idea 3</em></div>
        \(ideaBtn())
      </div>
      <div class="col" data-col="maybe-later">
        <h4>Maybe later <span class="meta">parked</span></h4>
        <div class="item"><span class="tag">marketing</span> <em>Idea 4</em></div>
        \(ideaBtn())
      </div>
    </div>
    """
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: Build succeeded.

- [ ] **Step 3: Smoke test**

```bash
rm -f docs/devdash/sections/ideas.html
pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash >/dev/null 2>&1 &
```

Open dev-dash → Product → Ideas tab. Verify:
1. + Idea button at the bottom of each column adds a new `.item` above the button (button stays at bottom)
2. New idea card has the `new` tag and editable italic placeholder text
3. Saves auto-fire (orange flash → green flash)
4. No console errors

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/ProductDocGenerator.swift docs/devdash/sections/ideas.html
git commit -m "$(cat <<'EOF'
refactor: ideas.html stub uses inline Alpine + Idea buttons

Each column's + Idea button uses $el.insertAdjacentHTML('beforebegin', ...)
so the new card lands above the button and the button stays anchored
at the column bottom.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Rewrite the 6 stable artifact templates with inline Alpine buttons

**Files:**
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift` (the `template(_:projectName:)` switch — `.prd`, `.implementationPlan`, `.statusReport`, `.decisionLog`, `.conceptExplainer`, `.retrospective` cases)

These templates contain dynamic structures (KPI grids, checklists, tables) that previously got + Add buttons via auto-inject. We add inline Alpine buttons everywhere a + Add affordance is useful. Triage is handled separately in Task 7.

- [ ] **Step 1: PRD template — add buttons**

In `template(_:projectName:)`, locate `case .prd:`. After the Risks `<table>...</table>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add risk", html: "<tr><td><em>new risk</em></td><td><span class=\"pill warn\">Med</span></td><td><em>mitigation</em></td></tr>"))
```

After the Open questions `<ul>...</ul>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add question", html: "<li><em>New question — owner, due date</em></li>"))
```

After the Success metrics `<div class="kpi-grid">...</div>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add KPI", html: "<div class=\"kpi\"><div class=\"k-label\">New metric</div><div class=\"k-value\">—</div><div class=\"k-target\">target: —</div></div>"))
```

- [ ] **Step 2: Implementation Plan template — add buttons**

Locate `case .implementationPlan:`. After the Milestones `<ul class="timeline">...</ul>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add milestone", html: "<li><div class=\"t-meta\">Week ?</div><div class=\"t-title\">New milestone</div><p><em>Description.</em></p></li>"))
```

After the Risks `<table>...</table>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add risk", html: "<tr><td><em>new risk</em></td><td><span class=\"pill warn\">Med</span></td><td><span class=\"pill risk\">High</span></td><td><em>mitigation</em></td></tr>"))
```

After the Rollout `<ul class="checklist">...</ul>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add rollout step", html: "<li>☐ <em>New step</em></li>"))
```

- [ ] **Step 3: Status Report template — add buttons**

Locate `case .statusReport:`. The four `<div class="card">` blocks (Shipped / In progress / Slipped / Next week) each contain a `<ul>`. After each `</ul>` (still inside the card), add the appropriate addBtn:

```swift
// Inside the "✓ Shipped" card, after </ul>:
\(ProductDocAssets.addBtn(label: "+ Add", html: "<li><em>New item</em></li>"))
// Same pattern in the other three cards (In progress / Slipped / Next week).
```

After the Risks &amp; asks `<ul>...</ul>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add", html: "<li><span class=\"pill warn\">Risk</span> <em>New item</em></li>"))
```

- [ ] **Step 4: Decision Log template — add button on the options table**

Locate `case .decisionLog:`. Inside the single `<div class="card">` block, after the options `<table>...</table>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add option", html: "<tr><td><strong>?.</strong> <em>name</em></td><td><em>…</em></td><td><em>…</em></td></tr>"))
```

After the closing `</div>` of the first decision card, add a new + Decision button OUTSIDE the card so users can add new entries to the log. The button targets the immediately preceding card:

```swift
\(ProductDocAssets.addBtn(label: "+ Add decision", html: "<div class=\"card\"><div class=\"doc-head\"><h3 style=\"margin:0\">D-### · <em>title</em></h3><span class=\"doc-status meta\"><span class=\"pill warn\">Draft</span></span></div><h4>Context</h4><p><em>What forced the decision.</em></p><h4>Decision</h4><p><strong>Picked: …</strong> <em>Why.</em></p></div>"))
```

Wait — the addBtn helper appends to the previous sibling, but here we want each new decision to appear *between* the existing decision and the button (so the button stays at the bottom and decisions stack chronologically). Use a different pattern: have the button insert *before itself*:

```swift
let decisionCardHTML = "<div class=\"card\"><div class=\"doc-head\"><h3 style=\"margin:0\">D-### · <em>title</em></h3><span class=\"doc-status meta\"><span class=\"pill warn\">Draft</span></span></div><h4>Context</h4><p><em>What forced the decision.</em></p><h4>Decision</h4><p><strong>Picked: …</strong> <em>Why.</em></p></div>"
let escDecision = decisionCardHTML.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
let addDecisionBtn = """
<button class="add-btn" contenteditable="false" @click="$el.insertAdjacentHTML('beforebegin', '\(escDecision)'); window.devdashMarkDirty($el)">+ Add decision</button>
"""
```

Then place `\(addDecisionBtn)` after the closing `</div>` of the first card. The button remains the last element; new decisions appear above it.

- [ ] **Step 5: Concept Explainer template — add buttons**

Locate `case .conceptExplainer:`. After the Key terms `<table>...</table>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add term", html: "<tr><td><strong><em>New term</em></strong></td><td><em>1-line definition.</em></td></tr>"))
```

After the "How it actually works" `<ol>...</ol>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add step", html: "<li><em>New step</em></li>"))
```

After the Gotchas `<ul>` inside the warn callout, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add gotcha", html: "<li><em>New surprising thing</em></li>"))
```

- [ ] **Step 6: Retrospective template — add buttons**

Locate `case .retrospective:`. The four `<div class="card">` blocks each contain a `<ul>` (with `class="checklist"` for action items). After each `</ul>`, add an inline addBtn:

```swift
// Inside "👍 Went well" card, after </ul>:
\(ProductDocAssets.addBtn(label: "+ Add", html: "<li><em>New item</em></li>"))
// Same in "👎 Didn't go well", "💡 Lessons" cards.
// In the "→ Action items" card with ul.checklist:
\(ProductDocAssets.addBtn(label: "+ Add action", html: "<li>☐ <em>New action — owner, due date</em></li>"))
```

After the Timeline `<ul class="timeline">...</ul>`, add:

```swift
\(ProductDocAssets.addBtn(label: "+ Add milestone", html: "<li class=\"done\"><div class=\"t-meta\">When</div><div class=\"t-title\">New entry</div><p><em>What happened.</em></p></li>"))
```

- [ ] **Step 7: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: Build succeeded.

- [ ] **Step 8: Smoke test**

```bash
pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash >/dev/null 2>&1 &
```

Spawn one of each artifact type via DevDash → Product tab toolbar → pencil menu → New PRD / New Implementation Plan / etc. For each, verify:
1. The template file is created in its folder (`docs/devdash/prd/prd-feature.html`, `docs/devdash/plans/implementation-plan.html`, etc.)
2. Opening the artifact (it shows in the Artifacts tab automatically) reveals the inline + Add buttons in their expected positions
3. Each + Add button works — adds the right HTML in the right place, fires save

(You can spawn one new artifact, eyeball the buttons, then delete the file before spawning the next type to keep the dev-dash workspace clean — or leave them; they're throwaway in this dogfood project.)

- [ ] **Step 9: Commit**

```bash
git add Sources/DevDash/Scanners/ProductDocGenerator.swift
git commit -m "$(cat <<'EOF'
refactor: artifact templates use inline Alpine + Add buttons

PRD, Implementation Plan, Status Report, Decision Log, Concept
Explainer, and Retrospective templates now declare their + Add
buttons inline via Alpine @click. No more reliance on the
auto-inject layer to decorate dynamic structures.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Rewrite triage template — body shell with x-data + JSON state

**Files:**
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift` (`.triageBoard` case in `template(_:projectName:)`)

- [ ] **Step 1: Replace the `.triageBoard` case body**

Locate `case .triageBoard:` in `template(_:projectName:)`. Replace the entire returned string with:

```swift
case .triageBoard:
    return """
    <div class="doc-head">
      <h2>Triage Board</h2>
      <span class="doc-status meta">Drag tickets between columns. Auto-saves.</span>
    </div>

    <script type="application/json" id="triage-state" data-state="triage">
    { "cards": [] }
    </script>

    <div data-section-file="" data-section-format="alpine-triage" x-data="triageBoard()" x-init="init()">
      <div class="triage-controls">
        <button class="add-btn" contenteditable="false" @click="addCard('now')">+ Ticket</button>
        <button class="add-btn" contenteditable="false" @click="copyMarkdown()" x-text="copyLabel"></button>
      </div>
      <div class="triage-cols">
        <template x-for="col in cols" :key="col">
          <div class="triage-col" :data-col="col" @dragover.prevent @drop="drop($event, col)">
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
                  <button class="rm-btn" contenteditable="false" @click="removeCard(card.id)">✕</button>
                </div>
              </template>
            </div>
          </div>
        </template>
      </div>
    </div>

    <p class="empty">Hint: click a tag on a ticket to filter. Click the title to edit.</p>
    """
```

Note: `data-section-file=""` is filled in at *load* time by the bridge, NOT at scaffold time, because the file path isn't known when the template is rendered (the file is later named via `uniquePath`). See Task 9 for how the bridge fills it in. Alternative: have the spawn flow inject the path. We use the bridge approach because it keeps the template free of dynamic file paths.

Actually, the path IS known when scaffolding — `spawnTemplate` writes the file to a known target. But threading the path through `template(...)` requires changing its signature. Simpler: the bridge fills in `data-section-file` from the section's containing artifact card. See Task 9.

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: Build succeeded.

- [ ] **Step 3: Smoke test**

Spawn a fresh triage board: DevDash → Product → pencil menu → Triage Board.

Open the new triage file in the Artifacts tab. Verify:
1. The four columns render: Now, Next, Later, Cut
2. Each column shows `0` count (no cards yet — JSON state is empty)
3. + Ticket button is visible
4. "Copy as Markdown" button shows
5. NO console errors (especially no "triageBoard is not defined")
6. Clicking + Ticket may or may not work yet — Task 8 finalizes the full data flow including save

(If you see "triageBoard is not defined", devdash-components.js didn't load or is malformed — check the script tag and the file contents.)

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/ProductDocGenerator.swift
git commit -m "$(cat <<'EOF'
refactor: triage template uses Alpine x-data with JSON state block

Triage scaffold now includes a <script id="triage-state"> JSON block
as source of truth, plus an x-data root that uses x-for to render
columns and cards. State persistence wiring lands in subsequent commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Slim ProductWebView bridge JS + add devdashMarkDirty / devdashSaveAlpine

**Files:**
- Modify: `Sources/DevDash/Views/ProductWebView.swift`

- [ ] **Step 1: Replace the `bridgeJS` constant**

In `ProductWebView.swift`, locate `private static let bridgeJS = """ ... """` (line 80–449). Replace the entire string with the slim version:

```swift
private static let bridgeJS = """
(function() {
  function post(payload) {
    try { window.webkit.messageHandlers.devdash.postMessage(payload); }
    catch (e) { console.error('devdash bridge failed', e); }
  }

  // Walk every artifact embed (.embed[data-section-file]) and copy the section
  // file path onto any descendant Alpine-managed root that doesn't have one yet.
  // Triage templates ship with data-section-file="" because the path isn't known
  // at scaffold time; the embed wrapper supplies it at view time.
  function fillAlpineSectionPaths(scope) {
    (scope || document).querySelectorAll('[data-section-file]').forEach(function(host) {
      var hostPath = host.dataset.sectionFile;
      if (!hostPath) return;
      host.querySelectorAll('[data-section-format="alpine-triage"]').forEach(function(node) {
        if (!node.dataset.sectionFile) node.dataset.sectionFile = hostPath;
      });
    });
  }

  function attachEditing(root) {
    (root || document).querySelectorAll('[data-section-file]').forEach(function(el) {
      if (el.dataset.editingAttached) return;
      // Alpine-managed sections own their own state machine; do not make their
      // root contenteditable.
      if (el.dataset.sectionFormat === 'alpine-triage') { el.dataset.editingAttached = 'true'; return; }
      // Artifact-browser .embed wrappers that contain an Alpine-triage root
      // delegate ownership to the inner Alpine component — making the outer
      // wrapper contenteditable would cause the whole embed innerHTML to save
      // alongside (and conflict with) the JSON-block save path.
      if (el.querySelector('[data-section-format="alpine-triage"]')) {
        el.dataset.editingAttached = 'true';
        return;
      }
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

  // Inline Alpine @click handlers in templates call this after mutating DOM
  // inside a contenteditable section, so the input listener fires and the
  // debounced save runs.
  window.devdashMarkDirty = function(el) {
    var section = el.closest('[data-section-file]');
    if (!section) return;
    section.classList.add('is-dirty');
    section.dispatchEvent(new Event('input', { bubbles: true }));
  };

  // Triage's scheduleSave() calls this with the section path + JSON state.
  // Bridge ships it to Swift, which regex-replaces the JSON block in the file.
  window.devdashSaveAlpine = function(path, state) {
    if (!path) return;   // Alpine root hadn't been linked to a file yet
    post({ action: 'save-alpine', path: path, state: state });
    var sec = document.querySelector('[data-section-file="' + path + '"]');
    if (sec) {
      sec.classList.add('is-saved');
      setTimeout(function() { sec.classList.remove('is-saved'); }, 1500);
    }
  };

  // Pass-through delegate for any [data-action] not consumed locally.
  // Keeps open-file / regenerate / etc. working from the rendered HTML.
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

  // Bridge style for dirty/saved indicators
  if (!document.getElementById('devdash-bridge-style')) {
    var style = document.createElement('style');
    style.id = 'devdash-bridge-style';
    style.textContent = '\\n[data-section-file] { transition: box-shadow 0.18s; outline: none; border-radius: 6px; }' +
                        '\\n[data-section-file]:focus { box-shadow: inset 0 0 0 1px var(--accent); }' +
                        '\\n[data-section-file].is-dirty { box-shadow: inset 0 0 0 1px var(--orange); }' +
                        '\\n[data-section-file].is-saved { box-shadow: inset 0 0 0 1px var(--green); }';
    document.head.appendChild(style);
  }

  fillAlpineSectionPaths(document);
  attachEditing(document);
  document.querySelectorAll('nav.tabs .tab').forEach(function(b) {
    b.addEventListener('click', function() {
      setTimeout(function() {
        fillAlpineSectionPaths(document);
        attachEditing(document);
      }, 30);
    });
  });
})();
"""
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: Build succeeded.

- [ ] **Step 3: Smoke test (no save-alpine handler yet)**

```bash
pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash >/dev/null 2>&1 &
```

Open dev-dash → Product. Verify:
1. Overview / Roadmap / Initiatives / Goals / Ideas tabs all still render
2. Goals tab + Add buttons still fire (these now route through `window.devdashMarkDirty` via Alpine `@click`, not data-action)
3. Ideas + Idea buttons still fire
4. Web Inspector console is clean — no errors
5. Triage board (open from Artifacts tab): + Ticket button now works (Alpine has `addCard('now')` wired). The card appears in the Now column. (Save will fail in Swift handler — ignore; that's Task 9.) The console may log a `save-alpine` warning from Swift; acceptable for now.

Old artifacts (PRD/plan/etc.) created BEFORE this commit no longer have inline buttons — they relied on auto-inject. Either delete them or accept that they'll lose + Add affordances.

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Views/ProductWebView.swift
git commit -m "$(cat <<'EOF'
refactor: slim bridge JS to ~80 lines — auto-save + Alpine pass-through

Deletes the auto-inject layer, dom-insert-template / dom-remove-closest
handlers, the inline templates dictionary, the triage drag-drop machinery,
and the contenteditable-vs-button caret hacks. Adds window.devdashMarkDirty
for Alpine @click handlers and window.devdashSaveAlpine for triage state
saves. Skips contenteditable on alpine-triage roots — Alpine owns the DOM
inside.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Add `save-alpine` handler — Coordinator + onSaveAlpine closure + Swift JSON-block rewriter

**Files:**
- Modify: `Sources/DevDash/Views/ProductWebView.swift` (add closure + coordinator case)
- Modify: `Sources/DevDash/Views/Tabs/ProductTabView.swift` (wire the closure)

- [ ] **Step 1: Add `onSaveAlpine` closure on `ProductWebView` + coordinator**

In `ProductWebView.swift`, change the struct's stored properties (around line 11–17):

```swift
struct ProductWebView: NSViewRepresentable {
    let url: URL
    let docsRoot: URL
    let reloadToken: Int
    let onSave: (String, String) -> Void           // (relPath, html)
    let onSaveAlpine: (String, String) -> Void     // (relPath, jsonState)
    let onAction: ([String: Any]) -> Void
```

Update `makeCoordinator()`:

```swift
func makeCoordinator() -> Coordinator {
    Coordinator(onSave: onSave, onSaveAlpine: onSaveAlpine, onAction: onAction)
}
```

Update the `Coordinator` class:

```swift
final class Coordinator: NSObject, WKScriptMessageHandler {
    var onSave: (String, String) -> Void
    var onSaveAlpine: (String, String) -> Void
    var onAction: ([String: Any]) -> Void
    var lastReloadToken: Int = -1

    init(onSave: @escaping (String, String) -> Void,
         onSaveAlpine: @escaping (String, String) -> Void,
         onAction: @escaping ([String: Any]) -> Void) {
        self.onSave = onSave
        self.onSaveAlpine = onSaveAlpine
        self.onAction = onAction
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["action"] as? String {
        case "save":
            if let path = body["path"] as? String,
               let html = body["html"] as? String {
                onSave(path, html)
            }
        case "save-alpine":
            if let path = body["path"] as? String,
               let state = body["state"] as? String {
                onSaveAlpine(path, state)
            }
        default:
            onAction(body)
        }
    }
}
```

Update `updateNSView` to refresh the new closure too:

```swift
func updateNSView(_ nsView: WKWebView, context: Context) {
    if nsView.url != url || context.coordinator.lastReloadToken != reloadToken {
        nsView.loadFileURL(url, allowingReadAccessTo: docsRoot)
        context.coordinator.lastReloadToken = reloadToken
    }
    context.coordinator.onSave = onSave
    context.coordinator.onSaveAlpine = onSaveAlpine
    context.coordinator.onAction = onAction
}
```

- [ ] **Step 2: Wire `onSaveAlpine` in `ProductTabView.swift`**

In `ProductTabView.swift`, locate the `ProductWebView(...)` invocation (around line 93–103). Add the new closure parameter:

```swift
ProductWebView(
    url: URL(fileURLWithPath: path),
    docsRoot: docsRoot,
    reloadToken: reloadToken,
    onSave: { rel, html in
        saveSection(projectPath: project.path, rel: rel, html: html)
    },
    onSaveAlpine: { rel, state in
        saveAlpineSection(projectPath: project.path, rel: rel, state: state)
    },
    onAction: { payload in
        handleAction(project: project, payload: payload)
    }
)
```

- [ ] **Step 3: Implement `saveAlpineSection` in `ProductTabView.swift`**

Add this private function alongside the existing `saveSection` (around line 116):

```swift
/// Bridge handler for Alpine-managed sections (currently triage). The browser
/// sends just the JSON state — we regex-replace the contents of the
/// <script id="triage-state">…</script> block in the file. If the file or
/// block is missing, regenerate the entire artifact from the triage template
/// scaffold and embed the new state.
private func saveAlpineSection(projectPath: String, rel: String, state: String) {
    let target = "\(projectPath)/docs/devdash/\(rel)"
    let dir = (target as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let fm = FileManager.default
    let existing = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
    if !existing.isEmpty,
       let updated = replaceTriageStateBlock(in: existing, with: state) {
        try? updated.write(toFile: target, atomically: true, encoding: .utf8)
        DocIndexGenerator.generate(projectPath: projectPath)
        return
    }

    // Fallback: file is missing or block is malformed — regenerate from the template
    // and patch the state in.
    let projectName = (projectPath as NSString).lastPathComponent
    let scaffold = ProductDocGenerator.template(.triageBoard, projectName: projectName)
    if let withState = replaceTriageStateBlock(in: scaffold, with: state) {
        try? withState.write(toFile: target, atomically: true, encoding: .utf8)
        DocIndexGenerator.generate(projectPath: projectPath)
    }
    _ = fm  // silence unused warning if compiler complains; remove if unneeded
}

/// Non-greedy regex replace of the contents of <script ... id="triage-state" ...>...</script>.
/// Returns nil if the block isn't found.
private func replaceTriageStateBlock(in html: String, with state: String) -> String? {
    let pattern = #"(<script[^>]*id="triage-state"[^>]*>)([\s\S]*?)(</script>)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    guard regex.firstMatch(in: html, options: [], range: range) != nil else { return nil }
    // Pretty-print the JSON for readability on disk.
    let pretty = prettyJSON(state) ?? state
    let replacement = "$1\n\(pretty)\n$3"
    return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: replacement)
}

private func prettyJSON(_ raw: String) -> String? {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: []),
          let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
          let str = String(data: pretty, encoding: .utf8) else { return nil }
    return str
}
```

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -10
```
Expected: Build succeeded. If it errors on `_ = fm`, just delete that line — it's a vestigial guard.

- [ ] **Step 5: Smoke test the full triage flow**

```bash
pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash >/dev/null 2>&1 &
```

In dev-dash:
1. Spawn a new Triage Board (Product → pencil → Triage Board)
2. Click + Ticket — a "New ticket" card appears in Now
3. Wait ~1s — the section flashes green (saved)
4. Open the file on disk:
   ```bash
   cat docs/devdash/triage/triage-*.html | head -40
   ```
   The `<script id="triage-state">` block now contains the card JSON (pretty-printed).
5. Edit the card title in the browser. Wait. The file updates with the new title.
6. Drag the card from Now to Next. The file updates: `"col": "next"`.
7. Click ✕ on the card. The file updates: `"cards": []`.
8. Click + Ticket again, then click the "untagged" tag — verify the filter behavior (clicking a tag hides cards without that tag in OTHER columns; click again to clear).
9. Click "Copy as Markdown" — verify it briefly says "Copied!" and the clipboard contains markdown.
10. Close the app and reopen — the saved triage state restores.

If the file isn't updating: check the WKWebView console for the `save-alpine` post payload, check `saveAlpineSection` is being called (add a temporary `NSLog`), check the regex matches the script tag in the saved HTML.

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Views/ProductWebView.swift Sources/DevDash/Views/Tabs/ProductTabView.swift
git commit -m "$(cat <<'EOF'
feat: save-alpine bridge — JSON state regex-rewrite for triage

ProductWebView gains an onSaveAlpine closure; the coordinator routes
save-alpine messages from window.devdashSaveAlpine. ProductTabView
implements the file write as a non-greedy regex replace of just the
<script id="triage-state"> block, falling back to full template
regenerate if the file or block is missing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Cleanup throwaway files + smoke test on wnba-tracker

**Files:**
- Delete: `docs/devdash/triage/*.html` (in dev-dash)
- Delete: `docs/devdash/sections/{goals,ideas}.html` (in dev-dash, if not already regenerated)
- Same in `~/dev/wnba-tracker`

- [ ] **Step 1: Clean dev-dash throwaway files**

```bash
ls docs/devdash/triage/ 2>/dev/null
rm -f docs/devdash/triage/*.html
rm -f docs/devdash/sections/goals.html docs/devdash/sections/ideas.html
# overview.html stays (no Alpine-affecting changes)
```

- [ ] **Step 2: Restart and verify dev-dash regenerates clean**

```bash
pkill -f .build/debug/DevDash; sleep 1; nohup .build/debug/DevDash >/dev/null 2>&1 &
```

Open dev-dash → Product. Verify:
1. Goals & KPIs tab renders with the new Alpine + Add buttons
2. Ideas tab renders with new Alpine + Idea buttons
3. Roadmap, Initiatives unchanged (state preserved from ProjectMeta)
4. Stage Q&A answers still present in Roadmap (verify by clicking through stages)
5. Web Inspector console: zero errors

- [ ] **Step 3: Smoke test on wnba-tracker**

In DevDash, switch to the wnba-tracker project. Verify the Product tab loads (it should already have docs/devdash/ from earlier). Then:

```bash
cd ~/dev/wnba-tracker
ls docs/devdash/triage/ 2>/dev/null
rm -f docs/devdash/triage/*.html
rm -f docs/devdash/sections/goals.html docs/devdash/sections/ideas.html
cd ~/dev/dev-dash
```

Switch wnba-tracker tab in DevDash. Verify:
1. Goals & KPIs tab renders fresh with Alpine + Add buttons
2. Ideas tab renders fresh
3. Spawn a triage board in wnba-tracker — verify add card / drag / save works there too
4. `docs/devdash/.assets/alpine.min.js` and `devdash-components.js` exist in wnba-tracker too (writeAssets is per-project)

- [ ] **Step 4: Confirm the bridge JS line count goal hit**

```bash
awk '/private static let bridgeJS = """/{flag=1} flag{count++} /^    """$/{if(flag){print count; exit}} ' Sources/DevDash/Views/ProductWebView.swift
```
Expected: ≤ 100 lines. (If higher, look for any logic that snuck in.)

- [ ] **Step 5: Final commit (optional — if any throwaway-cleanup cruft)**

If `git status` shows any test files that should be tracked or untracked, sort them. Otherwise this task ends with no commit (the cleanup was filesystem-only on test repos).

```bash
git status
```

If wnba-tracker has its own git repo, separately commit there:

```bash
cd ~/dev/wnba-tracker
git status
# review, then commit any throwaway file deletions
```

---

## Verification checklist (run after all tasks)

- [ ] `swift build` is clean (no warnings introduced by this work)
- [ ] Bridge JS in `ProductWebView.swift` is ≤ 100 lines
- [ ] All six tabs of dev-dash Product render: Overview, Roadmap, Initiatives, Goals & KPIs, Ideas, Artifacts
- [ ] Goals tab: + Add goal / + Add KPI tile / + Add metric all work
- [ ] Ideas tab: + Idea works in each of three columns; new card lands above the button
- [ ] Each artifact template (PRD, Plan, Status, Decision, Concept, Retro) renders with inline + Add buttons that work
- [ ] Triage: + Ticket adds card; drag between columns persists; ✕ removes; tag filter toggles; Copy as Markdown copies; title edits persist; reopening the app restores the state
- [ ] `docs/devdash/.assets/alpine.min.js` and `devdash-components.js` are present in dev-dash AND wnba-tracker
- [ ] Web Inspector console is clean (no errors) on every tab
- [ ] Roadmap stage Q&A and exit-criteria checkmarks unchanged
- [ ] Initiatives derived view unchanged
- [ ] Tasks tab unchanged
- [ ] Living doc still readable in default browser when opened via the toolbar's "Open in default browser" button (note: triage will render but won't be interactive without the file:// origin loading the .assets/ JS — Alpine still loads via relative URL so it should work)

## Rollback note

If a task lands incorrectly, `git revert <sha>` works because each task is one commit. The most likely failure spot is Task 9's regex replacer; if it corrupts a triage file, the fallback path regenerates from the template scaffold + the latest state, so worst case is losing one save's worth of edits.
