# Resume — 2026-07-12 (evening: markdown fix + wikis-count closed)

**State:** committed & pushed (59fd28b). Cross-line bold in Markdown.bodyHTML
fixed (paragraph-scoped inline processing, \n→<br> after); new
`--selftest-markdown` suite (12 checks) ALL PASS; verified live on the
life-wiki README. Wikis count-3/rows-2 sighting CLOSED as a one-frame List
diffing artifact — count/rows provably derive from the same array.

**Next steps:**
1. Decide: generalize nestAnchor + collections beyond books (recipes under
   Cooking, songs under Music)? Suki's call — scope, not a bug.

**Gotchas:** extend MarkdownSelfTest before touching processInline. Italic is
deliberately per-line ([^*\n]) so stray asterisks can't pair across lines.
Never `screencapture -R` for app evidence — window-scoped `-l<id>` only
(a -R capture grabbed the user's browser once this session).
