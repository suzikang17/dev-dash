import Foundation

/// One node in a day's bullet outline. `id`/`collapsed` are ephemeral UI state and
/// are NOT persisted; only `text` + nesting survive a round-trip to markdown.
struct DayNode: Identifiable, Equatable {
    let id: UUID
    var text: String
    var children: [DayNode]
    var collapsed: Bool

    init(id: UUID = UUID(), text: String, children: [DayNode] = [], collapsed: Bool = false) {
        self.id = id; self.text = text; self.children = children; self.collapsed = collapsed
    }
}

/// Pure markdown-list <-> [DayNode] parse/serialize. Indentation unit = 2 spaces/depth.
enum DayOutline {
    private static let indentUnit = 2

    static func serialize(_ nodes: [DayNode]) -> String {
        var out = ""
        func emit(_ node: DayNode, depth: Int) {
            let pad = String(repeating: " ", count: depth * indentUnit)
            out += "\(pad)- \(node.text)\n"
            for child in node.children { emit(child, depth: depth + 1) }
        }
        for node in nodes { emit(node, depth: 0) }
        return out
    }

    static func parse(_ markdown: String) -> [DayNode] {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        // Each non-empty line that is a list item ("- text", any indent). If NO line is a
        // list item, fall back to a single node holding the whole body (never drop content).
        struct Raw { let depth: Int; let text: String }
        var raws: [Raw] = []
        var sawListItem = false
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let leading = line.prefix { $0 == " " }.count
            let body = line.drop { $0 == " " }
            if body.hasPrefix("- ") || body == "-" {
                sawListItem = true
                let text = body.hasPrefix("- ") ? String(body.dropFirst(2)) : ""
                raws.append(Raw(depth: leading / indentUnit, text: text))
            } else if sawListItem {
                // continuation/wrapped line — append to previous node's text
                if let last = raws.popLast() {
                    raws.append(Raw(depth: last.depth, text: last.text + " " + line.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        if !sawListItem {
            return [DayNode(text: trimmed)]
        }

        // Build a flat array with each node's parent index (an ancestor stack tracks
        // the currently-open node at each depth), then assemble children bottom-up so
        // value-type DayNodes get their children before being copied into a parent.
        var flat: [(node: DayNode, parent: Int?)] = []
        var ancestors: [(idx: Int, depth: Int)] = []   // open ancestors, shallow->deep
        for raw in raws {
            while let last = ancestors.last, last.depth >= raw.depth { ancestors.removeLast() }
            let parent = ancestors.last?.idx
            flat.append((DayNode(text: raw.text), parent))
            ancestors.append((flat.count - 1, raw.depth))
        }

        var childrenOf: [Int: [DayNode]] = [:]
        var roots: [DayNode] = []
        for i in stride(from: flat.count - 1, through: 0, by: -1) {
            var n = flat[i].node
            n.children = childrenOf[i] ?? []
            if let p = flat[i].parent { childrenOf[p, default: []].insert(n, at: 0) }
            else { roots.insert(n, at: 0) }
        }
        return roots
    }

    // MARK: - Operations (value semantics; return new trees)

    static func update(_ id: UUID, text: String, in nodes: [DayNode]) -> [DayNode] {
        map(nodes) { n in if n.id == id { var m = n; m.text = text; return m }; return n }
    }

    static func insertSibling(after id: UUID, in nodes: [DayNode]) -> (nodes: [DayNode], focus: UUID) {
        let new = DayNode(text: "")
        func walk(_ list: [DayNode]) -> [DayNode] {
            var out: [DayNode] = []
            for n in list {
                var m = n
                m.children = walk(n.children)
                out.append(m)
                if n.id == id { out.append(new) }
            }
            return out
        }
        return (walk(nodes), new.id)
    }

    static func indent(_ id: UUID, in nodes: [DayNode]) -> [DayNode] {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else {
            return nodes.map { var m = $0; m.children = indent(id, in: $0.children); return m }
        }
        guard idx > 0 else { return nodes }     // no previous sibling -> no-op
        var out = nodes
        let moving = out.remove(at: idx)
        out[idx - 1].children.append(moving)
        return out
    }

    static func outdent(_ id: UUID, in nodes: [DayNode]) -> [DayNode] {
        // Find id among some parent's children; lift it to be the parent's next sibling.
        func walk(_ list: [DayNode]) -> [DayNode] {
            var out: [DayNode] = []
            for var parent in list {
                if let childIdx = parent.children.firstIndex(where: { $0.id == id }) {
                    let moving = parent.children.remove(at: childIdx)
                    out.append(parent)
                    out.append(moving)
                } else {
                    parent.children = walk(parent.children)
                    out.append(parent)
                }
            }
            return out
        }
        return walk(nodes)   // id at top level has no parent -> unchanged
    }

    static func mergeIntoPrevious(_ id: UUID, in nodes: [DayNode]) -> (nodes: [DayNode], focus: UUID?, caret: Int)? {
        let flat = flatten(nodes, includeCollapsedChildren: true)
        guard let pos = flat.firstIndex(where: { $0.node.id == id }), pos > 0 else { return nil }
        let prev = flat[pos - 1].node
        let cur = flat[pos].node
        let caret = prev.text.count
        var working = update(prev.id, text: prev.text + cur.text, in: nodes)
        // reparent cur's children under prev, then delete cur
        for child in cur.children { working = append(child, under: prev.id, in: working) }
        working = delete(id, in: working)
        return (working, prev.id, caret)
    }

    static func delete(_ id: UUID, in nodes: [DayNode]) -> [DayNode] {
        var out: [DayNode] = []
        for n in nodes where n.id != id {
            var m = n; m.children = delete(id, in: n.children); out.append(m)
        }
        return out
    }

    static func flatten(_ nodes: [DayNode], includeCollapsedChildren: Bool) -> [(node: DayNode, depth: Int)] {
        var out: [(DayNode, Int)] = []
        func walk(_ list: [DayNode], _ depth: Int) {
            for n in list {
                out.append((n, depth))
                if includeCollapsedChildren || !n.collapsed { walk(n.children, depth + 1) }
            }
        }
        walk(nodes, 0)
        return out
    }

    // MARK: - private helpers

    private static func map(_ nodes: [DayNode], _ f: (DayNode) -> DayNode) -> [DayNode] {
        nodes.map { n in var m = f(n); m.children = map(n.children, f); return m }
    }

    private static func append(_ child: DayNode, under parentId: UUID, in nodes: [DayNode]) -> [DayNode] {
        nodes.map { n in
            var m = n
            if n.id == parentId { m.children.append(child) }
            else { m.children = append(child, under: parentId, in: n.children) }
            return m
        }
    }
}
