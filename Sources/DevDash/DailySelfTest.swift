import Foundation

/// Headless deterministic checks for the daily-page logic. Mirrors TerminalSelfTest:
///   DevDash --daily-selftest
/// Runs in-memory + temp-dir assertions, prints PASS/FAIL, exits (0 = all pass).
enum DailySelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--daily-selftest") else { return }
        var failures: [String] = []
        func check(_ cond: Bool, _ label: String) {
            if cond { FileHandle.standardError.write(Data("  ok: \(label)\n".utf8)) }
            else { failures.append(label); FileHandle.standardError.write(Data("  FAIL: \(label)\n".utf8)) }
        }

        roundTrip(check)

        let msg = failures.isEmpty
            ? "daily-selftest: ALL PASS\n"
            : "daily-selftest: \(failures.count) FAILURE(S)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func roundTrip(_ check: (Bool, String) -> Void) {
        let md = "- a\n  - b\n  - c\n- d\n"
        let nodes = DayOutline.parse(md)
        check(nodes.count == 2, "parse: 2 top-level nodes")
        check(nodes.first?.text == "a", "parse: first node text == a")
        check(nodes.first?.children.count == 2, "parse: 'a' has 2 children")
        check(nodes.first?.children.first?.text == "b", "parse: first child == b")
        check(DayOutline.serialize(nodes) == md, "round-trip: serialize(parse(md)) == md")

        let empty = DayOutline.parse("")
        check(empty.isEmpty, "parse: empty string -> []")

        // Tolerant: malformed (non-list) content becomes a single bullet, never dropped.
        let raw = DayOutline.parse("just some prose\nmore prose")
        check(raw.count == 1, "parse: non-list prose -> 1 fallback node")
        check(raw.first?.text.contains("just some prose") == true, "parse: prose preserved")
    }
}
