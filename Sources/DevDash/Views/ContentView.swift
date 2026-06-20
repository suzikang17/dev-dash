import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            DetailPaneView()
        }
        .navigationTitle(store.selection.map(titleFor) ?? "Dev Dashboard")
        .toolbar { toolbarContent }
        .background { tabShortcuts }
    }

    /// Hidden buttons binding ⌘1–9 to the nine detail tabs (only while a
    /// project/service is selected — home ignores detailTab). ⌘0 is Home.
    @ViewBuilder
    private var tabShortcuts: some View {
        if let sel = store.selection, sel != .home {
            ForEach(Array(DetailTab.allCases.prefix(9).enumerated()), id: \.offset) { idx, tab in
                Button("") { store.detailTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                store.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!store.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")
            .accessibilityLabel("Back")

            Button {
                store.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!store.canGoForward)
            .keyboardShortcut("]", modifiers: .command)
            .help("Forward (⌘])")
            .accessibilityLabel("Forward")
        }
        ToolbarItem(placement: .principal) {
            if let sel = store.selection, sel != .home {
                Picker("Mode", selection: $store.detailTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Label(tab.label, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: DSSpace.sm) {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    TimeAgoLabel()
                }
                Button {
                    store.terminalOpen.toggle()
                } label: {
                    Image(systemName: "terminal")
                }
                .keyboardShortcut("`", modifiers: .command)
                .disabled(store.project(for: store.selection) == nil)
                .help("Toggle terminal (⌘`)")
                .accessibilityLabel("Toggle terminal")
                Button {
                    Task { await store.refreshAll(); await store.refreshTodos() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh (⌘R)")
                .accessibilityLabel("Refresh")
            }
        }
    }

    private func titleFor(_ selection: Selection) -> String {
        switch selection {
        case .home:
            return "Dev Dashboard"
        case .service(let id):
            return store.services.first { $0.id == id }?.name ?? "Service"
        case .project(let path):
            return store.projects.first { $0.path == path }?.name ?? "Project"
        }
    }
}

private struct TimeAgoLabel: View {
    @EnvironmentObject var store: DashboardStore
    @State private var secondsAgo = 0
    @State private var timer: Timer?

    var body: some View {
        Text(secondsAgo == 0 ? "just now" : "\(secondsAgo)s ago")
            .font(DSFont.monoDigits(.caption2))
            .foregroundColor(.secondary)
            .onAppear { start() }
            .onChange(of: store.lastUpdated) { _ in secondsAgo = 0 }
    }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in secondsAgo += 1 }
        }
    }
}
