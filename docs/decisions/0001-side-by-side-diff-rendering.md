---
lore_type: decision
title: "Render diffs by parsing git's unified output into an aligned-row list"
date: 2026-06-22
category: architecture
revisit: false
---

## Why this choice

The Changes tab needs a side-by-side diff with syntax highlighting and word-level
intra-line highlights, performant on large files. Two sub-problems: how to compute
the diff, and how to render two aligned columns in SwiftUI.

For computation we parse git's own unified-diff output (`git diff` / `git show`) in
`UnifiedDiffParser`, then run a cheap char-level common-prefix/suffix pass on paired
removed/added lines for word spans. For rendering we use a single
`ScrollView { LazyVStack }` of pre-aligned rows, where each row is
`HStack[ leftCell | divider | rightCell ]` — added rows have an empty left cell,
removed rows an empty right cell — instead of two independently scrolling text views.

## Options considered

- **Compute:** parse git unified output (chosen) vs. write our own LCS line-differ
  vs. add a diffing dependency (we have a no-external-deps rule; kyde uses the Rust
  `similar` crate, which has no Swift equivalent we wanted to vendor).
- **Render:** one aligned `LazyVStack` of paired rows (chosen) vs. two synced
  `NSTextView`s with manual scroll-sync and alignment padding (kyde's gpui approach).

## Tradeoffs

- Gain: git does the correct, fast line diff; `LazyVStack` gives row alignment and
  viewport virtualization for free; the renderer stays pure SwiftUI with no deps.
- Give up: word-level highlighting is prefix/suffix only (can over-highlight reordered
  lines), and there is no per-side horizontal scroll — long lines wrap within their
  half. Both are acceptable for v1 and can be revisited if a dual-pane renderer is
  ever wanted (the parser output already supports it).
