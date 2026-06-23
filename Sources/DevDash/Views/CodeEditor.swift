import SwiftUI
import AppKit

/// Native NSTextView-based code editor with regex syntax highlighting.
/// Gives us ⌘F find panel, undo/redo, multi-cursor (TextKit2), and file-type aware coloring.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: SyntaxHighlighter.Language
    /// When false the view is a read-only, still-selectable code viewer.
    var isEditable: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isRichText = false
        textView.usesFindBar = true                // ⌘F → find bar
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = true
        textView.smartInsertDeleteEnabled = false

        // Word wrap OFF — code editors typically don't wrap
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scroll.hasHorizontalScroller = true

        // Tab = 4 spaces
        let para = NSMutableParagraphStyle()
        para.tabStops = (1...20).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 26, options: [:]) }
        para.defaultTabInterval = 26
        textView.defaultParagraphStyle = para

        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.applyHighlighting(to: textView, language: language)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self   // keep binding/language current for the change handler
        if tv.string != text {
            tv.string = text
            context.coordinator.applyHighlighting(to: tv, language: language)
        } else if context.coordinator.lastLanguage != language {
            context.coordinator.applyHighlighting(to: tv, language: language)
        }
        context.coordinator.lastLanguage = language
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var lastLanguage: SyntaxHighlighter.Language?
        private var debounce: DispatchWorkItem?

        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            // Debounce highlighting on rapid typing
            debounce?.cancel()
            let item = DispatchWorkItem { [weak self, weak tv] in
                guard let self = self, let tv = tv else { return }
                self.applyHighlighting(to: tv, language: self.parent.language)
            }
            debounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }

        func applyHighlighting(to tv: NSTextView, language: SyntaxHighlighter.Language) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: full)
            for token in SyntaxHighlighter.tokenize(tv.string, language: language) {
                storage.addAttributes([.foregroundColor: token.kind.color], range: token.range)
                if token.kind == .comment {
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).italic(), range: token.range)
                }
            }
            storage.endEditing()
        }
    }
}

private extension NSFont {
    func italic() -> NSFont {
        let descriptor = self.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
