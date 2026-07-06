import SwiftUI

/// Toolbar bell + unread badge; click opens the notification center popover.
struct NotificationBellButton: View {
    @EnvironmentObject private var notifications: NotificationStore
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if notifications.unreadCount > 0 {
                        Text(verbatim: notifications.unreadCount > 99 ? "99+" : String(notifications.unreadCount))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .help("Notifications")
        .accessibilityLabel("Notifications")
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            NotificationCenterPanel()
        }
        .onChange(of: showPanel) { _, open in
            // Opening the panel marks everything seen (mark-all-seen model).
            if open { notifications.markAllSeen() }
        }
    }
}

/// The popover: newest-first feed, click a row to navigate.
struct NotificationCenterPanel: View {
    @EnvironmentObject private var notifications: NotificationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(DSFont.bodyEmphasized)
                Spacer()
                if !notifications.feed.isEmpty {
                    Button("Clear") { notifications.markAllSeen() }
                        .buttonStyle(.plain)
                        .font(DSFont.micro)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(DSSpace.sm)
            Divider()

            if notifications.feed.isEmpty {
                Text("No notifications yet.")
                    .font(DSFont.label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DSSpace.lg)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(notifications.feed) { item in
                            NotificationRow(item: item)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 360)
    }
}

private struct NotificationRow: View {
    let item: AppNotification
    @EnvironmentObject private var store: DashboardStore
    @Environment(\.dismiss) private var dismiss

    /// Project display name from the path's last component.
    private var projectName: String? {
        item.projectPath.map { ($0 as NSString).lastPathComponent }
    }

    var body: some View {
        Button {
            store.navigate(projectPath: item.projectPath, tabRaw: item.tab, taskId: item.taskId)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: DSSpace.sm) {
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(DSFont.label)
                        .foregroundStyle(.primary)
                    Text(item.body)
                        .font(DSFont.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: DSSpace.xs) {
                        if let projectName {
                            Text(projectName)
                        }
                        Text(item.date, format: .relative(presentation: .named))
                    }
                    .font(DSFont.micro)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpace.sm)
            .padding(.vertical, DSSpace.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
