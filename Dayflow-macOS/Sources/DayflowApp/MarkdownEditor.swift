import AppKit
import SwiftUI

/// A multi-line plain-text Markdown editor wrapping `NSTextView`.
///
/// Why NSTextView and not SwiftUI's TextEditor:
/// - We want Tab to actually insert a literal tab (not advance focus).
/// - We want to intercept clicks on `- [ ]` / `- [x]` so the user can toggle
///   a checkbox by clicking, exactly like Obsidian.
/// - We syntax-highlight bullets/headers/checkboxes inline.
/// - We persist on every keystroke via the binding.
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
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.drawsBackground = false
        tv.usesFindBar = true
        tv.string = text

        // intercept tab as literal indent
        context.coordinator.textView = tv

        // click handler for checkboxes
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
            // preserve selection
            let sel = tv.selectedRange()
            tv.string = text
            let safe = NSRange(location: min(sel.location, text.count), length: 0)
            tv.setSelectedRange(safe)
            context.coordinator.applyHighlighting()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.onChange(tv.string)
            applyHighlighting()
        }

        // Tab → literal "  " (2 spaces) for nesting markdown lists.
        // Shift+Tab → outdent the current line (remove 2 leading spaces).
        // Enter → smart continuation: if previous line is `- [ ]` or `- `, repeat.
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
            if line.hasPrefix("  ") {
                let newLine = String(line.dropFirst(2))
                tv.shouldChangeText(in: lineRange, replacementString: newLine)
                tv.replaceCharacters(in: lineRange, with: newLine)
                tv.didChangeText()
                let newCaret = max(lineRange.location, sel.location - 2)
                tv.setSelectedRange(NSRange(location: newCaret, length: 0))
            } else if line.hasPrefix(" ") {
                let newLine = String(line.dropFirst(1))
                tv.shouldChangeText(in: lineRange, replacementString: newLine)
                tv.replaceCharacters(in: lineRange, with: newLine)
                tv.didChangeText()
                let newCaret = max(lineRange.location, sel.location - 1)
                tv.setSelectedRange(NSRange(location: newCaret, length: 0))
            }
        }

        /// On Enter, peek at the current line. If it's a list item, continue the list.
        /// If the line is an empty list marker (e.g. just "- [ ] "), break out instead.
        private func continueListItem(_ tv: NSTextView) -> Bool {
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)

            // count leading spaces
            var indent = ""
            for ch in line {
                if ch == " " { indent.append(" ") } else { break }
            }
            let body = line.dropFirst(indent.count)

            // checkbox: "- [ ] xxx" or "- [x] xxx"
            if let match = checkboxPrefix(of: String(body)) {
                let rest = body.dropFirst(match.count).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    // empty list item — clear the line and break out of the list
                    tv.shouldChangeText(in: lineRange, replacementString: "\n")
                    tv.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                    return true
                }
                let newLine = "\n\(indent)- [ ] "
                tv.insertText(newLine, replacementRange: tv.selectedRange())
                return true
            }
            // plain bullet: "- xxx" or "* xxx"
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

        private func checkboxPrefix(of line: String) -> String? {
            // matches "- [ ] " or "- [x] " (and *,+; X,✓)
            let bullets: [Character] = ["-", "*", "+"]
            guard let first = line.first, bullets.contains(first) else { return nil }
            let after = line.dropFirst()
            guard after.hasPrefix(" [") else { return nil }
            // need 4 more chars: "[", x, "]", " "
            let inside = after.dropFirst(2)
            guard inside.count >= 3 else { return nil }
            let arr = Array(inside)
            let mark = arr[0]
            guard arr[1] == "]", arr[2] == " " else { return nil }
            guard mark == " " || mark == "x" || mark == "X" || mark == "✓" else { return nil }
            return "\(first) [\(mark)] "
        }

        // MARK: - click toggling

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let tv = textView else { return }
            let point = gesture.location(in: tv)
            let inset = tv.textContainerInset
            let glyphPoint = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
            guard let container = tv.textContainer, let lm = tv.layoutManager else { return }
            let index = lm.characterIndex(for: glyphPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            let ns = tv.string as NSString
            guard index < ns.length else { return }
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let line = ns.substring(with: lineRange)

            // find "- [ ]" or "- [x]" and the position of the inner char
            guard let openBracket = line.range(of: "[") else { return }
            let innerIdx = line.index(after: openBracket.lowerBound)
            guard innerIdx < line.endIndex else { return }
            let inner = line[innerIdx]
            guard inner == " " || inner == "x" || inner == "X" || inner == "✓" else { return }

            // compute absolute index of the inner char
            let innerOffset = line.distance(from: line.startIndex, to: innerIdx)
            let absIndex = lineRange.location + innerOffset

            // figure out if click landed within ~12pt of the bracket horizontally
            let bracketRange = NSRange(location: lineRange.location + line.distance(from: line.startIndex, to: openBracket.lowerBound), length: 3)
            let bracketRect = lm.boundingRect(forGlyphRange: bracketRange, in: container)
            let expanded = bracketRect.insetBy(dx: -6, dy: -3)
            guard expanded.contains(glyphPoint) else { return }

            // toggle the inner character
            let newChar: String = (inner == " ") ? "x" : " "
            let replaceRange = NSRange(location: absIndex, length: 1)
            tv.shouldChangeText(in: replaceRange, replacementString: newChar)
            tv.replaceCharacters(in: replaceRange, with: newChar)
            tv.didChangeText()
        }

        // MARK: - syntax highlighting

        func applyHighlighting() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            storage.beginEditing()
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
            ], range: full)

            let ns = tv.string as NSString
            ns.enumerateSubstrings(in: full, options: .byLines) { (substring, lineRange, _, _) in
                guard let line = substring else { return }
                let trimmedStart = line.firstIndex(where: { $0 != " " }) ?? line.startIndex
                let leadingSpaces = line.distance(from: line.startIndex, to: trimmedStart)
                let body = line[trimmedStart...]

                // headers
                if body.hasPrefix("# ") {
                    storage.addAttributes([
                        .font: NSFont.boldSystemFont(ofSize: 18),
                        .foregroundColor: NSColor.labelColor,
                    ], range: lineRange)
                    return
                }
                if body.hasPrefix("## ") {
                    storage.addAttributes([
                        .font: NSFont.boldSystemFont(ofSize: 15),
                        .foregroundColor: NSColor.labelColor,
                    ], range: lineRange)
                    return
                }
                // checkbox
                if body.hasPrefix("- [x]") || body.hasPrefix("- [X]") || body.hasPrefix("- [✓]") {
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ], range: lineRange)
                    let bracketRange = NSRange(location: lineRange.location + leadingSpaces, length: 5)
                    storage.addAttributes([
                        .foregroundColor: NSColor.systemGreen,
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                    ], range: bracketRange)
                    return
                }
                if body.hasPrefix("- [ ]") {
                    let bracketRange = NSRange(location: lineRange.location + leadingSpaces, length: 5)
                    storage.addAttributes([
                        .foregroundColor: NSColor.systemOrange,
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                    ], range: bracketRange)
                    return
                }
                // bullets
                if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                    let bulletRange = NSRange(location: lineRange.location + leadingSpaces, length: 1)
                    storage.addAttributes([
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ], range: bulletRange)
                }
            }
            storage.endEditing()
        }
    }
}
