import Foundation

/// Headless deterministic checks for PolicyStore + policy querying.
///   DevDash --selftest-policy
/// Runs entirely in a fresh temp directory, prints PASS/FAIL per check, exits.
enum PolicySelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-policy") else { return }
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    private static func run() -> Never {
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { print("  ok   \(label)") }
            else     { failures.append(label); print("  FAIL \(label)") }
        }

        checkPolicyReadRoundTrip(check)
        checkPolicyQuery(check)
        checkBreakdownPrompt(check)

        let msg = failures.isEmpty
            ? "policy-selftest: ALL PASS"
            : "policy-selftest: \(failures.count) FAILURE(S)"
        print(msg)
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func makeTempProject(_ suffix: String) -> String {
        let dir = NSTemporaryDirectory() + "devdash-policy-selftest-\(suffix)"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writePolicy(_ projectPath: String, filename: String, contents: String) {
        let dir = "\(projectPath)/docs/policies"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? contents.write(toFile: "\(dir)/\(filename)", atomically: true, encoding: .utf8)
    }

    private static func checkPolicyReadRoundTrip(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("read")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        writePolicy(proj, filename: "0001-breakdown.md", contents: """
        ---
        lore_type: policy
        title: Break tickets into tasks
        applies_to: ticket, task
        trigger: on_demand, on_work
        status: active
        priority: 10
        ---
        Break a ticket into child tasks when appropriate.
        Output each as: `TASK: <title>`
        """)

        let policies = PolicyStore.read(proj)
        guard let p = policies.first(where: { $0.id == "0001" }) else {
            check(false, "read: policy 0001 not found"); return
        }
        check(p.title == "Break tickets into tasks", "read: title round-trip")
        check(p.appliesTo == ["ticket", "task"],     "read: applies_to comma-list parsed")
        check(p.trigger == ["on_demand", "on_work"], "read: trigger comma-list parsed")
        check(p.status == .active,                    "read: status parsed")
        check(p.priority == 10,                       "read: priority parsed")
        check(p.body.contains("TASK: <title>"),       "read: body captured")
    }

    @MainActor
    private static func checkPolicyQuery(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("query")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        // active ticket policy, priority 20
        writePolicy(proj, filename: "0001-a.md", contents: """
        ---
        lore_type: policy
        title: A
        applies_to: [ticket]
        trigger: [on_demand]
        status: active
        priority: 20
        ---
        body A
        """)
        // active ticket policy, priority 5 (should sort first)
        writePolicy(proj, filename: "0002-b.md", contents: """
        ---
        lore_type: policy
        title: B
        applies_to: [any]
        trigger: [on_demand, on_work]
        status: active
        priority: 5
        ---
        body B
        """)
        // draft — must be excluded
        writePolicy(proj, filename: "0003-c.md", contents: """
        ---
        lore_type: policy
        title: C
        applies_to: [ticket]
        trigger: [on_demand]
        status: draft
        ---
        body C
        """)
        // wrong trigger — excluded for on_demand
        writePolicy(proj, filename: "0004-d.md", contents: """
        ---
        lore_type: policy
        title: D
        applies_to: [ticket]
        trigger: [always]
        status: active
        ---
        body D
        """)

        let store = DashboardStore()
        let onDemand = store.policies(for: proj, appliesTo: "ticket", trigger: "on_demand")
        check(onDemand.map { $0.id } == ["0002", "0001"],
              "query: active+scope+trigger, ordered by priority (B before A)")
        check(!onDemand.contains { $0.id == "0003" }, "query: draft excluded")
        check(!onDemand.contains { $0.id == "0004" }, "query: wrong-trigger excluded")
        check(onDemand.contains { $0.id == "0002" },  "query: 'any' scope matches ticket")

        let onWork = store.policies(for: proj, appliesTo: "ticket", trigger: "on_work")
        check(onWork.map { $0.id } == ["0002"], "query: on_work matches only B")
    }

    @MainActor
    private static func checkBreakdownPrompt(_ check: (Bool, String) -> Void) {
        let proj = makeTempProject("prompt")
        defer { try? FileManager.default.removeItem(atPath: proj) }

        writePolicy(proj, filename: "0001-breakdown.md", contents: """
        ---
        lore_type: policy
        title: Break tickets into tasks
        applies_to: [ticket]
        trigger: [on_demand, on_work]
        status: active
        ---
        POLICY_MARKER produce 3-6 tasks. Output each as: `TASK: <title>`
        """)

        let store = DashboardStore()
        store.reloadPolicies(for: proj)

        let ticket = Ticket(
            id: "0007", title: "Implement login", status: .open, owner: .none,
            category: .engineering, pr: nil, createdAt: Date(), completedAt: nil,
            notes: "Email + password.", priority: nil, effort: nil
        )

        let quick = store.buildTicketBreakdownPrompt(
            ticket: ticket, existingTaskTitles: ["Add form UI"], projectPath: proj, deep: false)
        check(quick.contains("POLICY_MARKER"),        "prompt: injects policy body")
        check(quick.contains("Implement login"),       "prompt: includes ticket title")
        check(quick.contains("Email + password."),     "prompt: includes ticket notes")
        check(quick.contains("Add form UI"),           "prompt: lists existing tasks (dedupe)")
        check(quick.contains("TASK:"),                 "prompt: carries TASK: instruction")

        let deep = store.buildTicketBreakdownPrompt(
            ticket: ticket, existingTaskTitles: [], projectPath: proj, deep: true)
        check(deep.lowercased().contains("read"),      "prompt: deep mode invites reading code")

        let policyText = store.ticketPolicyText(projectPath: proj, trigger: "on_work")
        check(policyText.contains("POLICY_MARKER"),    "policyText: on_work returns body")
    }
}
