import SwiftUI
import AppKit

@main
struct DevDashApp: App {
    @StateObject private var store = DashboardStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        TerminalSelfTest.runIfRequested()   // exits early when launched with --selftest-terminal
        DocRegenCLI.runIfRequested()        // exits early when launched with --regen <projectPath>
    }

    var body: some Scene {
        WindowGroup("Dev Dashboard", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.serverStore)
                .environmentObject(store.tabStore)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(store.appTheme.colorScheme)
                .overlay {
                    if store.isSettingsVisible {
                        SettingsView()
                            .environmentObject(store)
                    }
                }
                // Invisible button holds the ⌘, shortcut binding (⌘K lives in
                // ContentView, where it focuses the toolbar command field).
                .background {
                    Button("") { store.isSettingsVisible = true }
                        .keyboardShortcut(",", modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                }
                .sheet(isPresented: Binding(
                    get: { store.openSessionId != nil },
                    set: { if !$0 { store.openSessionId = nil } }
                )) {
                    if let id = store.openSessionId {
                        SessionDetailView(sessionId: id)
                            .environmentObject(store)
                    }
                }
                .sheet(isPresented: Binding(
                    get: { store.openTaskId != nil },
                    set: { if !$0 { store.openTaskId = nil; store.openTaskProjectPath = nil } }
                )) {
                    if let id = store.openTaskId, let path = store.openTaskProjectPath {
                        TaskDetailSheet(projectPath: path, taskId: id)
                            .environmentObject(store)
                    }
                }
                .task {
                    let hasSavedSelection = UserDefaults.standard.string(forKey: "devdash.lastSelection") != nil
                    if store.selection == nil && !hasSavedSelection { store.selection = .home }
                    await store.reattachManagedServers()
                    await store.refreshAll()
                    store.restoreLastSelection()
                    await store.refreshTodos()
                    store.startAutoRefresh()
                    Task { await store.refreshIssues() }
                    store.refreshHeatmaps()
                    store.refreshRecentCommits()
                    store.refreshSessionDigests()
                    store.loadProjectMetaAndTasks()
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
