import SwiftUI
import AppKit

/// Which surface the Preview tab is showing for a project that has more than one.
enum PreviewMode: String { case web, ios }

struct PreviewTabView: View {
    @EnvironmentObject var store: DashboardStore
    // Canvas panels pinned to another project inject this override (see PanelContentView).
    @Environment(\.panelSelection) private var panelSelection
    @StateObject private var holder = WebViewHolder()
    @State private var snapshotInProgress = false
    @State private var diffResult: SnapshotDiffResult?
    @State private var toastMessage: String?
    @State private var showingProduction = false
    /// Web | iOS selection, when the project supports both. Resolved/persisted per project.
    @State private var previewMode: PreviewMode = .web
    /// The current project's iOS Xcode project, if any. Resolved off the body
    /// (disk I/O) in a `.task` keyed on the selection.
    @State private var iosXcode: XcodeProject? = nil

    private func isAppleProject(_ project: Project) -> Bool {
        ["macOS App", "iOS App", "Swift Package", "Xcode"].contains(project.framework)
    }

    /// The iOS-simulator-buildable Xcode project for `project`, if one applies.
    ///
    /// Heuristic (no `xcodebuild` platform probe): an Xcode project is treated as
    /// iOS when the scanner already classified the repo as an iOS App, or when the
    /// project was discovered in a subdirectory (e.g. `ios/`) rather than the repo
    /// root — a root-level `.xcodeproj` on a non-iOS repo is more likely a macOS app.
    private func iosProject(for project: Project) -> XcodeProject? {
        guard let xp = XcodeProject.discover(name: project.name, rootPath: project.path) else { return nil }
        if project.framework == "iOS App" { return xp }
        if xp.rootPath != project.path { return xp }   // found in a subdir like ios/
        return nil
    }

    // MARK: Per-project mode memory

    private static let modeMemoryKey = "devdash.previewMode"

    private func savedMode(for path: String) -> PreviewMode? {
        (UserDefaults.standard.dictionary(forKey: Self.modeMemoryKey) as? [String: String])?[path]
            .flatMap { PreviewMode(rawValue: $0) }
    }

    private func saveMode(_ mode: PreviewMode, for path: String) {
        var m = (UserDefaults.standard.dictionary(forKey: Self.modeMemoryKey) as? [String: String]) ?? [:]
        m[path] = mode.rawValue
        UserDefaults.standard.set(m, forKey: Self.modeMemoryKey)
    }

    var body: some View {
        let proj = store.project(for: panelSelection ?? store.selection)
        let svc: Service? = store.service(for: panelSelection ?? store.selection)
        let customURL: URL? = proj.flatMap { URL(string: store.meta(for: $0.path).customDevServerURL ?? "") }
        let effectiveURL: URL? = customURL ?? svc.flatMap { URL(string: $0.url ?? "") }
        let hasWeb = effectiveURL != nil
        let hasIOS = iosXcode != nil

        VStack(spacing: 0) {
            if let proj, hasIOS, hasWeb {
                PreviewModeSwitcher(mode: $previewMode)
                    .onChange(of: previewMode) { _, m in saveMode(m, for: proj.path) }
                Divider()
            }
            routedContent(proj: proj, svc: svc, effectiveURL: effectiveURL,
                          hasWeb: hasWeb, hasIOS: hasIOS)
        }
        // Resolve the iOS project + restore the saved mode off the body, re-running
        // whenever the selected project changes.
        .task(id: proj?.path) {
            let resolved = proj.flatMap { iosProject(for: $0) }
            iosXcode = resolved
            if let proj {
                previewMode = savedMode(for: proj.path) ?? (effectiveURL != nil ? .web : .ios)
            }
        }
    }

    /// Routes to the iOS embed, web preview, Apple buttons view, or empty states.
    @ViewBuilder
    private func routedContent(proj: Project?, svc: Service?, effectiveURL: URL?,
                               hasWeb: Bool, hasIOS: Bool) -> some View {
        if let proj, hasIOS, !(hasWeb && previewMode == .web) {
            // iOS app, and either there's no web to show or the user picked iOS.
            SimulatorEmbedView(fixedProject: proj)
                .environmentObject(store)
        } else if let proj, isAppleProject(proj), svc == nil, !hasWeb {
            // macOS / Swift Package Apple project (iOS handled above).
            AppleAppPreview(project: proj)
                .environmentObject(store)
        } else if let url = effectiveURL {
            webPreview(proj: proj, svc: svc, url: url)
        } else if let proj {
            NotRunningView(project: proj)
        } else {
            Text("No preview available")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func webPreview(proj: Project?, svc: Service?, url: URL) -> some View {
        let projectServices: [Service] = proj.map { store.services(for: $0.path) } ?? []
        let slug = VisualSnapshotStore.slugify(url)
            let vp = holder.viewport.rawValue
            let projectPath = proj?.path ?? ""
            let doSnapshot: (() -> Void)? = svc != nil ? {
                Task { @MainActor in
                    guard !snapshotInProgress else { return }
                    snapshotInProgress = true
                    defer { snapshotInProgress = false }
                    do {
                        let newImage = try await VisualDiffRunner.takeSnapshot(webView: holder.webView)
                        let savedBaseline = VisualSnapshotStore.baseline(for: projectPath, urlSlug: slug, viewport: vp)
                        let prodURLString = store.meta(for: projectPath).productionURL
                        let baseline: CGImage
                        if let saved = savedBaseline {
                            baseline = saved
                        } else if let prodStr = prodURLString, let prodURL = URL(string: prodStr) {
                            toastMessage = "Fetching baseline from production..."
                            let prodImage = try await VisualDiffRunner.takeSnapshotFromURL(prodURL, viewportSize: holder.webView.frame.size)
                            VisualSnapshotStore.saveBaseline(prodImage, projectPath: projectPath, urlSlug: slug, viewport: vp)
                            baseline = prodImage
                        } else {
                            VisualSnapshotStore.saveBaseline(newImage, projectPath: projectPath, urlSlug: slug, viewport: vp)
                            toastMessage = "Baseline saved"
                            return
                        }
                        let diff = VisualDiffRunner.diff(new: newImage, baseline: baseline)
                        if diff.isSignificant {
                            let runId = ISO8601DateFormatter().string(from: Date())
                            let run = VisualRun(
                                id: runId, url: url.absoluteString, viewportLabel: vp,
                                changedPixelRatio: diff.changedPixelRatio, approved: false,
                                taskId: nil, createdAt: Date()
                            )
                            let path = VisualSnapshotStore.saveRun(
                                newImage: newImage, diffImage: diff.diffImage,
                                run: run, projectPath: projectPath, urlSlug: slug, viewport: vp
                            )
                            VisualSnapshotStore.pruneRuns(projectPath: projectPath, urlSlug: slug, viewport: vp)
                            diffResult = SnapshotDiffResult(
                                newImage: newImage, diffImage: diff.diffImage,
                                changedPixelRatio: diff.changedPixelRatio, isSignificant: true, runPath: path
                            )
                        } else {
                            VisualSnapshotStore.saveBaseline(newImage, projectPath: projectPath, urlSlug: slug, viewport: vp)
                            toastMessage = "No significant changes"
                        }
                    } catch {
                        toastMessage = "Snapshot failed: \(error.localizedDescription)"
                    }
                }
            } : nil

            let prodURL = store.meta(for: projectPath).productionURL.flatMap { URL(string: $0) }
            let displayURL = (showingProduction && prodURL != nil) ? prodURL! : url

            VStack(spacing: 0) {
                if projectServices.count > 1, let path = proj?.path {
                    ServiceSwitcher(services: projectServices, currentPort: svc?.port ?? 0, projectPath: path)
                    Divider()
                }
                if let prodURL {
                    LocalProductionSwitcher(showingProduction: $showingProduction, localURL: url, productionURL: prodURL)
                    Divider()
                }
                ZStack {
                    if let size = holder.viewport.size {
                        ScrollView([.horizontal, .vertical]) {
                            WebPreview(webView: holder.webView)
                                .frame(width: size.width, height: size.height)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(Color.black.opacity(0.4), lineWidth: 8)
                                )
                                .shadow(radius: 12)
                                .padding(40)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .background(Color(NSColor.windowBackgroundColor))   // device-frame canvas; intentionally not a card
                    } else {
                        WebPreview(webView: holder.webView)
                    }
                    if case .failed(let msg) = holder.status {
                        VStack(spacing: DSSpace.sm) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 32))
                                .foregroundColor(DSColor.warning)
                            Text("Couldn't load \(url.absoluteString)")
                                .font(DSFont.title)
                            Text(msg)
                                .font(DSFont.label)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 480)
                            Button("Open in browser") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.bordered)
                        }
                        .padding()
                        .background(.regularMaterial)
                    }
                    if let msg = toastMessage {
                        VStack {
                            Spacer()
                            Text(msg)
                                .font(DSFont.label.weight(.medium))
                                .padding(.horizontal, DSSpace.lg)
                                .padding(.vertical, DSSpace.sm)
                                .background(.regularMaterial)
                                .clipShape(Capsule())
                                .padding(.bottom, DSSpace.md)
                        }
                        .task(id: msg) {
                            try? await Task.sleep(for: .seconds(2))
                            toastMessage = nil
                        }
                    }
                }
                Divider()
                AddressBar(
                    url: displayURL,
                    status: holder.status,
                    viewport: $holder.viewport,
                    pid: svc?.pid,
                    snapshotInProgress: snapshotInProgress,
                    onOpenExternal: { NSWorkspace.shared.open(displayURL) },
                    onReload: { holder.reload() },
                    onSnapshot: (!showingProduction && svc != nil) ? doSnapshot : nil,
                    onResetBaseline: (!showingProduction && svc != nil) ? {
                        VisualSnapshotStore.deleteBaseline(projectPath: projectPath, urlSlug: slug, viewport: vp)
                        toastMessage = "Baseline reset"
                    } : nil,
                    onStop: svc.map { s in { Task { await store.stopServer(pid: s.pid) } } }
                )
            }
            .sheet(item: $diffResult) { result in
                VisualDiffSheet(
                    result: result,
                    projectPath: projectPath,
                    urlSlug: slug,
                    viewportLabel: vp,
                    pageURL: url,
                    onApprove: { newImage in
                        VisualSnapshotStore.saveBaseline(newImage, projectPath: projectPath, urlSlug: slug, viewport: vp)
                    }
                )
            }
            .onAppear { holder.loadIfNeeded(displayURL) }
            .onChange(of: url) { _, newURL in holder.loadIfNeeded(newURL) }
            .onChange(of: showingProduction) { _, showing in
                let target = (showing && prodURL != nil) ? prodURL! : url
                holder.webView.load(URLRequest(url: target))
            }
            .onChange(of: panelSelection ?? store.selection) { _, _ in showingProduction = false }
    }
}

// MARK: - Preview mode switcher (Web | iOS)

/// Segmented Web | iOS toggle shown at the top of the Preview tab when the
/// selected project has both a web preview and an iOS app.
private struct PreviewModeSwitcher: View {
    @Binding var mode: PreviewMode

    var body: some View {
        HStack(spacing: DSSpace.sm) {
            pill(label: "Web", systemImage: "globe", active: mode == .web) { mode = .web }
            pill(label: "iOS", systemImage: "iphone", active: mode == .ios) { mode = .ios }
            Spacer()
        }
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.xs)
        .background(.bar)
    }

    private func pill(label: String, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(DSFont.micro)
                Text(label)
                    .font(DSFont.micro.weight(.medium))
            }
            .padding(.horizontal, DSSpace.sm)
            .padding(.vertical, DSSpace.xs)
            .background(active ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.10))
            .foregroundColor(active ? .accentColor : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct LocalProductionSwitcher: View {
    @Binding var showingProduction: Bool
    let localURL: URL
    let productionURL: URL

    var body: some View {
        HStack(spacing: DSSpace.sm) {
            pill(label: "Local", url: localURL, active: !showingProduction) { showingProduction = false }
            pill(label: "Production", url: productionURL, active: showingProduction) { showingProduction = true }
            Spacer()
        }
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.xs)
        .background(.bar)
    }

    private func pill(label: String, url: URL, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if active {
                    Circle().fill(DSColor.success).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(DSFont.micro.weight(.medium))
                Text(url.host ?? url.absoluteString)
                    .font(DSFont.mono(.caption2))
            }
            .padding(.horizontal, DSSpace.sm)
            .padding(.vertical, DSSpace.xs)
            .background(active ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.10))
            .foregroundColor(active ? .accentColor : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ServiceSwitcher: View {
    let services: [Service]
    let currentPort: Int
    let projectPath: String
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        HStack(spacing: DSSpace.sm) {
            Image(systemName: "rectangle.split.2x1")
                .font(DSFont.micro)
                .foregroundColor(.secondary)
            ForEach(services, id: \.id) { svc in
                Button {
                    store.setPrimaryService(svc.port, for: projectPath)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: svc.role.systemImage)
                            .font(DSFont.micro)
                        if !svc.role.label.isEmpty {
                            Text(svc.role.label)
                                .font(DSFont.micro.weight(.medium))
                        }
                        Text(verbatim: ":\(svc.port)")
                            .font(DSFont.monoDigits(.caption2).weight(.semibold))
                    }
                    .padding(.horizontal, DSSpace.sm)
                    .padding(.vertical, DSSpace.xs)
                    .background(svc.port == currentPort ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.10))
                    .foregroundColor(svc.port == currentPort ? .accentColor : .secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(svc.framework) — localhost:\(svc.port)")
            }
            Spacer()
        }
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.xs)
        .background(.bar)
    }
}

private struct AddressBar: View {
    let url: URL
    let status: WebLoadStatus
    @Binding var viewport: Viewport
    let pid: Int32?
    let snapshotInProgress: Bool
    let onOpenExternal: () -> Void
    let onReload: () -> Void
    let onSnapshot: (() -> Void)?
    let onResetBaseline: (() -> Void)?
    let onStop: (() -> Void)?

    var body: some View {
        HStack(spacing: DSSpace.sm) {
            Group {
                switch status {
                case .loading: ProgressView().controlSize(.mini)
                case .loaded:  Image(systemName: "checkmark.circle.fill").foregroundColor(DSColor.success)
                case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundColor(DSColor.warning)
                }
            }
            .frame(width: 14)
            Text(url.absoluteString)
                .font(DSFont.mono(.caption))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()

            Picker("Viewport", selection: $viewport) {
                ForEach(Viewport.allCases) { vp in
                    Image(systemName: vp.systemImage)
                        .help(vp.label)
                        .tag(vp)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)

            if let onSnapshot {
                Button(action: onSnapshot) {
                    if snapshotInProgress {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "camera")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(snapshotInProgress)
                .help("Take visual snapshot — right-click to reset baseline")
                .accessibilityLabel("Take visual snapshot — right-click to reset baseline")
                .frame(width: 20)
                .contextMenu {
                    Button("Take snapshot", action: onSnapshot)
                    if let onReset = onResetBaseline {
                        Divider()
                        Button("Reset baseline for this URL", action: onReset)
                    }
                }
            }

            Button(action: onReload) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload")
            .accessibilityLabel("Reload")

            Button(action: onOpenExternal) {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in browser")
            .accessibilityLabel("Open in browser")

            if let onStop = onStop, let pid = pid {
                Button(role: .destructive, action: onStop) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .foregroundColor(DSColor.danger)
                .help("Stop server (PID \(pid))")
                .accessibilityLabel("Stop server (PID \(pid))")
            }
        }
        .padding(.horizontal, DSSpace.lg)
        .padding(.vertical, DSSpace.sm)
        .background(.regularMaterial)
    }
}

private struct NotRunningView: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var serverStore: ServerStore

    var body: some View {
        VStack(spacing: DSSpace.lg) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("\(project.name) isn't running")
                .font(DSFont.sectionTitle)
            Text("Start the dev server to preview it here.")
                .foregroundColor(.secondary)
            HStack(spacing: DSSpace.md) {
                Button {
                    Task { await store.startServer(for: project.path) }
                } label: {
                    Label("Start dev server", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverStore.isStarting(project.path))

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            if let err = serverStore.startError(project.path) {
                Text(err)
                    .font(DSFont.label)
                    .foregroundColor(DSColor.danger)
                    .padding(.top, DSSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
