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
        ZStack(alignment: .leading) {
            Button(action: onEdit) {
                Rectangle().fill(Color.clear).frame(maxWidth: .infinity, minHeight: 18)
            }
            .buttonStyle(.plain)

            rendered
                .font(DSFont.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.absoluteString.hasPrefix(Self.linkScheme) else { return .systemAction }
                    let title = String(url.absoluteString.dropFirst(Self.linkScheme.count)).removingPercentEncoding ?? ""
                    if !title.isEmpty { onOpenLink(title) }
                    return .handled
                })
        }
    }

    private var rendered: Text {
        let ns = text as NSString
        let matches = (try? NSRegularExpression(pattern: "\\[\\[(.+?)\\]\\]"))?
            .matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        if matches.isEmpty { return Text(text.isEmpty ? " " : text) }

        var result = Text("")
        var loc = 0
        for m in matches {
            if m.range.location > loc {
                result = result + Text(ns.substring(with: NSRange(location: loc, length: m.range.location - loc)))
            }
            result = result + link(ns.substring(with: m.range(at: 1)))
            loc = m.range.location + m.range.length
        }
        if loc < ns.length { result = result + Text(ns.substring(from: loc)) }
        return result
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
