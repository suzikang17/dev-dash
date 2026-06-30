# jj workspace spike — runbook

Executable companion to task **0008** (`docs/tasks/0008-spike-jj-workspaces-vs-git-worktrees.md`).
Setup is **done**: jj 0.42 installed, colocated on this repo (`.jj/` excluded from git).
Everything below is reversible.

## Status / teardown

```bash
jj --version                 # 0.42.0
jj workspace list            # default: …  (only the main workspace)
# To fully undo the spike:
rm -rf .jj                   # repo reverts to plain git, nothing else changes
```

> Note: the initial colocated working-copy commit has an empty author (`<>`) because it
> predates `jj config set`. Cosmetic; fix with `jj metaedit --update-author` if it matters.

## Run the head-to-head (same 4-agent scenario both ways)

### Substrate A — git worktrees (control, = `WorktreeManager` today)

```bash
for i in 1 2 3 4; do
  git worktree add .worktrees/agent-$i -b spike/agent-$i   # branch REQUIRED up front
done
git worktree list                                          # observability = this list only
# rollback agent 2: cd in, git reset --hard / or remove the worktree + branch by hand
# conflict: agents 2 & 3 edit the same file → integration blocks at merge/PR
```

### Substrate B — jj workspaces

```bash
for i in 1 2 3 4; do
  jj workspace add .worktrees-jj/agent-$i                  # NO branch name needed
done
jj workspace list

# Central observability — ONE timeline across all 4 agents:
jj op log --limit 20

# Per-agent rollback — revert one agent's bad op without touching the others:
jj op log                       # find the bad op id
jj op restore <op-id>

# Stable change-id per agent (the durable task→code anchor):
jj log -r '@' --no-graph -T 'change_id'    # run inside each workspace

# Conflict-as-data — agents 2 & 3 edit the same file, then:
jj rebase ...                   # completes; conflict stored in the commit, no block

# teardown:
for i in 1 2 3 4; do jj workspace forget agent-$i; done
rm -rf .worktrees-jj
```

## Score sheet (fill in, then apply the GO/NO-GO bar in task 0008)

| Dimension | git worktrees | jj workspaces | winner |
| --- | --- | --- | --- |
| Setup steps / glue to spin up one sandbox | branch + collision-retry + exclude | `jj workspace add` | |
| Central observability (one timeline of all 4) | none native | `jj op log` | |
| Per-agent rollback (commands + time) | `reset`/manual | `jj op restore` | |
| Conflict handling (blocks mid-op?) | blocks | conflict-as-data | |
| Stable change-id survives rebase? | no (sha moves) | yes | |
| Integration cost in dev-dash | n/a (current) | `parseWorktrees` rewrite + `update-stale` | |

**GO** if rollback **and** observability are clearly simpler **and** integration cost is
bounded to `parseWorktrees` + `update-stale`. **NO-GO** otherwise → keep `WorktreeManager`.
Record the verdict as a devlog + a decision (or update ADR 0013).
