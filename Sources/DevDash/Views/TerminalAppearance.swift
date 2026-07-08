import AppKit
import SwiftTerm

// MARK: - User-facing config enums

/// Cursor shape for the embedded terminals. Persisted under devdash.terminal.cursorStyle.
enum TerminalCursorStyle: String, CaseIterable {
    case block, bar, underline
    var label: String { self == .block ? "Block" : self == .bar ? "Bar" : "Underline" }
    /// We use the STEADY variants (no blink) for a calmer UI.
    var swiftTerm: SwiftTerm.CursorStyle {
        switch self {
        case .block: return .steadyBlock
        case .bar: return .steadyBar
        case .underline: return .steadyUnderline
        }
    }
}

/// Monospace font family choice. Persisted under devdash.terminal.fontFamily.
/// Each case resolves to a concrete NSFont via a graceful fallback chain so an
/// uninstalled family never yields a proportional system font.
enum TerminalFontFamily: String, CaseIterable {
    case system          // monospacedSystemFont (always available)
    case jetBrainsMono
    case firaCode
    case sfMono
    case menlo

    var label: String {
        switch self {
        case .system: return "System Mono"
        case .jetBrainsMono: return "JetBrains Mono"
        case .firaCode: return "Fira Code"
        case .sfMono: return "SF Mono"
        case .menlo: return "Menlo"
        }
    }

    /// PostScript/family names tried in order; first that exists at this size wins.
    private var candidates: [String] {
        switch self {
        case .system: return []
        case .jetBrainsMono: return ["JetBrains Mono", "JetBrainsMono-Regular", "SF Mono", "Menlo"]
        case .firaCode: return ["Fira Code", "FiraCode-Regular", "SF Mono", "Menlo"]
        case .sfMono: return ["SF Mono", "SFMono-Regular", "Menlo"]
        case .menlo: return ["Menlo", "Menlo-Regular"]
        }
    }

    func font(size: CGFloat) -> NSFont {
        for name in candidates {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Resolved appearance bundle

/// Everything needed to paint a terminal. Built from the store's settings and
/// passed to applyTerminalAppearance(_:to:). Keep this a plain value type so the
/// cached-shell store can hold/compare it.
struct TerminalAppearance: Equatable {
    var theme: AppTheme
    var fontSize: CGFloat
    var fontFamily: TerminalFontFamily
    var cursorStyle: TerminalCursorStyle
    var scrollback: Int

    /// Sensible standalone default for callers with no store value threaded
    /// through. Mirrors DashboardStore's persisted defaults.
    static func current() -> TerminalAppearance {
        let d = UserDefaults.standard
        let theme = AppTheme(rawValue: d.string(forKey: "devdash.theme") ?? "") ?? .dark
        let size = d.object(forKey: "devdash.terminal.fontSize") as? Double ?? 13
        let family = TerminalFontFamily(rawValue: d.string(forKey: "devdash.terminal.fontFamily") ?? "") ?? .system
        let cursor = TerminalCursorStyle(rawValue: d.string(forKey: "devdash.terminal.cursorStyle") ?? "") ?? .block
        let scroll = d.object(forKey: "devdash.terminal.scrollback") as? Int ?? 10000
        return TerminalAppearance(theme: theme, fontSize: CGFloat(size), fontFamily: family,
                                  cursorStyle: cursor, scrollback: scroll)
    }
}

// MARK: - Palettes

/// SwiftTerm's public Color init takes UInt16 (0..65535); the 8-bit init(red8:) is
/// INTERNAL to SwiftTerm and NOT callable from here. Scale 8-bit by 257.
@inline(__always)
private func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SwiftTerm.Color {
    SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
}

enum TerminalPalettes {
    // 16 ANSI entries: 0-7 normal, 8-15 bright. Order: black,red,green,yellow,blue,magenta,cyan,white.
    // Dark palette: tuned for the #1C1E21 dark background (bright, saturated).
    static let dark: [SwiftTerm.Color] = [
        c(0x2e,0x34,0x36), c(0xe0,0x4b,0x4b), c(0x8a,0xe2,0x34), c(0xe6,0xc3,0x4f),
        c(0x5a,0x9c,0xf2), c(0xc6,0x82,0xe6), c(0x34,0xe2,0xe2), c(0xd9,0xd9,0xd9),
        c(0x55,0x57,0x53), c(0xef,0x6b,0x6b), c(0xb5,0xf0,0x6a), c(0xfc,0xe9,0x4f),
        c(0x82,0xb6,0xff), c(0xd8,0xa5,0xf5), c(0x6b,0xf0,0xf0), c(0xff,0xff,0xff),
    ]
    // Light palette: DARKER, lower-luminance colors so text is legible on #FCFCFC.
    // (The dark palette's bright greens/yellows are unreadable on white — this is the A bug.)
    static let light: [SwiftTerm.Color] = [
        c(0x2e,0x34,0x36), c(0xc0,0x1c,0x28), c(0x26,0x82,0x26), c(0xa1,0x6c,0x00),
        c(0x1a,0x5f,0xb4), c(0x9c,0x3f,0xb4), c(0x0a,0x7e,0x8c), c(0x50,0x52,0x50),
        c(0x80,0x82,0x80), c(0xed,0x33,0x3b), c(0x2e,0xc2,0x7e), c(0xc8,0x8a,0x00),
        c(0x35,0x84,0xe4), c(0xc0,0x61,0xcb), c(0x1c,0x9a,0xa8), c(0x1a,0x1a,0x1a),
    ]
    static func palette(for theme: AppTheme) -> [SwiftTerm.Color] { theme == .light ? light : dark }
}

// MARK: - The single apply path (used by BOTH terminal entry points)

/// Apply font, bg/fg, caret, ANSI 16-palette, cursor style, and scrollback to a
/// live LocalProcessTerminalView. Safe to call after the process has started
/// (the getTerminal() emulator exists once setup() ran in init).
@MainActor
func applyTerminalAppearance(_ a: TerminalAppearance, to view: LocalProcessTerminalView) {
    // Font (family + size, with fallback chain).
    view.font = a.fontFamily.font(size: a.fontSize)

    // Background / foreground / caret (these are separate from installColors).
    switch a.theme {
    case .dark:
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.13, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.85, alpha: 1)
    case .light:
        view.nativeBackgroundColor = NSColor(calibratedWhite: 0.99, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.15, alpha: 1)
    }
    view.caretColor = NSColor.systemBlue

    // ANSI 16-color palette — THE core gap. Forces a redraw internally.
    view.installColors(TerminalPalettes.palette(for: a.theme))

    // Cursor style + scrollback via the public runtime emulator API.
    let term = view.getTerminal()
    term.setCursorStyle(a.cursorStyle.swiftTerm)
    term.changeScrollback(a.scrollback)
}
