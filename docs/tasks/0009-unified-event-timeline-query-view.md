---
lore_type: task
title: Unified event timeline + regenerable SQLite query view
status: open
owner: none
category: engineering
priority: low
effort: large
created: '2026-06-30'
ticket: '0008'
---
Merge the durable seams — the NDJSON op-log (task 0007), the session JSONL digests, and
each task's `## Status history` — into one timeline keyed by task / cwd / session: the
"SELECT across code + knowledge + activity, as-of any point" surface. Per ADR
[[0013-durable-agent-operation-log-jj-anchors]].

## Acceptance criteria

- [ ] A read API that merges the three sources on session / cwd / task and supports an
      `as-of <timestamp>` filter.
- [ ] When query load warrants it, a SQLite index built via the system `import SQLite3`
      (no SPM dependency), rebuilt by replaying the NDJSON — deletable and regenerable,
      never the only copy.
- [ ] If jj is present, cross-reference each repo-mutating event to its jj op id so the
      timeline can offer `jj op restore`.

## Notes

Do not add SQLite via SPM — honors the *no external Swift dependencies* rule. Truth stays
in text; SQLite is a throwaway view. Depends on task 0007.
