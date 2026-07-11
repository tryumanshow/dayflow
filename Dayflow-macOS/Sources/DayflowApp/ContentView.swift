import SwiftUI
import AppKit

// MARK: - Days badge (nav bar, right side) ------------------------------------

private struct DaysBadgeView: View {
    let startDateEpoch: Double

    @State var isHovering = false

    private static let sinceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    var body: some View {
        let days = max(0, Calendar.current.dateComponents(
            [.day],
            from: Date(timeIntervalSince1970: startDateEpoch),
            to: Date()
        ).day ?? 0)
        let isMilestone = ContentView.milestones.contains(days)
        let label = isHovering
            ? "\(days) days with Dayflow"
            : "Dayflow since \(Self.sinceFormatter.string(from: Date(timeIntervalSince1970: startDateEpoch)))"

        Text(label)
            .font(.system(size: 11, weight: isMilestone ? .semibold : .medium, design: .rounded))
            .foregroundStyle(isMilestone ? AnyShapeStyle(Color.dfAccent) : AnyShapeStyle(.tertiary))
            .contentTransition(.opacity)
            .animation(DS.Motion.settle, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

enum AppointmentRepeat: String, CaseIterable, Identifiable {
    case none, weekly, monthly
    var id: String { rawValue }
    var labelKey: String {
        switch self {
        case .none: return "appointments.repeat.none"
        case .weekly: return "appointments.repeat.weekly"
        case .monthly: return "appointments.repeat.monthly"
        }
    }
}

@MainActor
struct ContentView: View {
    @Environment(DayflowStore.self) var store

    // Month rail appointment form. Doubles as the add form and the
    // edit form — `editingAppointmentId` being non-nil flips the
    // submit button label and routes to `updateAppointment`.
    @State var aptTimeInput: String = ""
    @State var aptEndTimeInput: String = ""
    @State var aptTitleInput: String = ""
    @State var aptDateInput: Date = Date()
    /// `nil` distinguishes "no end date set" from any concrete value —
    /// it's the source of truth for single-day vs multi-day mode.
    @State var aptEndDateInput: Date? = nil
    @State var aptCategoryInput: AppointmentCategory = .event
    @State var aptRepeatInput: AppointmentRepeat = .none
    @State var editingAppointmentId: Int64? = nil
    /// Month rail's add-appointment form. Collapsed by default — it's a wide
    /// form in a narrow rail, and scheduling is occasional.
    @State var showAptForm: Bool = false
    @FocusState var aptTitleFocused: Bool

    // Day view and Month plan editor sizes live-update independently
    // via AppStorage. Shared keys/defaults in `AppStorageKeys`.
    @AppStorage(AppStorageKeys.dayEditorFontSize) var dayEditorFontSize: Double = AppStorageKeys.dayEditorFontSizeDefault
    @AppStorage(AppStorageKeys.monthPlanEditorFontSize) var monthPlanEditorFontSize: Double = AppStorageKeys.monthPlanEditorFontSizeDefault
    @AppStorage(AppStorageKeys.holidaysMode) var holidaysMode: HolidayDisplayMode = .off
    @AppStorage(AppStorageKeys.startDate) var startDateEpoch: Double = 0
    @AppStorage(AppStorageKeys.sideRailWidth) var sideRailWidth: Double = AppStorageKeys.sideRailWidthDefault
    @AppStorage(AppStorageKeys.sideRailHidden) var sideRailHidden: Bool = false
    @State var sideRailDragStart: CGFloat? = nil
    /// Transient drag-time width. AppKit mouseDragged callbacks update
    /// this @State (which reliably triggers SwiftUI body re-renders);
    /// on mouseUp we commit it back to @AppStorage. Direct writes to
    /// @AppStorage from AppKit event handlers can fail to invalidate the
    /// view during a drag, leaving the rail visually stuck.
    @State var liveRailWidth: Double? = nil
    var displayRailWidth: Double { liveRailWidth ?? sideRailWidth }
    /// Tracks which nav icon button the cursor is over so we can light it
    /// up on hover. Keyed by SF Symbol name — all current callers pass a
    /// unique symbol, which keeps the key collision-free without plumbing
    /// extra ids through call sites.
    @State var hoveredNavSymbol: String? = nil

    // Month-plan section selection + inline title-edit state. Kept in the
    // core struct because extensions can't declare stored properties; read
    // by the month view's plan rail (ContentView+MonthView.swift).
    @State var selectedSectionId: Int64? = nil
    @State var editingSectionTitleId: Int64? = nil
    @State var sectionTitleDraft: String = ""
    @State var historySectionId: Int64? = nil

    /// Global search overlay (⌘⇧F). Distinct from the in-editor ⌘F find.
    @State var showSearch: Bool = false

    /// Carry-over of unfinished tasks from earlier days.
    ///
    /// `carryoverPending` is a cache: `pendingCarryovers` runs SQL, and the
    /// Day view re-renders far more often than the underlying notes change,
    /// so the banner reads this instead of querying per render. Recomputed
    /// when the selected day changes.
    @State var carryoverPending: [CarryoverItem] = []
    /// Presented via `.sheet(item:)` rather than `.sheet(isPresented:)` — the
    /// boolean form captures the view *before* the same-transaction write to
    /// the items array lands, so the sheet came up empty ("0 to carry"). The
    /// item form hands the batch to the sheet directly.
    @State var carryoverBatch: CarryoverBatch? = nil
    /// Reactive mirror of the persisted per-day dismissal. UserDefaults is
    /// the durable record but SwiftUI doesn't observe it, so hiding the
    /// banner on tap needs state the view actually tracks.
    @State var carryoverDismissed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            content
                .animation(DS.Motion.settle, value: store.viewMode)
                .transition(.opacity)
        }
        .background(Color.dfCanvas)
        .overlay {
            if showSearch {
                SearchOverlay(isPresented: $showSearch)
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dayflowOpenSearch)) { _ in
            showSearch = true
        }
        // Keep the floor BELOW the primary column's needs (grid 320 / day
        // editor 360 + padding), not above grid+rail. A floor wider than
        // the actual screen (e.g. on a scaled display) forces the content
        // to lay out wider than the window and overflow both edges, with
        // the GeometryReaders below seeing the inflated width so their
        // rail auto-hide never triggers. With a low floor the readers see
        // the real width and collapse the rail when it can't fit.
        .frame(minWidth: 460, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: .dayflowZoomIn))    { _ in bumpEditorFontSize(by: +1) }
        .onReceive(NotificationCenter.default.publisher(for: .dayflowZoomOut))   { _ in bumpEditorFontSize(by: -1) }
        .onReceive(NotificationCenter.default.publisher(for: .dayflowZoomReset)) { _ in resetEditorFontSize() }
    }

    /// Range matches the Settings slider (see SettingsView). One step
    /// per shortcut press; sustained Cmd+= keeps the user in tactile
    /// control, no acceleration curve to surprise them.
    private static let editorFontSizeRange: ClosedRange<Double> = 9...20

    private func bumpEditorFontSize(by delta: Double) {
        let clamp: (Double) -> Double = { v in
            min(Self.editorFontSizeRange.upperBound, max(Self.editorFontSizeRange.lowerBound, v))
        }
        switch store.viewMode {
        case .day:   dayEditorFontSize = clamp(dayEditorFontSize + delta)
        case .month: monthPlanEditorFontSize = clamp(monthPlanEditorFontSize + delta)
        case .week:  NSSound.beep()  // no editor surface in week view
        }
    }

    private func resetEditorFontSize() {
        switch store.viewMode {
        case .day:   dayEditorFontSize = AppStorageKeys.dayEditorFontSizeDefault
        case .month: monthPlanEditorFontSize = AppStorageKeys.monthPlanEditorFontSizeDefault
        case .week:  NSSound.beep()
        }
    }

    // MARK: - navigation bar -------------------------------------------------

    private var navigationBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.lg) {
            HStack(spacing: 8) {
                DayflowLogo(size: 18)
                Text("Dayflow")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
            }

            Divider().frame(height: 16)

            HStack(spacing: 2) {
                ForEach(CalendarViewMode.allCases) { mode in
                    Button {
                        store.setMode(mode)
                    } label: {
                        Text(L("nav.\(mode.rawValue)"))
                            .font(.system(size: 12, weight: store.viewMode == mode ? .semibold : .regular))
                            .foregroundStyle(store.viewMode == mode ? Color.primary : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.sm)
                                    .fill(store.viewMode == mode ? Color.white.opacity(0.08) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                navIconButton("chevron.left", tooltip: L("nav.tooltip.previous")) { store.step(by: -1) }
                Button {
                    store.goToToday()
                } label: {
                    Text(L("nav.today"))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help(L("nav.tooltip.today"))
                navIconButton("chevron.right", tooltip: L("nav.tooltip.next")) { store.step(by: 1) }
            }

            Text(headerLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            if startDateEpoch > 0 {
                daysBadge
            }

            navIconButton("magnifyingglass", tooltip: L("nav.tooltip.search")) {
                showSearch = true
            }

            if store.viewMode != .week {
                navIconButton(
                    "sidebar.right",
                    tooltip: sideRailHidden
                        ? L("nav.tooltip.toggle_rail_show")
                        : L("nav.tooltip.toggle_rail_hide"),
                    isActive: !sideRailHidden
                ) {
                    withAnimation(DS.Motion.settle) { sideRailHidden.toggle() }
                }
            }
            navIconButton("arrow.clockwise", tooltip: L("nav.tooltip.refresh")) { store.refresh(force: true) }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .background(Color.dfCanvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dfHairline).frame(height: 0.7)
        }
    }

    fileprivate static let milestones: Set<Int> = [7, 30, 50, 100, 200, 365, 500, 730, 1000]

    private var daysBadge: some View {
        DaysBadgeView(startDateEpoch: startDateEpoch)
    }

    private func navIconButton(
        _ symbol: String,
        tooltip: String? = nil,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hoveredNavSymbol == symbol
        let tint: Color = isActive ? Color.dfAccent : (hovered ? .primary : .secondary)
        let bgOpacity: Double = hovered ? 0.10 : (isActive ? 0.07 : 0.04)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .fill(Color.white.opacity(bgOpacity))
                )
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                .animation(DS.Motion.snap, value: hovered)
                .animation(DS.Motion.snap, value: isActive)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredNavSymbol = isHovering ? symbol : (hoveredNavSymbol == symbol ? nil : hoveredNavSymbol)
        }
        .help(tooltip ?? "")
        .accessibilityLabel(tooltip ?? symbol)
    }

    private var headerLabel: String {
        switch store.viewMode {
        case .day:
            let base = DF.fullDate.string(from: store.selectedDate)
            guard let name = HolidayStore.holidayName(on: store.selectedDate, mode: holidaysMode) else { return base }
            return "\(base) · \(name)"
        case .week:
            let start = store.startOfWeek(store.selectedDate)
            let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
            return "\(DF.shortMonthDay.string(from: start)) – \(DF.shortMonthDay.string(from: end))"
        case .month:
            return DF.monthTitle.string(from: store.selectedDate)
        }
    }

    // MARK: - content router --------------------------------------------------

    @ViewBuilder
    private var content: some View {
        switch store.viewMode {
        case .day:   dayView
        case .week:  weekView
        case .month: monthView
        }
    }

}
