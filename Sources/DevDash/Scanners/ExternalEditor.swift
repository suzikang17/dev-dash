import AppKit
import Foundation

/// Helpers to launch external editors for a file path.
enum ExternalEditor {
    /// Open a file in a Terminal command-line editor (nvim, vim, helix…).
    /// Uses Terminal.app via AppleScript so user gets a real interactive shell.
    static func openInTerminal(path: String, command: String) {
        let dir = (path as NSString).deletingLastPathComponent
        let escapedDir = path.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedFile = path.replacingOccurrences(of: "\"", with: "\\\"")
        _ = dir
        let script = """
        tell application "Terminal"
            activate
            do script "cd \\"\(escapedDir)\\" && \(command) \\"\(escapedFile)\\""
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    /// Open a file using a specific .app (e.g. "Cursor", "Visual Studio Code", "Zed").
    /// Falls back to the system default if the app isn't installed.
    static func openWith(path: String, app: String) {
        let url = URL(fileURLWithPath: path)
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId(for: app))
            ?? findAppByName(app)
        if let appURL = appURL {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func bundleId(for appName: String) -> String {
        switch appName {
        case "Cursor": return "com.todesktop.230313mzl4w4u92"
        case "Visual Studio Code": return "com.microsoft.VSCode"
        case "Zed": return "dev.zed.Zed"
        case "Sublime Text": return "com.sublimetext.4"
        default: return ""
        }
    }

    private static func findAppByName(_ name: String) -> URL? {
        let paths = [
            "/Applications/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app"
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }
}
