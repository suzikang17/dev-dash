import SwiftUI
import WebKit
import AppKit

// MARK: - SimulatorView

/// Top-level view for the Simulator destination.
///
/// States:
///  - not installed  → install hint
///  - idle / stopped → device picker + "Start simulator" button
///  - starting       → progress indicator
///  - running        → live WKWebView embed + Stop button + Build & Run panel
///  - error          → localized error message
struct SimulatorView: View {
    @StateObject private var runner = BaguetteRunner()
    @StateObject private var webHolder = SimulatorWebHolder()
    @StateObject private var appRunner = SimAppRunner()
    @EnvironmentObject private var store: DashboardStore
    @State private var installed: Bool? = nil   // nil = checking
    @State private var startError: String? = nil
    @State private var selectedXcodeProject: XcodeProject? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            installed = await BaguetteRunner.isInstalled()
            if installed == true {
                await runner.refreshDevices()
            }
        }
        // Tear down the server when this view disappears (e.g. user switches away
        // while the server is running — explicit stop on navigation change).
        .onDisappear {
            if runner.serverState == .running {
                runner.stop()
            }
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: DSSpace.md) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
                .font(DSFont.body)

            Text("Simulator")
                .font(DSFont.bodyEmphasized)

            Spacer()

            if runner.serverState == .running {
                Button(role: .destructive) {
                    runner.stop()
                    webHolder.clear()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(DSColor.danger)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.sm)
    }

    // MARK: Content routing

    @ViewBuilder
    private var content: some View {
        switch installed {
        case nil:
            // Still checking
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case false:
            notInstalledView

        case true:
            switch runner.serverState {
            case .idle, .stopped:
                idleView
            case .starting:
                startingView
            case .running:
                runningView
            }
        // Swift exhaustiveness — `installed` is Bool?
        default:
            EmptyView()
        }
    }

    // MARK: Not installed

    private var notInstalledView: some View {
        VStack(spacing: DSSpace.lg) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("baguette not found")
                .font(DSFont.title)
            Text("Install baguette to embed a live iOS Simulator:")
                .font(DSFont.body)
                .foregroundStyle(.secondary)
            Text("brew install baguette")
                .font(DSFont.mono(.callout))
                .padding(.horizontal, DSSpace.lg)
                .padding(.vertical, DSSpace.sm)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DSRadius.small))
            Text("Note: baguette requires Xcode 26.")
                .font(DSFont.label)
                .foregroundStyle(.secondary)
        }
        .padding(DSSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Idle / stopped

    private var idleView: some View {
        VStack(spacing: DSSpace.xl) {
            Image(systemName: "iphone")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: DSSpace.md) {
                Text(runner.serverState == .stopped ? "Simulator stopped" : "iOS Simulator")
                    .font(DSFont.sectionTitle)

                if runner.devices.isEmpty {
                    Text("No simulators found. Install an iOS simulator runtime in Xcode.")
                        .font(DSFont.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    devicePicker
                }

                if let err = startError {
                    Text(err)
                        .font(DSFont.label)
                        .foregroundStyle(DSColor.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DSSpace.xl)
                }

                Button {
                    startError = nil
                    Task { await startSimulator() }
                } label: {
                    Label("Start simulator", systemImage: "play.fill")
                        .font(DSFont.bodyEmphasized)
                        .padding(.horizontal, DSSpace.lg)
                        .padding(.vertical, DSSpace.sm)
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.devices.isEmpty)
            }
        }
        .padding(DSSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var devicePicker: some View {
        Picker("Device", selection: $runner.selectedUDID) {
            Text("Select a device").tag(String?.none)
            ForEach(runner.devices) { device in
                Text(device.displayLabel).tag(Optional(device.udid))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 300)
    }

    // MARK: Starting

    private var startingView: some View {
        VStack(spacing: DSSpace.lg) {
            ProgressView()
                .controlSize(.large)
            Text("Starting baguette server…")
                .font(DSFont.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Running — live WKWebView embed + Build & Run panel

    @ViewBuilder
    private var runningView: some View {
        if let udid = runner.selectedUDID {
            HSplitView {
                // Left: live simulator embed
                ZStack {
                    SimulatorWebView(holder: webHolder)

                    // Overlay load-status feedback so the user isn't left with a
                    // blank view if the page is still loading or fails.
                    switch webHolder.status {
                    case .loading:
                        VStack(spacing: DSSpace.sm) {
                            ProgressView()
                            Text("Loading simulator…")
                                .font(DSFont.label)
                                .foregroundStyle(.secondary)
                        }
                        .padding(DSSpace.lg)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.medium))
                    case .failed(let msg):
                        VStack(spacing: DSSpace.sm) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 28))
                                .foregroundStyle(DSColor.danger)
                                .accessibilityHidden(true)
                            Text("Failed to load simulator page")
                                .font(DSFont.bodyEmphasized)
                            Text(msg)
                                .font(DSFont.label)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(DSSpace.xl)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.medium))
                    case .loaded:
                        EmptyView()
                    }
                }
                .frame(minWidth: 300)
                // Drive load from a task keyed on udid — fires on appear and
                // whenever the selected device changes, not on every body pass.
                .task(id: udid) {
                    webHolder.loadIfNeeded(BaguetteRunner.simulatorURL(udid: udid))
                }

                // Right: Build & Run panel
                BuildAndRunPanel(
                    udid: udid,
                    xcodeProjects: xcodeProjects,
                    selectedProject: $selectedXcodeProject,
                    appRunner: appRunner
                )
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }
        } else {
            Text("No simulator selected.")
                .font(DSFont.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Dashboard projects that contain an Xcode workspace or project at their root.
    private var xcodeProjects: [XcodeProject] {
        store.projects.compactMap { p in
            XcodeProject.discover(name: p.name, rootPath: p.path)
        }
    }

    // MARK: Start action

    private func startSimulator() async {
        do {
            try await runner.start()
        } catch let err as BaguetteError {
            startError = err.localizedDescription
        } catch {
            startError = error.localizedDescription
        }
    }
}

// MARK: - BuildAndRunPanel

/// Right-hand panel shown while the simulator server is running.
/// Lets the user pick an Xcode project, pick a scheme, and trigger
/// the build → install → launch pipeline.
private struct BuildAndRunPanel: View {
    let udid: String
    let xcodeProjects: [XcodeProject]
    @Binding var selectedProject: XcodeProject?
    @ObservedObject var appRunner: SimAppRunner

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                SectionHeader("BUILD & RUN")

                projectPickerSection
                schemePickerSection
                actionSection
            }
            .padding(DSSpace.lg)
        }
        .background(Color(NSColor.windowBackgroundColor))
        // Reload schemes whenever the project selection changes.
        .onChange(of: selectedProject) {
            guard let proj = selectedProject else { return }
            appRunner.reset()
            Task { await appRunner.fetchSchemes(for: proj) }
        }
        // Auto-populate on first appear if projects are already known.
        .onAppear {
            if selectedProject == nil { selectedProject = xcodeProjects.first }
        }
    }

    // MARK: Project picker

    @ViewBuilder
    private var projectPickerSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("Project")
                .font(DSFont.label)
                .foregroundStyle(.secondary)

            if xcodeProjects.isEmpty {
                // No qualifying projects found — offer a folder picker fallback.
                Button {
                    pickWithOpenPanel()
                } label: {
                    Label("Choose Xcode project…", systemImage: "folder")
                        .font(DSFont.body)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("No .xcworkspace or .xcodeproj found in your dashboard projects.")
                    .font(DSFont.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Project", selection: $selectedProject) {
                    Text("None").tag(XcodeProject?.none)
                    ForEach(xcodeProjects) { xp in
                        Text(xp.name).tag(Optional(xp))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }

            if let proj = selectedProject {
                Text(proj.buildTarget.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(DSFont.mono(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Scheme picker

    @ViewBuilder
    private var schemePickerSection: some View {
        if appRunner.phase == .fetchingSchemes {
            HStack(spacing: DSSpace.xs) {
                ProgressView().controlSize(.small)
                Text("Loading schemes…")
                    .font(DSFont.label)
                    .foregroundStyle(.secondary)
            }
        } else if appRunner.availableSchemes.count > 1 {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text("Scheme")
                    .font(DSFont.label)
                    .foregroundStyle(.secondary)
                Picker("Scheme", selection: $appRunner.selectedScheme) {
                    ForEach(appRunner.availableSchemes, id: \.self) { s in
                        Text(s).tag(Optional(s))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }
        }
        // Single scheme: no picker needed (auto-selected by fetchSchemes).
    }

    // MARK: Action / status area

    @ViewBuilder
    private var actionSection: some View {
        switch appRunner.phase {
        case .idle:
            buildButton
        case .fetchingSchemes:
            EmptyView()
        case .building, .installing, .launching:
            buildProgressView
        case .done:
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                HStack(spacing: DSSpace.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DSColor.success)
                        .accessibilityHidden(true)
                    Text("App launched!")
                        .font(DSFont.bodyEmphasized)
                        .foregroundStyle(DSColor.success)
                }
                Button("Build & Run again") {
                    triggerBuild()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                HStack(alignment: .top, spacing: DSSpace.xs) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DSColor.danger)
                        .accessibilityHidden(true)
                    Text(msg)
                        .font(DSFont.label)
                        .foregroundStyle(DSColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DSSpace.sm)
                .background(DSColor.danger.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: DSRadius.small))

                Button("Try again") {
                    triggerBuild()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var buildButton: some View {
        Button {
            triggerBuild()
        } label: {
            Label("Build & Run", systemImage: "hammer.fill")
                .font(DSFont.bodyEmphasized)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(selectedProject == nil || appRunner.selectedScheme == nil
                  || appRunner.phase == .fetchingSchemes)
    }

    private var buildProgressView: some View {
        // Fix 6: combine children so VoiceOver announces the phase label as the
        // primary element rather than reading out a fragment of raw xcodebuild output.
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack(spacing: DSSpace.xs) {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
                Text(phaseLabel)
                    .font(DSFont.bodyEmphasized)
            }
            if !appRunner.buildStatusLine.isEmpty {
                Text(appRunner.buildStatusLine)
                    .font(DSFont.mono(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            // Fix 1: Cancel button terminates the in-flight build immediately.
            Button("Cancel") {
                cancelBuild()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(phaseLabel)
    }

    private var phaseLabel: String {
        switch appRunner.phase {
        case .building:   return "Building…"
        case .installing: return "Installing…"
        case .launching:  return "Launching…"
        default:          return ""
        }
    }

    // MARK: Helpers

    private func triggerBuild() {
        guard let proj = selectedProject,
              let scheme = appRunner.selectedScheme else { return }
        // reset() cancels any in-flight build before starting a new one.
        appRunner.reset()
        appRunner.buildAndRun(project: proj, scheme: scheme, udid: udid)
    }

    private func cancelBuild() {
        appRunner.cancel()
    }

    /// NSOpenPanel fallback when no qualifying projects are found in the dashboard.
    private func pickWithOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a directory containing an .xcworkspace or .xcodeproj"
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rootPath = url.path
        let name = url.lastPathComponent
        if let xp = XcodeProject.discover(name: name, rootPath: rootPath) {
            selectedProject = xp
            Task { await appRunner.fetchSchemes(for: xp) }
        }
    }
}

// MARK: - SimulatorWebHolder

/// Owns the WKWebView for the simulator embed.  Mirrors `WebViewHolder` in
/// WebPreview.swift but skips viewport/user-agent logic (the baguette page
/// is a localhost tool UI, not a responsive app under test).
@MainActor
final class SimulatorWebHolder: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var status: WebLoadStatus = .loading
    private var currentURL: URL?

    override init() {
        let config = WKWebViewConfiguration()
        // Allow cross-origin requests — the baguette page loads resources from
        // the same local origin so this is effectively a no-op, but required
        // for any WebSocket handshake the page initiates.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        // Enable Web Inspector for easier debugging of the embedded page.
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }
    }

    /// Load `url` if it differs from what's already loaded.
    @discardableResult
    func loadIfNeeded(_ url: URL) -> URL {
        if currentURL != url {
            currentURL = url
            status = .loading
            webView.load(URLRequest(url: url))
        }
        return url
    }

    /// Drop the current page (called on Stop).
    func clear() {
        currentURL = nil
        status = .loading
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.status = .loaded }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.status = .failed(msg) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.status = .failed(msg) }
    }
}

// MARK: - SimulatorWebView

/// `NSViewRepresentable` wrapper around the stable `WKWebView` owned by
/// `SimulatorWebHolder`.  Mirrors the `WebPreview` pattern in WebPreview.swift.
struct SimulatorWebView: NSViewRepresentable {
    let holder: SimulatorWebHolder

    func makeNSView(context: Context) -> WKWebView { holder.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
