# Resume — 2026-07-12 (wiki-in-dev-dash release)

**State:** shipped & pushed (15 commits): Wikis sidebar tab, wiki-root scanning,
tables, in-app links + file viewer, Start here group, self/ sections,
Edit-with-Claude, collection view (scrollspy + sort), in-place editing
(outliner for bullet docs, raw editor for mixed). Build clean, taskstore
selftest ALL PASS.

**Next steps:**
1. Fix inline `**bold**` mid-sentence miss in Markdown.bodyHTML (seen in wiki README).
2. Wikis tab showed count 3 / 2 rows once (suspected scan race) — reproduce or close.
3. Consider generalizing nestAnchor + collections beyond books (recipes under Cooking, songs under Music).

**Gotchas:** Docs tab renders via Scanners/Markdown.swift, NOT MarkdownWebView.
DayOutline.parse drops non-bullet lines — never feed it mixed docs (DocEditPane
gates on isPureOutline). Wiki row display names special-case folders named "wiki".
