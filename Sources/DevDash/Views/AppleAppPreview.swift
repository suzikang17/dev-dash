import SwiftUI
import AppKit

/// Preview surface for macOS / iOS / Swift Package projects. Web preview
/// doesn't apply here, so we render a different layout with build / run /
/// focus / screenshot buttons. Live screen mirroring is a follow-up; this
/// is the buttons-first v1.
struct AppleAppPreview: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore

    @State private var screenshot: NSImage?
    @State private var screenshotAt: Date?
    @State private var running: NSRunningApplication?
    @State private var lastBuildLog: String = ""
    @State private var building = false
    @State private var buildExitCode: Int32?

    private var isIOS: Bool { project.framework == "iOS App" }
    private var isMacApp: Bool { project.framework == "macOS App" }

    // Filesystem probes, resolved once when the view appears instead of on every
    // body evaluation — these hit disk (fileExists / contentsOfDirectory) and
    // were previously recomputed on each render.
    @State private var isSPM = false
    @State private var hasXcodeProj = false

    private func detectProjectKind() {
        let path = project.path
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        isSPM = FileManager.default.fileExists(atPath: "\(path)/Package.swift")
        hasXcodeProj = entries.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.md) {
            header
            buttonsRow
            if !lastBuildLog.isEmpty {
                buildLog
            }
            screenshotPane
            Spacer()
        }
        .padding(DSSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { detectProjectKind(); refreshRunning() }
        .onChange(of: project.path) { _, _ in detectProjectKind(); refreshRunning() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: DSSpace.md) {
            Image(systemName: project.framework == "iOS App" ? "iphone" : "macwindow")
                .font(DSFont.sectionTitle)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DSSpace.xs) {
                    Text(project.name).font(DSFont.title)
                    Text(project.framework)
                        .font(DSFont.micro)
                        .padding(.horizontal, DSSpace.xs).padding(.vertical, 2)
                        .background(DSColor.info.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                }
                if let app = running {
                    HStack(spacing: DSSpace.xs) {
                        Circle().fill(DSColor.success).frame(width: 7, height: 7)
                        Text(verbatim: "Running · pid \(app.processIdentifier)")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Not running").font(DSFont.micro).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var buttonsRow: some View {
        HStack(spacing: DSSpace.sm) {
            // Open in Xcode (or default editor for Package.swift)
            if hasXcodeProj || isSPM {
                Button {
                    openInXcode()
                } label: {
                    Label("Open in Xcode", systemImage: "hammer.circle")
                }
                .buttonStyle(.bordered)
            }

            // SPM executable: swift run
            if isSPM && !hasXcodeProj {
                Button {
                    Task { await swiftRun() }
                } label: {
                    Label(building ? "Building…" : "Build & Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(building)
            }

            // Xcode: build & run via xcodebuild requires scheme picker — skip in v1, point user to Xcode
            if hasXcodeProj && !isSPM {
                Button {
                    Task { await xcodeBuildAndRun() }
                } label: {
                    Label(building ? "Building…" : "Build (debug)", systemImage: "hammer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(building)
                .help("Builds via xcodebuild — pick scheme in Xcode for now")
            }

            // iOS: open simulator
            if isIOS {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"))
                } label: {
                    Label("Open Simulator", systemImage: "iphone")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if running != nil {
                Button { focusRunning() } label: {
                    Label("Focus", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)

                Button { takeScreenshot() } label: {
                    Label("Screenshot", systemImage: "camera")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    quitRunning()
                } label: {
                    Label("Quit", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }

            Button {
                refreshRunning()
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Re-detect running app")
                .accessibilityLabel("Re-detect running app")
        }
    }

    @ViewBuilder
    private var buildLog: some View {
        DisclosureGroup {
            ScrollView {
                Text(lastBuildLog)
                    .font(DSFont.mono(.caption2))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DSSpace.sm)
            }
            .frame(maxHeight: 220)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
        } label: {
            HStack(spacing: DSSpace.xs) {
                if let exit = buildExitCode {
                    Image(systemName: exit == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(exit == 0 ? DSColor.success : DSColor.danger)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(buildExitCode.map { $0 == 0 ? "Build succeeded" : "Build failed (exit \($0))" } ?? "Building…")
                    .font(DSFont.label.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private var screenshotPane: some View {
        if let img = screenshot {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                HStack(spacing: DSSpace.xs) {
                    Text("Screenshot")
                        .font(DSFont.sectionHeader)
                        .tracking(0.6)
                        .foregroundColor(.secondary)
                    if let at = screenshotAt {
                        Text("· \(timeAgo(at))")
                            .font(DSFont.monoDigits(.caption2))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { takeScreenshot() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Refresh screenshot")
                }
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.small))
                        .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(DSColor.hairline, lineWidth: 1))
                        .padding(2)
                }
                .frame(maxHeight: 480)
            }
        } else if running != nil {
            Text("Click Screenshot to capture the running app's window. (Requires Screen Recording permission the first time.)")
                .font(DSFont.label)
                .foregroundColor(.secondary)
        } else {
            VStack(spacing: DSSpace.sm) {
                Image(systemName: project.framework == "iOS App" ? "iphone" : "macwindow")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("App isn't running")
                    .font(DSFont.body)
                    .foregroundColor(.secondary)
                Text(buildHint)
                    .font(DSFont.micro)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    private var buildHint: String {
        if isIOS { return "Open in Xcode and run on a simulator. DevDash will detect it once the app is running." }
        if isSPM { return "Click Build & Run for swift run, or Open in Xcode." }
        return "Click Build to compile via xcodebuild, or open in Xcode."
    }

    // MARK: - Running app detection

    private func refreshRunning() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .first { app in
                if let url = app.bundleURL?.path, url.hasPrefix(project.path) { return true }
                if let exec = app.executableURL?.path, exec.hasPrefix(project.path) { return true }
                if let name = app.localizedName?.lowercased(),
                   name.contains(project.name.lowercased()) || project.name.lowercased().contains(name) {
                    return true
                }
                return false
            }
    }

    private func focusRunning() {
        running?.activate(options: [])
    }

    private func quitRunning() {
        if let pid = running?.processIdentifier {
            kill(pid, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refreshRunning() }
        }
    }

    private func openInXcode() {
        let fm = FileManager.default
        let xcworkspaces = (try? fm.contentsOfDirectory(atPath: project.path))?.first { $0.hasSuffix(".xcworkspace") }
        let xcodeprojs = (try? fm.contentsOfDirectory(atPath: project.path))?.first { $0.hasSuffix(".xcodeproj") }
        let target: String
        if let ws = xcworkspaces { target = "\(project.path)/\(ws)" }
        else if let proj = xcodeprojs { target = "\(project.path)/\(proj)" }
        else { target = "\(project.path)/Package.swift" }
        NSWorkspace.shared.open(URL(fileURLWithPath: target))
    }

    // MARK: - Build & run

    private func swiftRun() async {
        building = true
        buildExitCode = nil
        lastBuildLog = "$ swift run\n"
        defer { building = false }
        let result = await runShell(["swift", "run"], cwd: project.path)
        buildExitCode = result.exitCode
        lastBuildLog = "$ swift run\n" + result.output
        await MainActor.run { refreshRunning() }
    }

    private func xcodeBuildAndRun() async {
        building = true
        buildExitCode = nil
        lastBuildLog = "$ xcodebuild -configuration Debug build\n"
        defer { building = false }
        let result = await runShell(["xcodebuild", "-configuration", "Debug", "build"], cwd: project.path, timeout: 300)
        buildExitCode = result.exitCode
        lastBuildLog = "$ xcodebuild -configuration Debug build\n" + result.output
    }

    private func runShell(_ argv: [String], cwd: String, timeout: TimeInterval = 180) async -> (exitCode: Int32, output: String) {
        await Task.detached(priority: .userInitiated) {
            let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("devdash-applebuild-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-ic", argv.joined(separator: " ")]
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            if let h = try? FileHandle(forWritingTo: outURL) {
                p.standardOutput = h
                p.standardError = h
            }
            do { try p.run() } catch {
                try? FileManager.default.removeItem(at: outURL)
                return (-1, "Failed to launch: \(error.localizedDescription)")
            }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
            let data = (try? Data(contentsOf: outURL)) ?? Data()
            try? FileManager.default.removeItem(at: outURL)
            let text = String(data: data, encoding: .utf8) ?? ""
            return (p.terminationStatus, text)
        }.value
    }

    // MARK: - Screenshot

    private func takeScreenshot() {
        guard let app = running else { return }
        let pid = app.processIdentifier
        let options = CGWindowListOption([.optionOnScreenOnly])
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        let appWindows = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        // Pick the largest window — typically the main one
        let target = appWindows.max { (a, b) -> Bool in
            let aBounds = (a[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
            let bBounds = (b[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
            let aArea = (aBounds["Width"] ?? 0) * (aBounds["Height"] ?? 0)
            let bArea = (bBounds["Width"] ?? 0) * (bBounds["Height"] ?? 0)
            return aArea < bArea
        }
        guard let target = target,
              let windowID = target[kCGWindowNumber as String] as? CGWindowID else { return }
        if let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .nominalResolution]) {
            screenshot = NSImage(cgImage: cgImage, size: .zero)
            screenshotAt = Date()
        }
    }
}
