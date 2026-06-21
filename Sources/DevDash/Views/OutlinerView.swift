import SwiftUI

/// One day's editable bullet outline. Pure-ish view over a [DayNode] binding —
/// all tree mutations go through DayOutline so they stay testable.
struct OutlinerView: View {
    @Binding var nodes: [DayNode]
    var onSupertag: (UUID) -> Void

    @State private var focusedId: UUID?
    @State private var caretToEnd = false

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
                    BulletRow(
                        text: binding(for: row.node.id),
                        isFocused: focusedId == row.node.id,
                        caretToEnd: caretToEnd && focusedId == row.node.id,
                        onKey: { handle($0, on: row.node.id) },
                        onFocus: { focusedId = row.node.id; caretToEnd = false }
                    )
                    Button { onSupertag(row.node.id) } label: {
                        Image(systemName: "number").font(.caption2).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Turn into a typed doc")
                }
                .padding(.leading, CGFloat(row.depth) * 18)
            }
        }
        .animation(.default, value: rows.count)
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { DayOutline.flatten(nodes, includeCollapsedChildren: true).first { $0.node.id == id }?.node.text ?? "" },
            set: { nodes = DayOutline.update(id, text: $0, in: nodes) }
        )
    }

    private func startFirstBullet() {
        let n = DayNode(text: "")
        nodes = [n]; focusedId = n.id; caretToEnd = true
    }

    private func handle(_ key: BulletKey, on id: UUID) {
        switch key {
        case .enterNew:
            let r = DayOutline.insertSibling(after: id, in: nodes)
            nodes = r.nodes; focusedId = r.focus; caretToEnd = true
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
}
