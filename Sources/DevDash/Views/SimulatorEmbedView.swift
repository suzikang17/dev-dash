import SwiftUI
import WebKit
import AppKit

// MARK: - SimulatorEmbedView

/// Reusable, project-scoped iOS Simulator surface: baguette server lifecycle, a
/// live `WKWebView` embed, and the `SimAppRunner` build → install → launch pipeline.
///
/// Hosted in two places:
///  - the global Simulator destination, with `fixedProject == nil` (user picks the
///    Xcode project from a menu of all dashboard projects), and
///  - the Preview tab's iOS mode, with `fixedProject` set to the current project
///    (the Build & Run panel is locked to it — no project picker).
///
/// States:
///  - not installed  → install hint
///  - idle / stopped → device picker + "Start simulator" button
///  - starting       → progress indicator
///  - running        → live WKWebView embed + Stop button + Build & Run panel
struct SimulatorEmbedView: View {
    /// When non-nil, the Build & Run panel is locked to this project and the
    /// project picker is hidden.  When nil, the user picks from all dashboard
    /// projects that contain an Xcode workspace/project.
    let fixedProject: Project?

    @StateObject private var runner = BaguetteRunner()
    @StateObject private var webHolder = SimulatorWebHolder()
    @StateObject private var appRunner = SimAppRunner()
    @EnvironmentObject private var store: DashboardStore
    @State private var installed: Bool? = nil   // nil = checking
    @State private var startError: String? = nil
    @State private var selectedXcodeProject: XcodeProject? = nil

    init(fixedProject: Project? = nil) {
        self.fixedProject = fixedProject
    }

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

            Text(fixedProject?.name ?? "Simulator")
                .font(DSFont.bodyEmphasized)

            Spacer()

            if runner.serverState == .running {
                zoomControls

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

    /// Zoom −/percentage/+ for the embedded simulator. The percentage label
    /// resets zoom to 100% when clicked.
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { webHolder.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(webHolder.zoom <= SimulatorWebHolder.minZoom)
            .help("Zoom out")
            .accessibilityLabel("Zoom out")

            Button { webHolder.resetZoom() } label: {
                Text(verbatim: "\(Int((webHolder.zoom * 100).rounded()))%")
                    .font(DSFont.monoDigits(.caption2))
                    .frame(width: 42)
            }
            .buttonStyle(.borderless)
            .help("Reset zoom to 100%")
            .accessibilityLabel("Reset zoom")

            Button { webHolder.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(webHolder.zoom >= SimulatorWebHolder.maxZoom)
            .help("Zoom in")
            .accessibilityLabel("Zoom in")
        }
        .padding(.trailing, DSSpace.xs)
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
            VStack(spacing: 0) {
                // Top: live simulator embed (full width)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Drive load from a task keyed on udid — fires on appear and
                // whenever the selected device changes, not on every body pass.
                .task(id: udid) {
                    webHolder.loadIfNeeded(BaguetteRunner.simulatorURL(udid: udid))
                }

                Divider()

                // Bottom: compact Build & Run bar (keeps the sim full-width).
                BuildAndRunBar(
                    udid: udid,
                    xcodeProjects: xcodeProjects,
                    locked: fixedProject != nil,
                    selectedProject: $selectedXcodeProject,
                    appRunner: appRunner
                )
            }
        } else {
            Text("No simulator selected.")
                .font(DSFont.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Xcode projects available to the Build & Run panel.  When locked to a
    /// `fixedProject`, just that project's discovered workspace/project; otherwise
    /// every dashboard project that contains one (at its root or a subdir like `ios/`).
    private var xcodeProjects: [XcodeProject] {
        if let p = fixedProject {
            return XcodeProject.discover(name: p.name, rootPath: p.path).map { [$0] } ?? []
        }
        return store.projects.compactMap { p in
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

// MARK: - BuildAndRunBar

/// Compact horizontal bar shown along the bottom of the simulator while the
/// server is running: project (locked label or picker) · scheme · the
/// build → install → launch action and its live status. Keeps the embed
/// full-width (it used to be a right-hand side panel).
struct BuildAndRunBar: View {
    let udid: String
    let xcodeProjects: [XcodeProject]
    /// When true the project is fixed by the host (Preview dock) — hide the
    /// project picker and folder fallback; show the project name as a label.
    var locked: Bool = false
    @Binding var selectedProject: XcodeProject?
    @ObservedObject var appRunner: SimAppRunner

    var body: some View {
        HStack(spacing: DSSpace.md) {
            projectArea
            schemeArea
            Spacer(minLength: DSSpace.sm)
            actionArea
        }
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.sm)
        .background(.bar)
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
        // When the host swaps the locked project, follow it.
        .onChange(of: xcodeProjects.first) {
            if locked { selectedProject = xcodeProjects.first }
        }
    }

    // MARK: Project

    @ViewBuilder
    private var projectArea: some View {
        if locked {
            if let proj = selectedProject {
                VStack(alignment: .leading, spacing: 0) {
                    Text(proj.name)
                        .font(DSFont.bodyEmphasized)
                        .lineLimit(1)
                    Text(proj.buildTarget.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(DSFont.mono(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 240, alignment: .leading)
            } else {
                Text("No Xcode project in this repo")
                    .font(DSFont.label)
                    .foregroundStyle(.secondary)
            }
        } else if xcodeProjects.isEmpty {
            Button { pickWithOpenPanel() } label: {
                Label("Choose Xcode project…", systemImage: "folder")
                    .font(DSFont.label)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Picker("Project", selection: $selectedProject) {
                Text("None").tag(XcodeProject?.none)
                ForEach(xcodeProjects) { xp in
                    Text(xp.name).tag(Optional(xp))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
        }
    }

    // MARK: Scheme

    @ViewBuilder
    private var schemeArea: some View {
        if appRunner.phase == .fetchingSchemes {
            HStack(spacing: DSSpace.xs) {
                ProgressView().controlSize(.small)
                Text("Schemes…")
                    .font(DSFont.label)
                    .foregroundStyle(.secondary)
            }
        } else if appRunner.availableSchemes.count > 1 {
            Picker("Scheme", selection: $appRunner.selectedScheme) {
                ForEach(appRunner.availableSchemes, id: \.self) { s in
                    Text(s).tag(Optional(s))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
        }
        // Single scheme: no picker (auto-selected by fetchSchemes).
    }

    // MARK: Action / status

    @ViewBuilder
    private var actionArea: some View {
        switch appRunner.phase {
        case .idle, .fetchingSchemes:
            buildButton
        case .building, .installing, .launching:
            HStack(spacing: DSSpace.sm) {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(phaseLabel)
                        .font(DSFont.bodyEmphasized)
                    if !appRunner.buildStatusLine.isEmpty {
                        Text(appRunner.buildStatusLine)
                            .font(DSFont.mono(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
                Button("Cancel") { cancelBuild() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(phaseLabel)
        case .done:
            HStack(spacing: DSSpace.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DSColor.success)
                    .accessibilityHidden(true)
                Text("Launched")
                    .font(DSFont.bodyEmphasized)
                    .foregroundStyle(DSColor.success)
                Button("Run again") { triggerBuild() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .failed(let msg):
            HStack(spacing: DSSpace.sm) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DSColor.danger)
                    .accessibilityHidden(true)
                Text(msg)
                    .font(DSFont.label)
                    .foregroundStyle(DSColor.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .leading)
                    .help(msg)
                Button("Try again") { triggerBuild() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var buildButton: some View {
        Button { triggerBuild() } label: {
            Label("Build & Run", systemImage: "hammer.fill")
                .font(DSFont.bodyEmphasized)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(selectedProject == nil || appRunner.selectedScheme == nil
                  || appRunner.phase == .fetchingSchemes)
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
    /// Current magnification of the embedded simulator (1.0 = 100%).
    @Published var zoom: CGFloat = 1.0
    private var currentURL: URL?

    /// Zoom bounds and step for the +/- controls.
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 4.0
    private static let zoomStep: CGFloat = 0.25

    override init() {
        let config = WKWebViewConfiguration()
        // Allow cross-origin requests — the baguette page loads resources from
        // the same local origin so this is effectively a no-op, but required
        // for any WebSocket handshake the page initiates.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        // Let the user pinch-to-zoom the simulator on a trackpad.
        self.webView.allowsMagnification = true
        // Enable Web Inspector for easier debugging of the embedded page.
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }
    }

    // MARK: Zoom

    /// Set the magnification, clamped to [minZoom, maxZoom].
    func setZoom(_ value: CGFloat) {
        let clamped = min(max(value, Self.minZoom), Self.maxZoom)
        zoom = clamped
        webView.magnification = clamped
    }

    func zoomIn()  { setZoom(zoom + Self.zoomStep) }
    func zoomOut() { setZoom(zoom - Self.zoomStep) }
    func resetZoom() { setZoom(1.0) }

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
