import SwiftUI

// MARK: - Canvas data model

/// What a canvas panel renders. Reuses existing views as panel bodies.
enum PanelKind: Codable, Hashable {
    case view(DetailTab)        // Info, Claude, Tasks, Product, Changes, Logs, Today
    case preview                // web preview for the project
    case simulator              // iOS simulator embed (project-scoped)
    case terminal(id: UUID)     // a live shell, keyed independently

    var label: String {
        switch self {
        case .view(let t): return t.label
        case .preview:     return "Preview"
        case .simulator:   return "Simulator"
        case .terminal:    return "Terminal"
        }
    }

    var systemImage: String {
        switch self {
        case .view(let t): return t.systemImage
        case .preview:     return "globe"
        case .simulator:   return "iphone"
        case .terminal:    return "terminal"
        }
    }

    // Codable: tag + associated value, hand-rolled so DetailTab/UUID encode cleanly.
    private enum CodingKeys: String, CodingKey { case kind, tab, terminalID }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .view(let t):
            try c.encode("view", forKey: .kind)
            try c.encode(t.rawValue, forKey: .tab)
        case .preview:
            try c.encode("preview", forKey: .kind)
        case .simulator:
            try c.encode("simulator", forKey: .kind)
        case .terminal(let id):
            try c.encode("terminal", forKey: .kind)
            try c.encode(id, forKey: .terminalID)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "view":
            let raw = try c.decode(String.self, forKey: .tab)
            self = .view(DetailTab(rawValue: raw) ?? .info)
        case "simulator": self = .simulator
        case "terminal":  self = .terminal(id: try c.decode(UUID.self, forKey: .terminalID))
        default:          self = .preview
        }
    }
}

/// One panel on the canvas: what it shows, where it sits, and its stacking order.
struct CanvasPanel: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: PanelKind
    var frame: CGRect    // position + size on the board (board coordinates)
    var z: Int           // higher = front
}

/// A project's canvas: its panels and the board's pan offset.
struct CanvasLayout: Codable {
    var panels: [CanvasPanel] = []
    var pan: CGSize = .zero
}

// MARK: - CanvasStore

/// Per-project freeform canvas state, split out of `DashboardStore` (like `TabStore`)
/// so panel drags/resizes don't republish the large store. Layouts + which projects
/// are in canvas mode are persisted to UserDefaults as JSON.
@MainActor
final class CanvasStore: ObservableObject {
    @Published private(set) var layouts: [String: CanvasLayout] = [:]
    @Published private(set) var enabled: Set<String> = []

    private let layoutsKey = "devdash.canvas.layouts"
    private let enabledKey = "devdash.canvas.enabled"

    init() {
        if let data = UserDefaults.standard.data(forKey: layoutsKey),
           let decoded = try? JSONDecoder().decode([String: CanvasLayout].self, from: data) {
            layouts = decoded
        }
        enabled = Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? [])
    }

    // MARK: Mode

    func isCanvasMode(_ path: String) -> Bool { enabled.contains(path) }

    func setCanvasMode(_ on: Bool, for path: String) {
        if on { enabled.insert(path) } else { enabled.remove(path) }
        persistEnabled()
    }

    func toggleCanvasMode(_ path: String) {
        setCanvasMode(!isCanvasMode(path), for: path)
    }

    // MARK: Layout access

    func layout(for path: String) -> CanvasLayout { layouts[path] ?? CanvasLayout() }

    func setPan(_ pan: CGSize, for path: String) {
        var l = layout(for: path)
        l.pan = pan
        layouts[path] = l
        persistLayouts()
    }

    // MARK: Panel ops

    /// Spawn a panel of `kind`, placed near the top-left of the current viewport
    /// (accounting for pan), stacked on top.
    func addPanel(kind: PanelKind, for path: String) {
        var l = layout(for: path)
        let topZ = (l.panels.map(\.z).max() ?? 0) + 1
        // Cascade new panels so they don't all stack exactly.
        let n = CGFloat(l.panels.count % 6)
        let origin = CGPoint(x: -l.pan.width + 60 + n * 28, y: -l.pan.height + 60 + n * 28)
        let size = defaultSize(for: kind)
        l.panels.append(CanvasPanel(id: UUID(), kind: kind,
                                    frame: CGRect(origin: origin, size: size), z: topZ))
        layouts[path] = l
        persistLayouts()
    }

    func updateFrame(_ id: UUID, frame: CGRect, for path: String) {
        var l = layout(for: path)
        guard let i = l.panels.firstIndex(where: { $0.id == id }) else { return }
        l.panels[i].frame = frame
        layouts[path] = l
        persistLayouts()
    }

    func removePanel(_ id: UUID, for path: String) {
        var l = layout(for: path)
        l.panels.removeAll { $0.id == id }
        layouts[path] = l
        persistLayouts()
    }

    /// Bring a panel to the front (highest z).
    func raise(_ id: UUID, for path: String) {
        var l = layout(for: path)
        guard let i = l.panels.firstIndex(where: { $0.id == id }) else { return }
        let topZ = (l.panels.map(\.z).max() ?? 0)
        guard l.panels[i].z != topZ else { return }
        l.panels[i].z = topZ + 1
        layouts[path] = l
        persistLayouts()
    }

    // MARK: Helpers

    private func defaultSize(for kind: PanelKind) -> CGSize {
        switch kind {
        case .simulator: return CGSize(width: 460, height: 720)
        case .preview:   return CGSize(width: 520, height: 420)
        case .terminal:  return CGSize(width: 520, height: 320)
        case .view:      return CGSize(width: 460, height: 480)
        }
    }

    private func persistLayouts() {
        if let data = try? JSONEncoder().encode(layouts) {
            UserDefaults.standard.set(data, forKey: layoutsKey)
        }
    }

    private func persistEnabled() {
        UserDefaults.standard.set(Array(enabled), forKey: enabledKey)
    }
}
