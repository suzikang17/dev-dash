import SwiftUI

/// App preferences modal. Opened via ⌘, or the command bar.
/// Presented as an overlay so a click outside (or Esc) dismisses it.
struct SettingsView: View {
    @EnvironmentObject var store: DashboardStore

    var body: some View {
        ZStack {
            // Dimmed backdrop — tapping anywhere outside the card dismisses.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            card
                // Swallow taps on the card so they don't reach the backdrop.
                .onTapGesture {}
                .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private var card: some View {
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
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func dismiss() { store.isSettingsVisible = false }

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
