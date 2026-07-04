---
lore_type: devlog
created: 2026-07-04
title: "lore OKF migration: status backfill on migrated task docs"
date: 2026-07-04
day: 17
---

**Upstream lore gained schema profiles + OKF `type:` frontmatter; dev-dash needed only a data fix — 6 migrated task docs were missing the required `status` field.**

## What got done
- Backfilled `status: open` on task docs 0001–0006 (the ticket-migration QA checklist docs) via `lore set-status`, which also stamped a `## Status history` entry (`unknown → open`) on each.
- `lore validate task` now exits 0 (was exit 1 on the 6 missing-status errors).
- Verified compatibility with the new lore (OKF type frontmatter, warn-only validate, schema profiles): `swift build` + `--selftest-taskstore` ALL PASS.

## Decisions
- Chose `status: open` for all 6 since none had a status history to infer from — honest default, reversible per doc with `lore set-status task <id> done` if they were actually completed.

## What to remember
- lore now warns (never errors) on docs missing `type:` frontmatter; `lore_type` remains a valid legacy alias, so dev-dash docs need no mass migration. `lore reindex <type> --fix-type` exists if we ever want to backfill `type:` wholesale.
- dev-dash's validate exit code isn't consumed programmatically, but keeping it green makes it usable as a pre-commit check.

---
## Commits
- 9ec58dc docs: backfill status=open on 6 migrated task docs missing it
