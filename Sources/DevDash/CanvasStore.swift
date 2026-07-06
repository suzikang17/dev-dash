import SwiftUI

// MARK: - Canvas data model

/// What a canvas panel renders. Reuses existing views as panel bodies.
enum PanelKind: Codable, Hashable {
    case view(DetailTab)        // Info, Claude, Tasks, Product, Changes, Logs, Today
    case preview                // web preview for the project
    case simulator              // iOS simulator embed (project-scoped)
    case terminal(id: UUID)     // a live shell, keyed independently
    case browser                // general web browser (address bar + WKWebView)

    var label: String {
        switch self {
        case .view(let t): return t.label
        case .preview:     return "Preview"
        case .simulator:   return "Simulator"
        case .terminal:    return "Terminal"
        case .browser:     return "Browser"
        }
    }

    var systemImage: String {
        switch self {
        case .view(let t): return t.systemImage
        case .preview:     return "globe"
        case .simulator:   return "iphone"
        case .terminal:    return "terminal"
        case .browser:     return "safari"
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
        case .browser:
            try c.encode("browser", forKey: .kind)
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
        case "browser":   self = .browser
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
    /// When set, the panel shows this project instead of the canvas's project
    /// (optional so pre-existing persisted layouts decode as "follow canvas").
    var projectOverride: String? = nil
    /// Assigned ⌘1–9 slot: pressing it raises + centers this panel (canvas mode
    /// repurposes the tab shortcuts, which are inert while the canvas covers the
    /// tab body). Optional so old persisted layouts decode.
    var shortcut: Int? = nil
}

/// Selection override injected by canvas panels so the shared tab views render a
/// pinned project instead of the globally selected one. Views resolve their
/// project/service via `panelSelection ?? store.selection`.
private struct PanelSelectionKey: EnvironmentKey {
    static let defaultValue: Selection? = nil
}

extension EnvironmentValues {
    var panelSelection: Selection? {
        get { self[PanelSelectionKey.self] }
        set { self[PanelSelectionKey.self] = newValue }
    }
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

    /// Spawn a panel of `kind`, stacked on top. When `at` (a board-coordinate
    /// point, e.g. a right-click location) is given the panel's top-left lands
    /// there; otherwise new panels cascade near the top-left of the viewport.
    func addPanel(kind: PanelKind, for path: String, at boardOrigin: CGPoint? = nil) {
        var l = layout(for: path)
        let topZ = (l.panels.map(\.z).max() ?? 0) + 1
        let origin: CGPoint
        if let boardOrigin {
            origin = boardOrigin
        } else {
            // Cascade new panels so they don't all stack exactly.
            let n = CGFloat(l.panels.count % 6)
            origin = CGPoint(x: -l.pan.width + 60 + n * 28, y: -l.pan.height + 60 + n * 28)
        }
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

    /// Bring a panel to the front (highest z). Compacts z-values to 0..<count while
    /// it's at it, so they don't grow unboundedly across a long-lived layout.
    func raise(_ id: UUID, for path: String) {
        var l = layout(for: path)
        guard let i = l.panels.firstIndex(where: { $0.id == id }) else { return }
        let topZ = (l.panels.map(\.z).max() ?? 0)
        // Already front → no-op. Matters: raise fires on every content click.
        guard l.panels[i].z != topZ else { return }
        compactZ(&l, raising: i)
        layouts[path] = l
        persistLayouts()
    }

    /// Reassign z = rank order (0..<count) with panel `raisedIndex` on top.
    private func compactZ(_ l: inout CanvasLayout, raising raisedIndex: Int) {
        let raisedID = l.panels[raisedIndex].id
        let order = l.panels.indices.sorted {
            (l.panels[$0].id == raisedID ? Int.max : l.panels[$0].z)
                < (l.panels[$1].id == raisedID ? Int.max : l.panels[$1].z)
        }
        for (rank, idx) in order.enumerated() { l.panels[idx].z = rank }
    }

    /// Pin a panel to a specific project (nil = follow the canvas's project).
    func setProjectOverride(_ projectPath: String?, panel id: UUID, for path: String) {
        var l = layout(for: path)
        guard let i = l.panels.firstIndex(where: { $0.id == id }) else { return }
        l.panels[i].projectOverride = projectPath
        layouts[path] = l
        persistLayouts()
    }

    // MARK: Panel shortcuts (⌘1–9)

    /// Assign a ⌘N slot to a panel (nil clears). A slot is unique per canvas:
    /// assigning steals it from whichever panel held it.
    func setShortcut(_ n: Int?, panel id: UUID, for path: String) {
        var l = layout(for: path)
        guard let i = l.panels.firstIndex(where: { $0.id == id }) else { return }
        if let n {
            for j in l.panels.indices where l.panels[j].shortcut == n { l.panels[j].shortcut = nil }
        }
        l.panels[i].shortcut = n
        layouts[path] = l
        persistLayouts()
    }

    func panelID(forShortcut n: Int, in path: String) -> UUID? {
        layout(for: path).panels.first { $0.shortcut == n }?.id
    }

    /// One-shot "raise + center this panel" request, published so the visible
    /// CanvasView (which owns the live pan state) can act on it. The token makes
    /// repeated jumps to the same panel observable via onChange.
    struct JumpRequest: Equatable {
        let path: String
        let panelID: UUID
        let token: Int
    }
    @Published private(set) var jump: JumpRequest?

    func requestJump(to panelID: UUID, in path: String) {
        jump = JumpRequest(path: path, panelID: panelID, token: (jump?.token ?? 0) + 1)
    }

    // MARK: Helpers

    private func defaultSize(for kind: PanelKind) -> CGSize {
        switch kind {
        case .simulator: return CGSize(width: 460, height: 720)
        case .preview:   return CGSize(width: 520, height: 420)
        case .browser:   return CGSize(width: 640, height: 480)
        case .terminal:  return CGSize(width: 520, height: 320)
        case .view(let tab):
            // Two-pane views (list/timeline + detail) need ~640px+ to lay out — spawn
            // them wide/tall so they don't get crushed.
            switch tab {
            case .daily, .changes: return CGSize(width: 860, height: 560)
            case .tasks:           return CGSize(width: 820, height: 620)
            case .docs:            return CGSize(width: 880, height: 640)
            default:               return CGSize(width: 460, height: 480)
            }
        }
    }

    /// Debounced: drag-end paths fire updateFrame + raise back-to-back, and scroll
    /// panning commits repeatedly — one JSON encode after the burst is enough.
    private var persistTask: Task<Void, Never>?

    private func persistLayouts() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(self.layouts) {
                UserDefaults.standard.set(data, forKey: self.layoutsKey)
            }
        }
    }

    private func persistEnabled() {
        UserDefaults.standard.set(Array(enabled), forKey: enabledKey)
    }
}
