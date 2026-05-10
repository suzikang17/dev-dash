import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var store: DashboardStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundColor(.accentColor)
            Text("Dev Dashboard")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if store.devServices.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                Text("No dev servers running")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.devServices) { svc in
                        MenuBarServiceRow(service: svc, openMain: openMainWindow)
                        if svc.id != store.devServices.last?.id {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                openMainWindow()
                store.selection = .home
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openMainWindow() {
        // Bring app to front + show the WindowGroup window
        NSApp.activate(ignoringOtherApps: true)
        // Find the existing main window if present
        if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title.contains("Dev Dashboard") }) {
            win.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

private struct MenuBarServiceRow: View {
    let service: Service
    let openMain: () -> Void
    @EnvironmentObject var store: DashboardStore
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(service.framework)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary).font(.system(size: 11))
                    Text(verbatim: ":\(service.port)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Button {
                    if let url = service.url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Open in browser")

                Button {
                    store.selection = .service(serviceID: service.id)
                    store.detailTab = .preview
                    openMain()
                } label: {
                    Image(systemName: "macwindow")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Open in Dashboard")

                Button(role: .destructive) {
                    Task { await store.stopServer(pid: service.pid) }
                } label: {
                    Image(systemName: "stop.fill")
                        .imageScale(.small)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Stop server")
            }
            .opacity(hover ? 1 : 0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(hover ? Color.accentColor.opacity(0.12) : Color.clear)
        .onHover { hover = $0 }
        .onTapGesture {
            store.selection = .service(serviceID: service.id)
            store.detailTab = .preview
            openMain()
        }
    }
}
