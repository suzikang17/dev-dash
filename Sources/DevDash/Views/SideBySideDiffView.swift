import SwiftUI
import AppKit
import DevDashCore

/// Single-file diff: scrolls on its own. For embedding many diffs in one shared
/// scroll (e.g. a whole commit), use `DiffRowsView` directly instead.
struct SideBySideDiffView: View {
    let diff: FileDiff
    let language: SyntaxHighlighter.Language
    var scrollID: Binding<Int?> = .constant(nil)

    var body: some View {
        ScrollView(.vertical) {
            DiffRowsView(diff: diff, language: language, scrollTarget: true)
                .padding(.vertical, DSSpace.xs)
        }
        .scrollPosition(id: scrollID, anchor: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

/// The diff rows themselves, with NO enclosing ScrollView. Lazily renders rows so
/// it can be embedded inside an outer ScrollView (commit detail) without nesting
/// scroll views, and large diffs only build rows as they scroll into view.
struct DiffRowsView: View {
    let diff: FileDiff
    let language: SyntaxHighlighter.Language
    var scrollTarget: Bool = false

    var body: some View {
        if diff.isBinary {
            placeholder("Binary file — no text diff")
        } else if diff.tooLarge {
            placeholder("Diff too large to render")
        } else if diff.rows.isEmpty {
            placeholder("No changes")
        } else {
            rows
        }
    }

    @ViewBuilder
    private var rows: some View {
        let stack = LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.rows.enumerated()), id: \.offset) { idx, row in
                DiffRowView(row: row, language: language).id(idx)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if scrollTarget {
            stack.scrollTargetLayout()
        } else {
            stack
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(DSFont.label)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpace.md)
    }
}

private struct DiffRowView: View {
    let row: DiffRow
    let language: SyntaxHighlighter.Language

    var body: some View {
        switch row.kind {
        case .hunkHeader:
            Text(verbatim: row.headerText ?? "")
                .font(DSFont.mono(.caption2))
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.08))
        default:
            HStack(alignment: .top, spacing: 0) {
                cell(lineNo: row.leftLineNo, text: row.leftText, spans: row.leftSpans,
                     side: .left)
                Rectangle().fill(DSColor.hairline).frame(width: 1)
                cell(lineNo: row.rightLineNo, text: row.rightText, spans: row.rightSpans,
                     side: .right)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private enum Side { case left, right }

    @ViewBuilder
    private func cell(lineNo: Int?, text: String?, spans: [WordSpan], side: Side) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(lineNo.map(String.init) ?? "")
                .font(DSFont.monoDigits(.caption2))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
            if let text {
                Text(styled(text, spans: spans, side: side))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(side: side))
    }

    private func rowBackground(side: Side) -> Color {
        switch row.kind {
        case .added:    return side == .right ? DSColor.success.opacity(0.12) : .clear
        case .removed:  return side == .left  ? DSColor.danger.opacity(0.12)  : .clear
        case .modified: return side == .left  ? DSColor.danger.opacity(0.10)  : DSColor.success.opacity(0.10)
        default:        return .clear
        }
    }

    /// Build an attributed line: syntax colors (via SyntaxHighlighter NSColors) + word-span backgrounds.
    private func styled(_ text: String, spans: [WordSpan], side: Side) -> AttributedString {
        let ms = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ])
        for token in SyntaxHighlighter.tokenize(text, language: language) {
            if NSMaxRange(token.range) <= ms.length {
                ms.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            }
        }
        let bg: NSColor? = {
            switch row.kind {
            case .modified: return side == .left
                ? NSColor.systemRed.withAlphaComponent(0.30)
                : NSColor.systemGreen.withAlphaComponent(0.30)
            default: return nil
            }
        }()
        if let bg {
            for span in spans {
                if let ns = nsRange(in: text, charStart: span.start, charLength: span.length),
                   NSMaxRange(ns) <= ms.length {
                    ms.addAttribute(.backgroundColor, value: bg, range: ns)
                }
            }
        }
        return AttributedString(ms)
    }

    private func nsRange(in text: String, charStart: Int, charLength: Int) -> NSRange? {
        guard let start = text.index(text.startIndex, offsetBy: charStart, limitedBy: text.endIndex),
              let end = text.index(start, offsetBy: charLength, limitedBy: text.endIndex) else { return nil }
        return NSRange(start..<end, in: text)
    }
}
