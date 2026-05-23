# Bracket Linking & Fluid Capture — Design Spec

**Date:** 2026-05-23  
**Status:** Approved

## Overview

Add Roam/Tana-style `[[double bracket]]` linking and a `⌘K` global capture bar to DevDash. The goal is a calm, fluid writing experience where tasks, ideas, and docs can be created or linked without leaving the current context. Everything is bidirectional: tasks remember the doc they came from, and docs show their linked tasks in a live sidebar.

---

## Capture Surfaces

### 1. `[[` inline linking (in doc editor)

When the user types `[[` anywhere in a contenteditable section of a product doc, a small autocomplete dropdown appears beneath the cursor. As the user types, it filters across:

- Existing tasks (showing status icon: ◯ open, ✓ done, ! blocked)
- Existing ideas (from the Ideas board)
- Other product docs

Selecting an existing item creates a **link chip** inline — a styled span with `data-link-id` and `data-link-type` attributes. The chip renders the item's live status on load via a JS bridge call.

Pressing Enter on a new (unmatched) name prompts: **Create as Task**, **Create as Idea**, or **Create as Doc**. Selecting "Task" calls the Swift bridge, creates the task with `linkedDocPath` set to the current doc, and inserts the link chip.

Doc sections save on blur. Link chips are stored as HTML with `data-link-id` attributes so they survive serialization.

The `[[` detection JS is added as a new string constant in `ProductWebView.swift` alongside the existing `bridgeJS` and injected at document-end via the same `WKUserScript` mechanism.

### 2. `⌘K` global command bar

Available from anywhere in the app. A floating SwiftUI overlay (not a sheet — appears without stealing focus from the current view). The user types to:

- Create a task, idea, or doc
- Search existing items

Context-aware: if the active view is a product doc, new tasks created via `⌘K` automatically receive `linkedDocPath` pointing to that doc. If no doc is active, `linkedDocPath` is nil.

The bar is dismissed with Escape or by clicking outside.

---

## Links — Bidirectional

### Model change

`TaskItem` gets one new optional field:

```swift
var linkedDocPath: String?  // absolute path to the source HTML file, e.g. "/Users/x/myproject/docs/devdash/prd/api-v2.html"
```

Absolute path, consistent with how the rest of the app stores `projectPath`.

Migration: existing tasks get `linkedDocPath = nil`. TaskStore serialization already uses `Codable` with default decoding, so old files load cleanly.

### Task detail — backlinks panel

`TaskDetailSheet` gets a "Referenced in" section at the bottom when `linkedDocPath != nil`. It shows the doc name as a tappable link (opens the product doc to that file). No free-text search — the path is stored directly.

### Doc sidebar — live task list

A collapsible `LinkedTasksSidebarView` (SwiftUI) sits beside `ProductWebView`. Hidden by default — a small chevron toggle at the top-right of the doc viewer reveals it. Width: ~180pt.

Shows all tasks where `linkedDocPath` matches the currently-open doc's path. Updates reactively via `DashboardStore.projectTasks`. Each row:
- Status icon + title
- Tap → opens `TaskDetailSheet`
- "+ Add" at the bottom → creates a new task linked to this doc

No regeneration needed. This is pure SwiftUI reading from `DashboardStore`, not HTML.

---

## Entry Points

### Ideas board → task

The Ideas section is an HTML file (`docs/devdash/sections/ideas.html`) rendered in WKWebView. Each idea card gets a "→ task" button in HTML. Clicking it posts a `promote-idea` action through the existing `onAction` bridge (same pattern as `open-file`, `open-task`). The handler in `ProductTabView.handleAction` creates the task and posts back a JS response to update the card's visual state (strike-through + "→ task" badge). No `ideas.html` regeneration needed — the visual update is JS-driven in-place.

Action payload:
```json
{ "action": "promote-idea", "title": "Cache layer for rate limits", "ideaId": "idea-123" }
```

Response: Swift calls `evaluateJavaScript` to mark the card promoted.

### PRD → task batch (Claude-assisted)

The product doc viewer gets a "Generate tasks from doc" button (shown when the active tab is a PRD-type doc). Tapping it:

1. Reads the current doc HTML
2. Calls the existing Claude suggestion mechanism (same pattern as `suggestTasksForStage`)
3. Shows a review sheet with suggested tasks — user can deselect before confirming
4. Confirmed tasks are created with `linkedDocPath` set to the PRD

---

## JS ↔ Swift Bridge

The existing `ProductWebView` already has a `WKScriptMessageHandler` setup. New message types:

| Message | Payload | Action |
|---|---|---|
| `createTask` | `{title, linkedDocPath}` | Creates task, returns `{id, title, status}` |
| `searchItems` | `{query}` | Returns matching tasks + ideas + docs as JSON |
| `getItemStatus` | `{id, type}` | Returns current status for a link chip |

Swift injects a `devdash` JS object on page load with methods that post these messages and resolve promises. The autocomplete dropdown and link chips use these methods.

---

## Calm UI Principles

- The `[[` dropdown appears only when triggered — no persistent UI chrome
- The sidebar is hidden by default; one click shows it
- `⌘K` is an overlay, not a modal — background content stays visible
- Link chips are visually subtle (thin border, muted background) until hovered
- No notifications or badges introduced by this feature

---

## What Ships

| Component | File(s) |
|---|---|
| `TaskItem.linkedDocPath` field + migration | `Models.swift`, `TaskStore.swift` |
| `[[` detection + autocomplete JS | `ProductWebView.swift` (new string constant alongside `bridgeJS`) |
| Link chip renderer + status updater JS | same |
| New bridge action handlers (`create-task`, `search-items`, `promote-idea`) | `ProductTabView.swift` (`handleAction`) |
| `⌘K` overlay view | `CommandBarView.swift` (new), registered as `.keyboardShortcut("k", modifiers: .command)` |
| Collapsible `LinkedTasksSidebarView` | `LinkedTasksSidebarView.swift` (new) |
| Updated `ProductTabView` layout (sidebar) | `ProductTabView.swift` |
| Backlinks section in task detail | `TaskDetailSheet.swift` |
| Ideas "→ task" button + bridge action | `docs/devdash/sections/ideas.html` template + `ProductTabView.swift` |
| PRD "Generate tasks" button + review sheet | `ProductTabView.swift` + `TaskSuggestionsSheet.swift` (new) |

---

## Out of Scope

- Graph view (visual link map)
- `[[` linking outside of product docs (e.g., in task notes)
- Full Roam-style block references
- Real-time collaborative editing
