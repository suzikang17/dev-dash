<!-- managed by devdash — edit answers/exit criteria in the dashboard, not this file -->

# dev-dash — Roadmap

> **Methodology:** Personal Tool  
> **Current stage:** Identify the itch

_You are the user. Build for yourself, use it daily, fix what actually annoys you (not what you imagine will annoy other people). Resist polishing for an audience that doesn't exist. If it ends up useful to others, that's a bonus — not the goal._

## Progress

- ▶︎ **Identify the itch** — 0/3 exit criteria
- ◯ **Sketch the smallest version** — 0/3 exit criteria
- ◯ **Live with it** — 0/3 exit criteria
- ◯ **Refine the parts that hurt** — 0/3 exit criteria
- ◯ **Maybe share it** — 0/3 exit criteria

---

## Identify the itch — _in progress_

**Purpose:** Pin down the recurring annoyance. Personal tools work when they fix something real for you, not something speculative.

> If you can't name the moment of annoyance, you don't have an itch yet — you have a curiosity. Wait for the itch.

### Questions (4/5 answered)

**What's the specific moment that annoys you?**
> Switching between many local dev projects and not knowing which is running, on what port, what AI sessions exist, what tasks are pending — context-loss when bouncing between projects daily.

**How often does it happen — daily, weekly, monthly?**
> Daily, multiple times per day.

**What's your current workaround — and why is it bad enough to replace?**
> Manually checking lsof, opening terminals per project, hunting for resume commands in ~/.claude. Slow and breaks flow.

**Is this actually a tool problem, or a habit problem?**
> _unanswered_

**What's the rough shape of the fix in your head?**
> Native macOS dashboard that auto-discovers running dev servers, shows them with previews, integrates Claude session resume, and tracks per-project tasks/state.

### Exit criteria

- [ ] The annoyance written in one sentence
- [ ] Frequency known (you've actually counted, not guessed)
- [ ] Rough shape of the fix sketched

---

## Sketch the smallest version — _pending_

**Purpose:** Build the crappiest possible version that solves the itch. No polish. No edge cases. No options. Make it work for you, today, in your one workflow.

> Hardcode everything. Skip auth. Skip config. Skip UI niceties. The goal is to use it, not to ship it.

### Questions (2/5 answered)

**What's the dumbest possible version that works?**
> Sidebar of running services + heatmap home + click to preview localhost URL in WKWebView.

**What can be hardcoded for now (paths, names, choices)?**
> _unanswered_

**What's the one workflow it must support?**
> _unanswered_

**What's NOT in v0 (write it down so you don't sneak it in)?**
> _unanswered_

**Where will it live — local script, menu bar app, web page on localhost?**
> Native macOS app (SPM executable) with menu bar extra + main window.

### Exit criteria

- [ ] It runs on your machine
- [ ] It solves the itch in your one workflow
- [ ] You haven't added a single feature beyond the itch

### Tasks

- [x] Build native macOS app _(Engineering)_
- [x] Wire up project tracker _(Engineering)_

---

## Live with it — _pending_

**Purpose:** Use it. Daily. Resist the urge to polish or feature-add until you actually feel the friction in real use.

> Don't open the editor for 1-2 weeks. Just use it. Take notes when something annoys you. The notes become the refine list.

### Questions (0/4 answered)

**Have you actually used it for the original itch this week?**
> _unanswered_

**What new annoyances have you noticed (be specific)?**
> _unanswered_

**What feature did you almost add — and is the urge real or imagined?**
> _unanswered_

**What's missing that genuinely blocks you, vs. nice-to-have?**
> _unanswered_

### Exit criteria

- [ ] Used daily/weekly for at least 1-2 weeks
- [ ] Friction list written (real annoyances, not imagined ones)
- [ ] Nothing added during this stage

### Tasks

- [/] Apply personal-tool template to dev-dash and use it daily _(Ops)_
- [ ] Verify chat sheet auto-fills question + persists across restarts _(QA)_
- [ ] Test session detail view from both Home and Claude tab _(QA)_
- [ ] Verify ROADMAP.md generation matches stage state across all mutations _(QA)_
- [ ] Test legacy root-level ROADMAP.md cleanup on first regeneration _(QA)_
- [ ] Run provider detection against 5+ real projects, verify accuracy _(QA)_
- [ ] Test validation runner on a real project _(QA)_
- [ ] Verify legacy todos.json migration to tasks.json _(QA)_
- [ ] Test back/forward navigation across all selection types _(QA)_
- [ ] Verify Suggest-tasks parser robustness across TASK: line variations _(QA)_
- [ ] Verify Swift / Apple platform project detection _(QA)_
- [ ] Use dev-dash for a week and file friction items _(Research)_

---

## Refine the parts that hurt — _pending_

**Purpose:** Fix the things you actually felt. Skip the things you only thought about. Resist scope creep.

> Sort the friction list by frequency × pain. Fix the top 3. Stop. Use it again.

### Questions (0/4 answered)

**What's the #1 friction point — and is it about correctness, speed, or ergonomics?**
> _unanswered_

**Are you fixing real friction, or rebuilding because you're bored?**
> _unanswered_

**What would make this 50% better in daily use?**
> _unanswered_

**What can you delete — features you added that you don't use?**
> _unanswered_

### Exit criteria

- [ ] Top 3 friction points fixed
- [ ] Unused features deleted (yes, deleted)
- [ ] Tool still solves the original itch

### Tasks

- [ ] Suggest-tasks prompt should reference user's saved guiding-question answers _(Engineering)_
- [ ] Per-task Run-with-Claude needs a visible button (not hover-only) _(Design)_
- [ ] Health check defaults handle pnpm/yarn/bun/python _(Engineering)_
- [ ] Stage advance should warn when validation checks failing _(Engineering)_
- [ ] Streaming chat replies should render markdown _(Engineering)_
- [ ] Roadmap freshness should detect newly-answered questions, not just file mtime _(Engineering)_
- [ ] GitHub issues read-mirror in unified task list _(Engineering)_
- [ ] Drag-to-reorder tasks within a stage _(Engineering)_
- [ ] Per-task notes UI _(Design)_
- [ ] Run-all-suggestions button after a suggest run _(Engineering)_

---

## Maybe share it — _pending_

**Purpose:** Optional. If it's useful to others without contorting your life, share it. If sharing means meetings, support, and feature debates — don't.

> Share at the level you can sustain. A README and a tweet is fine. Anything more is a commitment, treat it as one.

### Questions (0/5 answered)

**Is sharing this going to obligate you (PRs, issues, support)?**
> _unanswered_

**What's the smallest possible share — gist, tweet, README, package?**
> _unanswered_

**Who would actually find this useful — not theoretical, real people?**
> _unanswered_

**Are you ready to say no to feature requests that aren't your itch?**
> _unanswered_

**Or — should you just keep it private and free?**
> _unanswered_

### Exit criteria

- [ ] Decision made: keep private, or share at level X
- [ ] If sharing: README written, repo public, audience told
- [ ] If keeping private: that's also a valid endpoint — close the project

### Tasks

- [ ] Custom user templates (.devdash/templates/<id>.yaml) _(Engineering)_
- [ ] Provider spending APIs (Stripe usage / Vercel billing) _(Research)_
- [ ] Spawn agentic Claude session for task (vs current claude -p one-shot) _(Engineering)_
- [ ] Cost guardrails — token / dollar caps per project _(Engineering)_

---

_Last updated: 2026-05-10T17:59:42Z_
