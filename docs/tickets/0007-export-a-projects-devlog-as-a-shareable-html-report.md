---
lore_type: ticket
created: '2026-06-30'
title: Export a project's devlog as a shareable HTML report
status: open
category: engineering
---
Generate a single self-contained HTML file from a project's `docs/devlog/*.md`
entries that can be shared with someone who doesn't have the repo. It should
render each entry (TL;DR, sections, commits) in reverse-chronological order,
include the project name and date range, and work offline (inline CSS, no
external assets). Add a button in the app to produce it and reveal the file in
Finder.
