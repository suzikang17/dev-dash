import SwiftUI

/// Holds the active detail tab, split out of `DashboardStore` so switching tabs
/// (⌘1–9, the toolbar picker) only re-renders the views that actually consume
/// it — `DetailPaneView` and the toolbar `Picker` — instead of republishing the
/// whole store and re-rendering the sidebar and every row.
///
/// Per-project tab memory lives here too. `DashboardStore` owns one instance and
/// feeds it the current selection's key via `selectionChanged(toKey:)` (the key
/// derivation needs the store's `projects`/`services`).
@MainActor
final class TabStore: ObservableObject {
    @Published var detailTab: DetailTab = .info {
        didSet { persist() }
    }

    private let memoryKey = "devdash.lastTabPerProject"
    private var currentKey: String?
    /// Guards the restore path so applying a remembered tab doesn't immediately
    /// re-persist it.
    private var isRestoring = false

    private var memory: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: memoryKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: memoryKey) }
    }

    /// Called by the store whenever the selection changes. Restores the tab last
    /// used for that project (if any), without triggering a persist.
    func selectionChanged(toKey key: String?) {
        currentKey = key
        guard let key,
              let raw = memory[key],
              let tab = DetailTab(rawValue: raw),
              detailTab != tab else { return }
        isRestoring = true
        detailTab = tab
        isRestoring = false
    }

    private func persist() {
        guard !isRestoring, let key = currentKey else { return }
        var m = memory
        m[key] = detailTab.rawValue
        memory = m
    }
}
