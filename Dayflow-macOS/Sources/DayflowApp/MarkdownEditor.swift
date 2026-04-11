import AppKit
import SwiftUI

/// Obsidian-style live preview markdown editor.
///
/// Implementation strategy:
/// - The buffer is *always* canonical markdown (`- [ ]`, `- [x]`, `## …`).
///   We never substitute the backing characters — that fights with the
///   typing flow and Korean IME.
/// - Visual rendering is achieved via a custom `NSLayoutManager` subclass
///   that overrides `drawGlyphs(forGlyphRange:at:)`. For every line that
///   begins with `- [ ]` or `- [x]`, we mark those 5 characters with
///   `.foregroundColor = .clear` so they don't visibly draw, then paint
///   a single `☐` or `☑` glyph on top of where the bracket prefix lived.
/// - Click on the overlay glyph toggles the inner character of the
///   bracket region. Caret never enters the hidden glyphs because the
///   user always clicks on the visible text portion.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var onChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        // Build the text stack manually so we can install our subclass.
        let textStorage = NSTextStorage()
        let layoutManager = CheckboxOverlayLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let container = NSTextContainer(size: containerSize)
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = OverlayTextView(frame: .zero, textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
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

        scroll.documentView = tv
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

    /// Pretty-print helper for read-only previews (the month rail).
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
            let prefixes = ["- [ ] ", "- [x] ", "- [X] "]
            for p in prefixes {
                if body.hasPrefix(p) {
                    let rest = body.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty {
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

        // MARK: - click toggle on the overlay glyph
        //
        // Character-index based: if the click lands inside the 5-character
        // bracket prefix of a checkbox line, toggle. The hidden glyphs still
        // occupy a normal layout slot, so characterIndex(for:in:) returns the
        // correct index even though the foreground colour is clear.

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

            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let line = ns.substring(with: lineRange)
            let indent = line.prefix(while: { $0 == " " }).count
            let body = line.dropFirst(indent)
            let prefixStart = lineRange.location + indent
            let prefixEnd = prefixStart + 5

            // Only checkbox lines toggle.
            let isCheckbox = body.hasPrefix("- [ ]") || body.hasPrefix("- [x]") || body.hasPrefix("- [X]")
            guard isCheckbox else { return }
            // Click must land within the bracket prefix slot (or just past it
            // — we accept up to 1 char after, so the gap between glyph and
            // text isn't a dead zone).
            guard index >= prefixStart && index <= prefixEnd else { return }

            let innerRange = NSRange(location: prefixStart + 3, length: 1)
            guard NSMaxRange(innerRange) <= ns.length else { return }
            let inner = ns.substring(with: innerRange)
            guard inner == " " || inner == "x" || inner == "X" else { return }
            let toggled = (inner == " ") ? "x" : " "
            tv.shouldChangeText(in: innerRange, replacementString: toggled)
            storage.replaceCharacters(in: innerRange, with: toggled)
            tv.didChangeText()

            parent.text = tv.string
            parent.onChange(tv.string)
            applyHighlighting()
        }

        // MARK: - syntax highlighting (also marks the bracket prefix as `clear`
        // so the overlay layout manager has empty space to paint into).

        func applyHighlighting() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            let baseFont = NSFont.systemFont(ofSize: 14, weight: .regular)
            storage.beginEditing()
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
            ], range: full)

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

                // checkbox done — full line dim + strikethrough, hide bracket prefix
                if body.hasPrefix("- [x]") || body.hasPrefix("- [X]") {
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ], range: lineRange)
                    let bracketRange = NSRange(location: lineRange.location + indent, length: 5)
                    storage.addAttributes([
                        .foregroundColor: NSColor.clear,
                        .strikethroughStyle: 0,
                    ], range: bracketRange)
                    return
                }
                if body.hasPrefix("- [ ]") {
                    let bracketRange = NSRange(location: lineRange.location + indent, length: 5)
                    storage.addAttributes([
                        .foregroundColor: NSColor.clear,
                    ], range: bracketRange)
                    return
                }

                // plain bullet — hide the dash/star/plus, overlay paints `•`
                if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                    let bulletRange = NSRange(location: lineRange.location + indent, length: 1)
                    storage.addAttributes([
                        .foregroundColor: NSColor.clear,
                    ], range: bulletRange)
                }
            }
            storage.endEditing()
            // force a redraw so the overlay glyph repaints immediately
            tv.needsDisplay = true
        }
    }
}

// MARK: - NSTextView subclass — keeps origin pointer for the layout manager ----

final class OverlayTextView: NSTextView {
    // We rely on the standard caret/IME flow. No overrides needed beyond
    // the type itself, but the subclass exists in case we need to add
    // gesture-related tweaks later.
}

// MARK: - Layout manager that overlays ☐ / ☑ on `- [ ]` / `- [x]` -----------

final class CheckboxOverlayLayoutManager: NSLayoutManager {

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = self.textStorage,
              let container = self.textContainers.first else { return }

        let ns = storage.string as NSString
        let charRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        ns.enumerateSubstrings(in: charRange, options: .byLines) { (substring, lineRange, _, _) in
            guard let line = substring else { return }
            let indent = line.prefix(while: { $0 == " " }).count
            let body = line.dropFirst(indent)

            // (glyph, font, color, hidden-prefix length in characters)
            let payload: (glyph: String, font: NSFont, color: NSColor, length: Int)?
            if body.hasPrefix("- [ ]") {
                payload = ("\u{2610}", NSFont.systemFont(ofSize: 16, weight: .semibold), NSColor.systemOrange, 5)
            } else if body.hasPrefix("- [x]") || body.hasPrefix("- [X]") {
                payload = ("\u{2611}", NSFont.systemFont(ofSize: 16, weight: .semibold), NSColor.systemGreen, 5)
            } else if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                payload = ("\u{2022}", NSFont.systemFont(ofSize: 14, weight: .bold), NSColor.tertiaryLabelColor, 1)
            } else {
                payload = nil
            }
            guard let (glyph, font, color, prefixLen) = payload else { return }

            let prefixCharRange = NSRange(location: lineRange.location + indent, length: prefixLen)
            guard NSMaxRange(prefixCharRange) <= ns.length else { return }
            let prefixGlyphRange = self.glyphRange(forCharacterRange: prefixCharRange, actualCharacterRange: nil)
            let prefixRect = self.boundingRect(forGlyphRange: prefixGlyphRange, in: container)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            let attrStr = NSAttributedString(string: glyph, attributes: attrs)
            let glyphSize = attrStr.size()
            let drawPoint = NSPoint(
                x: origin.x + prefixRect.minX,
                y: origin.y + prefixRect.minY + (prefixRect.height - glyphSize.height) / 2
            )
            attrStr.draw(at: drawPoint)
        }
    }
}
