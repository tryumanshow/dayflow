import AppKit
import SwiftUI

/// Markdown editor with live rendering of `- [ ]` / `- [x]` checkboxes.
///
/// What "live rendering" means in this implementation:
/// - The DB / Store always holds canonical markdown (`- [ ]`, `- [x]`).
/// - The NSTextView displays canonical markdown collapsed to single glyphs
///   (`☐`, `☑`). The user types markdown the normal way; the moment a
///   `- [ ] ` or `- [x] ` literal lands in the buffer it is rewritten in
///   place to its glyph form.
/// - Clicking a `☐` / `☑` glyph toggles it.
/// - On every change we re-expand the visible text back to canonical markdown
///   and bubble that up via `onChange`, so the persisted DB content stays
///   markdown-clean.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String           // canonical markdown — source of truth
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
        tv.string = Self.markdownToDisplay(text)

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
        let display = Self.markdownToDisplay(text)
        if tv.string != display {
            // External change (different day loaded). Reset wholesale.
            let sel = tv.selectedRange()
            tv.string = display
            let safe = NSRange(location: min(sel.location, display.count), length: 0)
            tv.setSelectedRange(safe)
            context.coordinator.applyHighlighting()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - md ↔ display conversion -----------------------------------------

    /// Collapse `- [ ]` → `☐`, `- [x]` → `☑` (only for the literal markdown
    /// checkbox prefix; doesn't touch text outside the prefix). Indent is
    /// preserved exactly.
    static func markdownToDisplay(_ md: String) -> String {
        var out = ""
        out.reserveCapacity(md.count)
        let lines = md.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            out.append(transformLineMdToDisplay(line))
            if i < lines.count - 1 { out.append("\n") }
        }
        return out
    }

    static func displayToMarkdown(_ display: String) -> String {
        var out = ""
        out.reserveCapacity(display.count + 16)
        let lines = display.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            out.append(transformLineDisplayToMd(line))
            if i < lines.count - 1 { out.append("\n") }
        }
        return out
    }

    private static func transformLineMdToDisplay(_ line: String) -> String {
        // capture leading whitespace
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
        let indent = String(line[line.startIndex..<idx])
        let body = line[idx..<line.endIndex]

        if body.hasPrefix("- [ ] ") {
            return indent + "☐ " + String(body.dropFirst(6))
        }
        if body.hasPrefix("- [ ]") {
            return indent + "☐" + String(body.dropFirst(5))
        }
        if body.hasPrefix("- [x] ") || body.hasPrefix("- [X] ") || body.hasPrefix("- [✓] ") {
            return indent + "☑ " + String(body.dropFirst(6))
        }
        if body.hasPrefix("- [x]") || body.hasPrefix("- [X]") || body.hasPrefix("- [✓]") {
            return indent + "☑" + String(body.dropFirst(5))
        }
        return line
    }

    private static func transformLineDisplayToMd(_ line: String) -> String {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
        let indent = String(line[line.startIndex..<idx])
        let body = line[idx..<line.endIndex]

        if body.hasPrefix("☐ ") {
            return indent + "- [ ] " + String(body.dropFirst(2))
        }
        if body.hasPrefix("☐") {
            return indent + "- [ ]" + String(body.dropFirst(1))
        }
        if body.hasPrefix("☑ ") {
            return indent + "- [x] " + String(body.dropFirst(2))
        }
        if body.hasPrefix("☑") {
            return indent + "- [x]" + String(body.dropFirst(1))
        }
        return line
    }

    // MARK: - Coordinator -----------------------------------------------------

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }

            // Pass 1: literal `- [ ] ` / `- [x] ` was just typed → collapse to glyph.
            collapseFreshCheckboxes(tv)

            // Pass 2: convert visible buffer back to canonical markdown for storage.
            let md = MarkdownEditor.displayToMarkdown(tv.string)
            if md != parent.text {
                parent.text = md
                parent.onChange(md)
            }

            applyHighlighting()
        }

        /// Tab inserts 2 literal spaces (markdown nesting).
        /// Shift+Tab removes 2 leading spaces from the current line.
        /// Enter continues `☐ ` / `- ` / `* ` list items at the same indent.
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

        // MARK: - in-place collapse

        /// Scan the buffer for any literal markdown checkbox prefix that
        /// hasn't been collapsed yet and rewrite it as a single-glyph form.
        /// We do this on every text change so users can paste markdown,
        /// type `- [ ] `, etc., and immediately see the rendered form.
        private func collapseFreshCheckboxes(_ tv: NSTextView) {
            let storage = tv.textStorage!
            let ns = storage.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            // Walk lines from the end so range mutations don't break indices.
            var lineRanges: [NSRange] = []
            ns.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
                lineRanges.append(lineRange)
            }
            for lineRange in lineRanges.reversed() {
                let line = ns.substring(with: lineRange)
                guard let collapsed = collapsedLine(line), collapsed != line else { continue }
                let priorCaret = tv.selectedRange().location
                let priorLineEnd = lineRange.location + lineRange.length
                let delta = collapsed.count - line.count

                tv.shouldChangeText(in: lineRange, replacementString: collapsed)
                storage.replaceCharacters(in: lineRange, with: collapsed)
                tv.didChangeText()

                // adjust caret if it sat at/after this line
                if priorCaret >= priorLineEnd {
                    let newCaret = max(0, priorCaret + delta)
                    tv.setSelectedRange(NSRange(location: newCaret, length: 0))
                } else if priorCaret > lineRange.location {
                    // caret was inside the line — clamp to new line end
                    let newEnd = lineRange.location + collapsed.count
                    tv.setSelectedRange(NSRange(location: min(priorCaret + delta, newEnd), length: 0))
                }
            }
        }

        private func collapsedLine(_ line: String) -> String? {
            // Only collapse if literal markdown form is present.
            guard line.contains("- [ ]") || line.contains("- [x]") || line.contains("- [X]") || line.contains("- [✓]") else {
                return nil
            }
            return MarkdownEditor.transformLineMdToDisplay(line)
        }

        // MARK: - outdent / list continuation

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

            // Already-rendered checkbox glyph
            if body.hasPrefix("☐ ") || body.hasPrefix("☑ ") {
                let rest = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    tv.shouldChangeText(in: lineRange, replacementString: "\n")
                    tv.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                    return true
                }
                tv.insertText("\n\(indent)☐ ", replacementRange: tv.selectedRange())
                return true
            }
            if body.hasPrefix("- ") || body.hasPrefix("* ") {
                let rest = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    tv.shouldChangeText(in: lineRange, replacementString: "\n")
                    tv.replaceCharacters(in: lineRange, with: "\n")
                    tv.didChangeText()
                    tv.setSelectedRange(NSRange(location: lineRange.location + 1, length: 0))
                    return true
                }
                tv.insertText("\n\(indent)- ", replacementRange: tv.selectedRange())
                return true
            }
            return false
        }

        // MARK: - click toggle on glyph

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
            let charRange = NSRange(location: index, length: 1)
            let char = ns.substring(with: charRange)
            if char != "☐" && char != "☑" { return }

            let toggled = (char == "☐") ? "☑" : "☐"
            tv.shouldChangeText(in: charRange, replacementString: toggled)
            storage.replaceCharacters(in: charRange, with: toggled)
            tv.didChangeText()
            // bubble out the new markdown body
            let md = MarkdownEditor.displayToMarkdown(tv.string)
            parent.text = md
            parent.onChange(md)
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

                // checkbox glyphs
                if body.hasPrefix("☑") {
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ], range: lineRange)
                    let glyphRange = NSRange(location: lineRange.location + indent, length: 1)
                    storage.addAttributes([
                        .foregroundColor: NSColor.systemGreen,
                        .strikethroughStyle: 0,
                        .font: NSFont.systemFont(ofSize: 16, weight: .bold),
                    ], range: glyphRange)
                    return
                }
                if body.hasPrefix("☐") {
                    let glyphRange = NSRange(location: lineRange.location + indent, length: 1)
                    storage.addAttributes([
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .font: NSFont.systemFont(ofSize: 16, weight: .regular),
                    ], range: glyphRange)
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
