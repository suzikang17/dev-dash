import SwiftUI
import AppKit

/// Typora-style live markdown editor. The text model stays plain markdown; we
/// restyle the NSTextView's textStorage on every edit and selection change so
/// formatting (headings, bold, italic, code, [[wikilinks]]) renders inline. The
/// raw syntax markers (`#`, `**`, backticks, brackets) are HIDDEN except on the
/// line the cursor is on, which "reveals" the source for editing.
///
/// Mirrors CodeEditor's proven textStorage-attribute approach (isRichText = false,
/// direct attribute application), adding selection-aware syntax reveal.
struct MarkdownLiveEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }

        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 10)

        // Word wrap ON (prose, unlike CodeEditor).
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true

        tv.delegate = context.coordinator
        tv.string = text
        context.coordinator.restyle(tv, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // Only reset the string when an external change differs (e.g. switching docs);
        // never on our own edits (that would fight the cursor).
        if tv.string != text {
            tv.string = text
            context.coordinator.restyle(tv, force: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownLiveEditor
        private var lastActiveLine: NSRange?
        private var debounce: DispatchWorkItem?

        init(_ parent: MarkdownLiveEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
            debounce?.cancel()
            let item = DispatchWorkItem { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.restyle(tv, force: true)
            }
            debounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }

        func textViewDidChangeSelection(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            let line = (tv.string as NSString).lineRange(for: clamp(tv.selectedRange(), tv.string))
            if line != lastActiveLine { restyle(tv, force: false) }   // active line moved → re-reveal
        }

        // MARK: - Styling

        private static let base = NSFont.systemFont(ofSize: 13)
        private static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        func restyle(_ tv: NSTextView, force: Bool) {
            guard let storage = tv.textStorage else { return }
            let s = tv.string as NSString
            let full = NSRange(location: 0, length: s.length)
            let active = s.lineRange(for: clamp(tv.selectedRange(), tv.string))
            lastActiveLine = active

            storage.beginEditing()
            storage.setAttributes([.font: Self.base, .foregroundColor: NSColor.labelColor], range: full)

            styleHeadings(storage, s, active: active)
            styleLists(storage, s)
            styleBlockquote(storage, s, active: active)
            styleInline(storage, s, active: active,
                        pattern: "`([^`]+?)`", marker: 1,
                        content: [.font: Self.mono, .foregroundColor: NSColor.systemPink])
            styleInline(storage, s, active: active,
                        pattern: "\\[\\[([^\\]]+?)\\]\\]", marker: 2,
                        content: [.foregroundColor: NSColor.controlAccentColor,
                                  .underlineStyle: NSUnderlineStyle.single.rawValue])
            styleLinks(storage, s, active: active)
            styleWrapped(storage, s, active: active, delimiter: "**", trait: .bold)
            styleWrapped(storage, s, active: active, delimiter: "__", trait: .bold)
            styleWrapped(storage, s, active: active, delimiter: "*", trait: .italic)
            styleWrapped(storage, s, active: active, delimiter: "_", trait: .italic)
            storage.endEditing()
        }

        /// `#`..`######` headings: scale the line font; hide the `# ` marker off the
        /// active line.
        private func styleHeadings(_ storage: NSTextStorage, _ s: NSString, active: NSRange) {
            let re = try! NSRegularExpression(pattern: "^(#{1,6})\\s+", options: [.anchorsMatchLines])
            re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
                guard let m else { return }
                let lineRange = s.lineRange(for: m.range)
                let level = m.range(at: 1).length
                let size: CGFloat = [0: 22, 1: 22, 2: 19, 3: 17, 4: 15, 5: 14, 6: 14][min(level, 6)] ?? 15
                storage.addAttributes([.font: NSFont.boldSystemFont(ofSize: size)], range: lineRange)
                hideOrReveal(storage, marker: m.range, active: active, dimColor: .tertiaryLabelColor)
            }
        }

        /// `[text](url)` links: accent the visible text, hide `[`, `](url)` off-line.
        private func styleLinks(_ storage: NSTextStorage, _ s: NSString, active: NSRange) {
            let re = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+?)\\]\\(([^)\\n]+?)\\)")
            re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
                guard let m else { return }
                let text = m.range(at: 1)
                storage.addAttributes([.foregroundColor: NSColor.controlAccentColor,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue], range: text)
                let lead = NSRange(location: m.range.location, length: 1)                       // [
                let trailLoc = text.location + text.length                                       // ](url)
                let trail = NSRange(location: trailLoc, length: NSMaxRange(m.range) - trailLoc)
                hideOrReveal(storage, marker: lead, active: active)
                hideOrReveal(storage, marker: trail, active: active)
            }
        }

        /// `>` blockquotes: italic + secondary content, hide the `> ` marker off-line.
        private func styleBlockquote(_ storage: NSTextStorage, _ s: NSString, active: NSRange) {
            let re = try! NSRegularExpression(pattern: "^(>\\s?)(.*)$", options: [.anchorsMatchLines])
            re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
                guard let m else { return }
                storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: m.range(at: 2))
                applyTrait(storage, .italic, range: m.range(at: 2))
                hideOrReveal(storage, marker: m.range(at: 1), active: active)
            }
        }

        /// List items: dim the `-`/`*`/`1.` marker and add a hanging indent so wrapped
        /// lines align under the text. The marker stays visible (it reads as a bullet).
        private func styleLists(_ storage: NSTextStorage, _ s: NSString) {
            let re = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+]|\\d+\\.)([ \\t]+)", options: [.anchorsMatchLines])
            re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
                guard let m else { return }
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: m.range(at: 2))
                let para = NSMutableParagraphStyle()
                para.headIndent = 16
                storage.addAttributes([.paragraphStyle: para], range: s.lineRange(for: m.range))
            }
        }

        /// Inline patterns whose whole match's first `marker` chars + matching tail
        /// are the delimiters (used for `code` and `[[wikilink]]`).
        private func styleInline(_ storage: NSTextStorage, _ s: NSString, active: NSRange,
                                 pattern: String, marker: Int, content: [NSAttributedString.Key: Any]) {
            let re = try! NSRegularExpression(pattern: pattern)
            re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
                guard let m else { return }
                let inner = m.range(at: 1)
                storage.addAttributes(content, range: inner)
                let lead = NSRange(location: m.range.location, length: marker)
                let trail = NSRange(location: inner.location + inner.length, length: marker)
                hideOrReveal(storage, marker: lead, active: active)
                hideOrReveal(storage, marker: trail, active: active)
            }
        }

        /// Symmetric `**bold**` / `*italic*` style wrappers. `*` skips `**` so bold
        /// and italic don't collide.
        private func styleWrapped(_ storage: NSTextStorage, _ s: NSString, active: NSRange,
                                  delimiter: String, trait: NSFontDescriptor.SymbolicTraits) {
            let d = NSRegularExpression.escapedPattern(for: delimiter)
            let pattern: String
            if delimiter == "*" { pattern = "(?<!\\*)\\*(?!\\*)([^*\\n]+?)\\*(?!\\*)" }
            else if delimiter == "_" { pattern = "(?<![\\w_])_(?!_)([^_\\n]+?)_(?![\\w_])" }
            else { pattern = "\(d)([^\\n]+?)\(d)" }
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
                guard let m else { return }
                let inner = m.range(at: 1)
                applyTrait(storage, trait, range: inner)
                let lead = NSRange(location: m.range.location, length: delimiter.count)
                let trail = NSRange(location: inner.location + inner.length, length: delimiter.count)
                hideOrReveal(storage, marker: lead, active: active)
                hideOrReveal(storage, marker: trail, active: active)
            }
        }

        // MARK: - helpers

        /// Hide a syntax marker by collapsing it to a near-zero clear glyph — unless
        /// the cursor is on its line, where it's shown dimmed for editing.
        private func hideOrReveal(_ storage: NSTextStorage, marker: NSRange, active: NSRange,
                                  dimColor: NSColor = .tertiaryLabelColor) {
            guard marker.length > 0, NSMaxRange(marker) <= storage.length else { return }
            if NSIntersectionRange(marker, active).length > 0 || marker.location == active.location {
                storage.addAttributes([.foregroundColor: dimColor], range: marker)
            } else {
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1),
                                       .foregroundColor: NSColor.clear], range: marker)
            }
        }

        private func applyTrait(_ storage: NSTextStorage, _ trait: NSFontDescriptor.SymbolicTraits, range: NSRange) {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let f = (value as? NSFont) ?? Self.base
                let desc = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(trait))
                if let nf = NSFont(descriptor: desc, size: f.pointSize) {
                    storage.addAttributes([.font: nf], range: sub)
                }
            }
        }

        private func clamp(_ r: NSRange, _ s: String) -> NSRange {
            let len = (s as NSString).length
            return NSRange(location: min(r.location, len), length: 0)
        }
    }
}
