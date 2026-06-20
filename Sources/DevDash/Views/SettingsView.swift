import SwiftUI
import AppKit

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
                    Divider()
                    documentSection
                    Divider()
                    terminalSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 480, height: 640)
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

    // MARK: - Terminal

    private var terminalSection: some View {
        section(title: "Terminal") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("Placement")
                        .font(.system(size: 12))
                        .frame(width: 76, alignment: .leading)
                    Picker("", selection: $store.terminalPlacement) {
                        ForEach(TerminalPlacement.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack(spacing: 8) {
                    Text("Font size")
                        .font(.system(size: 12))
                        .frame(width: 76, alignment: .leading)
                    Button { store.zoomTerminal(-1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Text("\(Int(store.terminalFontSize)) pt")
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 40)
                    Button { store.zoomTerminal(1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Reset") { store.resetTerminalZoom() }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                HStack(spacing: 10) {
                    Text("Font")
                        .font(.system(size: 12))
                        .frame(width: 76, alignment: .leading)
                    Picker("", selection: $store.terminalFontFamily) {
                        ForEach(TerminalFontFamily.allCases, id: \.self) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                HStack(spacing: 10) {
                    Text("Cursor")
                        .font(.system(size: 12))
                        .frame(width: 76, alignment: .leading)
                    Picker("", selection: $store.terminalCursorStyle) {
                        ForEach(TerminalCursorStyle.allCases, id: \.self) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack(spacing: 8) {
                    Text("Scrollback")
                        .font(.system(size: 12))
                        .frame(width: 76, alignment: .leading)
                    Stepper(value: $store.terminalScrollback, in: 1000...50000, step: 1000) {
                        Text("\(store.terminalScrollback) lines")
                            .font(.system(size: 12).monospacedDigit())
                    }
                }
                Text("Background and foreground follow the app theme; ANSI colors are tuned per theme.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Document (living-doc appearance)

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    private var documentSection: some View {
        section(title: "Document") {
            VStack(alignment: .leading, spacing: 16) {
                // Accent hue — drives the whole generated palette.
                Text("ACCENT")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(DocAccent.allCases, id: \.self) { accent in
                        accentSwatch(accent)
                    }
                    Spacer(minLength: 0)
                }
                Text("Tints the whole living-doc palette — neutrals included.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                // Type pairing presets.
                Text("TYPE PAIRING")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 2)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84), spacing: 8)],
                    alignment: .leading, spacing: 8
                ) {
                    ForEach(DocFontPreset.allCases, id: \.self) { preset in
                        presetChip(preset)
                    }
                }

                // Live picker over installed fonts — choosing one flips to Custom.
                Text("FONTS — any installed on your Mac")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 2)
                fontPicker("Display", binding: customBinding(\.docFontDisplay))
                fontPicker("Body", binding: customBinding(\.docFontBody))
                fontPicker("Mono", binding: customBinding(\.docFontMono))
            }
        }
    }

    private func accentColor(_ a: DocAccent) -> Color {
        switch a {
        case .amber:      return Color(red: 0.83, green: 0.57, blue: 0.14)
        case .terracotta: return Color(red: 0.76, green: 0.39, blue: 0.25)
        case .ochre:      return Color(red: 0.78, green: 0.60, blue: 0.17)
        case .olive:      return Color(red: 0.49, green: 0.54, blue: 0.25)
        }
    }

    private func accentSwatch(_ accent: DocAccent) -> some View {
        let isSel = store.docAccent == accent
        return Button { store.docAccent = accent } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(accentColor(accent))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle().stroke(Color.primary.opacity(isSel ? 0 : 0.12), lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(isSel ? 1 : 0)
                    )
                Text(accent.label)
                    .font(.system(size: 10, weight: isSel ? .semibold : .regular))
                    .foregroundStyle(isSel ? .primary : .secondary)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func presetChip(_ preset: DocFontPreset) -> some View {
        let isSel = store.docFontPreset == preset
        return Button { store.docFontPreset = preset } label: {
            Text(preset.label)
                .font(.system(size: 12, weight: isSel ? .semibold : .regular))
                .foregroundStyle(isSel ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(isSel ? 0.10 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSel ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: isSel ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func fontPicker(_ label: String, binding: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Picker("", selection: binding) {
                Text("— preset default —").tag("")
                ForEach(fontFamilies, id: \.self) { fam in
                    Text(fam).font(.custom(fam, size: 13)).tag(fam)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    /// Edits a custom font override directly; selecting a real family flips the
    /// preset to `.custom` so the override takes effect.
    private func customBinding(
        _ keyPath: ReferenceWritableKeyPath<DashboardStore, String>
    ) -> Binding<String> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { value in
                store[keyPath: keyPath] = value
                if !value.isEmpty { store.docFontPreset = .custom }
            }
        )
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
