import SwiftUI
import AppKit

@main
struct DevDashApp: App {
    @StateObject private var store = DashboardStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Dev Dashboard", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
                .sheet(isPresented: Binding(
                    get: { store.openSessionId != nil },
                    set: { if !$0 { store.openSessionId = nil } }
                )) {
                    if let id = store.openSessionId {
                        SessionDetailView(sessionId: id)
                            .environmentObject(store)
                    }
                }
                .task {
                    if store.selection == nil { store.selection = .home }
                    await store.reattachManagedServers()
                    await store.refreshAll()
                    await store.refreshTodos()
                    store.startAutoRefresh()
                    Task { await store.refreshIssues() }
                    store.refreshHeatmaps()
                    store.refreshRecentCommits()
                    store.refreshSessionDigests()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)

        MenuBarExtra(content: {
            MenuBarView()
                .environmentObject(store)
                .frame(width: 320)
        }, label: {
            MenuBarLabel(count: store.devServices.count)
        })
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let count: Int
    var body: some View {
        if count == 0 {
            Image(systemName: "server.rack")
        } else {
            HStack(spacing: 3) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .imageScale(.small)
                Text(verbatim: String(count))
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
