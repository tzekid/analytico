import AnalyticoKit
import SwiftUI

/// Every report's frame: the Quando title and the period line, the period
/// bar, then Compare · Filter · Actions, above the report's cards. On iPhone
/// they stack; on iPad and Mac they share one row.
struct ScreenScaffold<Content: View>: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    let screen: Screen
    /// The period the report covers, once it has loaded.
    var wording: PeriodWording?
    /// Some reports can't be filtered (Search Console data) or compared.
    var filters = true
    var compare = true
    /// When the last refresh failed but older numbers are on screen.
    var stale: Date?
    /// A site still waiting for its first visit: no period, no controls.
    var waiting = false
    let reload: () async -> Void
    @ViewBuilder var content: Content

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                header
                if filters && !waiting && screen.fixedPeriod == nil { FilterChips() }
                if let stale { StaleNotice(since: stale) { Task { await reload() } } }
                content
            }
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.top, compact ? 2 : 14)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .refreshable { await reload() }
        #if os(macOS)
        // One report shows at a time on the Mac; iPhone tabs keep several alive.
        .focusedSceneValue(\.reload, ReloadAction(screen: screen, run: reload))
        #endif
    }

    @ViewBuilder private var header: some View {
        if waiting {
            titleBlock
        } else if compact {
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                if let fixed = screen.fixedPeriod {
                    FixedPeriodTag(text: fixed.text, why: fixed.why, live: screen == .live)
                } else {
                    PeriodBar(wording: wording)
                    ControlsRow(screen: screen, filters: filters, compare: compare)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                titleBlock
                Spacer(minLength: 12)
                if let fixed = screen.fixedPeriod {
                    FixedPeriodTag(text: fixed.text, why: fixed.why, live: screen == .live)
                    ActionsMenu(screen: screen)
                } else {
                    PeriodBar(wording: wording)
                        .fixedSize()
                    ControlsRow(screen: screen, filters: filters, compare: compare)
                }
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(screen.title)
                .font(Theme.display(compact ? 30 : 28, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(compact ? .subheadline : .callout)
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var subtitle: String {
        if waiting { return "No visits yet" }
        if screen == .live { return "\(state.site.host) · updates by itself" }
        if screen == .retention { return "Who comes back, and what brought them" }
        if screen == .paths && state.site.mode == "lite" { return "Paths need Session or Full mode" }
        guard let wording else { return " " }
        return state.view.compare && compare ? "\(wording.title) · \(wording.compared)" : wording.title
    }
}

/// What every report is filtered by, each removable, as on the web.
struct FilterChips: View {
    @Environment(SiteState.self) private var state

    var body: some View {
        if !state.view.filters.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if state.view.any && state.view.filters.count > 1 {
                        Text("Any of").font(.footnote).foregroundStyle(Theme.ink2)
                    }
                    ForEach(state.view.filters) { filter in
                        Button { state.view.filters.removeAll { $0 == filter } } label: {
                            HStack(spacing: 6) {
                                (Text("\(Labels.dimension(filter.dimension)) \(filter.negated ? "is not" : "is") ") + Text(Labels.value(filter.value, dimension: filter.dimension)).fontWeight(.semibold))
                                    .lineLimit(1)
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .font(.footnote)
                            .foregroundStyle(Theme.brandDark)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Theme.brandWash, in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove filter: \(Labels.dimension(filter.dimension)) \(filter.negated ? "is not" : "is") \(Labels.value(filter.value, dimension: filter.dimension))")
                    }
                    if state.view.filters.count > 1 {
                        Button("Clear all") { state.view.filters = [] }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.brandDark)
                            .padding(.horizontal, 6)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

/// "Couldn't refresh": the numbers on screen are from earlier.
struct StaleNotice: View {
    let since: Date
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Icon("refresh", size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn’t refresh").font(.subheadline.weight(.semibold))
                Text("Figures from \(since.formatted(date: .omitted, time: .shortened)) · check the connection").font(.caption)
            }
            Spacer()
            Button("Try again", action: retry).buttonStyle(.plain).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(Theme.warning)
        .padding(12)
        .background(Theme.amberWash, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.amber.opacity(0.35)))
    }
}

/// Live and Retention: their own period, said instead of a period bar.
struct FixedPeriodTag: View {
    let text: String
    let why: String
    var live = false

    var body: some View {
        HStack(spacing: 7) {
            if live {
                Circle().fill(Theme.good).frame(width: 8, height: 8)
            } else {
                Icon("calendar", size: 14)
            }
            Text(text).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(live ? Theme.good : Theme.ink2)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(live ? Theme.goodWash : Theme.subtle, in: .capsule)
        .help(why)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(text). \(why)")
    }
}

// MARK: - Period

/// 24h · 7d · 30d · 90d · dates. The last segment names chosen dates
/// ("Today", "14–20 Sep") and opens the period sheet or popover.
struct PeriodBar: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    var wording: PeriodWording?
    @State private var choosing = false

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 2) {
            ForEach(ViewState.Period.allCases) { period in
                segment(period.rawValue, selected: !state.view.isCustom && state.view.period == period) {
                    state.view.from = nil
                    state.view.to = nil
                    state.view.period = period
                }
                .accessibilityLabel(period.title)
            }
            segment(customLabel, icon: "calendar", selected: state.view.isCustom) { choosing = true }
                .fixedSize()
                .accessibilityLabel("Choose dates, \(customLabel)")
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    PeriodPicker(wording: wording)
                        .presentationCompactAdaptation(.sheet)
                        .presentationDragIndicator(.visible)
                }
        }
        .padding(3)
        .background(Theme.subtle, in: .rect(cornerRadius: sizeClass == .compact ? 11 : 9))
    }

    private var customLabel: String {
        if state.view.isCustom, let from = state.view.from, let to = state.view.to, let chosen = PeriodWording(from: from, to: to) { return chosen.button }
        return "Custom"
    }

    private func segment(_ title: String, icon: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Icon(icon, size: 14) }
                Text(title).lineLimit(1)
            }
            .font(sizeClass == .compact ? .subheadline : .callout)
            .fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(selected ? Theme.ink : Theme.ink2)
            .padding(.horizontal, sizeClass == .compact ? 8 : 12)
            .frame(maxWidth: icon == nil && sizeClass == .compact ? .infinity : nil)
            .frame(height: sizeClass == .compact ? 32 : 24)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: sizeClass == .compact ? 8 : 6).fill(Theme.surface)
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Presets, From and To, a calendar limited to days with data, and a
/// button that names the range: the period sheet (iPhone) and popover (Mac, iPad).
struct PeriodPicker: View {
    @Environment(SiteState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    var wording: PeriodWording?
    @State private var from = Dates.today
    @State private var to = Dates.today
    @State private var editingTo = false
    @State private var month = Dates.today

    /// The first day with data, never after today.
    private var first: Date { min(state.site.firstDay.flatMap(Dates.parse) ?? Dates.today, Dates.today) }
    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if compact {
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        CloseButton { dismiss() }
                        Spacer()
                        Text("Choose dates").font(.headline)
                        Spacer()
                        Color.clear.frame(width: 36, height: 36)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(QuickRange.allCases) { range in
                                Button(range.title) { choose(range) }
                                    .buttonStyle(ChipStyle(selected: isChosen(range)))
                            }
                        }
                    }
                    fields
                    MonthCalendar(month: $month, from: from, to: to, first: first, pick: pick)
                    Divider()
                    note
                    Button(showLabel) { apply() }
                        .buttonStyle(PrimaryButtonStyle(wide: true))
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 8)
                }
                .presentationDetents([.large])
                .presentationBackground(Theme.canvas)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(QuickRange.allCases) { range in
                            Button { choose(range) } label: {
                                Text(range.title).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).frame(height: 30)
                                    .background(isChosen(range) ? Theme.brandWash : .clear, in: .rect(cornerRadius: 6))
                                    .foregroundStyle(isChosen(range) ? Theme.brandDark : Theme.ink)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Custom range").frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(QuickRange.allCases.contains(where: isChosen) ? .clear : Theme.brandWash, in: .rect(cornerRadius: 6))
                            .foregroundStyle(QuickRange.allCases.contains(where: isChosen) ? Theme.ink2 : Theme.brandDark)
                            .fontWeight(.semibold)
                    }
                    .font(.callout)
                    .padding(10)
                    .frame(width: 150)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Theme.subtle)
                    VStack(alignment: .leading, spacing: 12) {
                        fields
                        MonthCalendar(month: $month, from: from, to: to, first: first, pick: pick)
                        note
                        HStack {
                            Spacer()
                            Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                            Button(showLabel) { apply() }.buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    .padding(16)
                    .frame(width: 380)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(compact ? Theme.canvas : Theme.surface)
        .environment(\.timeZone, .gmt)
        .onAppear {
            from = min(max(state.view.from.flatMap(Dates.parse) ?? wording?.start ?? Dates.today, first), Dates.today)
            to = min(max(state.view.to.flatMap(Dates.parse) ?? wording?.end ?? Dates.today, from), Dates.today)
            month = to
        }
    }

    private var fields: some View {
        HStack(spacing: 10) {
            DateField(label: "From", date: from, active: !editingTo) { editingTo = false; month = from }
            DateField(label: "To", date: to, active: editingTo) { editingTo = true; month = to }
        }
    }

    private var note: some View {
        Text("Your data starts on \(first.formatted(Dates.style.day().month(.abbreviated).year())). Days after today can’t be picked. One day shows hours; longer ranges show days.")
            .font(.caption)
            .foregroundStyle(Theme.ink2)
            .padding(compact ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(compact ? .clear : Theme.subtle, in: .rect(cornerRadius: 8))
    }

    /// "Show 14–20 Sep · 7 days", "Show 30 Sep · hour by hour".
    private var showLabel: String {
        let days = Calendar.utc.dateComponents([.day], from: from, to: to).day.map { $0 + 1 } ?? 1
        let chosen = PeriodWording(from: Dates.iso(from), to: Dates.iso(to))
        return days == 1 ? "Show \(chosen?.button ?? "") · hour by hour" : "Show \(chosen?.button ?? "") · \(days) days"
    }

    private func pick(_ day: Date) {
        if !editingTo {
            from = day
            if to < day { to = day }
            editingTo = true
        } else if day < from {
            from = day
        } else {
            to = day
        }
    }

    private func isChosen(_ range: QuickRange) -> Bool {
        let days = range.days()
        return state.view.from == days.from && state.view.to == days.to
    }

    private func choose(_ range: QuickRange) {
        let days = range.days()
        state.view = .custom(from: days.from, to: days.to, filters: state.view.filters, keeping: state.view)
        dismiss()
    }

    private func apply() {
        state.view = .custom(from: Dates.iso(from), to: Dates.iso(to), filters: state.view.filters, keeping: state.view)
        dismiss()
    }
}

extension ViewState {
    /// Chosen days, keeping the comparison and how filters combine.
    static func custom(from: String, to: String, filters: [Filter], keeping current: ViewState) -> ViewState {
        var view = ViewState.custom(from: from, to: to, filters: filters)
        view.compare = current.compare
        view.any = current.any
        return view
    }
}

private struct DateField: View {
    let label: String
    let date: Date
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(Theme.ink2)
                Text(date.formatted(Dates.style.weekday(.abbreviated).day().month(.abbreviated).year())).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Theme.brand : Theme.border, lineWidth: active ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(date.formatted(date: .long, time: .omitted))")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// One month, Monday first; the chosen days are a band between two dots.
struct MonthCalendar: View {
    @Binding var month: Date
    let from: Date
    let to: Date
    let first: Date
    let pick: (Date) -> Void

    private var calendar: Calendar {
        var calendar = Calendar.utc
        calendar.firstWeekday = 2
        return calendar
    }

    private var start: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: month))! }

    private var cells: [Date?] {
        let lead = (calendar.component(.weekday, from: start) + 5) % 7
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        return Array(repeating: nil, count: lead) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(start.formatted(Dates.style.month(.wide).year())).font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(start <= first)
                    .accessibilityLabel("Previous month")
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(calendar.date(byAdding: .month, value: 1, to: start)! > Dates.today)
                    .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.brand)
            .padding(.bottom, 4)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"], id: \.self) { day in
                    Text(day).font(.caption2.weight(.medium)).foregroundStyle(Theme.ink2)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day) } else { Color.clear.frame(height: 40) }
                }
            }
        }
    }

    private func cell(_ day: Date) -> some View {
        let enabled = day >= first && day <= Dates.today
        let end = day == from || day == to
        let inside = day > from && day < to
        return Button { pick(day) } label: {
            Text(day.formatted(Dates.style.day()))
                .font(.body.weight(end ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(end ? .white : inside ? Theme.brandDark : enabled ? Theme.ink : Theme.muted.opacity(0.5))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background {
                    ZStack {
                        if inside || (end && from != to) {
                            Rectangle().fill(Theme.brandWash)
                                .padding(.leading, day == from ? 20 : 0)
                                .padding(.trailing, day == to ? 20 : 0)
                        }
                        if end { Circle().fill(Theme.primary).frame(width: 38, height: 38) }
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(end ? .isSelected : [])
    }

    private func shift(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: start)!
    }
}

enum QuickRange: String, CaseIterable, Identifiable {
    case today, yesterday, thisMonth, lastMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        }
    }

    /// Inclusive days in UTC, the instance's clock.
    func days(now: Date = .now) -> (from: String, to: String) {
        let today = Calendar.utc.startOfDay(for: now)
        let monthStart = Calendar.utc.date(from: Calendar.utc.dateComponents([.year, .month], from: today))!
        switch self {
        case .today: return (Dates.iso(today), Dates.iso(today))
        case .yesterday:
            let day = today.addingTimeInterval(-86_400)
            return (Dates.iso(day), Dates.iso(day))
        case .thisMonth: return (Dates.iso(monthStart), Dates.iso(today))
        case .lastMonth:
            let end = monthStart.addingTimeInterval(-86_400)
            let start = Calendar.utc.date(from: Calendar.utc.dateComponents([.year, .month], from: end))!
            return (Dates.iso(start), Dates.iso(end))
        }
    }
}

// MARK: - Compare · Filter · Actions

/// The same three controls under the period on every report. Pressed
/// states use the brand wash; Filter says how many conditions apply.
struct ControlsRow: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    let screen: Screen
    var filters = true
    var compare = true
    @State private var filtering = false

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 8) {
            if compare {
                Button { state.view.compare.toggle() } label: {
                    Label(state.view.compare ? "Comparing" : "Compare", image: "Icons/compare")
                }
                .buttonStyle(ControlStyle(on: state.view.compare, grow: sizeClass == .compact))
                .accessibilityValue(state.view.compare ? "On" : "Off")
            }
            if filters {
                Button { filtering = true } label: {
                    Label(state.view.filters.isEmpty ? "Filter" : "Filter · \(state.view.filters.count)", image: "Icons/filter")
                }
                .buttonStyle(ControlStyle(on: !state.view.filters.isEmpty, grow: sizeClass == .compact))
                .popover(isPresented: $filtering, arrowEdge: .bottom) {
                    FilterEditor()
                        .presentationCompactAdaptation(.sheet)
                        .presentationDetents([.medium, .large])
                        .presentationBackground(Theme.canvas)
                        .presentationDragIndicator(.visible)
                }
            }
            ActionsMenu(screen: screen)
            #if os(macOS)
            Button { NSWorkspace.shared.open(state.workspaceURL(screen)) } label: { Icon("external", size: 15) }
                .buttonStyle(ControlStyle(on: false, square: true))
                .help("Open this view in the workspace")
                .accessibilityLabel("Open in the workspace")
            #endif
        }
    }
}

/// Open in the workspace, copy a link, share, add a note, set up an alert.
struct ActionsMenu: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    let screen: Screen

    var body: some View {
        let url = state.workspaceURL(screen)
        Menu {
            Button { openURL(url) } label: { Label("Open in the workspace", image: "Icons/external") }
            Button { copy(url) } label: { Label("Copy link to this view", image: "Icons/link") }
            ShareLink(item: url) { Label("Share…", image: "Icons/send") }
            Divider()
            Button { state.addingNote = true } label: { Label("Add a note to the chart", image: "Icons/pencil") }
            Button { openURL(state.client.instance.origin.appending(path: "\(state.site.slug)/reports").appending(queryItems: [URLQueryItem(name: "tab", value: "alerts")])) } label: {
                Label("Set up an alert…", image: "Icons/bell-plus")
            }
            Text("Alerts are set up in the workspace.")
        } label: {
            if sizeClass == .compact {
                Label("Actions", image: "Icons/more")
            } else {
                Icon("more", size: 16)
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(ControlStyle(on: false, grow: sizeClass == .compact, square: sizeClass != .compact))
        .accessibilityLabel("Actions")
    }

    private func copy(_ url: URL) {
        copyText(url.absoluteString)
    }
}

func copyText(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

extension View {
    /// Long-press (iPhone, iPad) or right-click (Mac) on a row: filter by it,
    /// leave it out, its details and page, copy it.
    func rowMenu(_ dimension: String, _ value: String, label: String? = nil) -> some View {
        modifier(RowMenu(dimension: dimension, value: value, label: label ?? value))
    }
}

private struct RowMenu: ViewModifier {
    @Environment(SiteState.self) private var state
    @Environment(\.openURL) private var openURL
    let dimension: String
    let value: String
    let label: String

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { state.filter(dimension, value) } label: { Label("Filter by \(label)", image: "Icons/filter") }
            Button {
                state.view.filters.removeAll { $0.dimension == dimension }
                state.view.filters.append(.init(dimension: dimension, value: value, negated: true))
            } label: { Label("Leave out \(label)", image: "Icons/x") }
            if dimension == "page" {
                Divider()
                Button { state.inspect(value) } label: { Label("Page details", image: "Icons/pages") }
                if let url = URL(string: "https://\(state.site.host)\(value)") {
                    Button { openURL(url) } label: { Label("Open on \(state.site.host)", image: "Icons/external") }
                }
            }
            Divider()
            Button { copyText(value) } label: { Label("Copy", image: "Icons/copy") }
        }
    }
}

// MARK: - Filter

/// Conditions on page, source, campaign, country, device, browser or OS,
/// all or any of them, with how many visitors match before applying.
struct FilterEditor: View {
    @Environment(SiteState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var draft = ViewState()
    @State private var adding = false
    @State private var match: (visitors: Double, everyone: Double)?

    static let dimensions = ["page", "source", "campaign", "country", "device", "browser", "os"]

    var body: some View {
        let compact = sizeClass == .compact
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if compact {
                    CloseButton { dismiss() }
                    Spacer(minLength: 0)
                }
                Text("Filter").font(.headline)
                Spacer()
                Button("Clear all") { draft.filters = [] }
                    .foregroundStyle(Theme.brandDark)
                    .disabled(draft.filters.isEmpty)
                    .buttonStyle(.plain)
            }
            if draft.filters.count > 1 || compact {
                Picker("Match", selection: $draft.any) {
                    Text("Every condition").tag(false)
                    Text("Any condition").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ForEach(draft.filters) { filter in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Labels.dimension(filter.dimension)) \(filter.negated ? "is not" : "is")").font(.caption).foregroundStyle(Theme.ink2)
                        Text(Labels.value(filter.value, dimension: filter.dimension)).foregroundStyle(Theme.ink).lineLimit(1)
                    }
                    Spacer()
                    Button { draft.filters.removeAll { $0 == filter } } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink2)
                        .accessibilityLabel("Remove \(Labels.dimension(filter.dimension)) \(filter.value)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.subtle, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }
            if adding {
                ConditionBuilder(view: draft) { filter in
                    draft.filters.removeAll { $0.dimension == filter.dimension && $0.negated == filter.negated }
                    draft.filters.append(filter)
                    adding = false
                } cancel: { adding = false }
            } else if draft.filters.count < 8 {
                Button { adding = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Add condition", systemImage: "plus").fontWeight(.medium)
                        Text("Page, source, campaign, country, device, browser, OS").font(.caption).foregroundStyle(Theme.ink2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.brandDark)
            }
            if let match, !draft.filters.isEmpty {
                Text("\(Format.count(Int(match.visitors))) visitors match · \(Format.share(match.visitors, of: match.everyone)) of everyone in these dates")
                    .font(.subheadline)
                    .foregroundStyle(Theme.brandDark)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.brandWash, in: .rect(cornerRadius: 10))
            }
            Spacer(minLength: 0)
            HStack {
                if !compact {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                }
                Button(applyLabel) {
                    state.view.filters = draft.filters
                    state.view.any = draft.any
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle(wide: compact))
            }
        }
        .padding(compact ? 16 : 18)
        .frame(width: compact ? nil : 380)
        .background(compact ? Theme.canvas : Theme.surface)
        .onAppear { draft = state.view }
        .task(id: draft) { await count() }
    }

    private var applyLabel: String {
        if draft.filters.isEmpty { return state.view.filters.isEmpty ? "Done" : "Show everyone" }
        guard let match else { return "Apply" }
        return sizeClass == .compact ? "Show \(Format.count(Int(match.visitors))) visitors" : "Show \(Format.count(Int(match.visitors)))"
    }

    /// Visitors in these dates with and without the conditions.
    private func count() async {
        guard !draft.filters.isEmpty else { match = nil; return }
        try? await Task.sleep(for: .milliseconds(250))
        var everyone = draft
        everyone.filters = []
        async let filtered = state.client.report("overview", site: state.site.slug, view: draft)
        async let all = state.client.report("overview", site: state.site.slug, view: everyone)
        guard let filtered = try? await filtered, let all = try? await all else { return }
        match = (filtered.rows.first?["visitor_days"]?.number ?? 0, all.rows.first?["visitor_days"]?.number ?? 0)
    }
}

/// A new condition: the dimension, is or is not, and a value from the
/// period's top values or typed in.
private struct ConditionBuilder: View {
    @Environment(SiteState.self) private var state
    let view: ViewState
    let add: (ViewState.Filter) -> Void
    let cancel: () -> Void
    @State private var dimension = "source"
    @State private var negated = false
    @State private var value = ""
    @State private var suggestions: [(value: String, label: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Dimension", selection: $dimension) {
                    ForEach(FilterEditor.dimensions, id: \.self) { Text(Labels.dimension($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Is", selection: $negated) {
                    Text("is").tag(false)
                    Text("is not").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.plain).foregroundStyle(Theme.ink2).font(.subheadline)
            }
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            let shown = suggestions.filter { value.isEmpty || $0.label.localizedStandardContains(value) || $0.value.localizedStandardContains(value) }.prefix(6)
            if !shown.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(shown), id: \.value) { suggestion in
                        Button { add(.init(dimension: dimension, value: suggestion.value, negated: negated)) } label: {
                            Text(suggestion.label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).frame(height: 34).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Theme.surface, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
        }
        .padding(12)
        .background(Theme.subtle, in: .rect(cornerRadius: 10))
        .task(id: dimension) { await suggest() }
    }

    private var placeholder: String {
        switch dimension {
        case "page": "/pricing"
        case "source": "google.com, newsletter"
        case "country": "DE, FR"
        case "device": "mobile, desktop, tablet"
        default: "Value"
        }
    }

    private func submit() {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        add(.init(dimension: dimension, value: trimmed, negated: negated))
    }

    private func suggest() async {
        suggestions = []
        var everyone = view
        everyone.filters = []
        guard let rows = try? await state.client.report("breakdown", site: state.site.slug, view: everyone, parameters: ["dimension": dimension, "limit": "20"]).rows else { return }
        suggestions = rows.compactMap { row in
            guard let key = row["value"]?.text, !key.isEmpty else { return nil }
            let label = row["label"]?.text ?? ""
            return (key, label.isEmpty || label == key ? Labels.value(key, dimension: dimension) : label)
        }
    }
}

// MARK: - Buttons

/// The controls row's buttons: 36 pt on iPhone, 28 pt on Mac; on is the brand wash.
struct ControlStyle: ButtonStyle {
    var on: Bool
    var grow = false
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ControlLabelStyle())
            .font(.subheadline.weight(on ? .semibold : .medium))
            .foregroundStyle(on ? Theme.brandDark : Theme.ink)
            .padding(.horizontal, square ? 0 : grow ? 8 : 12)
            .frame(width: square ? Theme.controlHeight : nil, height: Theme.controlHeight)
            .frame(maxWidth: grow ? .infinity : nil)
            .background(on ? Theme.brandWash : Theme.surface, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Theme.brand : Theme.border, lineWidth: on ? 1.2 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect)
    }
}

private struct ControlLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.frame(width: 16, height: 16)
            configuration.title.lineLimit(1)
        }
    }
}

/// Primary: the brand's dark red, 50 pt capsule on iPhone.
struct PrimaryButtonStyle: ButtonStyle {
    var wide = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(wide ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: wide ? 50 : Theme.controlHeight)
            .background(Theme.primary.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: .rect(cornerRadius: wide ? 25 : 8))
            .contentShape(.rect)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: wide ? 50 : Theme.controlHeight)
            .background(Theme.surface, in: .rect(cornerRadius: wide ? 25 : 8))
            .overlay(RoundedRectangle(cornerRadius: wide ? 25 : 8).strokeBorder(Theme.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect)
    }
}

struct ChipStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.medium))
            .foregroundStyle(selected ? Theme.brandDark : Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selected ? Theme.brandWash : Theme.subtle, in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The round × that closes a sheet on iPhone.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(Theme.ink2)
                .frame(width: 36, height: 36)
                .background(Theme.subtle, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// Display names for dimensions and the values the server sends.
enum Labels {
    static func dimension(_ name: String) -> String {
        switch name {
        case "os": "OS"
        default: name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    static func value(_ value: String, dimension: String) -> String {
        switch dimension {
        case "country":
            Locale.current.localizedString(forRegionCode: value) ?? value
        case "device", "browser", "os":
            ["macos": "macOS", "ios": "iOS"][value] ?? (value.prefix(1).uppercased() + value.dropFirst())
        case "source":
            value == "direct" ? "Direct" : value
        default:
            value
        }
    }
}
