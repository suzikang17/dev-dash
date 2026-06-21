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
}
