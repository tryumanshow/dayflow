import AppKit
import SwiftUI

/// Plain-text markdown editor (NSTextView wrapper).
///
/// Earlier we tried to live-rewrite `- [ ]` into `☐` on every keystroke, but
/// that fought with NSTextView's typing flow and Korean IME marked-text
/// handling — caret jumped, glyphs duplicated. Reverted to a simpler model:
///
/// - Buffer is canonical markdown end-to-end. No substitution while typing.
/// - Syntax highlighting makes brackets visually pop (orange for open,
///   green + strikethrough for done) so the editor still feels "rendered".
/// - Clicking the bracket region of a `- [ ]` / `- [x]` line toggles it in
///   place by mutating the single inner character.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var onChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 18, height: 18)
        tv.drawsBackground = false
        tv.usesFindBar = true
        tv.string = text

        context.coordinator.textView = tv

        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleClick(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        tv.addGestureRecognizer(click)

        DispatchQueue.main.async {
            context.coordinator.applyHighlighting()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            let safe = NSRange(location: min(sel.location, text.count), length: 0)
            tv.setSelectedRange(safe)
            context.coordinator.applyHighlighting()
        }
    }

    /// Display helper — used by the month-view preview rail (read-only mode).
    /// Pretty-print canonical markdown without mutating it.
    static func markdownToDisplay(_ md: String) -> String { md }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if tv.string != parent.text {
                parent.text = tv.string
                parent.onChange(tv.string)
            }
            applyHighlighting()
        }

        /// Tab → 2 literal spaces (markdown nesting).
        /// Shift+Tab → outdent the current line.
        /// Enter → continue `- [ ]` / `- ` / `* ` lists at the same indent.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                outdentCurrentLine(textView)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                return continueListItem(textView)
            default:
                return false
            }
        }

        private func outdentCurrentLine(_ tv: NSTextView) {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let line = ns.substring(with: lineRange)
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            if leadingSpaces == 0 { return }
            let drop = min(2, leadingSpaces)
            let newLine = String(line.dropFirst(drop))
            tv.shouldChangeText(in: lineRange, replacementString: newLine)
            tv.replaceCharacters(in: lineRange, with: newLine)
            tv.didChangeText()
            let newCaret = max(lineRange.location, sel.location - drop)
            tv.setSelectedRange(NSRange(location: newCaret, length: 0))
        }

        private func continueListItem(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let raw = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)

            var indent = ""
            for ch in raw {
                if ch == " " { indent.append(" ") } else { break }
            }
            let body = raw.dropFirst(indent.count)

            // checkbox: "- [ ] xxx" / "- [x] xxx"
            let checkboxPrefixes = ["- [ ] ", "- [x] ", "- [X] "]
            for p in checkboxPrefixes {
                if body.hasPrefix(p) {
                    let rest = body.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty {
                        // empty list item — break out
                        tv.shouldChangeText(in: lineRange, replacementString: "\n")
                        tv.replaceCharacters(in: lineRange, with: "\n")
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                        return true
                    }
                    tv.insertText("\n\(indent)- [ ] ", replacementRange: tv.selectedRange())
                    return true
                }
            }
            if body.hasPrefix("- ") || body.hasPrefix("* ") {
                let marker = String(body.prefix(2))
                let rest = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    tv.shouldChangeText(in: lineRange, replacementString: "\n")
                    tv.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                    return true
                }
                tv.insertText("\n\(indent)\(marker)", replacementRange: tv.selectedRange())
                return true
            }
            return false
        }

        // MARK: - click toggle on `[ ]` / `[x]`

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let tv = textView else { return }
            let point = gesture.location(in: tv)
            let inset = tv.textContainerInset
            let glyphPoint = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
            guard let container = tv.textContainer, let lm = tv.layoutManager else { return }
            let index = lm.characterIndex(for: glyphPoint, in: container,
                                          fractionOfDistanceBetweenInsertionPoints: nil)
            let storage = tv.textStorage!
            let ns = storage.string as NSString
            guard index < ns.length else { return }

            // find current line and look for "- [ ]" or "- [x]"
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let line = ns.substring(with: lineRange)
            let indent = line.prefix(while: { $0 == " " }).count
            let body = line.dropFirst(indent)
            guard body.hasPrefix("- [") else { return }
            let bracketStart = lineRange.location + indent + 3 // points at the inner char
            guard bracketStart < ns.length else { return }
            let innerRange = NSRange(location: bracketStart, length: 1)
            let inner = ns.substring(with: innerRange)
            guard inner == " " || inner == "x" || inner == "X" else { return }

            // also confirm the click landed within the bracket region
            let bracketRange = NSRange(location: lineRange.location + indent + 2, length: 3)
            let bracketRect = lm.boundingRect(forGlyphRange: bracketRange, in: container)
            if !bracketRect.insetBy(dx: -8, dy: -3).contains(glyphPoint) { return }

            let toggled = (inner == " ") ? "x" : " "
            tv.shouldChangeText(in: innerRange, replacementString: toggled)
            storage.replaceCharacters(in: innerRange, with: toggled)
            tv.didChangeText()

            parent.text = tv.string
            parent.onChange(tv.string)
            applyHighlighting()
        }

        // MARK: - syntax highlighting

        func applyHighlighting() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            let baseFont = NSFont.systemFont(ofSize: 14, weight: .regular)
            storage.beginEditing()
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
            ], range: full)

            let ns = tv.string as NSString
            ns.enumerateSubstrings(in: full, options: .byLines) { (substring, lineRange, _, _) in
                guard let line = substring else { return }
                let indent = line.prefix(while: { $0 == " " }).count
                let body = line.dropFirst(indent)

                // headers
                if body.hasPrefix("# ") {
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 22, weight: .bold),
                    ], range: lineRange)
                    return
                }
                if body.hasPrefix("## ") {
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                    ], range: lineRange)
                    return
                }
                if body.hasPrefix("### ") {
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ], range: lineRange)
                    return
                }

                // checkbox done
                if body.hasPrefix("- [x]") || body.hasPrefix("- [X]") {
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ], range: lineRange)
                    let bracketRange = NSRange(location: lineRange.location + indent, length: 5)
                    storage.addAttributes([
                        .foregroundColor: NSColor.systemGreen,
                        .strikethroughStyle: 0,
                        .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
                    ], range: bracketRange)
                    return
                }
                // checkbox open
                if body.hasPrefix("- [ ]") {
                    let bracketRange = NSRange(location: lineRange.location + indent, length: 5)
                    storage.addAttributes([
                        .foregroundColor: NSColor.systemOrange,
                        .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
                    ], range: bracketRange)
                    return
                }

                // bullets
                if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                    let bulletRange = NSRange(location: lineRange.location + indent, length: 1)
                    storage.addAttributes([
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ], range: bulletRange)
                }
            }
            storage.endEditing()
        }
    }
}
