# Changes Tab — Git Diff Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan is also structured for `phased-autonomous-build`: the four Phases map to four Workflow runs.

**Goal:** Replace the Files tab with a "Changes" tab — a kyde-style git diff viewer showing working-tree changes (per-file stage/revert) and commit history, rendering selected files as a side-by-side diff with syntax + word-level highlighting.

**Architecture:** Pure diff parsing logic lives in a new `DevDashCore` library target (unit-tested via `swift test`). A `GitDiffScanner` (in the app target) shells out via `ShellRunner`/`GitStatusScanner.op` for git reads/mutations. `UnifiedDiffParser` turns git's unified-diff text into pre-aligned `DiffRow`s. `SideBySideDiffView` renders rows in a single virtualized `LazyVStack` (left/right cells), reusing `SyntaxHighlighter`. `ChangesTabView` assembles the sidebar (Staged/Unstaged/History) and diff pane.

**Tech Stack:** Swift 5.9+/SwiftUI, macOS 14+, SwiftPM. No new external deps. Reuses `ShellRunner`, `GitStatusScanner`, `SyntaxHighlighter`, design tokens in `DesignSystem.swift`.

## Global Constraints

- macOS 14+, SwiftUI + AppKit only; no new external Swift packages.
- All subprocesses go through `ShellRunner.run` or `GitStatusScanner.op` — never spawn `Process` directly in views.
- Use design tokens (`DSColor`, `DSFont`, `DSSpace`, `DSRadius`) — no inline `.font(.system(size:))` or magic colors except the existing removed-red `Color(red: 1, green: 0.35, blue: 0.35)`.
- Git binary path: `/usr/bin/git`. Pass `-c core.quotepath=false` as a *pre-subcommand* global option where paths are read.
- Commit directly to main (project convention). Commit messages: imperative mood, concise.
- Verification signal: `swift build` for all phases; `swift test` additionally for Phase 1. SourceKit "cannot find X in scope" is stale-index noise — trust `swift build`.
- After Phase 4, run `lore reindex devlog` is NOT required here; a devlog is written at the very end via `/devlog`.

---

## Phase 1 — Core models + parser + test target

Creates the `DevDashCore` library, the diff data model, the pure `UnifiedDiffParser`, and a `DevDashCoreTests` target. This is the only phase with behavioral tests.

### Task 1.1: Add DevDashCore library target + test target to Package.swift

**Files:**
- Modify: `Package.swift`
- Create (empty placeholder so the target compiles): `Sources/DevDashCore/.gitkeep` is NOT enough — SwiftPM needs a source file. Task 1.2 creates the first real source; do Task 1.1 and 1.2 together before building.

**Interfaces:**
- Produces: a library target `DevDashCore` that the app target and tests depend on.

- [ ] **Step 1: Edit Package.swift to add the library + test targets and wire the app dependency**

Replace the `targets:` array in `Package.swift` with:

```swift
    targets: [
        .target(
            name: "DevDashCore",
            path: "Sources/DevDashCore"
        ),
        .executableTarget(
            name: "DevDash",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "DevDashCore"
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
        ),
        .testTarget(
            name: "DevDashCoreTests",
            dependencies: ["DevDashCore"],
            path: "Tests/DevDashCoreTests"
        )
    ]
```

(Do not build yet — `DevDashCore` has no sources until Task 1.2.)

### Task 1.2: Diff data model (DevDashCore)

**Files:**
- Create: `Sources/DevDashCore/DiffCoreModels.swift`

**Interfaces:**
- Produces (all `public`): `DiffRowKind`, `WordSpan`, `DiffRow`, `FileDiff`. These are the parser's output types consumed by `UnifiedDiffParser` (Task 1.3) and `SideBySideDiffView` (Phase 3).

- [ ] **Step 1: Create the model file**

```swift
import Foundation

public enum DiffRowKind: Equatable {
    case hunkHeader
    case context
    case added
    case removed
    case modified   // a removed line paired with an added line on one visual row
}

/// A changed character range within a single diff line, expressed as Character offsets.
public struct WordSpan: Equatable {
    public let start: Int
    public let length: Int
    public init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
}

/// One visual row of a side-by-side diff. `left*` is the base side, `right*` the new side.
public struct DiffRow: Equatable {
    public let kind: DiffRowKind
    public let leftLineNo: Int?
    public let leftText: String?
    public let rightLineNo: Int?
    public let rightText: String?
    public let leftSpans: [WordSpan]
    public let rightSpans: [WordSpan]
    public let headerText: String?   // only for .hunkHeader

    public init(kind: DiffRowKind,
                leftLineNo: Int? = nil, leftText: String? = nil,
                rightLineNo: Int? = nil, rightText: String? = nil,
                leftSpans: [WordSpan] = [], rightSpans: [WordSpan] = [],
                headerText: String? = nil) {
        self.kind = kind
        self.leftLineNo = leftLineNo
        self.leftText = leftText
        self.rightLineNo = rightLineNo
        self.rightText = rightText
        self.leftSpans = leftSpans
        self.rightSpans = rightSpans
        self.headerText = headerText
    }
}

public struct FileDiff: Equatable {
    public let rows: [DiffRow]
    public let isBinary: Bool
    public let tooLarge: Bool
    public init(rows: [DiffRow], isBinary: Bool = false, tooLarge: Bool = false) {
        self.rows = rows
        self.isBinary = isBinary
        self.tooLarge = tooLarge
    }
}
```

- [ ] **Step 2: Build to confirm the targets compile**

Run: `swift build`
Expected: Build succeeds (DevDashCore now has a source file).

- [ ] **Step 3: Commit**

```bash
git add Package.swift Sources/DevDashCore/DiffCoreModels.swift
git commit -m "core: add DevDashCore target + diff data model"
```

### Task 1.3: UnifiedDiffParser (DevDashCore) — TDD

**Files:**
- Create: `Sources/DevDashCore/UnifiedDiffParser.swift`
- Test: `Tests/DevDashCoreTests/UnifiedDiffParserTests.swift`

**Interfaces:**
- Consumes: `DiffRow`, `WordSpan`, `FileDiff`, `DiffRowKind` (Task 1.2).
- Produces: `public enum UnifiedDiffParser { public static func parse(_ diffText: String) -> FileDiff }`.

**Parsing contract:**
- Ignore everything until the first `@@` hunk header (skips `git show` commit metadata, `diff --git`, `index`, `---`, `+++`).
- `@@ -l,s +r,s @@` sets left/right starting line numbers; emits a `.hunkHeader` row carrying the raw header text.
- ` ` prefix → `.context` (both sides, same text). `-` → buffered removed. `+` → buffered added.
- A run of removed then added lines is flushed: index-paired lines become `.modified` rows with word spans (char-level common-prefix/suffix); unpaired extras become `.removed`/`.added`.
- Lines starting with `\` (`\ No newline at end of file`) are skipped. Empty strings (split artifacts / blank lines outside content) are skipped — blank *context* lines arrive as `" "` and are handled by the context branch.
- `Binary files ... differ` → `FileDiff(rows: [], isBinary: true)`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import DevDashCore

final class UnifiedDiffParserTests: XCTestCase {

    func test_emptyInput_producesNoRows() {
        let d = UnifiedDiffParser.parse("")
        XCTAssertTrue(d.rows.isEmpty)
        XCTAssertFalse(d.isBinary)
    }

    func test_binaryDiff_isDetected() {
        let text = "diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n"
        let d = UnifiedDiffParser.parse(text)
        XCTAssertTrue(d.isBinary)
        XCTAssertTrue(d.rows.isEmpty)
    }

    func test_addedOnly_newFile() {
        let text = """
        diff --git a/f b/f
        new file mode 100644
        index 0000000..0cfbf08
        --- /dev/null
        +++ b/f
        @@ -0,0 +1,2 @@
        +hello
        +world
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body[0].kind, .added)
        XCTAssertNil(body[0].leftLineNo)
        XCTAssertEqual(body[0].rightLineNo, 1)
        XCTAssertEqual(body[0].rightText, "hello")
        XCTAssertEqual(body[1].rightLineNo, 2)
        XCTAssertEqual(body[1].rightText, "world")
    }

    func test_removedOnly() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +0,0 @@
        -foo
        -bar
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body[0].kind, .removed)
        XCTAssertEqual(body[0].leftLineNo, 1)
        XCTAssertEqual(body[0].leftText, "foo")
        XCTAssertNil(body[0].rightLineNo)
        XCTAssertEqual(body[1].leftLineNo, 2)
    }

    func test_modified_pairsLinesWithWordSpans() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,1 +1,1 @@
        -the quick brown fox
        +the slow brown fox
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.count, 1)
        let row = body[0]
        XCTAssertEqual(row.kind, .modified)
        XCTAssertEqual(row.leftText, "the quick brown fox")
        XCTAssertEqual(row.rightText, "the slow brown fox")
        // common prefix "the " (4), common suffix " brown fox" (10)
        XCTAssertEqual(row.leftSpans, [WordSpan(start: 4, length: 5)])  // "quick"
        XCTAssertEqual(row.rightSpans, [WordSpan(start: 4, length: 4)]) // "slow"
        XCTAssertEqual(row.leftLineNo, 1)
        XCTAssertEqual(row.rightLineNo, 1)
    }

    func test_contextAndChange_lineNumbersAdvance() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,3 +1,3 @@
         context1
        -old
        +new
         context2
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.map(\.kind), [.context, .modified, .context])
        XCTAssertEqual(body[0].leftLineNo, 1); XCTAssertEqual(body[0].rightLineNo, 1)
        XCTAssertEqual(body[1].leftLineNo, 2); XCTAssertEqual(body[1].rightLineNo, 2)
        XCTAssertEqual(body[2].leftLineNo, 3); XCTAssertEqual(body[2].rightLineNo, 3)
        XCTAssertEqual(body[2].leftText, "context2")
    }

    func test_noNewlineMarker_isSkipped() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,1 +1,1 @@
        -a
        +b
        \\ No newline at end of file
        """
        let d = UnifiedDiffParser.parse(text)
        let body = d.rows.filter { $0.kind != .hunkHeader }
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body[0].kind, .modified)
    }

    func test_multiHunk_resetsLineNumbers() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,1 +1,1 @@
        -a
        +A
        @@ -10,1 +10,1 @@
        -b
        +B
        """
        let d = UnifiedDiffParser.parse(text)
        let headers = d.rows.filter { $0.kind == .hunkHeader }
        XCTAssertEqual(headers.count, 2)
        let mods = d.rows.filter { $0.kind == .modified }
        XCTAssertEqual(mods.count, 2)
        XCTAssertEqual(mods[0].leftLineNo, 1)
        XCTAssertEqual(mods[1].leftLineNo, 10)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'UnifiedDiffParser' in scope`.

- [ ] **Step 3: Implement the parser**

```swift
import Foundation

public enum UnifiedDiffParser {

    public static func parse(_ diffText: String) -> FileDiff {
        if diffText.range(of: "\nBinary files ") != nil || diffText.hasPrefix("Binary files ") {
            return FileDiff(rows: [], isBinary: true)
        }

        var rows: [DiffRow] = []
        var inHunk = false
        var leftNo = 0
        var rightNo = 0
        var pendingRemoved: [(Int, String)] = []
        var pendingAdded: [(Int, String)] = []

        func flush() {
            let n = max(pendingRemoved.count, pendingAdded.count)
            for i in 0..<n {
                if i < pendingRemoved.count && i < pendingAdded.count {
                    let (lno, ltext) = pendingRemoved[i]
                    let (rno, rtext) = pendingAdded[i]
                    let (ls, rs) = wordSpans(ltext, rtext)
                    rows.append(DiffRow(kind: .modified,
                                        leftLineNo: lno, leftText: ltext,
                                        rightLineNo: rno, rightText: rtext,
                                        leftSpans: ls, rightSpans: rs))
                } else if i < pendingRemoved.count {
                    let (lno, ltext) = pendingRemoved[i]
                    rows.append(DiffRow(kind: .removed, leftLineNo: lno, leftText: ltext))
                } else {
                    let (rno, rtext) = pendingAdded[i]
                    rows.append(DiffRow(kind: .added, rightLineNo: rno, rightText: rtext))
                }
            }
            pendingRemoved.removeAll(keepingCapacity: true)
            pendingAdded.removeAll(keepingCapacity: true)
        }

        for line in diffText.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                flush()
                let (l, r) = parseHunkHeader(line)
                leftNo = l
                rightNo = r
                inHunk = true
                rows.append(DiffRow(kind: .hunkHeader, headerText: line))
                continue
            }
            if line.hasPrefix("diff --git") {
                flush()
                inHunk = false
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("\\") { continue }    // \ No newline at end of file
            guard let first = line.first else { continue } // skip empty split artifacts
            let text = String(line.dropFirst())
            switch first {
            case " ":
                flush()
                rows.append(DiffRow(kind: .context,
                                    leftLineNo: leftNo, leftText: text,
                                    rightLineNo: rightNo, rightText: text))
                leftNo += 1
                rightNo += 1
            case "-":
                pendingRemoved.append((leftNo, text))
                leftNo += 1
            case "+":
                pendingAdded.append((rightNo, text))
                rightNo += 1
            default:
                continue
            }
        }
        flush()
        return FileDiff(rows: rows)
    }

    static func parseHunkHeader(_ line: String) -> (Int, Int) {
        var left = 0
        var right = 0
        for tok in line.split(separator: " ") {
            if tok.hasPrefix("-") {
                let num = tok.dropFirst().split(separator: ",").first ?? ""
                left = Int(num) ?? 0
            } else if tok.hasPrefix("+") {
                let num = tok.dropFirst().split(separator: ",").first ?? ""
                right = Int(num) ?? 0
            }
        }
        return (left, right)
    }

    /// Character-level common prefix/suffix → a single changed span per side (empty if none).
    static func wordSpans(_ left: String, _ right: String) -> ([WordSpan], [WordSpan]) {
        let l = Array(left)
        let r = Array(right)
        var p = 0
        while p < l.count && p < r.count && l[p] == r[p] { p += 1 }
        var s = 0
        while s < (l.count - p) && s < (r.count - p) && l[l.count - 1 - s] == r[r.count - 1 - s] { s += 1 }
        let lLen = l.count - p - s
        let rLen = r.count - p - s
        let ls = lLen > 0 ? [WordSpan(start: p, length: lLen)] : []
        let rs = rLen > 0 ? [WordSpan(start: p, length: rLen)] : []
        return (ls, rs)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — all `UnifiedDiffParserTests` green.

- [ ] **Step 5: Commit**

```bash
git add Sources/DevDashCore/UnifiedDiffParser.swift Tests/DevDashCoreTests/UnifiedDiffParserTests.swift
git commit -m "core: unified diff parser with word-level spans + tests"
```

---

## Phase 2 — GitDiffScanner (app target)

All git reads/mutations for the tab. No behavioral tests (IO); gate is `swift build`.

### Task 2.1: ChangedFile / GitCommit / FileDiffSource models

**Files:**
- Create: `Sources/DevDash/Models/DiffModels.swift`

**Interfaces:**
- Produces: `ChangedFile`, `GitCommit`, `FileDiffSource`.

- [ ] **Step 1: Create the file**

```swift
import Foundation

struct ChangedFile: Identifiable, Hashable {
    let path: String            // repo-relative
    let stagedStatus: Character?    // index (X) column; nil if unmodified there
    let unstagedStatus: Character?  // worktree (Y) column; nil if unmodified there
    let isUntracked: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct GitCommit: Identifiable, Hashable {
    let sha: String
    let shortSha: String
    let subject: String
    let author: String
    let relativeDate: String
    var id: String { sha }
}

enum FileDiffSource: Hashable {
    case unstaged
    case staged
    case commit(String)
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Models/DiffModels.swift
git commit -m "changes: ChangedFile/GitCommit/FileDiffSource models"
```

### Task 2.2: GitDiffScanner

**Files:**
- Create: `Sources/DevDash/Scanners/GitDiffScanner.swift`

**Interfaces:**
- Consumes: `ShellRunner.run`, `GitStatusScanner.op`, `ChangedFile`, `GitCommit`, `FileDiffSource`.
- Produces: `enum GitDiffScanner` with `changedFiles`, `commits`, `commitFiles`, `fileDiff`, `stage`, `unstage`, `revert`.

- [ ] **Step 1: Create the scanner**

```swift
import Foundation

enum GitDiffScanner {

    /// Parse `git status --porcelain=v1`. X = staged column, Y = worktree column.
    static func changedFiles(path: String) async -> [ChangedFile] {
        guard let raw = await ShellRunner.run("/usr/bin/git",
            args: ["-c", "core.quotepath=false", "status", "--porcelain=v1"],
            cwd: path, timeout: 10) else { return [] }

        var files: [ChangedFile] = []
        for line in raw.components(separatedBy: "\n") where line.count >= 4 {
            let chars = Array(line)
            let x = chars[0]
            let y = chars[1]
            var pathPart = String(line.dropFirst(3))
            if let arrow = pathPart.range(of: " -> ") {   // rename: "old -> new"
                pathPart = String(pathPart[arrow.upperBound...])
            }
            pathPart = pathPart.trimmingCharacters(in: .whitespaces)
            let untracked = (x == "?" && y == "?")
            files.append(ChangedFile(
                path: pathPart,
                stagedStatus: (x == " " || x == "?") ? nil : x,
                unstagedStatus: (y == " ") ? nil : y,
                isUntracked: untracked))
        }
        return files
    }

    static func commits(path: String, limit: Int = 60) async -> [GitCommit] {
        let fmt = "%H%x1f%h%x1f%s%x1f%an%x1f%cr"
        guard let raw = await ShellRunner.run("/usr/bin/git",
            args: ["log", "-n", "\(limit)", "--pretty=format:\(fmt)"],
            cwd: path, timeout: 10) else { return [] }

        var commits: [GitCommit] = []
        for line in raw.components(separatedBy: "\n") where !line.isEmpty {
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count == 5 else { continue }
            commits.append(GitCommit(sha: f[0], shortSha: f[1], subject: f[2],
                                     author: f[3], relativeDate: f[4]))
        }
        return commits
    }

    /// Files changed in a single commit (vs its first parent).
    static func commitFiles(path: String, sha: String) async -> [ChangedFile] {
        guard let raw = await ShellRunner.run("/usr/bin/git",
            args: ["-c", "core.quotepath=false", "show", "--name-status", "--format=", sha],
            cwd: path, timeout: 10) else { return [] }

        var files: [ChangedFile] = []
        for line in raw.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            let status = parts[0].first ?? "M"
            let filePath = (parts.last ?? "").trimmingCharacters(in: .whitespaces)
            files.append(ChangedFile(path: filePath, stagedStatus: status,
                                     unstagedStatus: nil, isUntracked: false))
        }
        return files
    }

    /// Raw unified diff for one file from the requested source. `untracked` files
    /// have no tracked diff, so use --no-index against /dev/null to show them as added.
    static func fileDiff(path: String, file: String, source: FileDiffSource,
                         untracked: Bool = false) async -> String? {
        let args: [String]
        switch source {
        case .unstaged:
            args = untracked
                ? ["diff", "--no-index", "--", "/dev/null", file]
                : ["diff", "--", file]
        case .staged:
            args = ["diff", "--cached", "--", file]
        case .commit(let sha):
            args = ["show", sha, "--", file]
        }
        return await ShellRunner.run("/usr/bin/git", args: args, cwd: path, timeout: 15)
    }

    // MARK: - Mutations (return success)

    static func stage(path: String, file: String) async -> Bool {
        await GitStatusScanner.op(["add", "--", file], in: path).1
    }

    static func unstage(path: String, file: String) async -> Bool {
        await GitStatusScanner.op(["reset", "HEAD", "--", file], in: path).1
    }

    static func revert(path: String, file: String, untracked: Bool) async -> Bool {
        if untracked {
            return await GitStatusScanner.op(["clean", "-f", "--", file], in: path).1
        } else {
            return await GitStatusScanner.op(["checkout", "--", file], in: path).1
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Scanners/GitDiffScanner.swift
git commit -m "changes: GitDiffScanner (status/log/show/diff + stage/unstage/revert)"
```

---

## Phase 3 — SideBySideDiffView renderer (app target)

### Task 3.1: SideBySideDiffView

**Files:**
- Create: `Sources/DevDash/Views/SideBySideDiffView.swift`

**Interfaces:**
- Consumes: `FileDiff`, `DiffRow`, `DiffRowKind`, `WordSpan` (from `DevDashCore`), `SyntaxHighlighter`, `DSColor`, `DSFont`.
- Produces: `struct SideBySideDiffView: View` with `init(diff: FileDiff, language: SyntaxHighlighter.Language)`.

- [ ] **Step 1: Create the view**

```swift
import SwiftUI
import AppKit
import DevDashCore

struct SideBySideDiffView: View {
    let diff: FileDiff
    let language: SyntaxHighlighter.Language

    var body: some View {
        Group {
            if diff.isBinary {
                placeholder("Binary file — no text diff")
            } else if diff.tooLarge {
                placeholder("Diff too large to render")
            } else if diff.rows.isEmpty {
                placeholder("No changes")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.rows.enumerated()), id: \.offset) { _, row in
                            DiffRowView(row: row, language: language)
                        }
                    }
                    .padding(.vertical, DSSpace.xs)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(DSFont.label)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffRowView: View {
    let row: DiffRow
    let language: SyntaxHighlighter.Language

    var body: some View {
        switch row.kind {
        case .hunkHeader:
            Text(verbatim: row.headerText ?? "")
                .font(DSFont.mono(.caption2))
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.08))
        default:
            HStack(spacing: 0) {
                cell(lineNo: row.leftLineNo, text: row.leftText, spans: row.leftSpans,
                     side: .left)
                Rectangle().fill(DSColor.hairline).frame(width: 1)
                cell(lineNo: row.rightLineNo, text: row.rightText, spans: row.rightSpans,
                     side: .right)
            }
        }
    }

    private enum Side { case left, right }

    @ViewBuilder
    private func cell(lineNo: Int?, text: String?, spans: [WordSpan], side: Side) -> some View {
        HStack(spacing: 6) {
            Text(lineNo.map(String.init) ?? "")
                .font(DSFont.monoDigits(.caption2))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
            if let text {
                Text(styled(text, spans: spans, side: side))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(side: side))
    }

    private func rowBackground(side: Side) -> Color {
        switch row.kind {
        case .added:    return side == .right ? DSColor.success.opacity(0.12) : .clear
        case .removed:  return side == .left  ? DSColor.danger.opacity(0.12)  : .clear
        case .modified: return side == .left  ? DSColor.danger.opacity(0.10)  : DSColor.success.opacity(0.10)
        default:        return .clear
        }
    }

    /// Build an attributed line: syntax colors (via SyntaxHighlighter NSColors) + word-span backgrounds.
    private func styled(_ text: String, spans: [WordSpan], side: Side) -> AttributedString {
        let ms = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ])
        for token in SyntaxHighlighter.tokenize(text, language: language) {
            if NSMaxRange(token.range) <= ms.length {
                ms.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            }
        }
        let bg: NSColor? = {
            switch row.kind {
            case .modified: return side == .left
                ? NSColor.systemRed.withAlphaComponent(0.30)
                : NSColor.systemGreen.withAlphaComponent(0.30)
            default: return nil
            }
        }()
        if let bg {
            for span in spans {
                if let ns = nsRange(in: text, charStart: span.start, charLength: span.length),
                   NSMaxRange(ns) <= ms.length {
                    ms.addAttribute(.backgroundColor, value: bg, range: ns)
                }
            }
        }
        return AttributedString(ms)
    }

    private func nsRange(in text: String, charStart: Int, charLength: Int) -> NSRange? {
        guard let start = text.index(text.startIndex, offsetBy: charStart, limitedBy: text.endIndex),
              let end = text.index(start, offsetBy: charLength, limitedBy: text.endIndex) else { return nil }
        return NSRange(start..<end, in: text)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Views/SideBySideDiffView.swift
git commit -m "changes: side-by-side diff renderer (syntax + word-level highlight)"
```

---

## Phase 4 — ChangesTabView + tab wiring

### Task 4.1: ChangesTabView

**Files:**
- Create: `Sources/DevDash/Views/Tabs/ChangesTabView.swift`

**Interfaces:**
- Consumes: `DashboardStore` (`store.project(for:)`, `store.selection`), `GitDiffScanner`, `SideBySideDiffView`, `UnifiedDiffParser`, `ChangedFile`, `GitCommit`, `FileDiffSource`, `SyntaxHighlighter`, design tokens.
- Produces: `struct ChangesTabView: View`.

- [ ] **Step 1: Create the view**

```swift
import SwiftUI
import AppKit
import DevDashCore

struct ChangesTabView: View {
    @EnvironmentObject var store: DashboardStore

    @State private var unstaged: [ChangedFile] = []
    @State private var staged: [ChangedFile] = []
    @State private var commits: [GitCommit] = []
    @State private var expandedSha: String? = nil
    @State private var commitFiles: [ChangedFile] = []

    @State private var selection: DiffSelection? = nil
    @State private var diff: FileDiff? = nil
    @State private var loadingDiff = false
    @State private var revertTarget: ChangedFile? = nil

    struct DiffSelection: Equatable {
        let file: String
        let source: FileDiffSource
        let untracked: Bool
    }

    var body: some View {
        if let project = store.project(for: store.selection) {
            HSplitView {
                sidebar(projectPath: project.path)
                    .frame(minWidth: 200, idealWidth: 280, maxWidth: 460)
                    .background(DSColor.cardBg)
                diffPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor))
            }
            .task(id: project.path) { await refresh(project.path) }
            .alert("Discard changes to \(revertTarget?.name ?? "")?",
                   isPresented: Binding(get: { revertTarget != nil },
                                        set: { if !$0 { revertTarget = nil } })) {
                Button("Discard", role: .destructive) {
                    if let t = revertTarget { Task { await doRevert(project.path, t) } }
                }
                Button("Cancel", role: .cancel) { revertTarget = nil }
            } message: {
                Text("This permanently discards the file's uncommitted changes.")
            }
        } else {
            Text("Select a project to view changes")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Sidebar

    @ViewBuilder
    private func sidebar(projectPath: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                fileGroup(title: "Unstaged", files: unstaged, projectPath: projectPath,
                          source: .unstaged, isStaged: false)
                fileGroup(title: "Staged", files: staged, projectPath: projectPath,
                          source: .staged, isStaged: true)
                Divider().padding(.vertical, DSSpace.xs)
                historyGroup(projectPath: projectPath)
            }
            .padding(DSSpace.sm)
        }
    }

    @ViewBuilder
    private func fileGroup(title: String, files: [ChangedFile], projectPath: String,
                           source: FileDiffSource, isStaged: Bool) -> some View {
        if !files.isEmpty {
            SectionHeader("\(title) (\(files.count))")
                .padding(.top, DSSpace.xs)
            ForEach(files) { file in
                fileRow(file, projectPath: projectPath, source: source, isStaged: isStaged)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: ChangedFile, projectPath: String,
                         source: FileDiffSource, isStaged: Bool) -> some View {
        let isSelected = selection?.file == file.path && selection?.source == source
        HStack(spacing: 6) {
            Text(statusBadge(file, isStaged: isStaged))
                .font(DSFont.monoDigits(.caption2))
                .foregroundColor(badgeColor(file, isStaged: isStaged))
                .frame(width: 14)
            Text(file.name)
                .font(DSFont.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if isStaged {
                rowButton("minus.circle", help: "Unstage") {
                    Task { await GitDiffScanner.unstage(path: projectPath, file: file.path); await refresh(projectPath) }
                }
            } else {
                rowButton("plus.circle", help: "Stage") {
                    Task { await GitDiffScanner.stage(path: projectPath, file: file.path); await refresh(projectPath) }
                }
                rowButton("arrow.uturn.backward", help: "Discard") { revertTarget = file }
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
        .contentShape(Rectangle())
        .onTapGesture {
            selection = DiffSelection(file: file.path, source: source, untracked: file.isUntracked)
            Task { await loadDiff(projectPath) }
        }
    }

    @ViewBuilder
    private func historyGroup(projectPath: String) -> some View {
        SectionHeader("History")
        ForEach(commits) { commit in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: expandedSha == commit.sha ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Text(commit.shortSha).font(DSFont.mono(.caption2)).foregroundColor(DSColor.gitMeta)
                    Text(commit.subject).font(DSFont.label).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(commit.relativeDate).font(DSFont.micro).foregroundColor(.secondary)
                }
                .padding(.vertical, 3).padding(.horizontal, 6)
                .contentShape(Rectangle())
                .onTapGesture { Task { await toggleCommit(commit, projectPath: projectPath) } }

                if expandedSha == commit.sha {
                    ForEach(commitFiles) { file in
                        let isSel = selection?.file == file.path && selection?.source == .commit(commit.sha)
                        HStack(spacing: 6) {
                            Text(file.stagedStatus.map(String.init) ?? "M")
                                .font(DSFont.monoDigits(.caption2)).foregroundColor(.secondary).frame(width: 14)
                            Text(file.name).font(DSFont.label).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2).padding(.leading, 22).padding(.trailing, 6)
                        .background(isSel ? Color.accentColor.opacity(0.15) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = DiffSelection(file: file.path, source: .commit(commit.sha), untracked: false)
                            Task { await loadDiff(projectPath) }
                        }
                    }
                }
            }
        }
    }

    private func rowButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 11)) }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help(help)
    }

    private func statusBadge(_ file: ChangedFile, isStaged: Bool) -> String {
        if file.isUntracked { return "?" }
        let c = isStaged ? file.stagedStatus : file.unstagedStatus
        return c.map(String.init) ?? "•"
    }

    private func badgeColor(_ file: ChangedFile, isStaged: Bool) -> Color {
        if file.isUntracked { return DSColor.success }
        let c = isStaged ? file.stagedStatus : file.unstagedStatus
        switch c {
        case "A": return DSColor.success
        case "D": return DSColor.danger
        case "M": return DSColor.warning
        default:  return .secondary
        }
    }

    // MARK: Diff pane

    @ViewBuilder
    private var diffPane: some View {
        if loadingDiff {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff, let selection {
            VStack(spacing: 0) {
                HStack {
                    Text(selection.file).font(DSFont.mono(.caption)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, DSSpace.md).padding(.vertical, DSSpace.sm)
                Divider()
                SideBySideDiffView(diff: diff, language: language(for: selection.file))
            }
        } else {
            Text("Select a file to view its diff")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func language(for file: String) -> SyntaxHighlighter.Language {
        SyntaxHighlighter.Language.detect(from: (file as NSString).pathExtension)
    }

    // MARK: Loading

    private func refresh(_ projectPath: String) async {
        let all = await GitDiffScanner.changedFiles(path: projectPath)
        let log = await GitDiffScanner.commits(path: projectPath)
        await MainActor.run {
            unstaged = all.filter { $0.unstagedStatus != nil || $0.isUntracked }
            staged = all.filter { $0.stagedStatus != nil }
            commits = log
        }
    }

    private func loadDiff(_ projectPath: String) async {
        guard let sel = selection else { return }
        await MainActor.run { loadingDiff = true }
        let raw = await GitDiffScanner.fileDiff(path: projectPath, file: sel.file,
                                                source: sel.source, untracked: sel.untracked) ?? ""
        let parsed = UnifiedDiffParser.parse(raw)
        await MainActor.run {
            diff = parsed
            loadingDiff = false
        }
    }

    private func toggleCommit(_ commit: GitCommit, projectPath: String) async {
        if expandedSha == commit.sha {
            await MainActor.run { expandedSha = nil; commitFiles = [] }
            return
        }
        let files = await GitDiffScanner.commitFiles(path: projectPath, sha: commit.sha)
        await MainActor.run { expandedSha = commit.sha; commitFiles = files }
    }

    private func doRevert(_ projectPath: String, _ file: ChangedFile) async {
        _ = await GitDiffScanner.revert(path: projectPath, file: file.path, untracked: file.isUntracked)
        await MainActor.run { revertTarget = nil }
        await refresh(projectPath)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/DevDash/Views/Tabs/ChangesTabView.swift
git commit -m "changes: ChangesTabView (sidebar groups + history + diff pane)"
```

### Task 4.2: Wire the tab + remove FilesTabView

**Files:**
- Modify: `Sources/DevDash/Models.swift:540-568` (DetailTab enum)
- Modify: `Sources/DevDash/Views/DetailPaneView.swift:49`
- Delete: `Sources/DevDash/Views/Tabs/FilesTabView.swift`

**Interfaces:**
- Consumes: `ChangesTabView` (Task 4.1).
- Produces: `DetailTab.changes` case rendered by `ChangesTabView`.

- [ ] **Step 1: Rename the enum case `files` → `changes`**

In `Sources/DevDash/Models.swift`, change the `case` declaration line:

```swift
    case info, preview, claude, tasks, product, changes, logs, daily
```

In the `label` switch, replace the `.files` arm:

```swift
        case .changes: return "Changes"
```

In the `systemImage` switch, replace the `.files` arm:

```swift
        case .changes: return "arrow.triangle.branch"
```

- [ ] **Step 2: Update DetailPaneView switch**

In `Sources/DevDash/Views/DetailPaneView.swift`, replace:

```swift
                case .files: FilesTabView()
```

with:

```swift
                case .changes: ChangesTabView()
```

- [ ] **Step 3: Delete FilesTabView**

```bash
git rm Sources/DevDash/Views/Tabs/FilesTabView.swift
```

- [ ] **Step 4: Resolve remaining references**

`FilesTabView` defined helper views (`LiveFilesSection`, `FileContentView`, `CodeEditor` usage) — check nothing else references symbols that lived only in `FilesTabView.swift`:

Run: `grep -rn "FilesTabView\|LiveFilesSection\|FileContentView" Sources/DevDash`
Expected: only matches inside the now-deleted file (none remain) OR references in other files. If `FileContentView`/`CodeEditor` are referenced elsewhere, they live in their own files (`CodeEditor.swift`) and are unaffected. If `LiveFilesSection` is referenced elsewhere, move it into the referencing file or a new small file. If `DetailTab.files` is referenced anywhere else, update to `.changes`:

Run: `grep -rn "\.files\b" Sources/DevDash`
Expected: update any `DetailTab.files` / `.files` (tab context) usages (e.g. default tab, keyboard shortcut maps in `ContentView.swift`) to `.changes`. Leave unrelated `.files` (e.g. FileManager) alone.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 6: Commit (feature files only — do NOT `git add -A`; the working tree has unrelated pre-existing changes)**

```bash
git add Sources/DevDash/Models.swift Sources/DevDash/Views/DetailPaneView.swift
git rm Sources/DevDash/Views/Tabs/FilesTabView.swift 2>/dev/null; true
# plus any other file you edited in Step 4 to resolve references (add it explicitly by path)
git commit -m "changes: wire Changes tab, remove Files tab"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Per-file stage/unstage/revert → Task 2.2 + 4.1 ✓
- Side-by-side layout → Task 3.1 ✓
- Staged/Unstaged groups → Task 4.1 `fileGroup` ✓
- Commit history + per-commit files + diff → Task 4.1 `historyGroup`, Task 2.2 `commits`/`commitFiles` ✓
- No commit box → not implemented (correct) ✓
- Parse-git-unified + word-level → Task 1.3 ✓
- Single aligned-row virtualized list → Task 3.1 `LazyVStack` ✓
- Syntax highlight reuse → Task 3.1 `SyntaxHighlighter.tokenize` ✓
- Untracked files (added, --no-index) → Task 2.2 `fileDiff(untracked:)`, 4.1 unstaged filter ✓
- Binary/empty placeholders → Task 1.3 binary detect + Task 3.1 placeholders ✓
- Tab rename + remove FilesTabView → Task 4.2 ✓
- `pendingFilePath` not consumed by Changes tab → not wired (matches spec) ✓
- Unit tests → Task 1.3 ✓

**Placeholder scan:** none — all code blocks complete.

**Type consistency:** `FileDiff`/`DiffRow`/`WordSpan`/`DiffRowKind` (core) used identically in parser, renderer. `ChangedFile`/`GitCommit`/`FileDiffSource` consistent across scanner + view. `FileDiffSource` is `Hashable` (used in `DiffSelection: Equatable` and `==` comparisons) ✓.

**Known risk (accepted):** Phases 2–4 are gated by `swift build` only (no behavioral tests for IO/GUI), per the user's "full auto on compile signal" decision.
