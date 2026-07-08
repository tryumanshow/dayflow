import SwiftUI
import AppKit

@MainActor
extension ContentView {
    // MARK: - month view (heatmap left, minimal rail right) -----------------

    var monthView: some View {
        let stats = store.currentMonthStats()
        let (gridStart, gridEnd) = store.monthGridRange(store.selectedDate)
        let cal = Calendar.current
        var days: [Date] = []
        var cursor = gridStart
        while cursor <= gridEnd {
            days.append(cursor)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        let weekdayHeaders = localizedWeekdayHeaders()

        // Chunk the 42-day grid into 6 rows of 7. Manual HStack-per-row
        // layout lets each cell stretch to fill its row's share of the
        // available vertical space — LazyVGrid wouldn't distribute the
        // leftover height on its own.
        let rows: [[Date]] = stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }

        return GeometryReader { geo in
          // On a narrow or scaled display, only keep the rail if it can be
          // drawn at its own minimum width (300, the resize-handle floor)
          // without pushing the grid below its minimum. If it can't, drop
          // the rail entirely so the calendar takes the full width — far
          // better than clipping the rail's text or overlapping the grid.
          // The user's manual hide toggle still wins on top of this.
          let gridMin: CGFloat = 320
          let handleW: CGFloat = 10
          let railMin: CGFloat = 300
          let railCap = max(0, geo.size.width - gridMin - handleW)
          let railVisible = !sideRailHidden && railCap >= railMin
          let railW = min(displayRailWidth, railCap)
          HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: 4) {
                    ForEach(weekdayHeaders, id: \.self) { wd in
                        Text(wd)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.breathe)

                let layout = Self.spanLayout(for: store.currentMonthSpans(), gridDays: days, cal: cal)
                VStack(spacing: Self.spanCellSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                        let weekStartIdx = rowIdx * 7
                        let weekLanes = layout.laneCount(weekStartIdx: weekStartIdx)
                        let topReserve: CGFloat = CGFloat(weekLanes) * (Self.spanBarHeight + Self.spanLaneGap)
                        ZStack(alignment: .topLeading) {
                            HStack(spacing: Self.spanCellSpacing) {
                                ForEach(row, id: \.self) { day in
                                    heatCell(for: day, stats: stats, topReserve: topReserve)
                                }
                            }
                            spanOverlay(weekStartIdx: weekStartIdx, layout: layout)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.bottom, DS.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Match Day editor's pattern: explicit `minWidth` gives the
            // HStack a concrete lower bound so fixed-width siblings (the
            // resize handle and the rail) are honored during re-layout
            // when `displayRailWidth` changes mid-drag. Without minWidth,
            // a `maxWidth: .infinity` + `layoutPriority(1)` combination
            // — especially with a GeometryReader inside (`spanOverlay`)
            // — confuses HStack's negotiation and the rail's fixed width
            // updates fail to propagate visually during a drag.
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

            if railVisible {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.breathe) {
                        monthMetricsRail(stats)
                        monthAppointmentsRail
                        monthPlanRail
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.top, DS.Space.breathe)
                    .padding(.bottom, DS.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                appCredit
            }
            .frame(width: railW)
            .frame(maxHeight: .infinity)
            .background(Color.dfQuiet)
            // Handle as an overlay on the rail's leading edge instead of
            // an HStack sibling. Month grid's `maxWidth: .infinity` +
            // inner GeometryReader (`spanOverlay`) confuses HStack hit
            // testing on macOS — the NSView handle stops receiving
            // mouseEntered/mouseDown even when visible. Overlay
            // straddling the boundary guarantees z-order and hit area.
            .overlay(alignment: .leading) {
                HorizontalResizeHandle(
                    onDrag: { dx in
                        let base = liveRailWidth ?? sideRailWidth
                        liveRailWidth = max(300, min(500, base - Double(dx)))
                    },
                    onEnd: {
                        if let v = liveRailWidth { sideRailWidth = v; liveRailWidth = nil }
                    }
                )
                .frame(width: 10)
                .frame(maxHeight: .infinity)
                .offset(x: -5)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
            }
          }
        }
    }

    private func monthMetricsRail(_ stats: DayflowStore.MonthStats) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SectionLabel(text: DF.monthTitle.string(from: store.selectedDate))
            HStack(alignment: .bottom, spacing: 4) {
                Text("\(Int(stats.completionRate * 100))")
                    .font(DS.FontStyle.metric)
                    .foregroundStyle(Color.dfAccent)
                Text("%")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            Text(monthCaption(stats))
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func monthCaption(_ stats: DayflowStore.MonthStats) -> String {
        var parts: [String] = []
        parts.append(L("month.caption.n_of_m", stats.doneTasks, stats.totalTasks))
        if stats.longestStreak > 0 {
            parts.append(L("month.caption.streak_days", stats.longestStreak))
        }
        if let weekday = stats.busiestWeekday {
            parts.append(L("month.caption.busiest", weekday))
        }
        return parts.joined(separator: " · ")
    }

    /// Weekday header row for the month grid. Sunday-first, honors
    /// the app's language override via `DayflowL10n.activeLocale`.
    private func localizedWeekdayHeaders() -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = DayflowL10n.activeLocale
        return cal.shortWeekdaySymbols
    }

    /// Month view is the single source of truth for scheduling.
    private var monthAppointmentsRail: some View {
        let items = store.currentMonthAppointments()
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: L("appointments.month_header"))
                Spacer()
                Text(L("appointments.month_hint"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
            }
            if items.isEmpty {
                Text(L("appointments.empty"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { apt in
                            appointmentMonthRow(apt)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            let isMultiDay = aptEndDateInput != nil
            HStack(spacing: 6) {
                DatePicker("", selection: $aptDateInput, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                if isMultiDay {
                    Text("→")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { aptEndDateInput ?? aptDateInput },
                            set: { aptEndDateInput = $0 }
                        ),
                        in: aptDateInput...,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    Button {
                        aptEndDateInput = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("appointments.end_date_remove"))
                } else {
                    timeField($aptTimeInput, placeholder: L("appointments.time_placeholder"))
                    Text("–")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    timeField($aptEndTimeInput, placeholder: L("appointments.end_time_placeholder"))
                    Button {
                        aptEndDateInput = Calendar.current.date(byAdding: .day, value: 1, to: aptDateInput) ?? aptDateInput
                    } label: {
                        Text(L("appointments.end_date_add"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.dfHairlineSoft, lineWidth: 0.7)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if !isMultiDay {
                    Picker("", selection: $aptRepeatInput) {
                        ForEach(AppointmentRepeat.allCases) { r in
                            Text(L(r.labelKey)).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help(L("appointments.repeat.help"))
                }
            }
            .onChange(of: aptDateInput) { _, new in
                if let end = aptEndDateInput, end < new { aptEndDateInput = new }
            }
            HStack(spacing: 6) {
                Picker("", selection: $aptCategoryInput) {
                    ForEach(AppointmentCategory.allCases) { cat in
                        Text(cat.label).tag(cat)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                TextField(L("appointments.title_placeholder"), text: $aptTitleInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.04))
                    )
                    .focused($aptTitleFocused)
                    .onSubmit { submitMonthAppointment() }
                Button {
                    submitMonthAppointment()
                } label: {
                    Text(L(editingAppointmentId == nil ? "appointments.add" : "appointments.update"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dfAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.dfAccent.opacity(0.14)))
                }
                .buttonStyle(.plain)
                if editingAppointmentId != nil {
                    Button {
                        cancelAppointmentEdit()
                    } label: {
                        Text(L("appointments.cancel"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One row in the month appointments list. Click the date/time/
    /// title area to navigate to Day; pencil loads into the edit
    /// form; × deletes. Selected (being-edited) row wears the accent
    /// background so the user sees which row the form is bound to.
    @ViewBuilder
    private func appointmentMonthRow(_ apt: Appointment) -> some View {
        let isEditing = (editingAppointmentId == apt.id)
        let dateText: String = {
            if apt.isMultiDay, let endAt = apt.endAt {
                return "\(DF.shortMonthDay.string(from: apt.startAt)) → \(DF.shortMonthDay.string(from: endAt))"
            }
            return DF.shortMonthDay.string(from: apt.startAt)
        }()
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(dateText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if !apt.isMultiDay {
                    Text(DF.hourMinute.string(from: apt.startAt))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.dfAccent)
                        .fixedSize()
                    if let pill = Self.durationPill(from: apt.startAt, to: apt.endAt) {
                        Text(pill)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
                let liveCategory = isEditing ? aptCategoryInput : apt.category
                Text(apt.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(liveCategory.color.opacity(0.22))
                    )
                    .layoutPriority(0)
                Spacer(minLength: 0)
            }
            Button {
                startAppointmentEdit(apt)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isEditing ? AnyShapeStyle(Color.dfAccent) : AnyShapeStyle(.tertiary))
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                if isEditing { cancelAppointmentEdit() }
                store.deleteAppointment(apt)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isEditing ? Color.dfAccent.opacity(0.12) : .clear)
        )
    }

    /// Compact mono-digit `HH:MM` text field backed by the mask
    /// sanitizer — shared between the start and end time inputs in
    /// the Month rail appointment form. The `if masked != new`
    /// guard short-circuits the second `onChange` pass so the
    /// re-assignment doesn't loop.
    private func timeField(_ binding: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .frame(width: 52)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.04))
            )
            .onChange(of: binding.wrappedValue) { _, new in
                let masked = Self.maskHHMM(new)
                if masked != new { binding.wrappedValue = masked }
            }
            .onSubmit { submitMonthAppointment() }
    }

    /// Validation of hours/minutes > 23/59 is left to
    /// `DayflowStore.combine`; this helper only enforces shape.
    static func maskHHMM(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber).prefix(4)
        if digits.count <= 2 { return String(digits) }
        let h = digits.prefix(2)
        let m = digits.dropFirst(2)
        return "\(h):\(m)"
    }

    /// Rendered alongside start time instead of a second time chip
    /// so rows stay single-line. Returns nil when no end, or end
    /// not strictly after start.
    static func durationPill(from start: Date, to end: Date?) -> String? {
        guard let end, end > start else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    private func startAppointmentEdit(_ apt: Appointment) {
        let isSpan = apt.isMultiDay
        editingAppointmentId = apt.id
        aptDateInput = apt.startAt
        aptEndDateInput = isSpan ? apt.endAt : nil
        aptTimeInput = isSpan ? "" : DF.hourMinute.string(from: apt.startAt)
        aptEndTimeInput = isSpan ? "" : (apt.endAt.map { DF.hourMinute.string(from: $0) } ?? "")
        aptTitleInput = apt.title
        aptCategoryInput = apt.category
        aptTitleFocused = true
    }

    private func cancelAppointmentEdit() {
        resetAppointmentForm()
    }

    private func submitMonthAppointment() {
        // Time can be left blank — default to 00:00 so "all-day" style
        // adds still land. resolveTimes otherwise rejects empty hhmm.
        let effectiveTime = aptTimeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "00:00" : aptTimeInput
        let canRepeat = aptRepeatInput != .none && aptEndDateInput == nil
        let ok: Bool
        if let id = editingAppointmentId {
            let updated = store.updateAppointment(id, on: aptDateInput, hhmm: effectiveTime, endHHmm: aptEndTimeInput, endDay: aptEndDateInput, title: aptTitleInput, category: aptCategoryInput)
            if updated && canRepeat {
                addRepeatingAppointments(hhmm: effectiveTime, excludingDay: aptDateInput)
            }
            ok = updated
        } else if canRepeat {
            ok = addRepeatingAppointments(hhmm: effectiveTime, excludingDay: nil)
        } else {
            ok = store.addAppointment(on: aptDateInput, hhmm: effectiveTime, endHHmm: aptEndTimeInput, endDay: aptEndDateInput, title: aptTitleInput, category: aptCategoryInput)
        }
        if ok { resetAppointmentForm() }
    }

    /// Expand the form's single date into every matching date within
    /// the month containing `aptDateInput` (weekly = same weekday,
    /// monthly = same day-of-month). Days that don't exist (e.g. the
    /// 31st in February) are skipped. `excludingDay` skips a specific
    /// date — used in edit mode so the just-updated row isn't dupli-
    /// cated.
    @discardableResult
    private func addRepeatingAppointments(hhmm: String, excludingDay: Date?) -> Bool {
        let cal = Calendar(identifier: .gregorian)
        let monthComps = cal.dateComponents([.year, .month], from: aptDateInput)
        guard let firstOfMonth = cal.date(from: monthComps),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth) else { return false }

        var targets: [Date] = []
        switch aptRepeatInput {
        case .weekly:
            let weekday = cal.component(.weekday, from: aptDateInput)
            for day in range {
                var c = monthComps; c.day = day
                if let d = cal.date(from: c), cal.component(.weekday, from: d) == weekday {
                    targets.append(d)
                }
            }
        case .monthly:
            let dom = cal.component(.day, from: aptDateInput)
            if range.contains(dom) {
                var c = monthComps; c.day = dom
                if let d = cal.date(from: c) { targets.append(d) }
            }
        case .none:
            return false
        }

        var anyOk = false
        for d in targets {
            if let excl = excludingDay, cal.isDate(d, inSameDayAs: excl) { continue }
            if store.addAppointment(on: d, hhmm: hhmm, endHHmm: aptEndTimeInput, endDay: nil, title: aptTitleInput, category: aptCategoryInput) {
                anyOk = true
            }
        }
        return anyOk
    }

    private func resetAppointmentForm() {
        editingAppointmentId = nil
        aptTimeInput = ""
        aptEndTimeInput = ""
        aptEndDateInput = nil
        aptTitleInput = ""
        aptCategoryInput = .event
        aptRepeatInput = .none
        aptTitleFocused = false
    }


    /// Resolve the active section id — falls back to the first section
    /// when the stored selection is stale or nil.
    private var activeSectionId: Int64? {
        if let id = selectedSectionId,
           store.monthPlanSections.contains(where: { $0.id == id }) {
            return id
        }
        return store.monthPlanSections.first?.id
    }

    private var monthPlanRail: some View {
        @Bindable var store = store
        let activeId = activeSectionId
        let addSection = {
            store.addMonthPlanSection(title: L("month.plan.new_section"))
            if let last = store.monthPlanSections.last {
                selectedSectionId = last.id
            }
        }

        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: L("month.plan_header"))
                Spacer()
                Text(L("month.plan.hint"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
            }

            // Tab bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(store.monthPlanSections) { section in
                        if editingSectionTitleId == section.id {
                            TextField("", text: $sectionTitleDraft, onCommit: {
                                let trimmed = sectionTitleDraft.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty {
                                    store.renameMonthPlanSection(id: section.id, title: trimmed)
                                }
                                editingSectionTitleId = nil
                            })
                            .textFieldStyle(.plain)
                            .font(DS.FontStyle.caption.weight(.semibold))
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, DS.Space.xs)
                            .frame(maxWidth: 120)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                        } else {
                            monthPlanTab(section: section, isActive: section.id == activeId)
                        }
                    }

                    // "+" button
                    Button {
                        addSection()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, DS.Space.xs)
                            .padding(.vertical, DS.Space.xs)
                    }
                    .buttonStyle(.plain)
                    .help(L("month.plan.add_section"))
                }
            }

            // Editor for active section
            if let activeId {
                monthPlanEditor(sectionId: activeId)
            } else {
                Button {
                    addSection()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.tertiary)
                        Text(L("month.plan.empty"))
                            .font(DS.FontStyle.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DS.Space.xl)
            }
        }
        .sheet(item: Binding(
            get: { historySectionId.map(IdentifiedSectionId.init) },
            set: { historySectionId = $0?.id }
        )) { wrapped in
            MonthPlanHistorySheet(sectionId: wrapped.id, store: store) {
                historySectionId = nil
            }
        }
    }

    /// Separate view so the Binding captures `sectionId` by value
    /// instead of a mutable array index — prevents out-of-bounds
    /// crashes when the sections array is mutated mid-render.
    private func monthPlanEditor(sectionId: Int64) -> some View {
        @Bindable var store = store
        return MarkdownWebEditor(
            markdown: Binding(
                get: {
                    store.monthPlanSections.first(where: { $0.id == sectionId })?.bodyMd ?? ""
                },
                set: { newValue in
                    if let i = store.monthPlanSections.firstIndex(where: { $0.id == sectionId }) {
                        store.monthPlanSections[i].bodyMd = newValue
                    }
                }
            ),
            markdownJSON: Binding(
                get: {
                    store.monthPlanSections.first(where: { $0.id == sectionId })?.bodyJSON
                },
                set: { newValue in
                    if let i = store.monthPlanSections.firstIndex(where: { $0.id == sectionId }) {
                        store.monthPlanSections[i].bodyJSON = newValue
                    }
                }
            ),
            fontSize: monthPlanEditorFontSize,
            onChange: { md, json in
                store.updateMonthPlanSection(id: sectionId, body: md, bodyJSON: json)
            }
        )
        .id(sectionId)
        .frame(height: 440)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .stroke(Color.dfHairlineSoft, lineWidth: 0.7)
        )
    }

    private func monthPlanTab(section: MonthPlanSection, isActive: Bool) -> some View {
        Text(section.title)
            .font(DS.FontStyle.caption.weight(isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedSectionId = section.id
            }
            .contextMenu {
                Button(L("month.plan.rename_section")) {
                    sectionTitleDraft = section.title
                    editingSectionTitleId = section.id
                }
                Button(L("month.plan.history")) {
                    historySectionId = section.id
                }
                if store.monthPlanSections.count > 1 {
                    Divider()
                    Button(L("month.plan.delete_section"), role: .destructive) {
                        store.deleteMonthPlanSection(id: section.id)
                        if selectedSectionId == section.id {
                            selectedSectionId = store.monthPlanSections.first?.id
                        }
                    }
                }
            }
    }

    private func heatCell(for day: Date, stats: DayflowStore.MonthStats, topReserve: CGFloat = 0) -> some View {
        let cal = Calendar.current
        let inMonth = cal.component(.month, from: day) == cal.component(.month, from: store.selectedDate)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let key = DayflowDB.ymd(day)
        let done = stats.doneByDay[key] ?? 0
        let open = stats.openByDay[key] ?? 0
        let total = done + open
        let appointments = store.appointments(for: day)
        let holidayName = inMonth ? HolidayStore.holidayName(on: day, mode: holidaysMode) : nil

        return VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 14, weight: isToday ? .bold : .medium).monospacedDigit())
                        .foregroundColor(inMonth
                                         ? (isToday ? Color.dfAccent : (holidayName != nil ? Color.dfHoliday : Color.primary))
                                         : Color.secondary.opacity(0.4))
                    if let holidayName {
                        Text(holidayName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.dfHoliday)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if topReserve > 0 {
                    Color.clear.frame(height: topReserve)
                }
                // Show up to 3 appointment chips under the day number.
                // On overflow, last row becomes a "+N" counter. Only
                // for in-month cells — leading/trailing padding cells
                // stay visually quiet.
                if inMonth && !appointments.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        let visible = appointments.prefix(3)
                        ForEach(Array(visible)) { apt in
                            // Heatmap cells are too tight (~160px) to
                            // fit start + duration + title reliably,
                            // so the pill is rendered only in the
                            // wider surfaces (right rail, Day/Week).
                            // Cell chip stays start-only.
                            HStack(spacing: 3) {
                                Text(DF.hourMinute.string(from: apt.startAt))
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Color.dfAccent)
                                Text(apt.title)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .lineLimit(1)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(apt.category.color.opacity(0.22))
                                    )
                            }
                        }
                        if appointments.count > 3 {
                            Text("+\(appointments.count - 3)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(heatColor(inMonth: inMonth, total: total))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .stroke(isSelected ? Color.dfAccent.opacity(0.7) : Color.dfHairlineSoft,
                            lineWidth: isSelected ? 0.9 : 0.7)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                store.selectDate(day)
                store.setMode(.day)
            }
            .onTapGesture(count: 1) {
                store.selectDate(day)
            }
            .animation(DS.Motion.snap, value: isSelected)
    }

    /// Single warm-accent fill with opacity tied to activity density.
    /// Intentionally *not* sensitive to ratio — the month view's purpose is
    /// to convey rhythm, not success/failure. Value judgments belong in the
    /// rail's metric, not smeared across 42 cells.
    private func heatColor(inMonth: Bool, total: Int) -> Color {
        if !inMonth { return Color.white.opacity(0.015) }
        if total == 0 { return Color.white.opacity(0.025) }
        let intensity = min(1.0, Double(total) / 6.0)
        return Color.dfAccent.opacity(0.06 + intensity * 0.26)
    }

    // MARK: - multi-day span bars (month overlay)

    static let spanBarHeight: CGFloat = 14
    static let spanLaneGap: CGFloat = 2
    static let spanCellSpacing: CGFloat = 4
    // Cell padding 10 + ~14pt day digit + a little air.
    static let spanTopInset: CGFloat = 30

    /// Spans laid out against a fixed grid (column indices 0..gridDays.count-1)
    /// with greedy first-fit lane assignment. A span keeps its lane across
    /// every week it crosses, so a trip reads as one continuous strip.
    struct SpanLayout {
        struct Entry {
            let apt: Appointment
            let startIdx: Int
            let endIdx: Int
            let lane: Int
        }
        let entries: [Entry]

        func laneCount(weekStartIdx: Int) -> Int {
            let weekEndIdx = weekStartIdx + 6
            return entries.lazy
                .filter { $0.endIdx >= weekStartIdx && $0.startIdx <= weekEndIdx }
                .map { $0.lane + 1 }
                .max() ?? 0
        }
    }

    static func spanLayout(for spans: [Appointment], gridDays: [Date], cal: Calendar) -> SpanLayout {
        let dayKeys = gridDays.map { DayflowDB.ymd($0) }
        let keyToIdx: [String: Int] = Dictionary(uniqueKeysWithValues: dayKeys.enumerated().map { ($1, $0) })
        let lastIdx = gridDays.count - 1
        var laneEnds: [Int] = []
        var entries: [SpanLayout.Entry] = []
        for apt in spans {
            let startKey = DayflowDB.ymd(apt.startAt)
            let endKey = DayflowDB.ymd(apt.endAt ?? apt.startAt)
            // Spans starting before the grid clamp to 0; ending after, to lastIdx.
            let startIdx = keyToIdx[startKey] ?? (apt.startAt < gridDays.first! ? 0 : lastIdx)
            let endIdx = keyToIdx[endKey] ?? lastIdx
            let lane: Int
            if let i = laneEnds.firstIndex(where: { $0 < startIdx }) {
                laneEnds[i] = endIdx
                lane = i
            } else {
                laneEnds.append(endIdx)
                lane = laneEnds.count - 1
            }
            entries.append(.init(apt: apt, startIdx: startIdx, endIdx: endIdx, lane: lane))
        }
        return SpanLayout(entries: entries)
    }

    private func spanOverlay(weekStartIdx: Int, layout: SpanLayout) -> some View {
        let weekEndIdx = weekStartIdx + 6
        let cellSpacing = Self.spanCellSpacing
        return GeometryReader { geo in
            let cellWidth = (geo.size.width - cellSpacing * 6) / 7
            ForEach(layout.entries, id: \.apt.id) { entry in
                if entry.endIdx >= weekStartIdx && entry.startIdx <= weekEndIdx {
                    let segStart = max(entry.startIdx, weekStartIdx)
                    let segEnd = min(entry.endIdx, weekEndIdx)
                    let col = segStart - weekStartIdx
                    let span = segEnd - segStart + 1
                    let x = CGFloat(col) * (cellWidth + cellSpacing)
                    let w = CGFloat(span) * cellWidth + CGFloat(span - 1) * cellSpacing
                    let y = Self.spanTopInset + CGFloat(entry.lane) * (Self.spanBarHeight + Self.spanLaneGap)
                    // Only round the true ends so mid-week segments read
                    // as one continuous bar across week boundaries.
                    let isStart = segStart == entry.startIdx
                    let isEnd = segEnd == entry.endIdx
                    Text(entry.apt.title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .frame(width: w, height: Self.spanBarHeight, alignment: .leading)
                        .background(
                            UnevenRoundedRectangle(
                                topLeadingRadius: isStart ? 4 : 0,
                                bottomLeadingRadius: isStart ? 4 : 0,
                                bottomTrailingRadius: isEnd ? 4 : 0,
                                topTrailingRadius: isEnd ? 4 : 0,
                                style: .continuous
                            )
                            .fill(entry.apt.category.color.opacity(0.55))
                        )
                        .offset(x: x, y: y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
