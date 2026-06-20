import SwiftUI

// MARK: - Design tokens for the native chrome.
//
// Mirrors the OKLCH/CSS token system used by the living-doc generator
// (ProductDocGenerator.swift). Typography is built on semantic text styles so it
// honors Dynamic Type; default sizes are tuned to preserve the app's density.
// Use these instead of inline `.font(.system(size:))`, magic spacing/radii, and
// hardcoded status colors.

enum DSFont {
    static let micro          = Font.system(.caption2)                   // ~11pt — tiny meta
    static let label          = Font.system(.caption)                    // ~12pt — labels / secondary
    static let body           = Font.system(.callout)                    // ~13pt — primary row text
    static let bodyEmphasized = Font.system(.callout).weight(.medium)
    static let title          = Font.system(.headline)                   // ~13–15 semibold — card/row titles
    static let sectionTitle   = Font.system(.title3).weight(.semibold)   // ~18–20 — section titles
    static let display        = Font.system(.largeTitle).weight(.bold)   // ~26+ — big stats / empty states
    static let sectionHeader  = Font.system(.caption2).weight(.semibold) // uppercase micro-labels

    /// Monospaced text at a semantic size (scales with Dynamic Type).
    static func mono(_ style: Font.TextStyle = .callout) -> Font { .system(style, design: .monospaced) }
    /// Proportional text with tabular figures (for aligned numeric columns).
    static func monoDigits(_ style: Font.TextStyle = .callout) -> Font { .system(style).monospacedDigit() }
}

enum DSSpace {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
}

enum DSRadius {
    static let small:  CGFloat = 6
    static let medium: CGFloat = 10
    static let large:  CGFloat = 14
}

enum DSColor {
    static let cardBg   = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.10)
    // Status — theme-adaptive system colors (meaning-bearing; do not hardcode raw RGB).
    static let success = Color.green
    static let warning = Color.orange
    static let danger  = Color.red
    static let info    = Color.accentColor
    // Roles — kept distinct so meanings don't collide.
    static let user      = Color.accentColor
    static let assistant = Color.purple
    static let gitMeta   = Color.teal
}

/// Standard uppercase section header used across panels (replaces the repeated
/// `Text(...).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)`).
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(DSFont.sectionHeader)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// Standard card surface — fill + rounded clip, no decorative stroke.
    func cardSurface(_ radius: CGFloat = DSRadius.medium) -> some View {
        background(DSColor.cardBg, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
    /// Optional 1px hairline for cards that genuinely need separation from a like-colored ground.
    func dsHairline(_ radius: CGFloat = DSRadius.medium) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(DSColor.hairline, lineWidth: 1))
    }
    /// Minimum comfortable hit target for icon-only controls.
    func dsHitTarget(_ size: CGFloat = 28) -> some View {
        frame(minWidth: size, minHeight: size)
    }
}
