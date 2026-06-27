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
        .padding(.vertical, DSSpace.xs)
    }

    private var header: some View {
        HStack(spacing: DSSpace.sm) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundColor(.accentColor)
            Text("Dev Dashboard")
                .font(DSFont.title)
            Spacer()
            Button {
                Task { await store.refreshAll() }
            } label: {
                Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            .disabled(store.isLoading)
        }
        .padding(.horizontal, DSSpace.md)
        .padding(.vertical, DSSpace.sm)
    }

    @ViewBuilder
    private var content: some View {
        if store.devServices.isEmpty {
            VStack(spacing: DSSpace.sm) {
                Image(systemName: "moon.zzz")
                    .font(DSFont.sectionTitle)
                    .foregroundColor(.secondary)
                Text("No dev servers running")
                    .font(DSFont.label)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpace.xl)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.devServices) { svc in
                        MenuBarServiceRow(service: svc, openMain: openMainWindow)
                        if svc.id != store.devServices.last?.id {
                            Divider().padding(.horizontal, DSSpace.sm)
                        }
                    }
                }
                .padding(.vertical, DSSpace.xs)
            }
            .frame(maxHeight: 360)
        }
    }

    private var footer: some View {
        HStack(spacing: DSSpace.sm) {
            Button {
                openMainWindow()
                store.selection = .home
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
                    .font(DSFont.label)
            }
            .buttonStyle(.borderless)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(DSFont.label)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, DSSpace.md)
        .padding(.vertical, DSSpace.sm)
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
        HStack(spacing: DSSpace.sm) {
            Image(systemName: "circle.fill")
                .foregroundStyle(DSColor.success)
                .font(.system(size: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                    .font(DSFont.bodyEmphasized)
                    .lineLimit(1)
                HStack(spacing: DSSpace.sm) {
                    Text(service.framework)
                        .font(DSFont.micro)
                        .foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary).font(DSFont.micro)
                    Text(verbatim: ":\(service.port)")
                        .font(DSFont.monoDigits(.caption2))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            HStack(spacing: DSSpace.xs) {
                Button {
                    if let url = service.url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Open in browser")
                .accessibilityLabel("Open in browser")

                Button {
                    store.selection = .service(serviceID: service.id)
                    store.previewDockOpen = true
                    openMain()
                } label: {
                    Image(systemName: "macwindow")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Open in Dashboard")
                .accessibilityLabel("Open in Dashboard")

                Button(role: .destructive) {
                    Task { await store.stopServer(pid: service.pid) }
                } label: {
                    Image(systemName: "stop.fill")
                        .imageScale(.small)
                        .foregroundColor(DSColor.danger)
                }
                .buttonStyle(.plain)
                .help("Stop server")
                .accessibilityLabel("Stop server")
            }
            .opacity(hover ? 1 : 0.6)
        }
        .padding(.horizontal, DSSpace.md)
        .padding(.vertical, DSSpace.sm)
        .contentShape(Rectangle())
        .background(hover ? Color.accentColor.opacity(0.12) : Color.clear)
        .onHover { hover = $0 }
        .onTapGesture {
            store.selection = .service(serviceID: service.id)
            store.previewDockOpen = true
            openMain()
        }
    }
}
