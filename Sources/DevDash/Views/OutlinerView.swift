import SwiftUI

/// One day's editable bullet outline. Pure-ish view over a [DayNode] binding —
/// all tree mutations go through DayOutline so they stay testable.
struct OutlinerView: View {
    @Binding var nodes: [DayNode]
    let projectPath: String
    @State private var pickerNodeId: UUID?

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

    private func apply(_ type: SupertagType, to id: UUID) {
        pickerNodeId = nil
        guard let ex = LoreDocWriter.extract(nodeId: id, type: type, from: nodes) else { return }
        let before = nodes
        nodes = ex.mutatedNodes                                  // optimistic: show backlink
        Task {
            let ok = await LoreDocWriter.commit(projectPath: projectPath, type: type, result: ex)
            if !ok { await MainActor.run { nodes = before } }    // revert on failure
        }
    }
}
