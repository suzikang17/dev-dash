import Foundation

/// Holds dev-server management state that updates at high frequency — server
/// log lines stream in many times per second while a server runs. Keeping this
/// in its own `ObservableObject` (rather than on `DashboardStore`) means those
/// frequent updates only re-render views that actually observe server state
/// (LogsTabView, the start/stop buttons), instead of invalidating every view
/// bound to the main store (Home, Sidebar, all tabs).
@MainActor
final class ServerStore: ObservableObject {
    @Published var startingProjects: Set<String> = []
    @Published var startErrors: [String: String] = [:]
    @Published var serverLogs: [String: [String]] = [:]
    @Published var managedRunning: Set<String> = []

    func isStarting(_ projectPath: String) -> Bool {
        startingProjects.contains(projectPath)
    }

    func startError(_ projectPath: String) -> String? {
        startErrors[projectPath]
    }

    func logs(for projectPath: String) -> [String] {
        serverLogs[projectPath] ?? []
    }
}
