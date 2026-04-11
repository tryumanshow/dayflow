import AppKit
import SwiftUI

/// Notion-style block editor: every line is a SwiftUI block (real button for
/// the checkbox, real Text for the prefix, real indent). Editing happens in a
/// per-block NSTextField wrapped by InlineTextField, which keeps Korean IME
/// composition intact because we never mutate the field while the user types.
///
/// Markdown shortcuts trigger live in-place block transformation:
/// - `## ` at the start of a plain block → heading 2
/// - `- [ ] ` → checkbox
/// - `- ` → bullet
struct BlockEditor: View {
    @Binding var markdown: String
    var onChange: (String) -> Void

    @State private var blocks: [MarkdownBlock] = []
    @State private var focusedId: UUID? = nil
    @State private var lastSyncedMarkdown: String = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach($blocks) { $block in
                    BlockRow(
                        block: $block,
                        isFocused: focusedId == block.id,
                        onFocus: { focusedId = block.id },
                        onBodyChanged: { handleBodyChange(blockID: block.id) },
                        onEnter: { addBlockAfter(blockID: block.id) },
                        onTab: { indentBlock(blockID: block.id) },
                        onShiftTab: { outdentBlock(blockID: block.id) },
                        onBackspaceEmpty: { backspaceEmpty(blockID: block.id) },
                        onToggleCheck: { toggleCheck(blockID: block.id) }
                    )
                }
                trailingTapTarget
            }
            .padding(.vertical, DS.Space.md)
            .padding(.horizontal, DS.Space.lg)
        }
        .onAppear {
            syncFromMarkdown(markdown, force: true)
            if blocks.isEmpty {
                let starter = MarkdownBlock(id: UUID(), indent: 0, type: .plain, body: "")
                blocks = [starter]
                focusedId = starter.id
                commit(emit: false)
            }
        }
        .onChange(of: markdown) { _, newValue in
            if newValue != lastSyncedMarkdown {
                syncFromMarkdown(newValue, force: false)
            }
        }
    }

    private var trailingTapTarget: some View {
        Color.clear
            .frame(height: 80)
            .contentShape(Rectangle())
            .onTapGesture {
                addBlockAtEnd()
            }
    }

    // MARK: - sync

    private func syncFromMarkdown(_ md: String, force: Bool) {
        // Preserve focus identity if possible by reusing IDs from current blocks
        let parsed = MarkdownParser.parse(md)
        if force || blocks.isEmpty {
            blocks = parsed
        } else {
            blocks = parsed
        }
        lastSyncedMarkdown = md
        if let id = focusedId, !blocks.contains(where: { $0.id == id }) {
            focusedId = blocks.first?.id
        }
    }

    private func commit(emit: Bool = true) {
        let md = MarkdownParser.serialize(blocks)
        lastSyncedMarkdown = md
        markdown = md
        if emit { onChange(md) }
    }

    // MARK: - block ops

    private func addBlockAfter(blockID: UUID) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let current = blocks[idx]
        // continue list type, otherwise plain
        let newType: BlockType
        switch current.type {
        case .checkbox: newType = .checkbox(checked: false)
        case .bullet:   newType = .bullet
        default:        newType = .plain
        }
        // empty list item on Enter → break out (demote to plain)
        if current.body.isEmpty {
            switch current.type {
            case .checkbox, .bullet:
                blocks[idx].type = .plain
                commit()
                return
            default:
                break
            }
        }
        let newBlock = MarkdownBlock(id: UUID(), indent: current.indent, type: newType, body: "")
        blocks.insert(newBlock, at: idx + 1)
        focusedId = newBlock.id
        commit()
    }

    private func addBlockAtEnd() {
        let newBlock = MarkdownBlock(id: UUID(), indent: 0, type: .plain, body: "")
        blocks.append(newBlock)
        focusedId = newBlock.id
        commit()
    }

    private func indentBlock(blockID: UUID) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        if blocks[idx].indent < 8 {
            blocks[idx].indent += 1
            commit()
        }
    }

    private func outdentBlock(blockID: UUID) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        if blocks[idx].indent > 0 {
            blocks[idx].indent -= 1
            commit()
        }
    }

    private func backspaceEmpty(blockID: UUID) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        // demote list block to plain on backspace before deleting outright
        switch blocks[idx].type {
        case .checkbox, .bullet, .heading:
            blocks[idx].type = .plain
            commit()
            return
        case .plain:
            if blocks[idx].indent > 0 {
                blocks[idx].indent -= 1
                commit()
                return
            }
        }
        if blocks.count == 1 { return }  // keep at least one
        let prevId: UUID? = idx > 0 ? blocks[idx - 1].id : nil
        blocks.remove(at: idx)
        focusedId = prevId
        commit()
    }

    private func toggleCheck(blockID: UUID) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        if case .checkbox(let checked) = blocks[idx].type {
            blocks[idx].type = .checkbox(checked: !checked)
            commit()
        }
    }

    /// Handle live shortcut detection on body change. Triggered after a block's
    /// body binding mutates from typing.
    private func handleBodyChange(blockID: UUID) {
        guard let idx = blocks.firstIndex(where: { $0.id == blockID }) else {
            commit()
            return
        }
        let body = blocks[idx].body

        // Only re-type plain blocks. Already-typed blocks keep their type
        // unless explicitly demoted via Backspace.
        if case .plain = blocks[idx].type {
            if body.hasPrefix("### ") {
                blocks[idx].type = .heading(level: 3)
                blocks[idx].body = String(body.dropFirst(4))
            } else if body.hasPrefix("## ") {
                blocks[idx].type = .heading(level: 2)
                blocks[idx].body = String(body.dropFirst(3))
            } else if body.hasPrefix("# ") {
                blocks[idx].type = .heading(level: 1)
                blocks[idx].body = String(body.dropFirst(2))
            } else if body.hasPrefix("- [ ] ") {
                blocks[idx].type = .checkbox(checked: false)
                blocks[idx].body = String(body.dropFirst(6))
            } else if body.hasPrefix("- [x] ") || body.hasPrefix("- [X] ") {
                blocks[idx].type = .checkbox(checked: true)
                blocks[idx].body = String(body.dropFirst(6))
            } else if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                blocks[idx].type = .bullet
                blocks[idx].body = String(body.dropFirst(2))
            }
        }
        commit()
    }
}

// MARK: - BlockRow ------------------------------------------------------------

private struct BlockRow: View {
    @Binding var block: MarkdownBlock
    let isFocused: Bool
    let onFocus: () -> Void
    let onBodyChanged: () -> Void
    let onEnter: () -> Void
    let onTab: () -> Void
    let onShiftTab: () -> Void
    let onBackspaceEmpty: () -> Void
    let onToggleCheck: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if block.indent > 0 {
                Color.clear.frame(width: CGFloat(block.indent) * 18)
            }
            prefix
                .frame(minWidth: 18, alignment: .leading)
            field
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isFocused ? Color.dfAccent.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    private var verticalPadding: CGFloat {
        switch block.type {
        case .heading(let level):
            return level == 1 ? 8 : (level == 2 ? 6 : 4)
        default:
            return 2
        }
    }

    @ViewBuilder
    private var prefix: some View {
        switch block.type {
        case .heading(let level):
            Text(String(repeating: "#", count: level))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.dfAccent.opacity(0.55))
        case .checkbox(let checked):
            Button {
                onToggleCheck()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(checked ? Color.dfDone : Color.dfTodo, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                    if checked {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.dfDone)
                            .frame(width: 16, height: 16)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .bullet:
            Circle()
                .fill(Color.secondary)
                .frame(width: 5, height: 5)
                .padding(.leading, 6)
        case .plain:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var field: some View {
        let isDone: Bool = {
            if case .checkbox(let checked) = block.type { return checked }
            return false
        }()
        return InlineTextField(
            text: $block.body,
            isFocused: isFocused,
            font: fontFor(block.type),
            placeholder: placeholderFor(block.type),
            foregroundColor: isDone ? .tertiaryLabelColor : .labelColor,
            strikethrough: isDone,
            onTab: onTab,
            onShiftTab: onShiftTab,
            onEnter: onEnter,
            onBackspaceEmpty: onBackspaceEmpty,
            onCommandReturn: {
                if case .checkbox = block.type { onToggleCheck() }
            },
            onFocusChange: { focused in
                if focused { onFocus() }
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: block.body) { _, _ in
            onBodyChanged()
        }
    }

    private func fontFor(_ type: BlockType) -> NSFont {
        switch type {
        case .heading(let level):
            switch level {
            case 1: return NSFont.systemFont(ofSize: 26, weight: .bold)
            case 2: return NSFont.systemFont(ofSize: 19, weight: .semibold)
            default: return NSFont.systemFont(ofSize: 15, weight: .semibold)
            }
        default:
            return NSFont.systemFont(ofSize: 14, weight: .regular)
        }
    }

    private func placeholderFor(_ type: BlockType) -> String {
        switch type {
        case .heading: return "헤더 입력…"
        case .checkbox: return "할 일…"
        case .bullet: return "리스트 항목…"
        case .plain: return "이 블록에 적기…"
        }
    }
}
