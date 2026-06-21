import SwiftUI
import AppKit

enum BulletKey { case enterNew, indent, outdent, mergeBack, focusUp, focusDown }

/// A single editable bullet line. Wraps NSTextField so we can intercept the field
/// editor's command selectors (Return/Tab/Backspace/arrows) and turn them into
/// outline actions, which SwiftUI TextField cannot do.
struct BulletRow: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    var caretToEnd: Bool = false
    let onKey: (BulletKey) -> Void
    let onFocus: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 13)
        tf.lineBreakMode = .byWordWrapping
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        tf.delegate = context.coordinator
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
        context.coordinator.parent = self
        if isFocused, tf.window?.firstResponder != tf.currentEditor() {
            DispatchQueue.main.async {
                tf.window?.makeFirstResponder(tf)
                if caretToEnd, let editor = tf.currentEditor() {
                    editor.selectedRange = NSRange(location: tf.stringValue.count, length: 0)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BulletRow
        init(_ parent: BulletRow) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) { parent.onFocus() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onKey(.enterNew); return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onKey(.indent); return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onKey(.outdent); return true
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.selectedRange == NSRange(location: 0, length: 0) {
                    parent.onKey(.mergeBack); return true
                }
                return false
            case #selector(NSResponder.moveUp(_:)):
                parent.onKey(.focusUp); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onKey(.focusDown); return true
            default:
                return false
            }
        }
    }
}
