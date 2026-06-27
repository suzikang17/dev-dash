import Foundation

/// Headless deterministic checks for PolicyStore + policy querying.
///   DevDash --selftest-policy
/// Runs entirely in a fresh temp directory, prints PASS/FAIL per check, exits.
enum PolicySelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest-policy") else { return }
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { print("  ok   \(label)") }
            else     { failures.append(label); print("  FAIL \(label)") }
        }

        checkPolicyReadRoundTrip(check)

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
}
