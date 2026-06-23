import SwiftUI

/// Read-only render of a bullet line. Rendered inside a plain `Button` so taps are
/// handled by AppKit hit-testing (reliable) rather than SwiftUI `Text` link
/// interaction (which eats taps on link-containing text).
///
/// Tap behaviour: if the whole bullet is a single `[[backlink]]`, the tap opens that
/// doc; otherwise the tap enters edit mode. Inline markdown (bold/italic/code/links)
/// is styled for appearance only — no interactive link runs.
struct BulletRendered: View {
    let text: String
    let onOpenLink: (String) -> Void
    let onEdit: () -> Void

    /// The title if this bullet is exactly one `[[wikilink]]` and nothing else.
    private var pureLinkTitle: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[["), t.hasSuffix("]]") else { return nil }
        let inner = String(t.dropFirst(2).dropLast(2))
        guard !inner.isEmpty, !inner.contains("[["), !inner.contains("]]") else { return nil }
        return inner
    }

    var body: some View {
        Button {
            if let title = pureLinkTitle { onOpenLink(title) } else { onEdit() }
        } label: {
            rendered
                .font(DSFont.body)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Inline markdown, in priority order (earliest match wins; ties break by order).
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
        case 0: return Text(grp(1)).foregroundColor(.accentColor).underline()          // wikilink (appearance)
        case 1: return Text(grp(1)).foregroundColor(.accentColor)                       // [text](url)
        case 2: return Text(grp(1)).font(.system(.body, design: .monospaced)).foregroundColor(.pink)
        case 3: return Text(grp(2)).bold()
        case 4: return Text(grp(2)).italic()
        default: return Text(ns.substring(with: m.range))
        }
    }
}
