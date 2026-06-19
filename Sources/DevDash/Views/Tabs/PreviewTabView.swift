import SwiftUI
import AppKit

struct PreviewTabView: View {
    @EnvironmentObject var store: DashboardStore
    @StateObject private var holder = WebViewHolder()
    @State private var snapshotInProgress = false
    @State private var diffResult: SnapshotDiffResult?
    @State private var toastMessage: String?
    @State private var showingProduction = false

    private func isAppleProject(_ project: Project) -> Bool {
        ["macOS App", "iOS App", "Swift Package", "Xcode"].contains(project.framework)
    }

    var body: some View {
        let proj = store.project(for: store.selection)
        let projectServices: [Service] = proj.map { store.services(for: $0.path) } ?? []
        let svc: Service? = store.service(for: store.selection)
        let customURL: URL? = proj.flatMap { URL(string: store.meta(for: $0.path).customDevServerURL ?? "") }
        let effectiveURL: URL? = customURL ?? svc.flatMap { URL(string: $0.url ?? "") }

        if let proj = proj, isAppleProject(proj), svc == nil {
            AppleAppPreview(project: proj)
                .environmentObject(store)
        } else if let url = effectiveURL {
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
                        .background(Color(NSColor.windowBackgroundColor))
                    } else {
                        WebPreview(webView: holder.webView)
                    }
                    if case .failed(let msg) = holder.status {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 32))
                                .foregroundColor(.orange)
                            Text("Couldn't load \(url.absoluteString)")
                                .font(.headline)
                            Text(msg)
                                .font(.caption)
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
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.regularMaterial)
                                .clipShape(Capsule())
                                .padding(.bottom, 12)
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
            .onChange(of: store.selection) { _, _ in showingProduction = false }
        } else if let proj = proj {
            NotRunningView(project: proj)
        } else {
            Text("No preview available")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LocalProductionSwitcher: View {
    @Binding var showingProduction: Bool
    let localURL: URL
    let productionURL: URL

    var body: some View {
        HStack(spacing: 8) {
            pill(label: "Local", url: localURL, active: !showingProduction) { showingProduction = false }
            pill(label: "Production", url: productionURL, active: showingProduction) { showingProduction = true }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func pill(label: String, url: URL, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if active {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Text(url.host ?? url.absoluteString)
                    .font(.system(size: 11).monospaced())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
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
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            ForEach(services, id: \.id) { svc in
                Button {
                    store.setPrimaryService(svc.port, for: projectPath)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: svc.role.systemImage)
                            .font(.system(size: 10))
                        if !svc.role.label.isEmpty {
                            Text(svc.role.label)
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(verbatim: ":\(svc.port)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(svc.port == currentPort ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.10))
                    .foregroundColor(svc.port == currentPort ? .accentColor : .secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(svc.framework) — localhost:\(svc.port)")
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
        HStack(spacing: 10) {
            Group {
                switch status {
                case .loading: ProgressView().controlSize(.mini)
                case .loaded:  Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                case .failed:  Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                }
            }
            .frame(width: 14)
            Text(url.absoluteString)
                .font(.system(size: 12).monospaced())
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

            Button(action: onOpenExternal) {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in browser")

            if let onStop = onStop, let pid = pid {
                Button(role: .destructive, action: onStop) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .help("Stop server (PID \(pid))")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

private struct NotRunningView: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore
    @EnvironmentObject var serverStore: ServerStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("\(project.name) isn't running")
                .font(.title2)
            Text("Start the dev server to preview it here.")
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
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
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
