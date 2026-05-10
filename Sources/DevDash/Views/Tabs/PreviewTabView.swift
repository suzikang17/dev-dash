import SwiftUI
import AppKit

struct PreviewTabView: View {
    @EnvironmentObject var store: DashboardStore
    @StateObject private var holder = WebViewHolder()

    var body: some View {
        let proj = store.project(for: store.selection)
        let projectServices: [Service] = proj.map { store.services(for: $0.path) } ?? []
        let svc: Service? = store.service(for: store.selection)

        if let svc = svc,
           let urlString = svc.url,
           let url = URL(string: urlString) {
            VStack(spacing: 0) {
                if projectServices.count > 1, let path = proj?.path {
                    ServiceSwitcher(services: projectServices, currentPort: svc.port, projectPath: path)
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
                }
                Divider()
                AddressBar(
                    url: url,
                    status: holder.status,
                    viewport: $holder.viewport,
                    pid: svc.pid,
                    onOpenExternal: { NSWorkspace.shared.open(url) },
                    onReload: { holder.reload() },
                    onStop: { Task { await store.stopServer(pid: svc.pid) } }
                )
            }
            .onAppear { holder.loadIfNeeded(url) }
            .onChange(of: url) { _, newURL in holder.loadIfNeeded(newURL) }
        } else if let proj = proj {
            NotRunningView(project: proj)
        } else {
            Text("No preview available")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
    let pid: Int32
    let onOpenExternal: () -> Void
    let onReload: () -> Void
    let onStop: () -> Void

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

            Button(role: .destructive, action: onStop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            .help("Stop server (PID \(pid))")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

private struct NotRunningView: View {
    let project: Project
    @EnvironmentObject var store: DashboardStore

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
                .disabled(store.isStarting(project.path))

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            if let err = store.startError(project.path) {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
