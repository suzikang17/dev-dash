import SwiftUI

/// App preferences modal. Opened via ⌘, or the command bar.
struct SettingsView: View {
    @EnvironmentObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    appearanceSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 360)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        section(title: "Appearance") {
            HStack(spacing: 12) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    themeOption(theme)
                }
            }
        }
    }

    private func themeOption(_ theme: AppTheme) -> some View {
        let isSelected = store.appTheme == theme
        return Button {
            store.appTheme = theme
        } label: {
            VStack(spacing: 8) {
                Image(systemName: theme.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(height: 28)
                Text(theme.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(width: 96, height: 76)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                            lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func section<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
