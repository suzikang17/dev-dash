import Foundation

/// Hardcoded launch templates. Each template is a *methodology* — a sequence
/// of stages with guiding questions and exit criteria. The user (with the
/// tool's help) creates the actual tasks; nothing is auto-dumped into their
/// list.
enum Templates {
    static let all: [LaunchTemplate] = [saasMvp, personalTool, contentSite, marketingSite]

    static func find(_ id: String?) -> LaunchTemplate? {
        guard let id = id else { return nil }
        return all.first { $0.id == id }
    }
}

extension Templates {
    static let saasMvp = LaunchTemplate(
        id: "saas-mvp",
        name: "SaaS MVP Launch",
        summary: "Idea → MVP → Refine → Launch → Growth. Opinionated path that keeps you out of premature optimization and pre-mature marketing.",
        methodology: """
        Bias toward conviction over polish. Each stage should produce evidence \
        that the next stage is worth doing. Don't add tasks just because they \
        sound thorough — add tasks that move you toward the next stage's exit \
        criteria. If a task doesn't fit the current stage, defer it.
        """,
        stages: [
            .init(
                id: "validate",
                title: "Validate the problem",
                purpose: "Before writing code, prove someone actually wants this. The goal is conviction, not specs.",
                methodology: "Talk to humans. Watch for pull, not politeness. Specifics > generalities.",
                guidingQuestions: [
                    "What's the one-sentence problem you're solving?",
                    "Who specifically (not \"developers\" — what kind, in what role)?",
                    "What do they do today instead?",
                    "Have you talked to 5 of them? What did they say in their own words?",
                    "What would they pay for it (range, not number)?"
                ],
                exitCriteria: [
                    "Problem statement written in one sentence",
                    "ICP (ideal customer profile) defined",
                    "5+ customer conversations logged",
                    "Pricing hypothesis sketched"
                ]
            ),
            .init(
                id: "mvp",
                title: "Build the MVP",
                purpose: "Smallest thing that proves the value. Everything else is a distraction.",
                methodology: "Cut, don't add. Ship the single core flow. Auth, settings, polish — defer unless they block the value.",
                guidingQuestions: [
                    "What's the single core flow?",
                    "What's the smallest version of that flow that still demonstrates value?",
                    "What can you cut entirely (auth, multi-user, settings, etc.)?",
                    "Where will it run (local-only / staging / prod)?",
                    "Who's the first user — and when can they try it?"
                ],
                exitCriteria: [
                    "Core happy path works end-to-end",
                    "Deployed somewhere reachable",
                    "1+ user has used it without you sitting next to them"
                ],
                validationChecks: [
                    .init(id: "build", name: "Build", stageId: "mvp",
                          command: "if [ -f package.json ]; then npm run build 2>&1; elif [ -f Package.swift ]; then swift build 2>&1; elif [ -f Cargo.toml ]; then cargo build 2>&1; elif [ -f go.mod ]; then go build ./... 2>&1; else echo 'no build configured' && exit 1; fi"),
                    .init(id: "test", name: "Tests", stageId: "mvp",
                          command: "if [ -f package.json ]; then npm test 2>&1; elif [ -f Package.swift ]; then swift test 2>&1; elif [ -f Cargo.toml ]; then cargo test 2>&1; elif [ -f go.mod ]; then go test ./... 2>&1; else echo 'no tests configured' && exit 1; fi",
                          timeoutSeconds: 300)
                ]
            ),
            .init(
                id: "refine",
                title: "Refine with real users",
                purpose: "Tighten the loop. Find the rough edges by watching real use, not by polishing in isolation.",
                methodology: "Watch users; don't ask. The friction points they don't mention are the ones to fix.",
                guidingQuestions: [
                    "What's the activation metric (\"this is working\")?",
                    "Where do users get stuck or drop off?",
                    "What's the top friction point you've seen?",
                    "What's missing from onboarding — what do users have to ask you?",
                    "What's a feature request you should ignore right now?"
                ],
                exitCriteria: [
                    "Activation metric defined and instrumented",
                    "5+ users have completed the core flow without help",
                    "Top 3 friction points identified and fixed"
                ],
                validationChecks: [
                    .init(id: "build", name: "Build", stageId: "refine",
                          command: "if [ -f package.json ]; then npm run build 2>&1; elif [ -f Package.swift ]; then swift build 2>&1; elif [ -f Cargo.toml ]; then cargo build 2>&1; elif [ -f go.mod ]; then go build ./... 2>&1; else echo 'no build configured' && exit 1; fi"),
                    .init(id: "test", name: "Tests", stageId: "refine",
                          command: "if [ -f package.json ]; then npm test 2>&1; elif [ -f Package.swift ]; then swift test 2>&1; elif [ -f Cargo.toml ]; then cargo test 2>&1; elif [ -f go.mod ]; then go test ./... 2>&1; else echo 'no tests configured' && exit 1; fi",
                          timeoutSeconds: 300),
                    .init(id: "lint", name: "Lint", stageId: "refine",
                          command: "if [ -f package.json ] && jq -e '.scripts.lint' package.json >/dev/null 2>&1; then npm run lint 2>&1; else echo 'no lint configured' && exit 0; fi")
                ]
            ),
            .init(
                id: "launch",
                title: "Launch",
                purpose: "Tell people. Coordinate the message across channels. Don't half-launch.",
                methodology: "A launch is a coordinated moment, not a quiet release. Pick the channels your ICP actually reads.",
                guidingQuestions: [
                    "Where does your ICP actually hang out?",
                    "What's the one-line message?",
                    "What does the landing page need (proof, demo, pricing, CTA)?",
                    "How will you handle inbound — support, demos, replies?",
                    "What does week-1 follow-up look like (posts, demos, emails)?"
                ],
                exitCriteria: [
                    "Landing page is live and clear",
                    "Launch announcement written",
                    "Channels chosen and posted to",
                    "Support path exists (email / Discord / etc.)"
                ]
            ),
            .init(
                id: "growth",
                title: "Grow",
                purpose: "Find the loops that compound. Avoid \"random acts of growth.\"",
                methodology: "Find one channel that works before adding a second. Retention before acquisition.",
                guidingQuestions: [
                    "Which channel is bringing users — and is it repeatable?",
                    "What's retention look like — and is it good enough to scale?",
                    "What are churned users telling you?",
                    "Are you pricing-tested?",
                    "What's the next experiment, and what would you learn from it?"
                ],
                exitCriteria: [
                    "1 acquisition channel that reliably works",
                    "Retention measured and acceptable",
                    "Pricing tested with 2+ tiers",
                    "Roadmap based on user signal"
                ]
            )
        ]
    )

    static let personalTool = LaunchTemplate(
        id: "personal-tool",
        name: "Personal Tool",
        summary: "A tool for you, first. Itch → sketch → live with it → refine → maybe share. No marketing, no users, no stress — just build the thing you wish existed.",
        methodology: """
        You are the user. Build for yourself, use it daily, fix what actually \
        annoys you (not what you imagine will annoy other people). Resist \
        polishing for an audience that doesn't exist. If it ends up useful \
        to others, that's a bonus — not the goal.
        """,
        stages: [
            .init(
                id: "itch",
                title: "Identify the itch",
                purpose: "Pin down the recurring annoyance. Personal tools work when they fix something real for you, not something speculative.",
                methodology: "If you can't name the moment of annoyance, you don't have an itch yet — you have a curiosity. Wait for the itch.",
                guidingQuestions: [
                    "What's the specific moment that annoys you?",
                    "How often does it happen — daily, weekly, monthly?",
                    "What's your current workaround — and why is it bad enough to replace?",
                    "Is this actually a tool problem, or a habit problem?",
                    "What's the rough shape of the fix in your head?"
                ],
                exitCriteria: [
                    "The annoyance written in one sentence",
                    "Frequency known (you've actually counted, not guessed)",
                    "Rough shape of the fix sketched"
                ]
            ),
            .init(
                id: "sketch",
                title: "Sketch the smallest version",
                purpose: "Build the crappiest possible version that solves the itch. No polish. No edge cases. No options. Make it work for you, today, in your one workflow.",
                methodology: "Hardcode everything. Skip auth. Skip config. Skip UI niceties. The goal is to use it, not to ship it.",
                guidingQuestions: [
                    "What's the dumbest possible version that works?",
                    "What can be hardcoded for now (paths, names, choices)?",
                    "What's the one workflow it must support?",
                    "What's NOT in v0 (write it down so you don't sneak it in)?",
                    "Where will it live — local script, menu bar app, web page on localhost?"
                ],
                exitCriteria: [
                    "It runs on your machine",
                    "It solves the itch in your one workflow",
                    "You haven't added a single feature beyond the itch"
                ]
            ),
            .init(
                id: "live-with-it",
                title: "Live with it",
                purpose: "Use it. Daily. Resist the urge to polish or feature-add until you actually feel the friction in real use.",
                methodology: "Don't open the editor for 1-2 weeks. Just use it. Take notes when something annoys you. The notes become the refine list.",
                guidingQuestions: [
                    "Have you actually used it for the original itch this week?",
                    "What new annoyances have you noticed (be specific)?",
                    "What feature did you almost add — and is the urge real or imagined?",
                    "What's missing that genuinely blocks you, vs. nice-to-have?"
                ],
                exitCriteria: [
                    "Used daily/weekly for at least 1-2 weeks",
                    "Friction list written (real annoyances, not imagined ones)",
                    "Nothing added during this stage"
                ]
            ),
            .init(
                id: "refine",
                title: "Refine the parts that hurt",
                purpose: "Fix the things you actually felt. Skip the things you only thought about. Resist scope creep.",
                methodology: "Sort the friction list by frequency × pain. Fix the top 3. Stop. Use it again.",
                guidingQuestions: [
                    "What's the #1 friction point — and is it about correctness, speed, or ergonomics?",
                    "Are you fixing real friction, or rebuilding because you're bored?",
                    "What would make this 50% better in daily use?",
                    "What can you delete — features you added that you don't use?"
                ],
                exitCriteria: [
                    "Top 3 friction points fixed",
                    "Unused features deleted (yes, deleted)",
                    "Tool still solves the original itch"
                ]
            ),
            .init(
                id: "maybe-share",
                title: "Maybe share it",
                purpose: "Optional. If it's useful to others without contorting your life, share it. If sharing means meetings, support, and feature debates — don't.",
                methodology: "Share at the level you can sustain. A README and a tweet is fine. Anything more is a commitment, treat it as one.",
                guidingQuestions: [
                    "Is sharing this going to obligate you (PRs, issues, support)?",
                    "What's the smallest possible share — gist, tweet, README, package?",
                    "Who would actually find this useful — not theoretical, real people?",
                    "Are you ready to say no to feature requests that aren't your itch?",
                    "Or — should you just keep it private and free?"
                ],
                exitCriteria: [
                    "Decision made: keep private, or share at level X",
                    "If sharing: README written, repo public, audience told",
                    "If keeping private: that's also a valid endpoint — close the project"
                ]
            )
        ]
    )

    static let contentSite = LaunchTemplate(
        id: "content-site",
        name: "Content / Tracker Site",
        summary: "Niche → build → index → monetize → compound. For blogs, trackers, aggregators, review sites — anything that grows on traffic and monetizes via ads, affiliates, or sponsorship.",
        methodology: """
        The site is a content engine, not an app. Pick a niche narrow enough \
        that you can dominate it. Get pages indexed before you optimize \
        monetization — no traffic, no revenue. Treat each post as a unit and \
        compound by replicating what works, not by chasing every topic.
        """,
        stages: [
            .init(
                id: "niche",
                title: "Pick the niche & angle",
                purpose: "Specificity wins. \"Tech blog\" loses. \"Reviews of CLI tools for Mac developers\" wins. Pick a beachhead narrow enough to dominate.",
                methodology: "Specific niche + clear angle + sustainable interest = compounding. Skip any of those and the site stalls.",
                guidingQuestions: [
                    "What topic — specific enough that you can name the reader in one phrase?",
                    "Who's the reader, exactly (role, situation, what they want from the site)?",
                    "What angle / POV do you have that existing sites don't?",
                    "Is this evergreen content or news-cycle? Pick one — they need different stacks.",
                    "What's the smallest beachhead topic you can own before expanding?",
                    "Name 3 competitor sites — what do they get wrong, and what do they do well?"
                ],
                exitCriteria: [
                    "Niche written down (specific enough one reader can be named)",
                    "Reader persona sketched",
                    "Unique angle / POV stated",
                    "3 competitor sites studied",
                    "Beachhead topic chosen"
                ]
            ),
            .init(
                id: "build",
                title: "Build the site & content engine",
                purpose: "Set up the shell and seed it with enough content that the niche is recognizable. The publishing flow matters more than the design.",
                methodology: "Cadence > volume. A flow you can sustain for 12 months beats a perfect setup you abandon in 3.",
                guidingQuestions: [
                    "What stack (static + markdown / Astro / Next / WordPress / something else)?",
                    "Where does writing happen — markdown in repo, headless CMS, Notion + sync?",
                    "What's the publishing cadence you can actually sustain (weekly? bi-weekly?)",
                    "What are the first 5-10 pieces — and do they collectively define the niche?",
                    "Is SEO foundation in place (sitemap.xml, OG tags, schema markup, semantic HTML)?",
                    "What's the URL structure — and will you regret it in 2 years?"
                ],
                exitCriteria: [
                    "Site live with 5-10 pieces of content",
                    "Publishing flow exists end-to-end",
                    "Sitemap + OG + analytics installed",
                    "URL structure stable"
                ]
            ),
            .init(
                id: "index",
                title: "Get indexed & found",
                purpose: "Indexing precedes traffic. Get into search consoles and aggregators before optimizing monetization.",
                methodology: "Backlinks compound; one good link from a niche site beats ten random ones. Patience here pays.",
                guidingQuestions: [
                    "Submitted to Google Search Console + Bing Webmaster?",
                    "What's indexed vs. discovered-but-not-indexed in Search Console?",
                    "Where could you get 3-5 niche-relevant backlinks (HN, Reddit, niche newsletters, directories)?",
                    "What internal linking structure makes pages findable from each other?",
                    "What's the first piece of \"link bait\" content (data study, definitive guide, tool)?",
                    "What's organic traffic doing week-over-week?"
                ],
                exitCriteria: [
                    "Site verified in Search Console",
                    "80%+ of pages indexed",
                    "3+ relevant backlinks",
                    "Organic traffic measurable"
                ]
            ),
            .init(
                id: "monetize",
                title: "Monetize",
                purpose: "Pick the revenue mechanism that fits the niche, not the one that pays best on average. Affiliate review sites and ad-funded blogs need different layouts.",
                methodology: "Match monetization to reader intent. Don't bolt ads onto a how-to site without thinking about user flow.",
                guidingQuestions: [
                    "Which mechanism fits — display ads, affiliates, sponsorships, paid newsletter, digital products?",
                    "What's realistic RPM/RPS for your niche (research, not assume)?",
                    "Display ads: AdSense first, then graduate to Mediavine/Ezoic at threshold (50k sessions/mo)?",
                    "Affiliates: which programs match the niche (Amazon, niche-specific, SaaS deals)?",
                    "Are pages designed around the monetization, or fighting it?",
                    "What's a single \"money page\" you can optimize first?"
                ],
                exitCriteria: [
                    "Monetization live (one mechanism, not three half-done)",
                    "First $1+ earned",
                    "1 \"money page\" identified and intentionally designed",
                    "Tracking set up to attribute revenue per page"
                ]
            ),
            .init(
                id: "compound",
                title: "Compound",
                purpose: "Replicate what works, refresh what's aging, build retention. This is the long game.",
                methodology: "Top 10% of posts drive 80% of traffic. Find them and make more like them. Refresh evergreen content yearly.",
                guidingQuestions: [
                    "Which 5-10 posts are driving most of the traffic — and what do they have in common?",
                    "Can you make 10 more posts like the top performers?",
                    "What's the email / RSS retention mechanism (newsletter, follow button, RSS link)?",
                    "What evergreen pieces are aging and need a refresh?",
                    "Where's the bottleneck — writing speed, ranking, conversion to revenue?",
                    "What experiment will you run next, and what would you learn from it?"
                ],
                exitCriteria: [
                    "Sustainable cadence held for 4+ weeks",
                    "Top performers identified and replicated",
                    "Retention mechanism live (email or RSS)",
                    "1 evergreen piece refreshed and showing improvement",
                    "Bottleneck named — and the next experiment chosen"
                ]
            )
        ]
    )

    static let marketingSite = LaunchTemplate(
        id: "marketing-site",
        name: "Marketing Site",
        summary: "Audience → message → site → ship → measure. For landing pages, brochureware, content sites.",
        methodology: """
        Don't write copy for everyone. Pick a person and write to them. The \
        site exists to do one job — make sure that job is unmistakable.
        """,
        stages: [
            .init(
                id: "audience",
                title: "Define audience & message",
                purpose: "Don't write copy for everyone. Pick a person and write to them.",
                methodology: "Specific > clever. The headline should make the right person stop scrolling.",
                guidingQuestions: [
                    "Who specifically should this site convince?",
                    "What outcome do they want?",
                    "What's the headline (state the outcome, not the mechanism)?",
                    "What 3 things matter most to them?",
                    "What's the single CTA?"
                ],
                exitCriteria: [
                    "ICP written down",
                    "Headline + subhead approved",
                    "3 key value props chosen",
                    "Primary CTA chosen"
                ]
            ),
            .init(
                id: "build",
                title: "Build the site",
                purpose: "Fast, on-brand, accessible. No CMS yet unless you really need one.",
                methodology: "Static beats dynamic. Performance is a feature.",
                guidingQuestions: [
                    "What's the stack (static / Next / Astro / something else)?",
                    "What sections does the page need (hero, features, social proof, FAQ, CTA)?",
                    "What's the visual identity?",
                    "How does it look on mobile?"
                ],
                exitCriteria: [
                    "Hero + 3 sections live",
                    "CTA wired to a real destination",
                    "Mobile-clean",
                    "Lighthouse perf > 90"
                ]
            ),
            .init(
                id: "ship",
                title: "Ship",
                purpose: "Domain, deploy, analytics, share.",
                methodology: "Don't push the button until tracking and OG are right — relaunches are awkward.",
                guidingQuestions: [
                    "What domain? Is DNS pointed?",
                    "What analytics — and what's the conversion event?",
                    "Are OG / Twitter card meta set?",
                    "Where will you share it first?"
                ],
                exitCriteria: [
                    "Custom domain live",
                    "Analytics installed",
                    "Open Graph tags set",
                    "Site shared in 3+ places"
                ]
            ),
            .init(
                id: "measure",
                title: "Measure & iterate",
                purpose: "What's working? Iterate on the message and the conversion paths.",
                methodology: "One change at a time. Compare conversion, not vibes.",
                guidingQuestions: [
                    "What's the conversion metric — and what's the current rate?",
                    "Where do visitors drop off?",
                    "What's your first A/B test (probably the headline)?",
                    "What did you learn — and what's next?"
                ],
                exitCriteria: [
                    "Conversion metric defined and measured",
                    "1 A/B test run",
                    "1 message change based on data"
                ]
            )
        ]
    )
}
