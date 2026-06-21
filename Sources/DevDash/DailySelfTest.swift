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
        outlineOps(check)

        let msg = failures.isEmpty
            ? "daily-selftest: ALL PASS\n"
            : "daily-selftest: \(failures.count) FAILURE(S)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func outlineOps(_ check: (Bool, String) -> Void) {
        let base = DayOutline.parse("- a\n- b\n  - c\n")
        let aId = base[0].id, bId = base[1].id

        // insertSibling after a -> a, NEW, b
        let ins = DayOutline.insertSibling(after: aId, in: base)
        check(ins.nodes.count == 3, "insertSibling: 3 top-level")
        check(ins.nodes[1].text == "" && ins.nodes[1].id == ins.focus, "insertSibling: focus on new empty node")

        // indent b -> a has child b (which has child c)
        let ind = DayOutline.indent(bId, in: base)
        check(ind.count == 1 && ind[0].children.count == 1, "indent: b becomes child of a")
        check(ind[0].children[0].children.first?.text == "c", "indent: b keeps its child c")

        // outdent c -> c becomes sibling of b under root
        let cId = base[1].children[0].id
        let outd = DayOutline.outdent(cId, in: base)
        check(outd.count == 3, "outdent: c lifted to top level (a,b,c)")

        // mergeIntoPrevious b -> a becomes "ab", c reparented under a
        let merged = DayOutline.mergeIntoPrevious(bId, in: base)
        check(merged?.nodes.count == 1, "merge: b folds into a")
        check(merged?.nodes.first?.text == "ab", "merge: text concatenated -> ab")
        check(merged?.nodes.first?.children.first?.text == "c", "merge: c reparented under a")
        check(DayOutline.mergeIntoPrevious(aId, in: base) == nil, "merge: first node returns nil")

        // flatten respects collapsed
        var coll = base; coll[1].collapsed = true
        let visible = DayOutline.flatten(coll, includeCollapsedChildren: false)
        check(visible.count == 2, "flatten: collapsed b hides c (a,b visible)")
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
