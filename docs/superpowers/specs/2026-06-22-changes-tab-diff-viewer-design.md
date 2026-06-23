# Changes tab — git diff viewer (replaces Files tab)

**Date:** 2026-06-22
**Status:** Approved (design), pending implementation
**Inspiration:** [kyle-ssg/kyde](https://github.com/kyle-ssg/kyde) — native GPU commit/diff editor

## Goal

Replace the existing **Files** tab with a **Changes** tab: a git diff viewer modeled
on kyde's commit view. It shows uncommitted working-tree changes (with per-file
stage/revert) *and* commit history, and renders the selected file as a **side-by-side
diff** with syntax highlighting and word-level intra-line highlighting.

## Scope (decided)

- **Per-file** stage / unstage / revert. **No per-hunk** staging.
- **Side-by-side** layout (not unified). The kyde look.
- File list split into **Staged / Unstaged** groups (standard git-GUI model).
- **Commit history** list below the working-changes groups; selecting a commit
  shows its changed files and their diffs.
- **No commit message box / commit / push** in v1 — viewing only for history;
  staging is supported but committing stays in the existing Info tab for now.

### Out of scope (v1)

- Per-hunk staging, commit authoring/push, branch switching, search, terminal,
  two independently-scrolling panes with per-side horizontal scroll.

## Architecture

### Rendering approach (decided)

**Single aligned-row list**, not two synced NSTextViews. One
`ScrollView { LazyVStack }` where each row is `HStack[ leftCell | gutter | rightCell ]`.
The diff parser pre-aligns rows (added rows have an empty left cell; removed rows an
empty right cell), so row alignment is free, there is one shared vertical scroll, and
`LazyVStack` gives viewport virtualization out of the box (handles 30k+ line files).

### Diff computation (decided)

**Parse git's unified-diff output; add word-level highlighting ourselves.** Git already
computes a fast, correct line-level diff. We shell out via `ShellRunner`, parse the
unified hunks into aligned rows, and run a small token-level diff only on *paired*
removed/added lines within a hunk to produce word-level highlight spans. We do not
re-implement a line-diff engine.

### Components (new files)

| File | Purpose |
|---|---|
| `Sources/DevDash/Models/DiffModels.swift` | `ChangedFile`, `GitCommit`, `FileDiffSource` enum (`.unstaged` / `.staged` / `.commit(sha)`), `DiffRow`, `WordSpan`, `FileDiff`. |
| `Sources/DevDash/Scanners/GitDiffScanner.swift` | All git reads/writes for the tab (reuses `ShellRunner`). |
| `Sources/DevDash/Scanners/UnifiedDiffParser.swift` | Pure function: unified-diff text → `[DiffRow]` with word-level `WordSpan`s. No UI/IO. **Unit-tested.** |
| `Sources/DevDash/Views/Tabs/ChangesTabView.swift` | Top-level tab: sidebar (changed files + history) ‖ diff pane. |
| `Sources/DevDash/Views/SideBySideDiffView.swift` | The aligned-row renderer. Reuses `SyntaxHighlighter`; overlays word-spans via `AttributedString`. |

`FilesTabView.swift` and its file-tree helpers are removed.

### GitDiffScanner API

```swift
enum GitDiffScanner {
    static func changedFiles(path: String) async -> [ChangedFile]      // git status --porcelain=v1 -z
    static func commits(path: String, limit: Int) async -> [GitCommit] // git log --pretty
    static func commitFiles(path: String, sha: String) async -> [ChangedFile] // git show --name-status
    static func fileDiff(path: String, file: String, source: FileDiffSource) async -> String?
    // mutations (reuse GitStatusScanner.op):
    static func stage(path: String, file: String) async -> Bool        // git add -- <file>
    static func unstage(path: String, file: String) async -> Bool      // git reset HEAD -- <file>
    static func revert(path: String, file: String) async -> Bool       // git checkout -- <file> (or clean for untracked)
}
```

`fileDiff` chooses the git command by source:
- `.unstaged` → `git diff -- <file>`
- `.staged` → `git diff --cached -- <file>`
- `.commit(sha)` → `git show <sha> -- <file>` (commit vs its parent)

### Data model

```swift
struct ChangedFile: Identifiable, Hashable {
    let path: String           // repo-relative
    let stagedStatus: Char?    // X column, nil if unmodified in index
    let unstagedStatus: Char?  // Y column, nil if unmodified in worktree
    let isUntracked: Bool
    var id: String { path }
}
struct GitCommit: Identifiable, Hashable {
    let sha: String; let shortSha: String
    let subject: String; let author: String; let relativeDate: String
    var id: String { sha }
}
enum FileDiffSource: Hashable { case unstaged, staged, commit(String) }
enum DiffRowKind { case context, added, removed, hunkHeader, meta }
struct WordSpan { let range: Range<String.Index>; }   // intra-line changed span
struct DiffRow {
    let kind: DiffRowKind
    let leftLineNo: Int?;  let leftText: String?
    let rightLineNo: Int?; let rightText: String?
    let leftSpans: [WordSpan]; let rightSpans: [WordSpan]
}
struct FileDiff { let rows: [DiffRow]; let isBinary: Bool; let tooLarge: Bool }
```

## UI / data flow

```
┌ Changes tab ─────────────────────────────────────────────┐
│ Sidebar                          │  SideBySideDiffView     │
│ ▾ Unstaged (n)   [stage] [↩]     │   base   │  working     │
│    M Foo.swift                   │  ─ line  │  + line       │
│    ? new.swift                   │   ctx    │   ctx (wordhl)│
│ ▾ Staged (n)     [unstage]       │          │              │
│    M Bar.swift                   │          │              │
│ ─────────────                    │          │              │
│ ▾ History                        │          │              │
│    abc123 fix watcher    2h      │          │              │
└──────────────────────────────────────────────────────────┘
```

- Select unstaged/staged file → `fileDiff(source:)` → `UnifiedDiffParser` → `SideBySideDiffView`.
- Select a commit → expands its `commitFiles`; selecting a file → `git show sha -- file` diff.
- Stage / unstage / revert are per-file (row hover buttons + group-level button).
  After any mutation, re-run `changedFiles()`. Revert is destructive → confirmation alert.
- Refresh: on tab appear, on selected-project change, and after mutations.

## Reuse & edge cases

- **Syntax highlight:** reuse `SyntaxHighlighter.tokenize` (extension → `Language`). Per-line
  tokens → base `AttributedString`; word-spans layer a background color (success/danger tint).
- **Untracked files:** appear in Unstaged; whole file shown as added (right side only).
- **Binary / image / >1MB:** skip side-by-side; show a placeholder
  (`binary file` / image thumbnail / `diff too large — N lines`).
- **Empty state:** clean tree → "No changes"; history still browsable.
- **No-newline-at-EOF** (`\ No newline at end of file`) handled by the parser (not a row).

## Tab wiring

- `DetailTab` enum (`Models.swift`): rename case `files` → `changes`; `label` "Changes";
  `systemImage` `arrow.triangle.branch`.
- `DetailPaneView.swift` switch: `case .changes: ChangesTabView()`.
- Remove `FilesTabView()` reference and the file.
- `store.pendingFilePath` consumers (TasksTabView, TaskDetailSheet, ProductTabView,
  VisualDiffSheet) currently route a file into the Files tab. Decide per-call: keep
  `pendingFilePath` working by having `ChangesTabView` ignore it (it's a diff view, not a
  file opener) — those callers fall back gracefully (no-op) or open externally. **v1: the
  Changes tab does not consume `pendingFilePath`;** existing callers keep their other
  behaviors. (Revisit if a "reveal file" affordance is wanted.)

## Theme tokens

- Added: `DSColor.success` fg + `.success.opacity(0.12)` bg; word-span `.success.opacity(0.30)`.
- Removed: red fg (`Color(red:1,green:0.35,blue:0.35)`) + `DSColor.danger.opacity(0.12)` bg;
  word-span `.danger.opacity(0.30)`.
- Hunk header: `.accentColor`. Line numbers: `.secondary`, `DSFont.monoDigits`.
- Code: `DSFont.mono(.caption)`.

## Testing

- `UnifiedDiffParser` unit tests (new SwiftPM test target `DevDashTests`):
  added-only, removed-only, modified-with-word-spans, multi-hunk, no-newline-at-EOF,
  context-only, empty diff, untracked/new-file. Pure function → fast headless tests.
- Build signal: `swift build`. (GUI/IO layers verified by build only — accepted risk.)

## Build phases (for phased-autonomous-build)

1. **Models + parser (+ tests).** `DiffModels.swift`, `UnifiedDiffParser.swift`, test target.
   Gate: `swift build` + `swift test`.
2. **Scanner.** `GitDiffScanner.swift` (reads + mutations). Gate: `swift build`.
3. **Renderer.** `SideBySideDiffView.swift` (aligned rows, syntax + word highlight, edge cases).
   Gate: `swift build`.
4. **Tab assembly + wiring.** `ChangesTabView.swift`, `DetailTab` rename, `DetailPaneView`
   switch, remove `FilesTabView`. Gate: `swift build`.
