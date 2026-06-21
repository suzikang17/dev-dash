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
        pageStoreIO(check)
        supertagRegistry(check)
        loreWriter(check)

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

    private static func pageStoreIO(_ check: (Bool, String) -> Void) {
        let tmp = NSTemporaryDirectory() + "ddtest-\(UUID().uuidString)"
        let docs = tmp + "/docs/notes"
        try? FileManager.default.createDirectory(atPath: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let date = "2026-06-21"
        let nodes = DayOutline.parse("- hello\n  - world\n")
        do {
            try DailyPageStore.write(projectPath: tmp, date: date, nodes: nodes)
        } catch { check(false, "pageStore: write threw \(error)"); return }

        let path = DailyPageStore.fileURL(projectPath: tmp, date: date).path
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check(raw.contains("title:"), "pageStore: frontmatter title written on create")
        check(raw.contains("- hello"), "pageStore: body serialized")

        let reloaded = DailyPageStore.load(projectPath: tmp, date: date)
        check(reloaded.first?.text == "hello", "pageStore: round-trip load text")
        check(reloaded.first?.children.first?.text == "world", "pageStore: round-trip load child")

        // Frontmatter (e.g. tags) preserved across re-write.
        var fm = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        fm = fm.replacingOccurrences(of: "title:", with: "tags: keep\ntitle:")
        try? fm.write(toFile: path, atomically: true, encoding: .utf8)
        try? DailyPageStore.write(projectPath: tmp, date: date, nodes: DayOutline.parse("- changed\n"))
        let raw2 = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check(raw2.contains("tags: keep"), "pageStore: preserves existing frontmatter on re-write")
        check(raw2.contains("- changed") && !raw2.contains("- hello"), "pageStore: body replaced")

        check(DailyPageStore.load(projectPath: tmp, date: "2099-01-01").isEmpty, "pageStore: missing file -> []")
    }

    private static func supertagRegistry(_ check: (Bool, String) -> Void) {
        let types = SupertagRegistry.all()
        let names = types.map(\.loreType)
        check(names.contains("task"), "registry: includes task")
        check(names.contains("idea"), "registry: includes idea")
        check(names.contains("decision"), "registry: includes decision")
        check(names.contains("kpi"), "registry: includes kpi")
        check(names.contains("devlog"), "registry: includes devlog")
        check(!names.contains("note"), "registry: note is default, not offered")
        check(SupertagRegistry.find("task")?.dir == "tasks", "registry: task dir == tasks")
        check(SupertagRegistry.find("kpi")?.dir == "kpis", "registry: kpi dir == kpis (plural)")
        check(SupertagRegistry.find("decision")?.bodyIsFree == false, "registry: decision is sections schema")
        check(SupertagRegistry.find("task")?.frontmatterFields.contains("status=open") == true,
              "registry: task seeds status=open")
    }

    private static func loreWriter(_ check: (Bool, String) -> Void) {
        let nodes = DayOutline.parse("- ship login\n  - add form\n  - wire api\n- other\n")
        let target = nodes[0].id

        guard let ex = LoreDocWriter.extract(nodeId: target, type: SupertagRegistry.find("task")!, from: nodes) else {
            check(false, "extract: returned nil"); return
        }
        check(ex.docTitle == "ship login", "extract: title from bullet text")
        check(ex.docBody.contains("- add form") && ex.docBody.contains("- wire api"), "extract: children become body")
        check(ex.backlink == "[[ship login]]", "extract: backlink token")
        check(ex.mutatedNodes[0].text == "[[ship login]]", "extract: bullet replaced with backlink")
        check(ex.mutatedNodes[0].children.isEmpty, "extract: children moved out of outline")
        check(ex.mutatedNodes.count == 2, "extract: sibling 'other' untouched")

        let task = LoreDocWriter.docContent(type: SupertagRegistry.find("task")!,
                                            title: "ship login", bodyMarkdown: "- add form", today: "2026-06-21")
        check(task.contains("status: open"), "docContent: task seeds status")
        check(task.contains("title: \"ship login\""), "docContent: title in frontmatter")

        let dec = LoreDocWriter.docContent(type: SupertagRegistry.find("decision")!,
                                           title: "use sqlite", bodyMarkdown: "because simple", today: "2026-06-21")
        check(dec.contains("date:"), "docContent: sections schema gets date")
        check(dec.contains("## Why this choice"), "docContent: decision scaffolds required H2s")

        // empty bullet cannot be extracted
        let empty = DayOutline.parse("- \n")
        check(LoreDocWriter.extract(nodeId: empty[0].id, type: SupertagRegistry.find("task")!, from: empty) == nil,
              "extract: empty bullet -> nil")
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
