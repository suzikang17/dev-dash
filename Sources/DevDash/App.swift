import SwiftUI
import AppKit
import UserNotifications

@main
struct DevDashApp: App {
    @StateObject private var store = DashboardStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        TerminalSelfTest.runIfRequested()   // exits early when launched with --selftest-terminal
        DocRegenCLI.runIfRequested()        // exits early when launched with --regen <projectPath>
        DailySelfTest.runIfRequested()      // exits early when launched with --daily-selftest
        TaskStoreSelfTest.runIfRequested()  // exits early when launched with --selftest-taskstore
        PolicySelfTest.runIfRequested()     // exits early when launched with --selftest-policy
        EventLogSelfTest.runIfRequested()   // exits early when launched with --selftest-eventlog
        NotificationSelfTest.runIfRequested() // exits early when launched with --selftest-notifications
    }

    var body: some Scene {
        WindowGroup("Dev Dashboard", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.serverStore)
                .environmentObject(store.tabStore)
                .environmentObject(store.canvasStore)
                .environmentObject(store.notificationStore)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(store.appTheme.colorScheme)
                .overlay {
                    if store.isSettingsVisible {
                        SettingsView()
                            .environmentObject(store)
                            .environmentObject(store.notificationStore)
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
                    Notifier.requestAuthIfNeeded()
                    store.notificationStore.restoreFromDisk()
                    let hasSavedSelection = UserDefaults.standard.string(forKey: "devdash.lastSelection") != nil
                    if store.selection == nil && !hasSavedSelection { store.selection = .home }
                    store.startEventServer()
                    store.armNavigationObserver()
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
                    store.armTaskWatcherIfNeeded()
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

extension Notification.Name {
    /// Posted by AppDelegate when a system notification banner is clicked.
    /// userInfo: projectPath / tab / taskId (all optional strings).
    static let devdashNavigate = Notification.Name("devdash.navigate")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Show banners even while the app is frontmost (macOS suppresses them by default).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Banner clicked → activate and forward the navigation target to the store.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo
        var info: [String: String] = [:]
        for (k, v) in raw {
            if let ks = k as? String, let vs = v as? String { info[ks] = vs }
        }
        let payload = info
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .devdashNavigate, object: nil, userInfo: payload)
        }
    }
}
