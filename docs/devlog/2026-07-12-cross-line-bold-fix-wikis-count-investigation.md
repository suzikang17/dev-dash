---
lore_type: devlog
created: 2026-07-12
title: "Cross-line bold fix + Wikis count investigation"
date: 2026-07-12
day: 25
---

**Fixed bold spans that wrap across lines in Markdown.bodyHTML (TDD, new --selftest-markdown suite) and closed the Wikis-tab count-3/rows-2 sighting as a transient render artifact.**

## What got done
- Fixed the wiki-README bold miss: `processInline` ran per line, so a `**span**` opening on one hard-wrapped line and closing on the next never matched. Paragraph text is now inline-processed as one string, then newlines become `<br>` (`Scanners/Markdown.swift`).
- Added `MarkdownSelfTest` (`--selftest-markdown`, registered in App.swift): 12 checks covering bold/italic/code/links, HTML escaping, `javascript:` href rejection, newline→`<br>`, the cross-line bold case, no-span-across-blank-line, headings, list inline, fenced code. Written failing-first; all pass after the fix.
- Verified end-to-end: launched the app, life-wiki README renders "create more than you consume." bold across the wrap (screenshot). Taskstore/daily/policy suites still ALL PASS.
- Investigated RESUME item "Wikis tab showed count 3 / 2 rows once" and closed it as no-bug.

## Decisions
- Inline spans may now cross hard-wrapped lines within a paragraph (code and links too) — matches CommonMark intent while keeping the notes/PKM newline-as-`<br>` behavior. Italic still stays per-line (`[^*\n]`) so stray `*` on different lines can't pair.

## Issues
- Wikis count sighting: three wikis genuinely exist (dev, work-wiki, life) and all detect as framework "Wiki"; header count and rows derive from the same filtered array in the same body evaluation, ids are deduped paths, rows render unconditionally — a 3/2 mismatch is impossible in current code. Verdict: one-frame SwiftUI List diffing artifact during a wholesale `projects` assignment. Closed, nothing to fix.
- During verification, a region `screencapture -R` grabbed the user's active browser window (DevDash wasn't frontmost) — deleted immediately. Window-scoped `-l<id>` only.

## What to remember
- `Markdown.bodyHTML` inline formatting is paragraph-scoped now; if a future block type feeds multi-line text through `processInline`, newlines survive until the post-pass `\n`→`<br>` replacement.
- `--selftest-markdown` is the regression net for the Docs-tab renderer — extend it before touching `processInline`.

---

## Commits
- 59fd28b Fix bold spans crossing hard-wrapped lines in Markdown.bodyHTML
