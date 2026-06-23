---
lore_type: decision
title: "Put pure, testable logic in a DevDashCore library target"
date: 2026-06-22
category: architecture
revisit: false
---

## Why this choice

DevDash is a single `@main` SwiftUI executable target with no tests. The diff parser
is pure logic that genuinely needs unit tests. Testing code inside an executable
target via `@testable import` is unreliable because of the `@main` entry point
(linker/duplicate-symbol friction). To get a real `swift test` signal we extracted
the pure types (`DiffRow`, `WordSpan`, `FileDiff`, `FileDiffSection`, `DiffRowKind`)
and `UnifiedDiffParser` into a new `DevDashCore` library target, with a
`DevDashCoreTests` target depending on it. The app target depends on `DevDashCore`
and the new diff files `import DevDashCore`.

## Options considered

- New `DevDashCore` library target + test target (chosen).
- `@testable import DevDash` of the executable target (fought the `@main` entry).
- No unit tests; rely on `swift build` only (the GUI/IO layers already do this, but
  the parser is exactly the kind of pure logic worth testing).

## Tradeoffs

- Gain: fast, headless, dependency-free unit tests for the parser; a clear home for
  future pure logic; no `@main` linking hacks.
- Give up: a second target to maintain and an `import DevDashCore` in consumers; types
  shared across the boundary must be `public`. SwiftPM also required a source file in
  the test dir before it would accept the target (a `Placeholder.swift` was added).

Rule of thumb going forward: new pure, unit-testable helpers go in `DevDashCore`;
view/IO code stays in the app target.
