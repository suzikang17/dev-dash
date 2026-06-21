# Daily-page docs entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the **Today** tab into a Roam-style infinite scroll of editable daily pages — each day a `note` doc rendered as a native SwiftUI bullet outliner — where a bullet can be supertagged into any lore type (extract-to-typed-doc + backlink), with live file-watch so Claude-Code-written bullets appear automatically.

**Architecture:** Pure logic (parse/serialize, outline ops, supertag extraction) lives in `Scanners/` and is verified deterministically through a headless `--daily-selftest` CLI subcommand (mirroring the existing `TerminalSelfTest`/`DocRegenCLI` pattern). The UI is a native SwiftUI outliner (`OutlinerView` + an `NSTextField`-backed `BulletRow` with field-editor key interception). `DailyTabView` composes per-day outliner blocks into an infinite scroll. A `NotesFileWatcher` (DispatchSource) refreshes non-focused days when files change on disk.

**Tech Stack:** Swift / SwiftUI, AppKit (`NSTextField`, `NSViewRepresentable`, DispatchSource), the `lore` CLI via `ShellRunner.run`, existing helpers `LoreSection`, `LoreReader`, `LoreRunner.nextId`/`.slug`, `LoreLinkIndex`.

## Global Constraints

- macOS 14+, Swift 5.9, SwiftUI + AppKit only (plus SwiftTerm, already a dep). No new external Swift dependencies.
- No XCTest target exists. Deterministic logic is verified via the headless CLI subcommand `DevDash --daily-selftest` (build + run, assert PASS / exit 0). UI-only tasks are verified via `swift build` + `bash run.sh` manual check.
- Lore type ≠ folder: folder is plural (`docs/decisions`), CLI type is the schema's singular `name` (`decision`). Never pass a plural to `lore reindex` (see `LoreSection`).
- Doc authoring is deterministic (hand-written frontmatter + body), not AI-generated — supertag extraction must never call `claude -p`.
- Daily note files live at `docs/notes/YYYY-MM-DD.md`, frontmatter `title` + `created` (the date), body is a markdown bullet list. Indentation unit = **2 spaces per depth**.
- Commit directly to `main`, imperative concise messages (per project CLAUDE.md).
- Run `lore reindex <type>` after creating/mutating a typed doc.

---

## File Structure

**Create:**
- `Sources/DevDash/Scanners/DayOutline.swift` — `DayNode` model + markdown list ⇄ `[DayNode]` parse/serialize + pure outline operations (indent/outdent/split/merge/move/delete). One responsibility: the outline data structure and its transforms. Pure, no IO.
- `Sources/DevDash/Scanners/DailyPageStore.swift` — per-day file IO: resolve `docs/notes/YYYY-MM-DD.md`, load → `[DayNode]`, debounced atomic save (preserving frontmatter), lazy-create today. `@MainActor ObservableObject`.
- `Sources/DevDash/Scanners/SupertagRegistry.swift` — the dynamic list of taggable lore types (from `LoreSection.all` + synthesized `task`/`devlog`), each describing how to author a valid doc.
- `Sources/DevDash/Scanners/LoreDocWriter.swift` — schema-driven doc authoring: build a typed doc's file content (pure) and the supertag extraction transform (pure), plus the IO wrapper that writes the file + runs `lore reindex`.
- `Sources/DevDash/Scanners/NotesFileWatcher.swift` — DispatchSource watcher over `docs/notes/`, debounced change callback.
- `Sources/DevDash/Views/BulletRow.swift` — `NSViewRepresentable` wrapping a single `NSTextField`; intercepts Enter/Tab/Shift-Tab/Backspace/arrows via `control(_:textView:doCommandBy:)` and reports them as semantic actions.
- `Sources/DevDash/Views/OutlinerView.swift` — renders one day's `[DayNode]` as a flattened list of `BulletRow`s; owns focus, fold state, supertag picker, and wires row actions to outline ops + the store.
- `Sources/DevDash/DailySelfTest.swift` — headless `--daily-selftest` harness (assertions over the pure logic).

**Modify:**
- `Sources/DevDash/App.swift:11` — add `DailySelfTest.runIfRequested()` alongside the existing self-test/CLI calls.
- `Sources/DevDash/Views/Tabs/DailyTabView.swift` — replace the read-only `.daily` timeline with the infinite-scroll editable outliner; keep `.browse` mode, the sessions band, and the summarize-day wand.

---

## Task 1: Outline model + markdown round-trip

**Files:**
- Create: `Sources/DevDash/Scanners/DayOutline.swift`
- Create: `Sources/DevDash/DailySelfTest.swift`
- Modify: `Sources/DevDash/App.swift:11`

**Interfaces:**
- Produces:
  - `struct DayNode: Identifiable { let id: UUID; var text: String; var children: [DayNode]; var collapsed: Bool }` with `init(text:children:collapsed:)` defaulting `children: []`, `collapsed: false`.
  - `enum DayOutline { static func parse(_ markdown: String) -> [DayNode]; static func serialize(_ nodes: [DayNode]) -> String }`
  - `enum DailySelfTest { static func runIfRequested() }`

- [ ] **Step 1: Write the failing test (self-test harness + first assertions)**

Create `Sources/DevDash/DailySelfTest.swift`:

```swift
import Foundation

/// Headless deterministic checks for the daily-page logic. Mirrors TerminalSelfTest:
///   DevDash --daily-selftest
/// Runs in-memory + temp-dir assertions, prints PASS/FAIL, exits (0 = all pass).
enum DailySelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--daily-selftest") else { return }
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { FileHandle.standardError.write(Data("  ok: \(label)\n".utf8)) }
            else { failures.append(label); FileHandle.standardError.write(Data("  FAIL: \(label)\n".utf8)) }
        }

        roundTrip(check)

        let msg = failures.isEmpty
            ? "daily-selftest: ALL PASS\n"
            : "daily-selftest: \(failures.count) FAILURE(S)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func roundTrip(_ check: (Bool, String) -> Void) {
        let md = "- a\n  - b\n  - c\n- d\n"
        let nodes = DayOutline.parse(md)
        check(nodes.count == 2, "parse: 2 top-level nodes")
        check(nodes.first?.text == "a", "parse: first node text == a")
        check(nodes.first?.children.count == 2, "parse: 'a' has 2 children")
        check(nodes.first?.children.first?.text == "b", "parse: first child == b")
        check(DayOutline.serialize(nodes) == md, "round-trip: serialize(parse(md)) == md")

        let empty = DayOutline.parse("")
        check(empty.isEmpty, "parse: empty string -> []")

        // Tolerant: malformed (non-list) content becomes a single bullet, never dropped.
        let raw = DayOutline.parse("just some prose\nmore prose")
        check(raw.count == 1, "parse: non-list prose -> 1 fallback node")
        check(raw.first?.text.contains("just some prose") == true, "parse: prose preserved")
    }
}
```

Wire it into `Sources/DevDash/App.swift` `init()` (after line 11):

```swift
        DocRegenCLI.runIfRequested()        // exits early when launched with --regen <projectPath>
        DailySelfTest.runIfRequested()      // exits early when launched with --daily-selftest
```

- [ ] **Step 2: Run to verify it fails (does not compile — `DayOutline`/`DayNode` undefined)**

Run: `swift build 2>&1 | head -5`
Expected: FAIL — `cannot find 'DayOutline' in scope`.

- [ ] **Step 3: Implement `DayOutline.swift`**

Create `Sources/DevDash/Scanners/DayOutline.swift`:

```swift
import Foundation

/// One node in a day's bullet outline. `id`/`collapsed` are ephemeral UI state and
/// are NOT persisted; only `text` + nesting survive a round-trip to markdown.
struct DayNode: Identifiable, Equatable {
    let id: UUID
    var text: String
    var children: [DayNode]
    var collapsed: Bool

    init(id: UUID = UUID(), text: String, children: [DayNode] = [], collapsed: Bool = false) {
        self.id = id; self.text = text; self.children = children; self.collapsed = collapsed
    }
}

/// Pure markdown-list <-> [DayNode] parse/serialize. Indentation unit = 2 spaces/depth.
enum DayOutline {
    private static let indentUnit = 2

    static func serialize(_ nodes: [DayNode]) -> String {
        var out = ""
        func emit(_ node: DayNode, depth: Int) {
            let pad = String(repeating: " ", count: depth * indentUnit)
            out += "\(pad)- \(node.text)\n"
            for child in node.children { emit(child, depth: depth + 1) }
        }
        for node in nodes { emit(node, depth: 0) }
        return out
    }

    static func parse(_ markdown: String) -> [DayNode] {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        // Each non-empty line that is a list item ("- text", any indent). If NO line is a
        // list item, fall back to a single node holding the whole body (never drop content).
        struct Raw { let depth: Int; let text: String }
        var raws: [Raw] = []
        var sawListItem = false
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let leading = line.prefix { $0 == " " }.count
            let body = line.drop { $0 == " " }
            if body.hasPrefix("- ") || body == "-" {
                sawListItem = true
                let text = body.hasPrefix("- ") ? String(body.dropFirst(2)) : ""
                raws.append(Raw(depth: leading / indentUnit, text: text))
            } else if sawListItem {
                // continuation/wrapped line — append to previous node's text
                if let last = raws.popLast() {
                    raws.append(Raw(depth: last.depth, text: last.text + " " + line.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        if !sawListItem {
            return [DayNode(text: trimmed)]
        }

        // Build a flat array with each node's parent index (an ancestor stack tracks
        // the currently-open node at each depth), then assemble children bottom-up so
        // value-type DayNodes get their children before being copied into a parent.
        var flat: [(node: DayNode, parent: Int?)] = []
        var ancestors: [(idx: Int, depth: Int)] = []   // open ancestors, shallow→deep
        for raw in raws {
            while let last = ancestors.last, last.depth >= raw.depth { ancestors.removeLast() }
            let parent = ancestors.last?.idx
            flat.append((DayNode(text: raw.text), parent))
            ancestors.append((flat.count - 1, raw.depth))
        }

        var childrenOf: [Int: [DayNode]] = [:]
        var roots: [DayNode] = []
        for i in stride(from: flat.count - 1, through: 0, by: -1) {
            var n = flat[i].node
            n.children = childrenOf[i] ?? []
            if let p = flat[i].parent { childrenOf[p, default: []].insert(n, at: 0) }
            else { roots.insert(n, at: 0) }
        }
        return roots
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build 2>&1 | tail -3 && swift run DevDash --daily-selftest 2>&1 | tail -8`
Expected: build succeeds; output ends with `daily-selftest: ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Scanners/DayOutline.swift Sources/DevDash/DailySelfTest.swift Sources/DevDash/App.swift
git commit -m "daily: outline model + markdown round-trip + headless selftest"
```

---

## Task 2: Pure outline operations

**Files:**
- Modify: `Sources/DevDash/Scanners/DayOutline.swift`
- Modify: `Sources/DevDash/DailySelfTest.swift`

**Interfaces:**
- Consumes: `DayNode`, `DayOutline.serialize/parse`.
- Produces, all on `enum DayOutline`, operating on `[DayNode]` by node `id` and returning a NEW tree (value semantics) plus the id that should hold focus next:
  - `static func insertSibling(after id: UUID, in nodes: [DayNode]) -> (nodes: [DayNode], focus: UUID)` — new empty node as the next sibling of `id`.
  - `static func indent(_ id: UUID, in nodes: [DayNode]) -> [DayNode]` — make `id` a child of its previous sibling (no-op if it has none).
  - `static func outdent(_ id: UUID, in nodes: [DayNode]) -> [DayNode]` — move `id` to be the next sibling of its parent (no-op at depth 0).
  - `static func mergeIntoPrevious(_ id: UUID, in nodes: [DayNode]) -> (nodes: [DayNode], focus: UUID?, caret: Int)?` — Backspace-at-start: append `id`'s text to the previous visible node, reparent `id`'s children to it, delete `id`. Returns nil if `id` is the very first node.
  - `static func update(_ id: UUID, text: String, in nodes: [DayNode]) -> [DayNode]`
  - `static func flatten(_ nodes: [DayNode], includeCollapsedChildren: Bool) -> [(node: DayNode, depth: Int)]` — preorder, skipping descendants of collapsed nodes when `includeCollapsedChildren == false`.

- [ ] **Step 1: Write the failing test**

Add to `DailySelfTest.runIfRequested()` body, after `roundTrip(check)`:

```swift
        outlineOps(check)
```

Add this method to `DailySelfTest`:

```swift
    private static func outlineOps(_ check: (Bool, String) -> Void) {
        let base = DayOutline.parse("- a\n- b\n  - c\n")
        let aId = base[0].id, bId = base[1].id

        // insertSibling after a -> a, NEW, b
        let ins = DayOutline.insertSibling(after: aId, in: base)
        check(ins.nodes.count == 3, "insertSibling: 3 top-level")
        check(ins.nodes[1].text == "" && ins.nodes[1].id == ins.focus, "insertSibling: focus on new empty node")

        // indent b -> a has child b (which has child c)
        let ind = DayOutline.indent(bId, in: base)
        check(ind.count == 1 && ind[0].children.count == 1, "indent: b becomes child of a")
        check(ind[0].children[0].children.first?.text == "c", "indent: b keeps its child c")

        // outdent c -> c becomes sibling of b under root
        let cId = base[1].children[0].id
        let outd = DayOutline.outdent(cId, in: base)
        check(outd.count == 3, "outdent: c lifted to top level (a,b,c)")

        // mergeIntoPrevious b -> a becomes "ab", c reparented under a
        let merged = DayOutline.mergeIntoPrevious(bId, in: base)
        check(merged?.nodes.count == 1, "merge: b folds into a")
        check(merged?.nodes.first?.text == "ab", "merge: text concatenated -> ab")
        check(merged?.nodes.first?.children.first?.text == "c", "merge: c reparented under a")
        check(DayOutline.mergeIntoPrevious(aId, in: base) == nil, "merge: first node returns nil")

        // flatten respects collapsed
        var coll = base; coll[1].collapsed = true
        let visible = DayOutline.flatten(coll, includeCollapsedChildren: false)
        check(visible.count == 2, "flatten: collapsed b hides c (a,b visible)")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | head -5`
Expected: FAIL — `type 'DayOutline' has no member 'insertSibling'`.

- [ ] **Step 3: Implement the operations**

Append to `enum DayOutline` in `DayOutline.swift`:

```swift
    // MARK: - Operations (value semantics; return new trees)

    static func update(_ id: UUID, text: String, in nodes: [DayNode]) -> [DayNode] {
        map(nodes) { n in if n.id == id { var m = n; m.text = text; return m }; return n }
    }

    static func insertSibling(after id: UUID, in nodes: [DayNode]) -> (nodes: [DayNode], focus: UUID) {
        let new = DayNode(text: "")
        func walk(_ list: [DayNode]) -> [DayNode] {
            var out: [DayNode] = []
            for n in list {
                var m = n
                m.children = walk(n.children)
                out.append(m)
                if n.id == id { out.append(new) }
            }
            return out
        }
        return (walk(nodes), new.id)
    }

    static func indent(_ id: UUID, in nodes: [DayNode]) -> [DayNode] {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else {
            return nodes.map { var m = $0; m.children = indent(id, in: $0.children); return m }
        }
        guard idx > 0 else { return nodes }     // no previous sibling -> no-op
        var out = nodes
        let moving = out.remove(at: idx)
        out[idx - 1].children.append(moving)
        return out
    }

    static func outdent(_ id: UUID, in nodes: [DayNode]) -> [DayNode] {
        // Find id among some parent's children; lift it to be the parent's next sibling.
        func walk(_ list: [DayNode]) -> [DayNode] {
            var out: [DayNode] = []
            for var parent in list {
                if let childIdx = parent.children.firstIndex(where: { $0.id == id }) {
                    let moving = parent.children.remove(at: childIdx)
                    out.append(parent)
                    out.append(moving)
                } else {
                    parent.children = walk(parent.children)
                    out.append(parent)
                }
            }
            return out
        }
        return walk(nodes)   // id at top level has no parent -> unchanged
    }

    static func mergeIntoPrevious(_ id: UUID, in nodes: [DayNode]) -> (nodes: [DayNode], focus: UUID?, caret: Int)? {
        let flat = flatten(nodes, includeCollapsedChildren: true)
        guard let pos = flat.firstIndex(where: { $0.node.id == id }), pos > 0 else { return nil }
        let prev = flat[pos - 1].node
        let cur = flat[pos].node
        let caret = prev.text.count
        var working = update(prev.id, text: prev.text + cur.text, in: nodes)
        // reparent cur's children under prev, then delete cur
        for child in cur.children { working = append(child, under: prev.id, in: working) }
        working = delete(id, in: working)
        return (working, prev.id, caret)
    }

    static func delete(_ id: UUID, in nodes: [DayNode]) -> [DayNode] {
        var out: [DayNode] = []
        for n in nodes where n.id != id {
            var m = n; m.children = delete(id, in: n.children); out.append(m)
        }
        return out
    }

    static func flatten(_ nodes: [DayNode], includeCollapsedChildren: Bool) -> [(node: DayNode, depth: Int)] {
        var out: [(DayNode, Int)] = []
        func walk(_ list: [DayNode], _ depth: Int) {
            for n in list {
                out.append((n, depth))
                if includeCollapsedChildren || !n.collapsed { walk(n.children, depth + 1) }
            }
        }
        walk(nodes, 0)
        return out
    }

    // MARK: - private helpers

    private static func map(_ nodes: [DayNode], _ f: (DayNode) -> DayNode) -> [DayNode] {
        nodes.map { n in var m = f(n); m.children = map(n.children, f); return m }
    }

    private static func append(_ child: DayNode, under parentId: UUID, in nodes: [DayNode]) -> [DayNode] {
        nodes.map { n in
            var m = n
            if n.id == parentId { m.children.append(child) }
            else { m.children = append(child, under: parentId, in: n.children) }
            return m
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run DevDash --daily-selftest 2>&1 | tail -12`
Expected: ends with `daily-selftest: ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Scanners/DayOutline.swift Sources/DevDash/DailySelfTest.swift
git commit -m "daily: pure outline ops (insert/indent/outdent/merge/flatten)"
```

---

## Task 3: DailyPageStore (per-day file IO)

**Files:**
- Create: `Sources/DevDash/Scanners/DailyPageStore.swift`
- Modify: `Sources/DevDash/DailySelfTest.swift`

**Interfaces:**
- Consumes: `DayOutline`, `DayNode`, `LoreReader.parseFrontmatter`.
- Produces:
  - `static func DailyPageStore.fileURL(projectPath: String, date: String) -> URL` — `docs/notes/<date>.md`.
  - `static func DailyPageStore.load(projectPath: String, date: String) -> [DayNode]` — parses body (frontmatter stripped); `[]` if file absent.
  - `static func DailyPageStore.write(projectPath: String, date: String, nodes: [DayNode]) throws` — preserves existing frontmatter (or writes `title`/`created` on create), replaces body with `DayOutline.serialize(nodes)`, atomic.
  - `static func DailyPageStore.recentDates(projectPath: String, limit: Int) -> [String]` — existing `notes/*.md` filenames that look like `YYYY-MM-DD`, descending, plus today even if absent.

  (The `@MainActor` debounced-save wrapper is added in the UI task; the statics above are the testable core.)

- [ ] **Step 1: Write the failing test**

Add `pageStoreIO(check)` to the self-test run body and this method:

```swift
    private static func pageStoreIO(_ check: (Bool, String) -> Void) {
        let tmp = NSTemporaryDirectory() + "ddtest-\(UUID().uuidString)"
        let docs = tmp + "/docs/notes"
        try? FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let date = "2026-06-21"
        let nodes = DayOutline.parse("- hello\n  - world\n")
        do {
            try DailyPageStore.write(projectPath: tmp, date: date, nodes: nodes)
        } catch { check(false, "pageStore: write threw \(error)"); return }

        let path = DailyPageStore.fileURL(projectPath: tmp, date: date).path
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check(raw.contains("title:"), "pageStore: frontmatter title written on create")
        check(raw.contains("- hello"), "pageStore: body serialized")

        let reloaded = DailyPageStore.load(projectPath: tmp, date: date)
        check(reloaded.first?.text == "hello", "pageStore: round-trip load text")
        check(reloaded.first?.children.first?.text == "world", "pageStore: round-trip load child")

        // Frontmatter (e.g. tags) preserved across re-write.
        var fm = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        fm = fm.replacingOccurrences(of: "title:", with: "tags: keep\ntitle:")
        try? fm.write(toFile: path, atomically: true, encoding: .utf8)
        try? DailyPageStore.write(projectPath: tmp, date: date, nodes: DayOutline.parse("- changed\n"))
        let raw2 = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check(raw2.contains("tags: keep"), "pageStore: preserves existing frontmatter on re-write")
        check(raw2.contains("- changed") && !raw2.contains("- hello"), "pageStore: body replaced")

        check(DailyPageStore.load(projectPath: tmp, date: "2099-01-01").isEmpty, "pageStore: missing file -> []")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | head -5`
Expected: FAIL — `cannot find 'DailyPageStore' in scope`.

- [ ] **Step 3: Implement `DailyPageStore.swift`**

```swift
import Foundation

/// File IO for a single day's note page (docs/notes/YYYY-MM-DD.md). Pure statics are
/// deterministic and selftested; `DailyPageController` (UI task) adds the debounced
/// @MainActor save wrapper on top.
enum DailyPageStore {
    static func fileURL(projectPath: String, date: String) -> URL {
        URL(fileURLWithPath: "\(projectPath)/docs/notes/\(date).md")
    }

    static func load(projectPath: String, date: String) -> [DayNode] {
        let url = fileURL(projectPath: projectPath, date: date)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return DayOutline.parse(stripFrontmatter(raw))
    }

    static func write(projectPath: String, date: String, nodes: [DayNode]) throws {
        let dir = "\(projectPath)/docs/notes"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = fileURL(projectPath: projectPath, date: date)
        let body = DayOutline.serialize(nodes)
        let frontmatter = existingFrontmatter(at: url) ?? "---\ntitle: \"\(date)\"\ncreated: \"\(date)\"\n---"
        let content = "\(frontmatter)\n\n\(body)"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func recentDates(projectPath: String, limit: Int) -> [String] {
        let dir = "\(projectPath)/docs/notes"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let re = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
        var dates = Set(files.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }
            .filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil })
        dates.insert(todayString())
        return Array(dates.sorted(by: >).prefix(limit))
    }

    static func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - frontmatter

    /// The literal `---\n...\n---` block at the top of the file, or nil if none.
    private static func existingFrontmatter(at url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8), raw.hasPrefix("---") else { return nil }
        let lines = raw.components(separatedBy: "\n")
        var fences = 0, end = 0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("---") { fences += 1; if fences == 2 { end = i; break } }
        }
        guard fences == 2 else { return nil }
        return lines[0...end].joined(separator: "\n")
    }

    private static func stripFrontmatter(_ s: String) -> String {
        guard s.hasPrefix("---") else { return s }
        let lines = s.components(separatedBy: "\n")
        var fences = 0, start = 0
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("---") { fences += 1; if fences == 2 { start = i + 1; break } }
        }
        return lines.dropFirst(start).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run DevDash --daily-selftest 2>&1 | tail -10`
Expected: ends with `daily-selftest: ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Scanners/DailyPageStore.swift Sources/DevDash/DailySelfTest.swift
git commit -m "daily: DailyPageStore per-day file IO (frontmatter-preserving)"
```

---

## Task 4: SupertagRegistry

**Files:**
- Create: `Sources/DevDash/Scanners/SupertagRegistry.swift`
- Modify: `Sources/DevDash/DailySelfTest.swift`

**Interfaces:**
- Consumes: `LoreSection.all`.
- Produces:
  - `struct SupertagType: Equatable { let loreType: String; let dir: String; let label: String; let bodyIsFree: Bool; let requiredSections: [String]; let frontmatterFields: [String] }`
  - `enum SupertagRegistry { static func all() -> [SupertagType]; static func find(_ loreType: String) -> SupertagType? }`
  - `all()` = every `LoreSection.all` entry mapped to `SupertagType`, **plus** synthesized `task` and `devlog`, **minus** `note` (note is the default bullet state — tagging note is a no-op, so it is not offered). Order: task, idea, decision, kpi, devlog, overview.

- [ ] **Step 1: Write the failing test**

Add `supertagRegistry(check)` to the run body and:

```swift
    private static func supertagRegistry(_ check: (Bool, String) -> Void) {
        let types = SupertagRegistry.all()
        let names = types.map(\.loreType)
        check(names.contains("task"), "registry: includes task")
        check(names.contains("idea"), "registry: includes idea")
        check(names.contains("decision"), "registry: includes decision")
        check(names.contains("kpi"), "registry: includes kpi")
        check(names.contains("devlog"), "registry: includes devlog")
        check(!names.contains("note"), "registry: note is default, not offered")
        check(SupertagRegistry.find("task")?.dir == "tasks", "registry: task dir == tasks")
        check(SupertagRegistry.find("kpi")?.dir == "kpis", "registry: kpi dir == kpis (plural)")
        check(SupertagRegistry.find("decision")?.bodyIsFree == false, "registry: decision is sections schema")
        check(SupertagRegistry.find("task")?.frontmatterFields.contains("status=open") == true,
              "registry: task seeds status=open")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | head -5`
Expected: FAIL — `cannot find 'SupertagRegistry' in scope`.

- [ ] **Step 3: Implement `SupertagRegistry.swift`**

```swift
import Foundation

/// Describes a lore type a bullet can be supertagged into, including exactly how to
/// author a valid doc of that type (mirrors LoreSection.newDocFields semantics).
struct SupertagType: Equatable {
    let loreType: String        // singular CLI type, e.g. "task"
    let dir: String             // plural folder, e.g. "tasks"
    let label: String
    let bodyIsFree: Bool
    let requiredSections: [String]
    let frontmatterFields: [String]   // "k=v" pairs, e.g. ["status=open"]
}

/// The dynamic supertag set = all registered lore types. Built from LoreSection.all
/// plus task/devlog (which LoreSection does not model), minus note (the default).
enum SupertagRegistry {
    static func all() -> [SupertagType] {
        let task = SupertagType(loreType: "task", dir: "tasks", label: "Task",
                                bodyIsFree: true, requiredSections: [],
                                frontmatterFields: ["status=open", "owner=human", "category=engineering"])
        let devlog = SupertagType(loreType: "devlog", dir: "devlog", label: "Devlog",
                                  bodyIsFree: true, requiredSections: [], frontmatterFields: [])
        let fromSections: [SupertagType] = LoreSection.all.compactMap { s in
            guard s.loreType != "note" else { return nil }   // note = default, not offered
            return SupertagType(loreType: s.loreType, dir: s.dir, label: s.label,
                                bodyIsFree: s.bodyIsFree, requiredSections: s.requiredSections,
                                frontmatterFields: s.newDocFields)
        }
        // Stable, sensible order.
        let order = ["task", "idea", "decision", "kpi", "devlog", "overview"]
        let merged = [task, devlog] + fromSections
        return merged.sorted { (order.firstIndex(of: $0.loreType) ?? 99) < (order.firstIndex(of: $1.loreType) ?? 99) }
    }

    static func find(_ loreType: String) -> SupertagType? {
        all().first { $0.loreType == loreType }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run DevDash --daily-selftest 2>&1 | tail -12`
Expected: ends with `daily-selftest: ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Scanners/SupertagRegistry.swift Sources/DevDash/DailySelfTest.swift
git commit -m "daily: SupertagRegistry (all lore types, schema-aware)"
```

---

## Task 5: LoreDocWriter — doc content + supertag extraction

**Files:**
- Create: `Sources/DevDash/Scanners/LoreDocWriter.swift`
- Modify: `Sources/DevDash/DailySelfTest.swift`

**Interfaces:**
- Consumes: `SupertagType`, `SupertagRegistry`, `DayNode`, `DayOutline`, `LoreRunner.nextId`, `LoreRunner.slug`, `ShellRunner.run`.
- Produces:
  - `static func LoreDocWriter.docContent(type:title:bodyMarkdown:today:) -> String` — pure: builds frontmatter (`title`, `created`/`date`, each `frontmatterFields` k=v, `date` for sections schema) + body (free types: bodyMarkdown; sections types: scaffold `## <required>` headers, bodyMarkdown under the first).
  - `struct ExtractionResult { let mutatedNodes: [DayNode]; let docTitle: String; let docBody: String; let backlink: String }`
  - `static func LoreDocWriter.extract(nodeId:type:from:) -> ExtractionResult?` — pure: find node, title = its text, body = serialized de-indented children, replace node.text with `[[<title>]]` and clear its children. nil if node not found / empty title.
  - `static func LoreDocWriter.commit(projectPath:type:result:) async -> Bool` — IO: write `docs/<dir>/<nextId>-<slug>.md` with `docContent(...)`, then `lore reindex <type>`. Returns success.

- [ ] **Step 1: Write the failing test (pure parts only — no IO/CLI in selftest)**

Add `loreWriter(check)` to the run body and:

```swift
    private static func loreWriter(_ check: (Bool, String) -> Void) {
        let nodes = DayOutline.parse("- ship login\n  - add form\n  - wire api\n- other\n")
        let target = nodes[0].id

        guard let ex = LoreDocWriter.extract(nodeId: target, type: SupertagRegistry.find("task")!, from: nodes) else {
            check(false, "extract: returned nil"); return
        }
        check(ex.docTitle == "ship login", "extract: title from bullet text")
        check(ex.docBody.contains("- add form") && ex.docBody.contains("- wire api"), "extract: children become body")
        check(ex.backlink == "[[ship login]]", "extract: backlink token")
        check(ex.mutatedNodes[0].text == "[[ship login]]", "extract: bullet replaced with backlink")
        check(ex.mutatedNodes[0].children.isEmpty, "extract: children moved out of outline")
        check(ex.mutatedNodes.count == 2, "extract: sibling 'other' untouched")

        let task = LoreDocWriter.docContent(type: SupertagRegistry.find("task")!,
                                            title: "ship login", bodyMarkdown: "- add form", today: "2026-06-21")
        check(task.contains("status: open"), "docContent: task seeds status")
        check(task.contains("title: \"ship login\""), "docContent: title in frontmatter")

        let dec = LoreDocWriter.docContent(type: SupertagRegistry.find("decision")!,
                                           title: "use sqlite", bodyMarkdown: "because simple", today: "2026-06-21")
        check(dec.contains("date:"), "docContent: sections schema gets date")
        check(dec.contains("## Why this choice"), "docContent: decision scaffolds required H2s")

        // empty bullet cannot be extracted
        let empty = DayOutline.parse("- \n")
        check(LoreDocWriter.extract(nodeId: empty[0].id, type: SupertagRegistry.find("task")!, from: empty) == nil,
              "extract: empty bullet -> nil")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | head -5`
Expected: FAIL — `cannot find 'LoreDocWriter' in scope`.

- [ ] **Step 3: Implement `LoreDocWriter.swift`**

```swift
import Foundation

enum LoreDocWriter {
    struct ExtractionResult: Equatable {
        let mutatedNodes: [DayNode]
        let docTitle: String
        let docBody: String
        let backlink: String
    }

    /// Pure: extract a bullet's subtree into doc content, leaving a backlink in the outline.
    static func extract(nodeId: UUID, type: SupertagType, from nodes: [DayNode]) -> ExtractionResult? {
        guard let found = find(nodeId, in: nodes) else { return nil }
        let title = found.text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let body = DayOutline.serialize(found.children)   // children de-indent to depth 0
        let backlink = "[[\(title)]]"
        let mutated = replace(nodeId, in: nodes) { var m = $0; m.text = backlink; m.children = []; return m }
        return ExtractionResult(mutatedNodes: mutated, docTitle: title, docBody: body, backlink: backlink)
    }

    /// Pure: full markdown file content for a new typed doc (deterministic, no AI).
    static func docContent(type: SupertagType, title: String, bodyMarkdown: String, today: String) -> String {
        var fm = "---\ntitle: \"\(escape(title))\"\n"
        fm += "created: \"\(today)\"\n"
        for pair in type.frontmatterFields {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fm += "\(parts[0]): \(parts[1])\n" }
        }
        if !type.bodyIsFree { fm += "date: \"\(today)\"\n" }   // sections schemas require a date
        fm += "---\n\n# \(title)\n\n"

        if type.bodyIsFree {
            return fm + (bodyMarkdown.isEmpty ? "" : bodyMarkdown + "\n")
        }
        // sections schema: scaffold required H2s; put body under the first.
        var out = fm
        for (i, section) in type.requiredSections.enumerated() {
            out += "## \(section)\n\n"
            if i == 0 && !bodyMarkdown.isEmpty { out += bodyMarkdown + "\n\n" }
        }
        return out
    }

    /// IO: write the doc file + reindex. Returns success.
    static func commit(projectPath: String, type: SupertagType, result: ExtractionResult) async -> Bool {
        let dir = "\(projectPath)/docs/\(type.dir)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = LoreRunner.nextId(in: dir)
        let slug = LoreRunner.slug(from: result.docTitle)
        let file = "\(dir)/\(id)-\(slug).md"
        let today = DailyPageStore.todayString()
        let content = docContent(type: type, title: result.docTitle, bodyMarkdown: result.docBody, today: today)
        do { try content.write(toFile: file, atomically: true, encoding: .utf8) }
        catch { return false }
        if let bin = await loreBinary() {
            _ = await ShellRunner.run(bin, args: ["reindex", type.loreType], cwd: projectPath)
        }
        return true
    }

    // MARK: - helpers

    private static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }

    private static func find(_ id: UUID, in nodes: [DayNode]) -> DayNode? {
        for n in nodes {
            if n.id == id { return n }
            if let hit = find(id, in: n.children) { return hit }
        }
        return nil
    }

    private static func replace(_ id: UUID, in nodes: [DayNode], _ f: (DayNode) -> DayNode) -> [DayNode] {
        nodes.map { n in
            if n.id == id { return f(n) }
            var m = n; m.children = replace(id, in: n.children, f); return m
        }
    }

    private static func loreBinary() async -> String? {
        for p in ["/usr/local/bin/lore", "/opt/homebrew/bin/lore", "\(NSHomeDirectory())/.local/bin/lore"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        if let found = await ShellRunner.run("/usr/bin/which", args: ["lore"]) {
            let t = found.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift run DevDash --daily-selftest 2>&1 | tail -14`
Expected: ends with `daily-selftest: ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Scanners/LoreDocWriter.swift Sources/DevDash/DailySelfTest.swift
git commit -m "daily: LoreDocWriter (doc content + supertag extraction)"
```

---

## Task 6: BulletRow — NSTextField with key interception

**Files:**
- Create: `Sources/DevDash/Views/BulletRow.swift`

**Interfaces:**
- Consumes: nothing from prior tasks (pure AppKit view).
- Produces:
  - `enum BulletKey { case enterNew, indent, outdent, mergeBack, focusUp, focusDown }`
  - `struct BulletRow: NSViewRepresentable` with: `@Binding var text: String`, `let isFocused: Bool`, `var caretToEnd: Bool = false`, `let onKey: (BulletKey) -> Void`, `let onFocus: () -> Void`. Reports Return→`enterNew`, Tab→`indent`, Backtab/Shift-Tab→`outdent`, delete-at-offset-0→`mergeBack`, up/down→`focusUp`/`focusDown`. Becomes first responder when `isFocused` flips true.

This is UI — verified by `swift build` (it compiles into the app) and exercised manually in Task 7. No selftest assertions.

- [ ] **Step 1: Implement `BulletRow.swift`**

```swift
import SwiftUI
import AppKit

enum BulletKey { case enterNew, indent, outdent, mergeBack, focusUp, focusDown }

/// A single editable bullet line. Wraps NSTextField so we can intercept the field
/// editor's command selectors (Return/Tab/Backspace/arrows) and turn them into
/// outline actions, which SwiftUI TextField cannot do.
struct BulletRow: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    var caretToEnd: Bool = false
    let onKey: (BulletKey) -> Void
    let onFocus: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 13)
        tf.lineBreakMode = .byWordWrapping
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        tf.delegate = context.coordinator
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
        context.coordinator.parent = self
        if isFocused, tf.window?.firstResponder != tf.currentEditor() {
            DispatchQueue.main.async {
                tf.window?.makeFirstResponder(tf)
                if caretToEnd, let editor = tf.currentEditor() {
                    editor.selectedRange = NSRange(location: tf.stringValue.count, length: 0)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BulletRow
        init(_ parent: BulletRow) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) { parent.onFocus() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onKey(.enterNew); return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onKey(.indent); return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onKey(.outdent); return true
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.selectedRange == NSRange(location: 0, length: 0) {
                    parent.onKey(.mergeBack); return true
                }
                return false
            case #selector(NSResponder.moveUp(_:)):
                parent.onKey(.focusUp); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onKey(.focusDown); return true
            default:
                return false
            }
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build 2>&1 | tail -3`
Expected: build succeeds (no warnings about `BulletRow`).

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Views/BulletRow.swift
git commit -m "daily: BulletRow NSTextField with outline key interception"
```

---

## Task 7: OutlinerView — compose rows, wire ops + focus

**Files:**
- Create: `Sources/DevDash/Views/OutlinerView.swift`

**Interfaces:**
- Consumes: `DayNode`, `DayOutline` (insert/indent/outdent/merge/update/flatten), `BulletRow`, `BulletKey`.
- Produces:
  - `struct OutlinerView: View` with `@Binding var nodes: [DayNode]`, `var onSupertag: (UUID) -> Void` (opens the picker for a node — wired in Task 8), and an internal `@State focusedId: UUID?`. Renders `DayOutline.flatten(nodes, includeCollapsedChildren: false)` as indented `BulletRow`s, applies key actions, and persists edits up through the binding.

Verified via `swift build` + manual (`bash run.sh`) once wired in Task 10.

- [ ] **Step 1: Implement `OutlinerView.swift`**

```swift
import SwiftUI

/// One day's editable bullet outline. Pure-ish view over a [DayNode] binding —
/// all tree mutations go through DayOutline so they stay testable.
struct OutlinerView: View {
    @Binding var nodes: [DayNode]
    var onSupertag: (UUID) -> Void

    @State private var focusedId: UUID?
    @State private var caretToEnd = false

    var body: some View {
        let rows = DayOutline.flatten(nodes, includeCollapsedChildren: false)
        VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty {
                Button { startFirstBullet() } label: {
                    Text("Start typing…").foregroundColor(.secondary).font(DSFont.body)
                }
                .buttonStyle(.plain)
            }
            ForEach(rows, id: \.node.id) { row in
                HStack(alignment: .top, spacing: DSSpace.xs) {
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                        .padding(.top, 7)
                    BulletRow(
                        text: binding(for: row.node.id),
                        isFocused: focusedId == row.node.id,
                        caretToEnd: caretToEnd && focusedId == row.node.id,
                        onKey: { handle($0, on: row.node.id) },
                        onFocus: { focusedId = row.node.id; caretToEnd = false }
                    )
                    Button { onSupertag(row.node.id) } label: {
                        Image(systemName: "number").font(.caption2).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Turn into a typed doc")
                }
                .padding(.leading, CGFloat(row.depth) * 18)
            }
        }
        .animation(.default, value: rows.count)
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { DayOutline.flatten(nodes, includeCollapsedChildren: true).first { $0.node.id == id }?.node.text ?? "" },
            set: { nodes = DayOutline.update(id, text: $0, in: nodes) }
        )
    }

    private func startFirstBullet() {
        let n = DayNode(text: "")
        nodes = [n]; focusedId = n.id; caretToEnd = true
    }

    private func handle(_ key: BulletKey, on id: UUID) {
        switch key {
        case .enterNew:
            let r = DayOutline.insertSibling(after: id, in: nodes)
            nodes = r.nodes; focusedId = r.focus; caretToEnd = true
        case .indent:
            nodes = DayOutline.indent(id, in: nodes)
        case .outdent:
            nodes = DayOutline.outdent(id, in: nodes)
        case .mergeBack:
            if let r = DayOutline.mergeIntoPrevious(id, in: nodes) {
                nodes = r.nodes; focusedId = r.focus; caretToEnd = true
            }
        case .focusUp:
            focusedId = neighbor(of: id, delta: -1) ?? focusedId
        case .focusDown:
            focusedId = neighbor(of: id, delta: +1) ?? focusedId
        }
    }

    private func neighbor(of id: UUID, delta: Int) -> UUID? {
        let flat = DayOutline.flatten(nodes, includeCollapsedChildren: false)
        guard let i = flat.firstIndex(where: { $0.node.id == id }) else { return nil }
        let j = i + delta
        return flat.indices.contains(j) ? flat[j].node.id : nil
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build 2>&1 | tail -3`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Views/OutlinerView.swift
git commit -m "daily: OutlinerView (rows + key ops + focus)"
```

---

## Task 8: Supertag picker + extraction wiring

**Files:**
- Modify: `Sources/DevDash/Views/OutlinerView.swift`

**Interfaces:**
- Consumes: `SupertagRegistry`, `SupertagType`, `LoreDocWriter` (`extract`, `commit`), `DayNode`.
- Produces: `OutlinerView` gains `let projectPath: String` and an internal supertag picker popover. Selecting a type runs `LoreDocWriter.extract` → updates `nodes` with the backlink → `await LoreDocWriter.commit` (writes typed doc + reindex). On commit failure, the outline mutation is reverted.

- [ ] **Step 1: Add the picker state + popover to OutlinerView**

Add stored properties and replace the supertag button action. Add near the top of `OutlinerView`:

```swift
    let projectPath: String
    @State private var pickerNodeId: UUID?
```

Replace the supertag `Button { onSupertag(row.node.id) }` with:

```swift
                    Button { pickerNodeId = row.node.id } label: {
                        Image(systemName: "number").font(.caption2).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Turn into a typed doc")
                    .popover(isPresented: Binding(
                        get: { pickerNodeId == row.node.id },
                        set: { if !$0 { pickerNodeId = nil } })) {
                        supertagPicker(for: row.node.id)
                    }
```

Add the picker view + apply method:

```swift
    @ViewBuilder
    private func supertagPicker(for id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Turn into").font(.caption).foregroundColor(.secondary)
                .padding(.bottom, 2)
            ForEach(SupertagRegistry.all(), id: \.loreType) { type in
                Button { apply(type, to: id) } label: {
                    HStack { Text("#\(type.loreType)"); Spacer(); Text(type.label).foregroundColor(.secondary) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3).padding(.horizontal, 6)
            }
        }
        .padding(8)
        .frame(width: 220)
    }

    private func apply(_ type: SupertagType, to id: UUID) {
        pickerNodeId = nil
        guard let ex = LoreDocWriter.extract(nodeId: id, type: type, from: nodes) else { return }
        let before = nodes
        nodes = ex.mutatedNodes                                  // optimistic: show backlink
        Task {
            let ok = await LoreDocWriter.commit(projectPath: projectPath, type: type, result: ex)
            if !ok { await MainActor.run { nodes = before } }    // revert on failure
        }
    }
```

`onSupertag` is now unused; remove the `var onSupertag` property and its callers.

- [ ] **Step 2: Verify it builds**

Run: `swift build 2>&1 | tail -3`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Views/OutlinerView.swift
git commit -m "daily: supertag picker + extraction wiring"
```

---

## Task 9: NotesFileWatcher

**Files:**
- Create: `Sources/DevDash/Scanners/NotesFileWatcher.swift`

**Interfaces:**
- Produces:
  - `final class NotesFileWatcher` with `init(dir: String, onChange: @escaping () -> Void)` and `func stop()`. Watches the `docs/notes` directory via a `DispatchSource` file-system object source; debounces bursts (~300ms) and calls `onChange` on the main queue. Re-arms if the directory is recreated.

Verified via `swift build` + manual (edit a notes file in another editor while the app runs; the non-focused day refreshes — checked in Task 10).

- [ ] **Step 1: Implement `NotesFileWatcher.swift`**

```swift
import Foundation

/// Watches docs/notes/ for external writes (Claude Code, editors) and fires a
/// debounced callback. The view layer refreshes NON-focused days only, so a
/// local in-progress edit is never clobbered.
final class NotesFileWatcher {
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let dir: String
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    init(dir: String, onChange: @escaping () -> Void) {
        self.dir = dir
        self.onChange = onChange
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        arm()
    }

    private func arm() {
        fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .global())
        src.setEventHandler { [weak self] in self?.fire() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    private func fire() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build 2>&1 | tail -3`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Scanners/NotesFileWatcher.swift
git commit -m "daily: NotesFileWatcher (DispatchSource, debounced)"
```

---

## Task 10: Integrate into DailyTabView (infinite scroll of editable pages)

**Files:**
- Modify: `Sources/DevDash/Views/Tabs/DailyTabView.swift`

**Interfaces:**
- Consumes: `DailyPageStore`, `DayNode`, `OutlinerView`, `NotesFileWatcher`.
- Produces: the `.daily` mode renders an infinite scroll of per-day blocks (newest first), each with an editable `OutlinerView` bound to that day's `[DayNode]`, plus the existing (de-emphasized, collapsible) sessions band. `.browse` mode, the summarize-day wand, and `NewLoreTaskSheet` are unchanged.

This is the integration task — verified by `swift build` then `bash run.sh` and manual interaction.

- [ ] **Step 1: Add per-day outline state + watcher to `DailyTabView`**

Add these `@State`s near the existing ones (top of `struct DailyTabView`):

```swift
    @State private var outlineByDate: [String: [DayNode]] = [:]
    @State private var saveWork: [String: DispatchWorkItem] = [:]
    @State private var focusedDate: String? = nil
    @State private var watcher: NotesFileWatcher? = nil
```

- [ ] **Step 2: Replace the `.daily` timeline body with editable day pages**

In `timeline(project:)`, replace the `else if mode == .daily { ScrollView { ... ForEach(days) ... } }` branch with:

```swift
            } else if mode == .daily {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DSSpace.xl, pinnedViews: .sectionHeaders) {
                        ForEach(days) { day in
                            Section {
                                dayPage(day, project: project)
                            } header: {
                                dayHeader(day)
                            }
                        }
                    }
                    .padding()
                }
            } else {
```

Add the `dayPage` builder (alongside `dayContent`):

```swift
    @ViewBuilder
    private func dayPage(_ day: DayGroup, project: Project) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.md) {
            OutlinerView(
                nodes: outlineBinding(for: day.dateStr, project: project),
                projectPath: project.path
            )
            .onAppear {
                if outlineByDate[day.dateStr] == nil {
                    outlineByDate[day.dateStr] = DailyPageStore.load(projectPath: project.path, date: day.dateStr)
                }
            }

            if !day.sessions.isEmpty {
                DisclosureGroup {
                    ForEach(day.sessions) { session in
                        DailyRow(
                            label: session.title ?? session.firstUserMessage ?? "Session",
                            detail: session.durationSeconds > 0 ? formatDuration(session.durationSeconds) : nil,
                            isSelected: selectedSession?.id == session.id,
                            action: { selectedEntry = nil; selectedSession = session }
                        )
                    }
                } label: {
                    Text("Claude · \(day.sessions.count)").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func outlineBinding(for date: String, project: Project) -> Binding<[DayNode]> {
        Binding(
            get: { outlineByDate[date] ?? [] },
            set: { newValue in
                outlineByDate[date] = newValue
                focusedDate = date
                scheduleSave(date: date, project: project)
            }
        )
    }

    private func scheduleSave(date: String, project: Project) {
        saveWork[date]?.cancel()
        let nodes = outlineByDate[date] ?? []
        let item = DispatchWorkItem {
            try? DailyPageStore.write(projectPath: project.path, date: date, nodes: nodes)
        }
        saveWork[date] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }
```

- [ ] **Step 3: Start the file watcher; refresh non-focused days on external change**

In `content(project:)`, add to the `.onAppear { reload(project: project) }` modifier a watcher start, and stop on disappear. Replace that `.onAppear` line with:

```swift
            .onAppear {
                reload(project: project)
                startWatcher(project: project)
            }
            .onDisappear { watcher?.stop(); watcher = nil }
```

Add the watcher methods:

```swift
    private func startWatcher(project: Project) {
        watcher?.stop()
        watcher = NotesFileWatcher(dir: "\(project.path)/docs/notes") {
            refreshUnfocusedPages(project: project)
        }
    }

    /// Re-load every loaded day EXCEPT the one being actively edited, so external
    /// writes (Claude Code) appear without clobbering local edits.
    private func refreshUnfocusedPages(project: Project) {
        for date in outlineByDate.keys where date != focusedDate {
            outlineByDate[date] = DailyPageStore.load(projectPath: project.path, date: date)
        }
        reload(project: project)   // refresh the day list (new files may add days)
    }
```

- [ ] **Step 4: Verify it builds**

Run: `swift build 2>&1 | tail -3`
Expected: build succeeds.

- [ ] **Step 5: Manual verification**

Run: `bash run.sh`
Check, with a project selected, on the **Today** tab:
1. Today's page shows "Start typing…"; clicking it / typing creates a bullet; Enter adds a sibling; Tab indents; Shift-Tab outdents; Backspace at start merges up.
2. The `#` button on a bullet opens the picker; choosing `#task` replaces the bullet with `[[title]]` and creates `docs/tasks/NNNN-title.md` (verify the file exists and `docs/tasks/index.md` lists it after reindex).
3. Scrolling down shows previous days as their own editable outlines.
4. Append a bullet to `docs/notes/<today>.md` from an external editor → within ~1s the page (if not the focused one) reflects it.

Run: `swift run DevDash --daily-selftest 2>&1 | tail -3`
Expected: `daily-selftest: ALL PASS` (no regressions).

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Views/Tabs/DailyTabView.swift
git commit -m "daily: infinite-scroll editable day pages + live file-watch"
```

---

## Task 11: Devlog + lore reindex

**Files:**
- Create: `docs/devlog/<today>-daily-page-docs-entry.md` (via the `/devlog` command, not hand-formatted)

- [ ] **Step 1: Write the devlog**

Run the `/devlog` command to capture this session's feature (the Roam×Tana daily-page entry). Per project CLAUDE.md, do not hand-format.

- [ ] **Step 2: Reindex + validate**

Run: `lore reindex devlog && lore validate devlog`
Expected: reindex writes `docs/devlog/index.md`; validate reports no errors.

- [ ] **Step 3: Commit**

```bash
git add docs/devlog
git commit -m "devlog: daily-page docs entry (Roam x Tana outliner)"
```

---

## Self-Review

**Spec coverage:**
- Infinite scroll of editable daily pages → Task 10. ✓
- One `note` doc per day, lazy-create, frontmatter preserved → Task 3. ✓
- Bullet outliner (Enter/Tab/Shift-Tab/Backspace/arrows, fold via `collapsed`) → Tasks 2, 6, 7. ✓
- Supertags = all registered lore types, dynamic → Task 4. ✓
- Extract-on-tag + `[[backlink]]` + reindex, schema-driven, deterministic (no AI) → Task 5, 8. ✓
- Live file-watch, non-focused refresh only → Tasks 9, 10. ✓
- Browse mode / sessions band / summarize wand retained → Task 10 keeps `.browse`, sessions DisclosureGroup, wand. ✓
- Error handling: write failures keep in-memory tree (Task 10 save is fire-and-forget on a copy); malformed parse → single fallback node (Task 1); extraction reverts outline on commit failure (Task 8); watcher never touches focused day (Task 10). ✓
- `[[` autocomplete: NOTE — the spec lists `[[` autocomplete inside the outliner as desirable; this plan ships clickable backlinks + the supertag picker but defers in-row `[[` autocomplete to a follow-up (the existing autocomplete lives in the lore-doc editors, not the NSTextField row). Flagged here rather than silently dropped.

**Placeholder scan:** No TBD/TODO; every code step is complete. ✓

**Type consistency:** `DayNode`, `DayOutline.*`, `SupertagType`, `SupertagRegistry.all/find`, `LoreDocWriter.extract/docContent/commit`, `ExtractionResult`, `BulletKey`, `BulletRow`, `OutlinerView(nodes:projectPath:)`, `DailyPageStore.load/write/fileURL/recentDates/todayString` are used consistently across tasks. ✓

**Scope:** Single cohesive subsystem (the daily-page outliner). One plan is appropriate. ✓

### Deferred (designed-around, not in this plan)
- In-row `[[` autocomplete (clickable backlinks ship; typeahead deferred).
- Drag-to-reorder (keyboard indent/outdent is the V1 reordering path).
- Soft line breaks within a bullet (`<br>`), multi-tag per node, per-supertag fields, tab consolidation — all per the spec's "Out of scope (V1)".
