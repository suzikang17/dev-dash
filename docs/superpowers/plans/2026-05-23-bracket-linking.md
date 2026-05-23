# Bracket Linking & Fluid Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Roam-style `[[]]` inline linking, a `⌘K` global command bar, bidirectional task-doc links, a live collapsible sidebar, and an Ideas → Task promotion flow to DevDash.

**Architecture:** A new `linkedDocPath: String?` field on `TaskItem` is the data backbone — tasks remember which doc created them. The JS layer in `ProductWebView` handles `[[` detection and posts structured messages through the existing WKWebView bridge. Swift handles creation and search, resolving results back to JS via `evaluateJavaScript("devdashResolve(...)")`. A new SwiftUI sidebar and `⌘K` overlay read reactively from `DashboardStore`.

**Tech Stack:** Swift/SwiftUI (macOS), WKWebView + `WKScriptMessageHandler`, vanilla JS injected at document-end, JSON file persistence via existing `TaskStore`.

---

## File Map

| Action | File | Responsibility |
|---|---|---|
| Modify | `Sources/DevDash/Models.swift` | Add `linkedDocPath` field to `TaskItem` |
| Modify | `Sources/DevDash/Scanners/TaskStore.swift` | Thread `linkedDocPath` through `add()` |
| Modify | `Sources/DevDash/DashboardStore.swift` | Update `addTask`, add `addLinkedTask`, `isCommandBarVisible`, `activeDocPath` |
| Modify | `Sources/DevDash/Views/ProductWebView.swift` | Add `callbackJS`, `bracketLinkJS`, new closures, webView ref on Coordinator |
| Modify | `Sources/DevDash/Views/Tabs/ProductTabView.swift` | Wire new bridge actions, add sidebar layout |
| Create | `Sources/DevDash/Views/LinkedTasksSidebarView.swift` | Live collapsible task list for current doc |
| Create | `Sources/DevDash/Views/CommandBarView.swift` | `⌘K` floating command bar |
| Modify | `Sources/DevDash/Views/TaskDetailSheet.swift` | Add "Referenced in" backlinks section |

---

## Task 1: Add `linkedDocPath` to `TaskItem`

**Files:**
- Modify: `Sources/DevDash/Models.swift`

- [ ] **Step 1: Add the field to `TaskItem`**

In `Models.swift`, find the `TaskItem` struct. After line `var gstackPersonaOverride: String? = nil`, add:

```swift
var linkedDocPath: String? = nil
```

The full field block should now end:
```swift
var hasAIRun: Bool = false
var phases: [String]? = nil
var completedPhases: [String] = []
var gstackPersonaOverride: String? = nil
var linkedDocPath: String? = nil
```

`Codable` decoding uses `nil` for any missing key automatically — no migration needed.

- [ ] **Step 2: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Models.swift
git commit -m "feat: add linkedDocPath field to TaskItem"
```

---

## Task 2: Thread `linkedDocPath` through `TaskStore.add`

**Files:**
- Modify: `Sources/DevDash/Scanners/TaskStore.swift`

- [ ] **Step 1: Add parameter to `TaskStore.add`**

Find the `static func add(` signature (line ~65). Change it to:

```swift
static func add(
    projectPath: String,
    title: String,
    category: TaskCategory = .other,
    stage: String? = nil,
    notes: String? = nil,
    source: TaskSource = .local,
    parentId: String? = nil,
    linkedDocPath: String? = nil
) throws -> TaskItem {
    var tasks = read(projectPath)
    let task = TaskItem(
        id: UUID().uuidString,
        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
        notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
        stage: stage,
        category: category,
        source: source,
        status: .open,
        createdAt: Date(),
        startedAt: nil,
        completedAt: nil,
        ghIssueURL: nil,
        parentId: parentId,
        linkedDocPath: linkedDocPath
    )
    tasks.append(task)
    try write(projectPath, tasks: tasks)
    return task
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Scanners/TaskStore.swift
git commit -m "feat: thread linkedDocPath through TaskStore.add"
```

---

## Task 3: Update `DashboardStore` — `addTask` + command bar state

**Files:**
- Modify: `Sources/DevDash/DashboardStore.swift`

- [ ] **Step 1: Add `linkedDocPath` to `addTask`**

Find `func addTask(` (line ~565). Change signature and body:

```swift
func addTask(
    projectPath: String,
    title: String,
    category: TaskCategory = .other,
    stage: String? = nil,
    notes: String? = nil,
    parentId: String? = nil,
    linkedDocPath: String? = nil
) {
    do {
        _ = try TaskStore.add(
            projectPath: projectPath, title: title,
            category: category, stage: stage, notes: notes,
            source: .local, parentId: parentId,
            linkedDocPath: linkedDocPath
        )
        projectTasks[projectPath] = TaskStore.read(projectPath)
        todoError = nil
        regenerateRoadmap(for: projectPath)
    } catch {
        todoError = "Couldn't add task: \(error.localizedDescription)"
    }
}
```

- [ ] **Step 2: Add command bar published state**

Find the `@Published var openTaskId` block (line ~69). Add two new properties nearby:

```swift
@Published var isCommandBarVisible: Bool = false
@Published var activeDocPath: String? = nil  // absolute path of doc open in ProductWebView
```

- [ ] **Step 3: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/DashboardStore.swift
git commit -m "feat: linkedDocPath in addTask, command bar state in DashboardStore"
```

---

## Task 4: ProductWebView — callback mechanism + new closures

**Files:**
- Modify: `Sources/DevDash/Views/ProductWebView.swift`

This task adds the JS promise/callback system and two new bridge closures so the `[[` JS can ask Swift for data and get answers back.

- [ ] **Step 1: Add new closure parameters to `ProductWebView`**

Replace the struct property declarations:

```swift
// Before:
struct ProductWebView: NSViewRepresentable {
    let url: URL
    let docsRoot: URL
    let reloadToken: Int
    let onSave: (String, String) -> Void
    let onSaveAlpine: (String, String) -> Void
    let onAction: ([String: Any]) -> Void

// After:
struct ProductWebView: NSViewRepresentable {
    let url: URL
    let docsRoot: URL
    let reloadToken: Int
    let onSave: (String, String) -> Void
    let onSaveAlpine: (String, String) -> Void
    let onAction: ([String: Any]) -> Void
    var onSearchItems: ((String) -> [[String: Any]])? = nil
    var onCreateTask: ((String, String?) -> [String: Any])? = nil
```

- [ ] **Step 2: Add `webView` weak ref to Coordinator and update callbacks**

Replace the `Coordinator` class:

```swift
final class Coordinator: NSObject, WKScriptMessageHandler {
    var onSave: (String, String) -> Void
    var onSaveAlpine: (String, String) -> Void
    var onAction: ([String: Any]) -> Void
    var onSearchItems: ((String) -> [[String: Any]])?
    var onCreateTask: ((String, String?) -> [String: Any])?
    var lastReloadToken: Int = -1
    weak var webView: WKWebView?

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
            if let path = body["path"] as? String, let html = body["html"] as? String {
                onSave(path, html)
            }
        case "save-alpine":
            if let path = body["path"] as? String, let state = body["state"] as? String {
                onSaveAlpine(path, state)
            }
        case "search-items":
            guard let query = body["query"] as? String,
                  let callbackId = body["callbackId"] as? String else { return }
            let results = onSearchItems?(query) ?? []
            if let data = try? JSONSerialization.data(withJSONObject: results),
               let json = String(data: data, encoding: .utf8) {
                webView?.evaluateJavaScript("devdashResolve('\(callbackId)', \(json))", completionHandler: nil)
            }
        case "create-task":
            guard let title = body["title"] as? String,
                  let callbackId = body["callbackId"] as? String else { return }
            let docPath = body["linkedDocPath"] as? String
            let result = onCreateTask?(title, docPath) ?? [:]
            if let data = try? JSONSerialization.data(withJSONObject: result),
               let json = String(data: data, encoding: .utf8) {
                webView?.evaluateJavaScript("devdashResolve('\(callbackId)', \(json))", completionHandler: nil)
            }
        case "get-item-status":
            guard let itemId = body["itemId"] as? String,
                  let callbackId = body["callbackId"] as? String else { return }
            let result = onSearchItems?("").first(where: { $0["id"] as? String == itemId }) ?? [:]
            if let data = try? JSONSerialization.data(withJSONObject: result),
               let json = String(data: data, encoding: .utf8) {
                webView?.evaluateJavaScript("devdashResolve('\(callbackId)', \(json))", completionHandler: nil)
            }
        default:
            onAction(body)
        }
    }
}
```

- [ ] **Step 3: Store webView ref and update closures in `makeNSView` / `updateNSView`**

In `makeNSView`, after `let wv = WKWebView(...)` and the `loadFileURL` call, add:
```swift
context.coordinator.webView = wv
```

In `updateNSView`, after the existing closure updates add:
```swift
context.coordinator.onSearchItems = onSearchItems
context.coordinator.onCreateTask = onCreateTask
```

In `makeCoordinator`, update to pass optionals:
```swift
func makeCoordinator() -> Coordinator {
    let c = Coordinator(onSave: onSave, onSaveAlpine: onSaveAlpine, onAction: onAction)
    c.onSearchItems = onSearchItems
    c.onCreateTask = onCreateTask
    return c
}
```

- [ ] **Step 4: Add `callbackJS` string constant and register it**

Add this constant after `bridgeJS` closes (after line 215):

```swift
private static let callbackJS = """
(function() {
  window._devdashCallbacks = window._devdashCallbacks || {};
  window.devdashResolve = function(callbackId, result) {
    var cb = window._devdashCallbacks[callbackId];
    if (cb) { cb(result); delete window._devdashCallbacks[callbackId]; }
  };
  window.devdash = window.devdash || {};
  function post(payload) {
    try { webkit.messageHandlers.devdash.postMessage(payload); }
    catch(e) { console.error('devdash bridge', e); }
  }
  function makePromise(action, extra) {
    return new Promise(function(resolve) {
      var id = Math.random().toString(36).slice(2);
      window._devdashCallbacks[id] = resolve;
      post(Object.assign({ action: action, callbackId: id }, extra));
    });
  }
  window.devdash.searchItems = function(query) {
    return makePromise('search-items', { query: query });
  };
  window.devdash.createTask = function(title, linkedDocPath) {
    return makePromise('create-task', { title: title, linkedDocPath: linkedDocPath });
  };
  window.devdash.getItemStatus = function(itemId, itemType) {
    return makePromise('get-item-status', { itemId: itemId, itemType: itemType });
  };
})();
"""
```

Register it in `makeNSView`. After `controller.add(context.coordinator, name: "devdash")`, insert:

```swift
controller.addUserScript(WKUserScript(
    source: Self.callbackJS,
    injectionTime: .atDocumentEnd,
    forMainFrameOnly: true
))
```

The existing `bridgeJS` registration remains unchanged below it.

- [ ] **Step 5: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 6: Commit**

```bash
git add Sources/DevDash/Views/ProductWebView.swift
git commit -m "feat: ProductWebView callback mechanism + onSearchItems/onCreateTask closures"
```

---

## Task 5: `[[` detection and autocomplete JS

**Files:**
- Modify: `Sources/DevDash/Views/ProductWebView.swift`

- [ ] **Step 1: Add `bracketLinkJS` constant**

Add this constant after `callbackJS` in `ProductWebView.swift`:

```swift
private static let bracketLinkJS = """
(function() {
  var dropdown = null;
  var pendingTextNode = null;
  var pendingOffset = -1;

  function escHtml(s) {
    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }
  function statusIcon(s) {
    if (s === 'done') return '✓';
    if (s === 'blocked') return '!';
    return '◯';
  }
  function typeIcon(t) {
    if (t === 'idea') return '💡';
    if (t === 'doc')  return '📄';
    return statusIcon('open');
  }

  function getQuery() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return null;
    var r = sel.getRangeAt(0);
    if (r.startContainer.nodeType !== Node.TEXT_NODE) return null;
    var text = r.startContainer.textContent.substring(0, r.startOffset);
    var idx = text.lastIndexOf('[[');
    if (idx === -1) return null;
    return { query: text.substring(idx + 2), offset: idx, textNode: r.startContainer, cursorOffset: r.startOffset };
  }

  function positionDropdown(dd) {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return;
    var rect = sel.getRangeAt(0).getBoundingClientRect();
    dd.style.top  = (rect.bottom + window.scrollY + 6) + 'px';
    dd.style.left = Math.max(8, rect.left + window.scrollX) + 'px';
  }

  function showDropdown(info) {
    hideDropdown();
    pendingTextNode = info.textNode;
    pendingOffset   = info.offset;

    dropdown = document.createElement('div');
    dropdown.style.cssText = [
      'position:absolute;z-index:99999;min-width:240px;max-height:220px;overflow-y:auto',
      'background:#1c1c22;border:1px solid rgba(255,255,255,0.14);border-radius:9px',
      'box-shadow:0 10px 40px rgba(0,0,0,0.7);padding:5px;font-family:inherit;font-size:12px'
    ].join(';');
    positionDropdown(dropdown);
    document.body.appendChild(dropdown);

    renderLoading();
    window.devdash && window.devdash.searchItems(info.query).then(function(results) {
      if (!dropdown) return;
      renderResults(results, info.query);
    });
  }

  function renderLoading() {
    if (!dropdown) return;
    dropdown.innerHTML = '<div style="padding:7px 10px;opacity:0.4;font-size:11px">Searching…</div>';
  }

  function renderResults(results, query) {
    if (!dropdown) return;
    dropdown.innerHTML = '';
    var trimmed = (query || '').trim();

    if (trimmed) {
      var cr = makeRow('+ Create task: ' + escHtml(trimmed), '#5ac8fa', true);
      cr.addEventListener('mousedown', function(e) {
        e.preventDefault();
        createAndInsert(trimmed);
      });
      dropdown.appendChild(cr);
    }

    (results || []).slice(0, 8).forEach(function(item) {
      var icon = item.type === 'task' ? statusIcon(item.status) : typeIcon(item.type);
      var row = makeRow(icon + ' ' + escHtml(item.title), null, false);
      row.addEventListener('mousedown', function(e) {
        e.preventDefault();
        insertChip(item);
      });
      dropdown.appendChild(row);
    });

    if (!trimmed && (!results || results.length === 0)) {
      dropdown.innerHTML = '<div style="padding:7px 10px;opacity:0.4;font-size:11px">Type to search or create…</div>';
    }
  }

  function makeRow(html, color, highlighted) {
    var d = document.createElement('div');
    d.style.cssText = 'padding:6px 10px;cursor:pointer;border-radius:6px;display:flex;align-items:center;gap:6px;' +
      (highlighted ? 'color:' + color + ';font-weight:500;' : 'color:inherit;') +
      (highlighted ? 'background:rgba(90,200,250,0.07);' : '');
    d.innerHTML = html;
    d.addEventListener('mouseenter', function() { d.style.background = 'rgba(255,255,255,0.06)'; });
    d.addEventListener('mouseleave', function() { d.style.background = highlighted ? 'rgba(90,200,250,0.07)' : ''; });
    return d;
  }

  function insertChip(item) {
    hideDropdown();
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || !pendingTextNode) return;
    var r = document.createRange();
    r.setStart(pendingTextNode, pendingOffset);
    r.setEnd(pendingTextNode, sel.getRangeAt(0).startOffset);
    r.deleteContents();

    var chip = buildChip(item.id, item.type, item.title, item.status || 'open');
    r.insertNode(chip);
    var after = document.createRange();
    after.setStartAfter(chip);
    sel.removeAllRanges();
    sel.addRange(after);

    var section = chip.closest('[data-section-file]');
    if (section) window.devdashMarkDirty && window.devdashMarkDirty(section);
    pendingTextNode = null;
  }

  function createAndInsert(title) {
    hideDropdown();
    var savedNode   = pendingTextNode;
    var savedOffset = pendingOffset;
    var linkedDocPath = window.location.pathname;
    window.devdash && window.devdash.createTask(title, linkedDocPath).then(function(task) {
      if (!task || !task.id) return;
      var sel = window.getSelection();
      if (!sel || sel.rangeCount === 0 || !savedNode) return;
      var r = document.createRange();
      r.setStart(savedNode, savedOffset);
      r.setEnd(savedNode, sel.getRangeAt(0).startOffset);
      r.deleteContents();

      var chip = buildChip(task.id, 'task', task.title, 'open');
      r.insertNode(chip);
      var after = document.createRange();
      after.setStartAfter(chip);
      sel.removeAllRanges();
      sel.addRange(after);

      var section = chip.closest('[data-section-file]');
      if (section) window.devdashMarkDirty && window.devdashMarkDirty(section);
    });
    pendingTextNode = null;
  }

  function buildChip(id, type, title, status) {
    var chip = document.createElement('span');
    chip.className = 'devdash-link-chip';
    chip.dataset.linkId   = id;
    chip.dataset.linkType = type;
    chip.contentEditable  = 'false';
    var icon = type === 'task' ? statusIcon(status) : typeIcon(type);
    chip.textContent = icon + ' ' + title;
    return chip;
  }

  function hideDropdown() {
    if (dropdown) { dropdown.remove(); dropdown = null; }
    pendingTextNode = null;
  }

  document.addEventListener('input', function(e) {
    if (!e.target.closest('[data-section-file]')) return;
    var info = getQuery();
    if (info) {
      showDropdown(info);
    } else {
      hideDropdown();
    }
  });

  document.addEventListener('keydown', function(e) {
    if (!dropdown) return;
    if (e.key === 'Escape') { hideDropdown(); e.preventDefault(); }
  });

  document.addEventListener('mousedown', function(e) {
    if (dropdown && !dropdown.contains(e.target)) hideDropdown();
  });

  // Chip styles
  if (!document.getElementById('devdash-chip-style')) {
    var s = document.createElement('style');
    s.id = 'devdash-chip-style';
    s.textContent = [
      '.devdash-link-chip{display:inline-flex;align-items:center;gap:4px',
      'background:rgba(90,200,250,0.1);border:1px solid rgba(90,200,250,0.3)',
      'padding:1px 7px;border-radius:4px;color:#5ac8fa;font-size:12px',
      'cursor:default;user-select:none;white-space:nowrap}',
      '.devdash-link-chip:hover{background:rgba(90,200,250,0.2)}'
    ].join(';');
    document.head.appendChild(s);
  }

  // Refresh chip status icons on load
  document.querySelectorAll('.devdash-link-chip[data-link-id]').forEach(function(chip) {
    window.devdash && window.devdash.getItemStatus(chip.dataset.linkId, chip.dataset.linkType).then(function(r) {
      if (!r || !r.status || chip.dataset.linkType !== 'task') return;
      var icon = statusIcon(r.status);
      var rest = chip.textContent.replace(/^[◯✓!]\s*/, '');
      chip.textContent = icon + ' ' + rest;
    });
  });
})();
"""
```

- [ ] **Step 2: Register `bracketLinkJS` in `makeNSView`**

After the `callbackJS` registration, add:

```swift
controller.addUserScript(WKUserScript(
    source: Self.bracketLinkJS,
    injectionTime: .atDocumentEnd,
    forMainFrameOnly: true
))
```

- [ ] **Step 3: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Views/ProductWebView.swift
git commit -m "feat: [[ bracket-link detection, autocomplete dropdown, link chip JS"
```

---

## Task 6: Bridge actions in `ProductTabView`

**Files:**
- Modify: `Sources/DevDash/Views/Tabs/ProductTabView.swift`

Wire `onSearchItems` and `onCreateTask` closures, and handle `promote-idea` in `handleAction`.

- [ ] **Step 1: Pass new closures to `ProductWebView` in `content(project:)`**

Inside the `if FileManager.default.fileExists(...)` block, replace the existing `ProductWebView(...)` call with:

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
    },
    onSearchItems: { [weak store] query in
        guard let store = store else { return [] }
        let tasks = store.tasksV2(for: project.path)
        let q = query.lowercased()
        return tasks
            .filter { q.isEmpty || $0.title.lowercased().contains(q) }
            .prefix(8)
            .map { t in
                ["id": t.id, "title": t.title, "type": "task", "status": t.status.rawValue]
            }
    },
    onCreateTask: { [weak store] title, linkedDocPath in
        guard let store = store else { return [:] }
        var created: TaskItem? = nil
        do {
            created = try TaskStore.add(
                projectPath: project.path,
                title: title,
                source: .local,
                linkedDocPath: linkedDocPath
            )
            store.projectTasks[project.path] = TaskStore.read(project.path)
            store.regenerateRoadmap(for: project.path)
        } catch {}
        guard let t = created else { return [:] }
        return ["id": t.id, "title": t.title, "status": t.status.rawValue]
    }
)
```

- [ ] **Step 2: Handle `promote-idea` in `handleAction`**

In the `switch action {` block, add after the existing cases and before `default:`:

```swift
case "promote-idea":
    if let title = payload["title"] as? String {
        store.addTask(projectPath: project.path, title: title)
    }
    // Visual update (mark promoted) is driven by JS on the calling side —
    // Swift doesn't need to write back to ideas.html.
```

- [ ] **Step 3: Track `activeDocPath` on URL change**

In `content(project:)`, after `let path = ProductDocGenerator.indexPath(for: project.path)`, add:

```swift
.onAppear {
    store.activeDocPath = path
}
.onChange(of: path) { _, newPath in
    store.activeDocPath = newPath
}
```

Add this modifier to the `ProductWebView(...)` call or wrap it in a `Group { ... }.onAppear { ... }`.

Actually, add these modifiers to the `ProductWebView(...)` call site:

```swift
ProductWebView(...) // existing call
    .onAppear { store.activeDocPath = path }
    .onChange(of: path) { _, p in store.activeDocPath = p }
```

- [ ] **Step 4: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Views/Tabs/ProductTabView.swift
git commit -m "feat: wire onSearchItems/onCreateTask bridge, promote-idea action, activeDocPath tracking"
```

---

## Task 7: `LinkedTasksSidebarView`

**Files:**
- Create: `Sources/DevDash/Views/LinkedTasksSidebarView.swift`
- Modify: `Sources/DevDash/Views/Tabs/ProductTabView.swift`

- [ ] **Step 1: Create `LinkedTasksSidebarView.swift`**

```swift
import SwiftUI

struct LinkedTasksSidebarView: View {
    @EnvironmentObject var store: DashboardStore
    let projectPath: String
    let docPath: String

    private var linkedTasks: [TaskItem] {
        store.tasksV2(for: projectPath).filter { $0.linkedDocPath == docPath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if linkedTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
            Divider()
            addButton
        }
        .frame(width: 180)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            Text("Linked tasks")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(linkedTasks.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        Text("No linked tasks")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding()
    }

    private var taskList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(linkedTasks) { task in
                    taskRow(task)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        Button {
            store.openTaskId = task.id
            store.openTaskProjectPath = projectPath
        } label: {
            HStack(spacing: 6) {
                statusDot(task.status)
                Text(task.title)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .strikethrough(task.status == .done, color: .secondary)
                    .foregroundStyle(task.status == .done ? .tertiary : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusDot(_ status: TaskStatus) -> some View {
        switch status {
        case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 10))
        case .blocked: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.system(size: 10))
        default:       Image(systemName: "circle").foregroundStyle(.blue).font(.system(size: 10))
        }
    }

    private var addButton: some View {
        Button {
            store.addTask(projectPath: projectPath, title: "Untitled task", linkedDocPath: docPath)
        } label: {
            Label("Add task", systemImage: "plus")
                .font(.system(size: 11))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Add sidebar toggle and layout to `ProductTabView`**

Add a `@State` property at the top of `ProductTabView`:

```swift
@State private var showLinkedSidebar: Bool = false
```

In `content(project:)`, wrap the existing `ProductWebView` + progress view in an `HStack`:

```swift
private func content(project: Project) -> some View {
    let path = ProductDocGenerator.indexPath(for: project.path)
    let docsRoot = URL(fileURLWithPath: ProductDocGenerator.folderPath(for: project.path))
    return HStack(spacing: 0) {
        Group {
            if FileManager.default.fileExists(atPath: path) {
                ProductWebView(
                    url: URL(fileURLWithPath: path),
                    docsRoot: docsRoot,
                    reloadToken: reloadToken,
                    onSave: { rel, html in saveSection(projectPath: project.path, rel: rel, html: html) },
                    onSaveAlpine: { rel, state in saveAlpineSection(projectPath: project.path, rel: rel, state: state) },
                    onAction: { payload in handleAction(project: project, payload: payload) },
                    onSearchItems: { [weak store] query in
                        guard let store = store else { return [] }
                        let tasks = store.tasksV2(for: project.path)
                        let q = query.lowercased()
                        return tasks
                            .filter { q.isEmpty || $0.title.lowercased().contains(q) }
                            .prefix(8)
                            .map { t in ["id": t.id, "title": t.title, "type": "task", "status": t.status.rawValue] }
                    },
                    onCreateTask: { [weak store] title, linkedDocPath in
                        guard let store = store else { return [:] }
                        var created: TaskItem? = nil
                        do {
                            created = try TaskStore.add(projectPath: project.path, title: title, source: .local, linkedDocPath: linkedDocPath)
                            store.projectTasks[project.path] = TaskStore.read(project.path)
                            store.regenerateRoadmap(for: project.path)
                        } catch {}
                        guard let t = created else { return [:] }
                        return ["id": t.id, "title": t.title, "status": t.status.rawValue]
                    }
                )
                .onAppear { store.activeDocPath = path }
                .onChange(of: path) { _, p in store.activeDocPath = p }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Generating…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if showLinkedSidebar {
            Divider()
            LinkedTasksSidebarView(
                projectPath: project.path,
                docPath: store.activeDocPath ?? path
            )
            .environmentObject(store)
        }
    }
}
```

- [ ] **Step 3: Add sidebar toggle button to toolbar**

In `toolbar(project:)`, before the final closing of the `HStack`, add the toggle button after the existing buttons:

```swift
Button {
    withAnimation(.easeInOut(duration: 0.18)) {
        showLinkedSidebar.toggle()
    }
} label: {
    Image(systemName: showLinkedSidebar ? "sidebar.right" : "sidebar.right")
        .symbolVariant(showLinkedSidebar ? .fill : .none)
}
.buttonStyle(.borderless)
.help(showLinkedSidebar ? "Hide linked tasks" : "Show linked tasks")
```

- [ ] **Step 4: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Views/LinkedTasksSidebarView.swift Sources/DevDash/Views/Tabs/ProductTabView.swift
git commit -m "feat: LinkedTasksSidebarView + toggle in ProductTabView"
```

---

## Task 8: `⌘K` Command Bar

**Files:**
- Create: `Sources/DevDash/Views/CommandBarView.swift`
- Modify: `Sources/DevDash/DevDashApp.swift` (or wherever the main `WindowGroup` lives — find with `grep -rn "WindowGroup\|@main" Sources/`)

- [ ] **Step 1: Find the app entry point**

```bash
grep -rn "@main\|WindowGroup" /Users/suki/dev/dev-dash/Sources/DevDash/ | head -10
```

- [ ] **Step 2: Create `CommandBarView.swift`**

```swift
import SwiftUI

struct CommandBarView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var query: String = ""
    @State private var selectedProjectPath: String = ""
    @FocusState private var isFocused: Bool

    private var projectPath: String {
        selectedProjectPath.isEmpty ? (store.selection ?? "") : selectedProjectPath
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.01)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                searchField
                if !query.isEmpty {
                    Divider()
                    actionList
                }
            }
            .frame(width: 400)
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .padding(.top, 100)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { isFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Create a task, idea, or search…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onSubmit { createTask() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var actionList: some View {
        VStack(spacing: 2) {
            actionRow(icon: "plus.circle.fill", color: .blue,
                      label: "Create task: \(query)") { createTask() }
            actionRow(icon: "lightbulb.fill", color: .yellow,
                      label: "Capture idea: \(query)") { captureIdea() }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private func actionRow(icon: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
                Text("↵")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.0001))
    }

    private func createTask() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard !projectPath.isEmpty else { dismiss(); return }
        store.addTask(
            projectPath: projectPath,
            title: query,
            linkedDocPath: store.activeDocPath
        )
        dismiss()
    }

    private func captureIdea() {
        // Ideas are stored in ideas.html as free-text; for now, create as a task with category .other
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard !projectPath.isEmpty else { dismiss(); return }
        store.addTask(projectPath: projectPath, title: query, category: .other)
        dismiss()
    }

    private func dismiss() {
        query = ""
        store.isCommandBarVisible = false
    }
}
```

- [ ] **Step 3: Register `⌘K` shortcut and overlay in the app entry point**

Find the file from Step 1. In the `WindowGroup` body (or the root content view), add the command bar overlay. In the root `ContentView` or the main view that wraps everything, wrap the existing body in a `ZStack`:

```swift
.overlay {
    if store.isCommandBarVisible {
        CommandBarView()
            .environmentObject(store)
    }
}
.onKeyPress(.init("k"), phases: .down) { press in
    if press.modifiers.contains(.command) {
        store.isCommandBarVisible.toggle()
        return .handled
    }
    return .ignored
}
```

If `.onKeyPress` is unavailable (requires macOS 14), use a keyboard shortcut via `.commands { }` or add it to the toolbar as a hidden button:

```swift
// Fallback for macOS 13:
Button("") { store.isCommandBarVisible.toggle() }
    .keyboardShortcut("k", modifiers: .command)
    .frame(width: 0, height: 0)
    .opacity(0)
```

- [ ] **Step 4: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDash/Views/CommandBarView.swift
git commit -m "feat: ⌘K CommandBarView — floating task/idea capture bar"
```

---

## Task 9: Backlinks in `TaskDetailSheet`

**Files:**
- Modify: `Sources/DevDash/Views/TaskDetailSheet.swift`

- [ ] **Step 1: Find the bottom of the detail body**

```bash
grep -n "Section\|VStack\|Divider\|body\|notes\|category\|metadataRow" /Users/suki/dev/dev-dash/Sources/DevDash/Views/TaskDetailSheet.swift | tail -30
```

- [ ] **Step 2: Add backlinks section**

Find the section that renders the task's metadata (notes, category, status, etc.) near the bottom of the scroll view body. After the last metadata section, add:

```swift
if let docPath = task.linkedDocPath {
    Divider().padding(.vertical, 4)
    VStack(alignment: .leading, spacing: 6) {
        Text("REFERENCED IN")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
        Button {
            store.pendingFilePath = docPath
            store.detailTab = .files
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.purple)
                    .font(.system(size: 12))
                Text(URL(fileURLWithPath: docPath).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.purple)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
    .padding(.horizontal)
}
```

The `task` variable is the `TaskItem` being displayed — check the sheet's variable name with the grep above and adjust if needed (it may be `item`, `task`, or `selectedTask`).

- [ ] **Step 3: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Views/TaskDetailSheet.swift
git commit -m "feat: backlinks 'Referenced in' panel in TaskDetailSheet"
```

---

## Task 10: Ideas board → task (HTML + bridge)

**Files:**
- Modify: `Sources/DevDash/Scanners/ProductDocGenerator.swift` (ideas scaffold template)
- Modify: `Sources/DevDash/Views/Tabs/ProductTabView.swift` (already done in Task 6)

- [ ] **Step 1: Find the ideas HTML scaffold**

```bash
grep -n "ideas\|idea" /Users/suki/dev/dev-dash/Sources/DevDash/Scanners/ProductDocGenerator.swift | head -20
```

- [ ] **Step 2: Check what the ideas scaffold looks like**

```bash
grep -n -A 5 "ideas" /Users/suki/dev/dev-dash/Sources/DevDash/Scanners/ProductDocGenerator.swift | head -40
```

The ideas section lives at `docs/devdash/sections/ideas.html`. It's a user-authored file that is scaffolded once. Add `data-action="promote-idea"` buttons to the scaffold template for new projects.

Find the string constant that produces the `ideas.html` scaffold. Add a sample card with a promote button:

```html
<div class="card idea-card" id="idea-example">
  <div style="display:flex;align-items:flex-start;gap:10px">
    <span style="font-size:18px">💡</span>
    <div style="flex:1">
      <div style="font-weight:600;margin-bottom:4px">Your idea title here</div>
      <div style="opacity:0.6;font-size:13px">Description of the idea.</div>
    </div>
    <button data-action="promote-idea"
            data-title="Your idea title here"
            data-idea-id="idea-example"
            style="font-size:11px;padding:3px 8px;border-radius:4px;border:1px solid rgba(90,200,250,0.4);
                   background:rgba(90,200,250,0.1);color:#5ac8fa;cursor:pointer;white-space:nowrap">
      → task
    </button>
  </div>
</div>
```

The `data-action="promote-idea"` attribute is caught by the existing `[data-action]` click handler in `bridgeJS`, which posts the payload to Swift. Swift's `handleAction` (already updated in Task 6) creates the task.

For the visual "promoted" badge update: after `promote-idea` is handled, Swift should call `evaluateJavaScript` to mark the card. Add to `handleAction` in `ProductTabView`:

```swift
case "promote-idea":
    if let title = payload["title"] as? String {
        store.addTask(projectPath: project.path, title: title)
    }
    if let ideaId = payload["ideaId"] as? String {
        // Visual update handled by JS — the button's own click handler in ideas.html
        // can add a "promoted" class. The data-action bridge fires on the button click
        // so the button click itself is the confirmation.
        // Optionally, evaluate JS to strike through the card:
        _ = ideaId  // used by JS side; Swift doesn't need to update DOM
    }
```

Note: because `data-action` buttons already get their click's default prevented in `bridgeJS`, add an inline `onclick` to the promote button in the ideas.html scaffold to update its own visual state before posting to the bridge:

```html
<button data-action="promote-idea"
        data-title="Your idea title here"
        data-idea-id="idea-example"
        onclick="this.textContent='✓ promoted';this.style.opacity='0.4';this.disabled=true;this.closest('.idea-card').style.opacity='0.5';"
        ...>
  → task
</button>
```

- [ ] **Step 3: Verify build**

```bash
cd /Users/suki/dev/dev-dash && swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 4: Commit**

```bash
git add Sources/DevDash/Scanners/ProductDocGenerator.swift Sources/DevDash/Views/Tabs/ProductTabView.swift
git commit -m "feat: ideas board → task promotion via data-action bridge"
```

---

---

> **Deferred:** PRD → task batch (Claude-assisted) from the spec is not in this plan. It requires reading arbitrary HTML, calling `claude -p` (like `suggestTasksForStage`), and showing a review/approval sheet — a separate task after the core linking system is working.

---

## Final: Smoke Test

- [ ] Build and run: `swift build && open .build/debug/DevDash.app`
- [ ] Open a project's Living Document tab
- [ ] Type `[[` in a contenteditable section — dropdown appears
- [ ] Type a few letters — results filter
- [ ] Select a result — link chip appears inline
- [ ] Press Enter on a new name — task is created, chip appears
- [ ] Press `⌘K` from anywhere — command bar floats over the app
- [ ] Type a task name, press Enter — task appears in the project's task list
- [ ] Toggle the sidebar — linked tasks panel slides in/out
- [ ] Click a task in the sidebar — `TaskDetailSheet` opens with "Referenced in" backlink
- [ ] Promote an idea card — button changes to "✓ promoted", task appears in backlog
