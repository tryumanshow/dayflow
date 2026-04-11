import AppKit
import SwiftUI

/// Single-line `NSTextField` wrapped for SwiftUI, used as the editable surface
/// of one block in BlockEditor. NSTextField is the only AppKit text control
/// whose IME / marked-text handling is rock solid for short single-line input,
/// which is exactly what each block needs.
///
/// We never mutate the field's contents from the outside while the user is
/// typing — we only sync `text` from the binding when it differs, and we never
/// touch `attributedStringValue` (which would corrupt the IME composition).
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Bool
    var font: NSFont
    var placeholder: String = ""
    var foregroundColor: NSColor = .labelColor
    var strikethrough: Bool = false

    var onTab: () -> Void = {}
    var onShiftTab: () -> Void = {}
    var onEnter: () -> Void = {}
    var onBackspaceEmpty: () -> Void = {}
    var onCommandReturn: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> KeyAwareInlineField {
        let tf = KeyAwareInlineField()
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.delegate = context.coordinator
        tf.font = font
        tf.placeholderString = placeholder
        tf.usesSingleLineMode = false
        tf.cell?.usesSingleLineMode = false
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        tf.lineBreakMode = .byWordWrapping
        tf.maximumNumberOfLines = 0
        tf.textColor = foregroundColor
        tf.stringValue = text
        tf.onCommandReturn = { context.coordinator.parent.onCommandReturn() }
        return tf
    }

    func updateNSView(_ nsView: KeyAwareInlineField, context: Context) {
        context.coordinator.parent = self

        // Only mutate the visible value if the underlying source changed AND
        // the field isn't currently the first responder. Touching stringValue
        // mid-edit blows up Korean IME composition.
        let isEditing = nsView.currentEditor() != nil
        if !isEditing && nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.font != font { nsView.font = font }
        if nsView.textColor != foregroundColor { nsView.textColor = foregroundColor }
        nsView.placeholderString = placeholder

        if isFocused {
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                if window.firstResponder !== nsView.currentEditor() {
                    window.makeFirstResponder(nsView)
                    if let editor = nsView.currentEditor() as? NSTextView {
                        let len = editor.string.count
                        editor.selectedRange = NSRange(location: len, length: 0)
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        init(_ parent: InlineTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocusChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Sync the latest typed value into the binding before any nav action.
            parent.text = control.stringValue

            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onShiftTab()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onEnter()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                if control.stringValue.isEmpty {
                    parent.onBackspaceEmpty()
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}

/// NSTextField subclass that lets us catch Cmd+Return — `doCommandBy` doesn't
/// receive command-return because it isn't routed as an "insertNewline" action.
final class KeyAwareInlineField: NSTextField {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           (event.keyCode == 36 || event.keyCode == 76) {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
