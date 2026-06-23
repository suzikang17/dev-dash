<!-- managed by devdash — edit answers/exit criteria in the dashboard, not this file -->

# dev-dash — Roadmap

> **Methodology:** Personal Tool  
> **Current stage:** Refine the parts that hurt

_You are the user. Build for yourself, use it daily, fix what actually annoys you (not what you imagine will annoy other people). Resist polishing for an audience that doesn't exist. If it ends up useful to others, that's a bonus — not the goal._

## Progress

- ✅ **Identify the itch** — 0/3 exit criteria
- ✅ **Sketch the smallest version** — 0/3 exit criteria
- ✅ **Live with it** — 0/3 exit criteria
- ▶︎ **Refine the parts that hurt** — 0/3 exit criteria
- ◯ **Maybe share it** — 0/3 exit criteria

---

## Identify the itch — _done_

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

## Sketch the smallest version — _done_

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

---

## Live with it — _done_

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

---

## Refine the parts that hurt — _in progress_

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

---

## Unstaged tasks

- [ ] Build native macOS app _(Other)_
- [ ] Wire up project tracker _(Other)_

---

_Last updated: 2026-06-23T04:45:30Z_
