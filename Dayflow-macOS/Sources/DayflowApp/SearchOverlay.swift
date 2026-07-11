import SwiftUI
import AppKit
import Observation

/// Backing state for the search overlay.
///
/// This is a class, and that is the whole point. Keyboard navigation needs an
/// `NSEvent` local monitor (the focused text field swallows arrows and return
/// before SwiftUI's `.onKeyPress` ever sees them), and that monitor is an
/// escaping closure that outlives any single `body` evaluation. A closure that
/// captures the `View` struct captures a *snapshot*: `@Environment` is only
/// valid during body evaluation, and reads of `@State` through the snapshot
/// aren't guaranteed to see later writes — which is exactly how ↵ ended up
/// firing `commit()` against an empty result list while ↑/↓ still appeared to
/// work. Holding the state in a reference type means the monitor always reads
/// the live values.
@MainActor
@Observable
final class SearchModel {
    var query: String = ""
    var results: [SearchResult] = []
    var selected: Int = 0

    @ObservationIgnored private var store: DayflowStore?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onClose: (() -> Void)?

    func start(store: DayflowStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 125:  // down
                if !self.results.isEmpty {
                    self.selected = min(self.results.count - 1, self.selected + 1)
                }
                return nil
            case 126:  // up
                if !self.results.isEmpty {
                    self.selected = max(0, self.selected - 1)
                }
                return nil
            case 36, 76:  // return / keypad enter
                self.commit()
                return nil
            case 53:  // escape
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    func recompute() {
        results = store?.search(query) ?? []
        selected = 0
    }

    func commit() {
        guard results.indices.contains(selected), let store else { return }
        store.goTo(results[selected])
        close()
    }

    func close() {
        stop()
        onClose?()
    }
}

/// Obsidian-style quick switcher. A dimmed backdrop over the whole window with
/// a centered command palette: type to search every day note, appointment, and
/// month-plan section; ↑/↓ to move, ↵ to open, esc to close.
@MainActor
struct SearchOverlay: View {
    @Environment(DayflowStore.self) var store
    @Binding var isPresented: Bool

    @State private var model = SearchModel()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        return ZStack(alignment: .top) {
            // Backdrop — click anywhere outside the panel to dismiss.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.close() }

            panel
                .frame(width: 580)
                .padding(.top, 90)
        }
        .onAppear {
            model.start(store: store) { isPresented = false }
            fieldFocused = true
        }
        .onDisappear { model.stop() }
        .onChange(of: model.query) { _, _ in model.recompute() }
    }

    private var panel: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(L("search.placeholder"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit { model.commit() }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(Color.dfHairline)

            Group {
                if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    hintRow(L("search.hint"))
                } else if model.results.isEmpty {
                    hintRow(L("search.empty"))
                } else {
                    resultsList
                }
            }

            Divider().overlay(Color.dfHairline)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.dfQuiet)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.dfHairlineSoft, lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { idx, result in
                        resultRow(result, isSelected: idx == model.selected)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selected = idx
                                model.commit()
                            }
                            .onHover { if $0 { model.selected = idx } }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 340)
            .onChange(of: model.selected) { _, new in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func resultRow(_ result: SearchResult, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(for: result.kind))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.dfAccent) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !result.snippet.isEmpty {
                    Text(result.snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.dfAccent.opacity(0.14) : .clear)
                .padding(.horizontal, 6)
        )
    }

    private func hintRow(_ text: String) -> some View {
        Text(text)
            .font(DS.FontStyle.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(L("search.footer"))
                .font(DS.FontStyle.micro)
                .foregroundStyle(.tertiary)
            Spacer()
            if !model.results.isEmpty {
                Text(L("search.count", model.results.count))
                    .font(DS.FontStyle.micro)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private static func icon(for kind: SearchResult.Kind) -> String {
        switch kind {
        case .dayNote:     return "doc.text"
        case .appointment: return "clock"
        case .monthPlan:   return "calendar"
        }
    }
}
