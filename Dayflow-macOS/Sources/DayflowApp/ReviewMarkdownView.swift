import SwiftUI

struct ReviewMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let line):
            attributedText(line)
                .font(.system(size: level <= 2 ? 14 : 13, weight: .semibold))
                .padding(.top, 4)
        case .bullet(let line):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                attributedText(line).font(DS.FontStyle.body)
            }
        case .numbered(let n, let line):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                attributedText(line).font(DS.FontStyle.body)
            }
        case .blank:
            Spacer().frame(height: 4)
        case .paragraph(let line):
            attributedText(line).font(DS.FontStyle.body)
        }
    }

    private func attributedText(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    private enum Block {
        case heading(Int, String)
        case bullet(String)
        case numbered(Int, String)
        case paragraph(String)
        case blank
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var inFence = false
        for raw in stripped.components(separatedBy: "\n") {
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { out.append(.paragraph(line)); continue }
            if trimmed.isEmpty { out.append(.blank); continue }
            if let h = parseHeading(trimmed) { out.append(.heading(h.0, h.1)); continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                out.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }
            if let num = parseNumbered(trimmed) { out.append(.numbered(num.0, num.1)); continue }
            out.append(.paragraph(trimmed))
        }
        return out
    }

    private var stripped: String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private func parseHeading(_ s: String) -> (Int, String)? {
        var level = 0
        for ch in s { if ch == "#" { level += 1 } else { break } }
        guard level > 0, level <= 6, s.count > level, s[s.index(s.startIndex, offsetBy: level)] == " " else { return nil }
        return (level, String(s.dropFirst(level + 1)))
    }

    private func parseNumbered(_ s: String) -> (Int, String)? {
        var idx = s.startIndex
        var digits = ""
        while idx < s.endIndex, s[idx].isNumber { digits.append(s[idx]); idx = s.index(after: idx) }
        guard !digits.isEmpty, let n = Int(digits), idx < s.endIndex, s[idx] == "." else { return nil }
        idx = s.index(after: idx)
        guard idx < s.endIndex, s[idx] == " " else { return nil }
        return (n, String(s[s.index(after: idx)...]))
    }
}
