import SwiftUI

/// Read-only render of a bullet line: `[[title]]` wikilinks become clickable accent
/// links (brackets hidden), everything else is plain text. Tapping a link calls
/// `onOpenLink(title)`; tapping plain text / empty space calls `onEdit()` to swap the
/// row to the editable field.
///
/// Layering trick: a full-width transparent Button sits BEHIND the Text. Link glyphs
/// are interactive and consume their own taps (handled via the openURL environment);
/// plain glyphs are non-interactive, so those taps fall through to the focus button.
struct BulletRendered: View {
    let text: String
    let onOpenLink: (String) -> Void
    let onEdit: () -> Void

    private static let linkScheme = "devdash-lore:"

    var body: some View {
        rendered
            .font(DSFont.body)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }            // tap anywhere on the bullet → edit
            .environment(\.openURL, OpenURLAction { url in   // tapping a link glyph → open
                guard url.absoluteString.hasPrefix(Self.linkScheme) else { return .systemAction }
                let title = String(url.absoluteString.dropFirst(Self.linkScheme.count)).removingPercentEncoding ?? ""
                if !title.isEmpty { onOpenLink(title) }
                return .handled
            })
    }

    // Inline markdown handled in rendered bullets, in priority order (earliest match
    // wins; ties break by this order). Kept simple/non-nested for V1.
    private static let patterns: [(re: NSRegularExpression, kind: Int)] = [
        (try! NSRegularExpression(pattern: "\\[\\[([^\\]]+?)\\]\\]"), 0),               // [[wikilink]]
        (try! NSRegularExpression(pattern: "\\[([^\\]\\n]+?)\\]\\(([^)\\n]+?)\\)"), 1), // [text](url)
        (try! NSRegularExpression(pattern: "`([^`]+?)`"), 2),                            // `code`
        (try! NSRegularExpression(pattern: "(\\*\\*|__)([^\\n]+?)\\1"), 3),              // **bold**
        (try! NSRegularExpression(pattern: "(?<![*_])([*_])([^\\n]+?)\\1"), 4),          // *italic*
    ]

    private var rendered: Text {
        if text.isEmpty { return Text(" ") }
        let ns = text as NSString
        var result = Text("")
        var idx = 0
        while idx < ns.length {
            let search = NSRange(location: idx, length: ns.length - idx)
            var best: NSTextCheckingResult?
            var bestKind = -1
            for (re, kind) in Self.patterns {
                guard let m = re.firstMatch(in: text, range: search) else { continue }
                if best == nil || m.range.location < best!.range.location {
                    best = m; bestKind = kind
                }
            }
            guard let m = best else {
                result = result + Text(ns.substring(from: idx)); break
            }
            if m.range.location > idx {
                result = result + Text(ns.substring(with: NSRange(location: idx, length: m.range.location - idx)))
            }
            result = result + styled(m, kind: bestKind, ns: ns)
            idx = m.range.location + m.range.length
        }
        return result
    }

    private func styled(_ m: NSTextCheckingResult, kind: Int, ns: NSString) -> Text {
        func grp(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        switch kind {
        case 0: return link(grp(1))                                                   // wikilink (clickable)
        case 1: return Text(grp(1)).foregroundColor(.accentColor)                     // [text](url)
        case 2: return Text(grp(1)).font(.system(.body, design: .monospaced)).foregroundColor(.pink)
        case 3: return Text(grp(2)).bold()
        case 4: return Text(grp(2)).italic()
        default: return Text(ns.substring(with: m.range))
        }
    }

    private func link(_ title: String) -> Text {
        var a = AttributedString(title)
        a.foregroundColor = .accentColor
        a.underlineStyle = .single
        if let enc = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "\(Self.linkScheme)\(enc)") {
            a.link = url
        }
        return Text(a)
    }
}
