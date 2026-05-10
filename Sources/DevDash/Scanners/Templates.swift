import Foundation

/// Hardcoded launch templates. Each template is a *methodology* — a sequence
/// of stages with guiding questions and exit criteria. The user (with the
/// tool's help) creates the actual tasks; nothing is auto-dumped into their
/// list.
enum Templates {
    static let all: [LaunchTemplate] = [saasMvp, library, marketingSite]

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

    static let library = LaunchTemplate(
        id: "library",
        name: "Open Source Library",
        summary: "Bones → polish → release → adoption. Optimized for code quality, docs, and discoverability.",
        methodology: """
        The README is the product. Names matter more than internals. Ship \
        small, document obsessively, and let adoption pull the roadmap.
        """,
        stages: [
            .init(
                id: "shape",
                title: "Shape the API",
                purpose: "Get the public surface right before you build the internals — names are the hardest part.",
                methodology: "Write the README before the code. The example is the spec.",
                guidingQuestions: [
                    "What's the 30-second pitch?",
                    "What does the simplest example look like?",
                    "What names did you almost pick — and why are these better?",
                    "Which license fits (MIT / Apache / BSD / something else)?",
                    "What's NOT in the v0 surface (be specific)?"
                ],
                exitCriteria: [
                    "README pitch + minimal example written",
                    "Public API sketched in one file",
                    "License decided"
                ]
            ),
            .init(
                id: "build",
                title: "Build it",
                purpose: "Implement the API; tests prove it works.",
                methodology: "Tests at the public surface, not the internals. Internals can change.",
                guidingQuestions: [
                    "What's the smallest implementation that passes the example?",
                    "What edge cases must work (and which can wait)?",
                    "What's the test strategy — unit, integration, snapshot?",
                    "What's CI doing — lint, test, build, publish?"
                ],
                exitCriteria: [
                    "Core API implemented",
                    "Test coverage on the public surface",
                    "CI green"
                ]
            ),
            .init(
                id: "polish",
                title: "Polish",
                purpose: "Docs, examples, error messages — the things that make people not give up.",
                methodology: "Every error message should suggest the fix. Every example should be paste-runnable.",
                guidingQuestions: [
                    "Are error messages actionable, or just descriptive?",
                    "Do you have basic / common / advanced examples?",
                    "Is there a CHANGELOG and what's the versioning scheme?",
                    "Where will users find docs (README, docs site, both)?"
                ],
                exitCriteria: [
                    "README has full feature coverage",
                    "Error messages are actionable",
                    "3+ working examples",
                    "Changelog started"
                ]
            ),
            .init(
                id: "release",
                title: "Release",
                purpose: "Ship 1.0 (or 0.1) and tell people.",
                methodology: "Pick channels by audience, not by reach. Library users live in different places than SaaS users.",
                guidingQuestions: [
                    "What version makes sense — 0.1, 0.x, or 1.0?",
                    "Where does your audience read about libraries (HN, Reddit, lobste.rs, lang-specific aggregators)?",
                    "What's the announcement story?",
                    "Where do issues / questions go?"
                ],
                exitCriteria: [
                    "Tagged release",
                    "Published to package registry",
                    "Announcement post written and shared"
                ]
            ),
            .init(
                id: "maintain",
                title: "Maintain & grow",
                purpose: "Respond to issues, ship features users actually need, build trust over time.",
                methodology: "Triage cadence > triage quality. Predictable beats thorough.",
                guidingQuestions: [
                    "What's your issue triage cadence?",
                    "How will external contributions get reviewed?",
                    "What's on the public roadmap?",
                    "What feature requests should you say no to?"
                ],
                exitCriteria: [
                    "Issue triage cadence defined",
                    "1+ external contributor",
                    "Roadmap published"
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
