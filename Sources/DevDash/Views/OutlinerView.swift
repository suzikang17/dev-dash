import SwiftUI

/// One day's editable bullet outline. Pure-ish view over a [DayNode] binding —
/// all tree mutations go through DayOutline so they stay testable.
struct OutlinerView: View {
    @Binding var nodes: [DayNode]
    let projectPath: String
    var onOpenDoc: (String) -> Void = { _ in }
    /// When true, focus the first bullet as soon as content is available (used by the
    /// doc pane so clicking a page drops you straight into editing).
    var autofocus: Bool = false
    @State private var pickerNodeId: UUID?

    @State private var focusedId: UUID?
    @State private var caretToEnd = false
    @State private var didAutofocus = false

    private var firstVisibleID: UUID? {
        DayOutline.flatten(nodes, includeCollapsedChildren: false).first?.node.id
    }

    var body: some View {
        let rows = DayOutline.flatten(nodes, includeCollapsedChildren: false)
        VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty {
                Button { startFirstBullet() } label: {
                    Text("Start typing…").foregroundColor(.secondary).font(DSFont.body)
                }
                .buttonStyle(.plain)
            }
            ForEach(rows, id: \.node.id) { row in
                HStack(alignment: .top, spacing: DSSpace.xs) {
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                        .padding(.top, 7)
                    if focusedId == row.node.id {
                        BulletRow(
                            text: binding(for: row.node.id),
                            isFocused: true,
                            caretToEnd: caretToEnd,
                            onKey: { handle($0, on: row.node.id) },
                            onFocus: { focusedId = row.node.id; caretToEnd = false }
                        )
                    } else {
                        BulletRendered(
                            text: row.node.text,
                            onOpenLink: { openLink($0) },
                            onEdit: { focusedId = row.node.id; caretToEnd = true }
                        )
                    }
                    Button { pickerNodeId = row.node.id } label: {
                        Image(systemName: "number").font(.caption2).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Turn into a typed doc")
                    .popover(isPresented: Binding(
                        get: { pickerNodeId == row.node.id },
                        set: { if !$0 { pickerNodeId = nil } })) {
                        supertagPicker(for: row.node.id)
                    }
                }
                .padding(.leading, CGFloat(row.depth) * 18)
            }
        }
        .animation(.default, value: rows.count)
        .onAppear { autofocusIfNeeded() }
        .onChange(of: firstVisibleID) { _, _ in autofocusIfNeeded() }
    }

    /// Focus the first bullet once, when autofocus is requested and content exists.
    private func autofocusIfNeeded() {
        guard autofocus, !didAutofocus, let id = firstVisibleID else { return }
        focusedId = id
        caretToEnd = true
        didAutofocus = true
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { DayOutline.flatten(nodes, includeCollapsedChildren: true).first { $0.node.id == id }?.node.text ?? "" },
            set: { newText in
                nodes = DayOutline.update(id, text: newText, in: nodes)
                // Inline supertag: typing "title #task " (trailing space) commits the tag.
                if let tag = Self.inlineSupertag(in: newText, committedBySpace: true) {
                    applyInlineTag(id: id, type: tag.type, title: tag.title)
                }
            }
        )
    }

    private func node(_ id: UUID) -> DayNode? {
        DayOutline.flatten(nodes, includeCollapsedChildren: true).first { $0.node.id == id }?.node
    }

    /// Resolve a `[[title]]` backlink to its lore doc and ask the host to open it.
    private func openLink(_ title: String) {
        let docs = LoreLinkIndex.allDocs(projectPath: projectPath, dirs: LoreLinkIndex.allDirs)
        if let hit = docs.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            onOpenDoc("\(projectPath)/docs/\(hit.path)")
        }
    }

    private func startFirstBullet() {
        let n = DayNode(text: "")
        nodes = [n]; focusedId = n.id; caretToEnd = true
    }

    private func handle(_ key: BulletKey, on id: UUID) {
        switch key {
        case .enterNew:
            // If the bullet ends in a "#task" tag, Enter commits the tag instead of
            // making a new sibling.
            if let n = node(id), let tag = Self.inlineSupertag(in: n.text, committedBySpace: false) {
                applyInlineTag(id: id, type: tag.type, title: tag.title)
            } else {
                let r = DayOutline.insertSibling(after: id, in: nodes)
                nodes = r.nodes; focusedId = r.focus; caretToEnd = true
            }
        case .indent:
            nodes = DayOutline.indent(id, in: nodes)
        case .outdent:
            nodes = DayOutline.outdent(id, in: nodes)
        case .mergeBack:
            if let r = DayOutline.mergeIntoPrevious(id, in: nodes) {
                nodes = r.nodes; focusedId = r.focus; caretToEnd = true
            }
        case .focusUp:
            focusedId = neighbor(of: id, delta: -1) ?? focusedId
        case .focusDown:
            focusedId = neighbor(of: id, delta: +1) ?? focusedId
        }
    }

    private func neighbor(of id: UUID, delta: Int) -> UUID? {
        let flat = DayOutline.flatten(nodes, includeCollapsedChildren: false)
        guard let i = flat.firstIndex(where: { $0.node.id == id }) else { return nil }
        let j = i + delta
        return flat.indices.contains(j) ? flat[j].node.id : nil
    }

    @ViewBuilder
    private func supertagPicker(for id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Turn into").font(.caption).foregroundColor(.secondary)
                .padding(.bottom, 2)
            ForEach(SupertagRegistry.all(), id: \.loreType) { type in
                Button { apply(type, to: id) } label: {
                    HStack { Text("#\(type.loreType)"); Spacer(); Text(type.label).foregroundColor(.secondary) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3).padding(.horizontal, 6)
            }
        }
        .padding(8)
        .frame(width: 220)
    }

    /// Apply a supertag via the inline token: strip the "#task" text, then extract.
    private func applyInlineTag(id: UUID, type: SupertagType, title: String) {
        nodes = DayOutline.update(id, text: title, in: nodes)
        apply(type, to: id)
    }

    private func apply(_ type: SupertagType, to id: UUID) {
        pickerNodeId = nil
        // Defensive: if the bullet still carries a trailing "#task" token (e.g. the
        // button was used after typing one), drop it so the title is clean.
        if let n = node(id) {
            let cleaned = Self.strippedTrailingTag(n.text)
            if cleaned != n.text { nodes = DayOutline.update(id, text: cleaned, in: nodes) }
        }
        guard let ex = LoreDocWriter.extract(nodeId: id, type: type, from: nodes) else { return }
        let before = nodes
        nodes = ex.mutatedNodes                                  // optimistic: show backlink
        Task {
            let ok = await LoreDocWriter.commit(projectPath: projectPath, type: type, result: ex)
            if !ok { await MainActor.run { nodes = before } }    // revert on failure
        }
    }

    // MARK: - Inline supertag parsing

    /// Detects a trailing `#<knownType>` token in a bullet and returns the matched
    /// type plus the title with the token removed. `committedBySpace` requires a
    /// trailing space (the space keystroke commits); otherwise the token may sit at
    /// the very end (Enter commits). The token must be the LAST thing in the bullet,
    /// must be a known lore type, and must leave a non-empty title — so "#taskforce",
    /// "use #task force", "#unknown", and a bare "#task" never fire.
    private static func inlineSupertag(in text: String, committedBySpace: Bool) -> (type: SupertagType, title: String)? {
        let names = SupertagRegistry.all().map { $0.loreType }.joined(separator: "|")
        let tail = committedBySpace ? "\\s+$" : "\\s*$"
        let pattern = "^(.*?)\\s*#(\(names))\(tail)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let typeName = ns.substring(with: m.range(at: 2)).lowercased()
        guard !title.isEmpty, let type = SupertagRegistry.find(typeName) else { return nil }
        return (type, title)
    }

    /// Removes a trailing `#<knownType>` token from a title (used by the button path).
    private static func strippedTrailingTag(_ text: String) -> String {
        let names = SupertagRegistry.all().map { $0.loreType }.joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: "\\s*#(\(names))\\s*$", options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
    }
}
