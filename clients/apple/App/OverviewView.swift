import AnalyticoKit
import Charts
import SwiftUI

/// The site at a glance, as on the workspace Overview: four metric cards
/// (each switches the chart or opens its report), the trend against the
/// period before, where visitors come from, where they are and what sells.
struct OverviewView: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @State private var data = Loaded<OverviewData>()
    @State private var metric: ChartMetric = .visitors
    @State private var pinned: Date?

    var body: some View {
        let waiting = state.site.firstDay == nil && data.value?.pageViews == 0
        ScreenScaffold(screen: .overview, wording: data.value?.wording, stale: data.stale, waiting: waiting, reload: load) {
            if let overview = data.value {
                if overview.pageViews == 0 {
                    nothingHere(overview)
                } else {
                    notes(overview)
                    tiles(overview)
                    chart(overview)
                    cards(overview)
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "The overview didn’t load")
            }
        }
        .task(id: LoadKey(view: state.view, metric: metric)) { await load() }
    }

    private func load() async {
        pinned = nil
        data.apply(await fetch { try await OverviewData.load(client: state.client, site: state.site, view: state.view, metric: metric) })
    }

    /// Just that day, hour by hour, with the same filters.
    private func open(_ day: Date) {
        let iso = Dates.iso(day)
        state.view = .custom(from: iso, to: iso, filters: state.view.filters, keeping: state.view)
    }

    // MARK: Metrics

    private func tiles(_ data: OverviewData) -> some View {
        let compare = state.view.compare
        let one = data.wording?.oneDay == true
        return MetricGrid {
            Button { metric = .visitors } label: {
                MetricCard(label: one ? "Visitors" : "Visitors / day", value: average(data.number("visitor_days") / data.days),
                           change: compare ? Format.change(data.number("visitor_days"), data.number("previous_visitor_days")) : nil,
                           versus: "vs \(average(data.number("previous_visitor_days") / data.days))", selected: metric == .visitors)
            }
            .buttonStyle(.plain)
            if state.site.mode == "full" {
                Button { state.show(.retention) } label: {
                    let now = data.totals["returning_share"]?.number
                    let before = data.totals["previous_returning_share"]?.number
                    MetricCard(label: "Returning visitors", value: now.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—",
                               change: compare ? pointsChange(now, before) : nil,
                               versus: before.map { "vs \($0.formatted(.percent.precision(.fractionLength(0))))" } ?? "")
                }
                .buttonStyle(.plain)
            } else {
                MetricCard(label: state.site.mode == "lite" ? "Visitor-days" : "Visits",
                           value: Format.count(Int(data.number(state.site.mode == "lite" ? "visitor_days" : "sessions"))),
                           change: compare ? Format.change(data.number(state.site.mode == "lite" ? "visitor_days" : "sessions"), data.number(state.site.mode == "lite" ? "previous_visitor_days" : "previous_sessions")) : nil,
                           versus: "vs \(Format.count(Int(data.number(state.site.mode == "lite" ? "previous_visitor_days" : "previous_sessions"))))")
            }
            Button { metric = .views } label: {
                MetricCard(label: "Page views", value: Format.count(Int(data.number("page_views"))),
                           change: compare ? Format.change(data.number("page_views"), data.number("previous_page_views")) : nil,
                           versus: "vs \(Format.count(Int(data.number("previous_page_views"))))", selected: metric == .views)
            }
            .buttonStyle(.plain)
            if data.number("orders") > 0 {
                Button { state.show(.revenue) } label: {
                    MetricCard(label: "Revenue", value: data.money("revenue_minor"),
                               change: compare ? Format.change(data.number("revenue_minor"), data.number("previous_revenue_minor")) : nil,
                               versus: "vs \(data.money("previous_revenue_minor"))")
                }
                .buttonStyle(.plain)
            } else {
                Button { metric = .active } label: {
                    MetricCard(label: "Active time", value: Format.duration(milliseconds: data.number("active_ms")),
                               change: compare ? Format.change(data.number("active_ms"), data.number("previous_active_ms")) : nil,
                               versus: "vs \(Format.duration(milliseconds: data.number("previous_active_ms")))", selected: metric == .active)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Chart

    private func chart(_ data: OverviewData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                // The loaded data's metric: the title never runs ahead of the line it names.
                Text(data.metric.title(oneDay: data.wording?.oneDay == true)).font(Theme.cardTitle).foregroundStyle(Theme.ink)
                Spacer()
                if let wording = data.wording { ChartLegend(wording: wording, compared: !data.previousTrend.isEmpty) }
            }
            if let day = pinned, let point = data.trend.first(where: { $0.at == day }) {
                let before = data.previousTrend.first { $0.at == day }
                let change = before.map { Format.change(point.value, $0.value) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(day.formatted(data.hourly ? Dates.style.weekday(.abbreviated).hour().minute() : Dates.style.weekday(.abbreviated).day().month(.abbreviated)) + (data.wording?.running == true && day == data.trend.last?.at ? " · so far" : ""))
                            .font(.caption).foregroundStyle(Theme.ink2)
                        HStack(spacing: 6) {
                            Text(data.metric.noun(point.value)).fontWeight(.semibold).foregroundStyle(Theme.ink)
                            if let change, !change.text.isEmpty { ChangeLabel(change: change, versus: "vs \(data.metric == .active ? Format.duration(milliseconds: before!.value) : Format.count(Int(before!.value)))") }
                        }
                    }
                    Spacer(minLength: 4)
                    if !data.hourly {
                        Button("Open this day →") { open(day) }
                            .buttonStyle(.plain)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.brandDark)
                    }
                    Button { pinned = nil } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.ink2).frame(width: 28, height: 28).background(Theme.subtle, in: .circle) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear the selected day")
                }
                .font(sizeClass == .compact ? .footnote : .callout)
            } else if let insight = data.insight {
                Text(insight).font(sizeClass == .compact ? .footnote : .callout).foregroundStyle(Theme.ink2)
            }
            TrendChart(current: data.trend, previous: data.previousTrend, notes: data.notes.filter { !$0.draft }, running: data.wording?.running ?? false, hourly: data.hourly, metric: data.metric, compact: sizeClass == .compact, pinned: $pinned, open: open)
                .frame(height: sizeClass == .compact ? 190 : 230)
        }
        .card()
    }

    // MARK: Cards

    @ViewBuilder private func cards(_ data: OverviewData) -> some View {
        let columns = sizeClass == .compact ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: sizeClass == .compact ? 12 : 16) {
            sources(data)
            places(data)
            if !data.products.isEmpty { products(data) } else { pages(data) }
        }
    }

    private func sources(_ data: OverviewData) -> some View {
        SectionCard(title: "Where visitors come from") {
            Text("Tap to filter")
        } content: {
            let top = data.sources.map { $0["page_views"]?.number ?? 0 }.max() ?? 1
            VStack(spacing: 8) {
                ForEach(Array(data.sources.enumerated()), id: \.offset) { _, row in
                    let tone = Theme.channel(row["channel"]?.text)
                    Button { state.filter("source", row["value"]?.text ?? "") } label: {
                        ShareRow(title: row["label"]?.text ?? row["value"]?.text ?? "", value: Format.count(Int(row["page_views"]?.number ?? 0)),
                                 share: share(row["page_views"]?.number ?? 0, top) * 0.85, color: tone.color, wash: tone.wash)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .rowMenu("source", row["value"]?.text ?? "", label: row["label"]?.text)
                    .accessibilityHint("Filters every report by this source")
                }
                if data.sources.isEmpty { Text("Nothing yet in this period").font(.callout).foregroundStyle(Theme.ink2) }
            }
            footerLink("All sources") { state.show(.sources) }
        }
    }

    private func places(_ data: OverviewData) -> some View {
        SectionCard(title: "Where they are") {
            Text("Page views")
        } content: {
            let total = data.number("page_views")
            VStack(spacing: 12) {
                ForEach(Array(data.countries.prefix(5).enumerated()), id: \.offset) { _, row in
                    let code = row["value"]?.text ?? ""
                    Button { state.filter("country", code) } label: {
                        MeterRow(code: code == "unknown" ? "?" : code, title: row["label"]?.text ?? code, value: Format.share(row["page_views"]?.number ?? 0, of: total), share: share(row["page_views"]?.number ?? 0, total))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .rowMenu("country", code, label: row["label"]?.text)
                }
            }
            Text("Country from the IP at collection · IP never stored").font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private func products(_ data: OverviewData) -> some View {
        SectionCard(title: "What sells") {
            Text("Revenue")
        } content: {
            VStack(spacing: 10) {
                ForEach(Array(data.products.prefix(4).enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink2)
                            .frame(width: 24, height: 24).background(Theme.subtle, in: .rect(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row["product"]?.text ?? "").foregroundStyle(Theme.ink).lineLimit(1)
                            Text(plural(Int(row["orders"]?.number ?? 0), "order")).font(.caption).foregroundStyle(Theme.ink2)
                        }
                        Spacer()
                        Text(Format.money(minor: Int(row["revenue_minor"]?.number ?? 0), currency: state.site.currency)).monospacedDigit().foregroundStyle(Theme.ink)
                    }
                }
            }
            footerLink("Open revenue") { state.show(.revenue) }
        }
    }

    private func pages(_ data: OverviewData) -> some View {
        SectionCard(title: "Top pages") {
            Text("Page views")
        } content: {
            let top = data.pages.map { $0["page_views"]?.number ?? 0 }.max() ?? 1
            VStack(spacing: 8) {
                ForEach(Array(data.pages.enumerated()), id: \.offset) { _, row in
                    Button { state.inspect(row["value"]?.text ?? "") } label: {
                        ShareRow(title: row["value"]?.text ?? "", value: Format.count(Int(row["page_views"]?.number ?? 0)), share: share(row["page_views"]?.number ?? 0, top) * 0.85, rule: false)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .rowMenu("page", row["value"]?.text ?? "")
                }
            }
            footerLink("All pages") { state.show(.pages) }
        }
    }

    private func footerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.right").font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.brandDark)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: States

    /// No visits in this view: a site still waiting for its first visit,
    /// filters that match nothing, or dates without data. Each says which.
    @ViewBuilder private func nothingHere(_ data: OverviewData) -> some View {
        let between = data.wording?.between ?? "in this period"
        if state.site.firstDay == nil {
            StageView(art: "waiting", title: "Waiting for your first visit",
                      text: "Charts appear here once the tracker on \(state.site.host) reports a page view. Dates and filters become useful then.",
                      primary: ("Open setup in the workspace", { openURL(state.client.instance.origin.appending(path: "\(state.site.slug)/setup")) }),
                      secondary: ("Check again", { Task { await load() } }))
        } else if !state.view.filters.isEmpty {
            StageView(art: "filter", title: "No visits match these filters",
                      text: "Nothing matched \(state.view.filters.map { "\(Labels.dimension($0.dimension)) \($0.negated ? "is not" : "is") \(Labels.value($0.value, dimension: $0.dimension))" }.joined(separator: state.view.any ? " or " : " and ")) \(between).",
                      primary: ("Clear filters", { state.view.filters = [] }),
                      secondary: ("Show the last 30 days", { state.view = ViewState(period: .month, filters: state.view.filters) }))
        } else {
            let first = state.site.firstDay.flatMap(Dates.parse)
            let before = if let first, let wording = data.wording { wording.end < first } else { false }
            StageView(art: "calendar",
                      title: data.wording?.isToday == true ? "No visits yet today" : before ? "Before tracking started" : "No visits \(between)",
                      text: before && first != nil
                        ? "\(state.site.name) has data from \(first!.formatted(Dates.style.day().month(.abbreviated).year())). These dates are before tracking started, so there is nothing to show yet."
                        : data.wording?.isToday == true
                            ? "Nothing has arrived since midnight (UTC). Data health in the workspace shows whether collection stopped."
                            : "The tracker reported nothing \(data.wording?.oneDay == true ? "that day" : "in these dates"). Data health in the workspace shows whether collection stopped.",
                      primary: ("Show the last 30 days", { state.view = ViewState(period: .month, filters: state.view.filters) }),
                      secondary: data.wording?.isToday == true ? ("Open data health", { openURL(state.client.instance.origin.appending(path: "\(state.site.slug)/health")) }) : nil)
        }
    }

    /// Notes the daily check drafted, to keep or dismiss.
    @ViewBuilder private func notes(_ data: OverviewData) -> some View {
        ForEach(data.notes.filter(\.draft)) { note in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Icon("sparkles", size: 14)
                    Text("Noticed on \(Dates.dayName(note.day))").font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.brandDark)
                Text(note.label).foregroundStyle(Theme.ink)
                HStack(spacing: 14) {
                    Button("Keep as a note") {
                        Task { try? await state.client.keepNote(site: state.site.slug, id: note.id); await load() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Theme.primary, in: .capsule)
                    Button("Dismiss") {
                        Task { try? await state.client.deleteNote(site: state.site.slug, id: note.id); await load() }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.brandDark)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.brandWash, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.brand.opacity(0.25)))
        }
    }
}

private struct LoadKey: Hashable {
    var view: ViewState
    var metric: ChartMetric
}

/// What the trend chart shows; the metric cards switch it.
enum ChartMetric: String, Hashable {
    case visitors, views, active

    var series: String {
        switch self {
        case .visitors: "visitor_days"
        case .views: "views"
        case .active: "active"
        }
    }

    func title(oneDay: Bool) -> String {
        switch self {
        case .visitors: oneDay ? "Visitors" : "Visitors / day"
        case .views: "Page views"
        case .active: "Active time"
        }
    }

    func noun(_ value: Double) -> String {
        switch self {
        case .visitors: plural(Int(value), "visitor")
        case .views: plural(Int(value), "page view")
        case .active: Format.duration(milliseconds: value)
        }
    }
}

struct OverviewData {
    var totals: Report.Row
    var currency: String
    /// What the period is called, for labels and comparisons.
    var wording: PeriodWording?
    var days: Double
    var hourly: Bool
    var trend: [Point]
    var previousTrend: [Point]
    var sources: [Report.Row]
    var countries: [Report.Row]
    var pages: [Report.Row]
    var products: [Report.Row]
    var notes: [Note]
    var metric: ChartMetric

    var pageViews: Double { number("page_views") }

    func number(_ key: String) -> Double { totals[key]?.number ?? 0 }

    func money(_ key: String) -> String { Format.money(minor: Int(number(key)), currency: currency) }

    /// "Tue 6 Oct was the busiest day — 2,796 visitors (3.3× the same day before)."
    var insight: String? {
        let complete = wording?.running == true ? Array(trend.dropLast()) : trend
        guard complete.count > 1, let best = complete.indices.max(by: { complete[$0].value < complete[$1].value }), complete[best].value > 0 else { return nil }
        let point = complete[best]
        let when = hourly ? point.at.formatted(Dates.style.hour().minute()) : point.at.formatted(Dates.style.weekday(.abbreviated).day().month(.abbreviated))
        var text = "\(when) was the busiest \(hourly ? "hour" : "day") — \(metric.noun(point.value))"
        if best < previousTrend.count, previousTrend[best].value > 0 {
            let change = Format.change(point.value, previousTrend[best].value)
            text += " (\(change.text.hasSuffix("×") ? "\(change.text) the same \(hourly ? "hour" : "day") before" : "\(change.text) on the same \(hourly ? "hour" : "day") before"))"
        }
        return text + "."
    }

    static func load(client: Client, site: Site, view: ViewState, metric: ChartMetric) async throws -> OverviewData {
        let slug = site.slug
        async let overview = client.report("overview", site: slug, view: view)
        async let series = client.report("timeseries", site: slug, view: view, parameters: ["metric": metric.series])
        async let sources = client.report("breakdown", site: slug, view: view, parameters: ["dimension": "source", "limit": "5"])
        async let countries = client.report("breakdown", site: slug, view: view, parameters: ["dimension": "country", "limit": "5"])
        async let pages = client.report("breakdown", site: slug, view: view, parameters: ["dimension": "page", "limit": "5"])
        async let notes = client.notes(site: slug, view: view)
        let report = try await overview
        let totals = report.rows.first ?? [:]
        let rolling = !view.isCustom && view.period == .day
        let wording = PeriodWording(from: report.from, to: report.to, rolling: rolling)
        let current = try await series.rows.map(Point.init(row:))
        var previous: [Point] = []
        if view.compare, !rolling, let before = view.previous(from: report.from, to: report.to) {
            previous = (try? await client.report("timeseries", site: slug, view: before, parameters: ["metric": metric.series]).rows.map(Point.init(row:))) ?? []
        }
        var products: [Report.Row] = []
        if (totals["orders"]?.number ?? 0) > 0 {
            products = (try? await client.report("revenue", site: slug, view: view, parameters: ["limit": "4"]).rows) ?? []
        }
        return try await OverviewData(
            totals: totals,
            currency: totals["currency"]?.text ?? site.currency,
            wording: wording,
            days: wording?.elapsedDays ?? 1,
            hourly: rolling || wording?.oneDay == true,
            trend: current,
            previousTrend: zip(current, previous).map { Point(at: $0.at, value: $1.value) },
            sources: sources.rows, countries: countries.rows, pages: pages.rows, products: products,
            notes: notes,
            metric: metric
        )
    }
}

/// Small averages keep a decimal, as in the workspace: 0.5, not 0.
func average(_ value: Double) -> String {
    value < 10 && value != value.rounded() ? value.formatted(.number.precision(.fractionLength(1))) : Format.count(Int(value.rounded()))
}

struct Point: Identifiable {
    var at: Date
    var value: Double
    var id: Date { at }

    init(at: Date, value: Double) {
        self.at = at
        self.value = value
    }

    init(row: Report.Row) {
        at = Dates.parse(row["at"]?.text ?? "") ?? .distantPast
        value = row["value"]?.number ?? row["page_views"]?.number ?? 0
    }
}

/// The metric over the period, the previous period dashed, notes as rules.
/// A running period's last bucket is a "now" band, never a drop.
struct TrendChart: View {
    let current: [Point]
    let previous: [Point]
    let notes: [Note]
    let running: Bool
    let hourly: Bool
    var metric: ChartMetric = .visitors
    /// iPhone: only the first and last day are named, at the chart's edges.
    var compact = false
    /// The bucket a finger last let go of (iPhone), shown above the chart.
    @Binding var pinned: Date?
    /// Opens a day (daily charts only): a click on the Mac.
    var open: ((Date) -> Void)?
    /// The bucket under the pointer (Mac, iPad) or the finger (iPhone).
    @State private var selection: Date?

    /// The bucket nearest to a date.
    func nearest(_ date: Date) -> Point? {
        current.min { abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date)) }
    }

    private var complete: [Point] { running ? Array(current.dropLast()) : current }

    /// The bucket nearest to where the pointer is.
    private var selected: Point? {
        selection.flatMap(nearest) ?? pinned.flatMap(nearest)
    }
    private var labelFormat: Date.FormatStyle {
        if hourly { return Dates.style.hour(.twoDigits(amPM: .abbreviated)).minute() }
        return compact || current.count > 8 ? Dates.style.day().month(.abbreviated) : Dates.style.weekday(.abbreviated).day()
    }

    private var ticks: [Date] {
        let step = max(1, Int((Double(current.count) / 7).rounded(.up)))
        return stride(from: 0, to: current.count, by: step).map { current[$0].at }
    }
    private var partial: Point? { running ? current.last : nil }
    private var bucket: TimeInterval { hourly ? 3600 : 86_400 }

    var body: some View {
        Chart {
            if let partial {
                RectangleMark(xStart: .value("Now", partial.at - bucket / 2), xEnd: .value("Now", partial.at + bucket / 2))
                    .foregroundStyle(Theme.brandWash)
                    .annotation(position: .overlay, alignment: .top) {
                        Text("now").font(.caption2.weight(.semibold)).foregroundStyle(Theme.brandDark).padding(.top, 4)
                    }
            }
            ForEach(previous) { point in
                LineMark(x: .value("Time", point.at), y: .value("Value", point.value), series: .value("Period", "Before"))
                    .foregroundStyle(Theme.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .interpolationMethod(.monotone)
            }
            ForEach(complete) { point in
                AreaMark(x: .value("Time", point.at), y: .value("Value", point.value))
                    .foregroundStyle(LinearGradient(colors: [Theme.brand.opacity(0.18), Theme.brand.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.at), y: .value("Value", point.value), series: .value("Period", "Now"))
                    .foregroundStyle(Theme.brand)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let last = complete.last {
                PointMark(x: .value("Time", last.at), y: .value("Value", last.value))
                    .symbol { Circle().strokeBorder(Theme.brand, lineWidth: 2).background(Circle().fill(Theme.surface)).frame(width: 9, height: 9) }
            }
            if let point = selected {
                #if os(macOS)
                RuleMark(x: .value("Selected", point.at))
                    .foregroundStyle(Theme.ink2.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartTooltip(point: point, before: previous.first { $0.at == point.at }, hourly: hourly, metric: metric, running: running && point.at == current.last?.at)
                    }
                #else
                RuleMark(x: .value("Selected", point.at))
                    .foregroundStyle(Theme.ink2.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                #endif
                PointMark(x: .value("Selected", point.at), y: .value("Value", point.value))
                    .symbol { Circle().fill(Theme.brand).frame(width: 9, height: 9).overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2)) }
                if let before = previous.first(where: { $0.at == point.at }) {
                    PointMark(x: .value("Selected", before.at), y: .value("Before", before.value))
                        .symbol { Circle().fill(Theme.muted).frame(width: 7, height: 7) }
                }
            }
            ForEach(notes) { note in
                if let day = Dates.parse(note.day) {
                    RuleMark(x: .value("Note", day))
                        .foregroundStyle(Theme.muted.opacity(0.5))
                        .annotation(position: .top, alignment: .leading) {
                            Text(note.label).font(.caption2).foregroundStyle(Theme.ink2)
                        }
                }
            }
        }
        .pointerSelection($selection, click: hourly ? nil : { date in if let point = nearest(date) { open?(point.at) } })
        #if os(iOS)
        // The chosen bucket's value shows above the chart, and stays when the finger lifts.
        .onChange(of: selection) { _, now in
            if let now { pinned = nearest(now)?.at }
        }
        .onChange(of: pinned) { _, now in
            if now == nil { selection = nil }
        }
        #endif
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.subtle)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .active ? Format.duration(milliseconds: number) : number.formatted(.number.notation(.compactName))).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .chartXAxis {
            if compact, let first = current.first, let last = current.last {
                AxisMarks(values: [first.at]) { _ in
                    AxisValueLabel(format: labelFormat, anchor: .topLeading).foregroundStyle(Theme.muted)
                }
                AxisMarks(values: [last.at]) { _ in
                    AxisValueLabel(format: labelFormat, anchor: .topTrailing).foregroundStyle(Theme.muted)
                }
            } else {
                // Labels sit under the points they name, at most seven of them.
                AxisMarks(values: ticks) { _ in
                    AxisValueLabel(format: labelFormat, anchor: .top).foregroundStyle(Theme.muted)
                }
            }
        }
        .environment(\.timeZone, .gmt)
        .accessibilityLabel(hourly ? "\(metric.title(oneDay: true)) hour by hour" : "\(metric.title(oneDay: false)) over the period")
    }
}

extension View {
    /// Reads a chart at the pointer: hovering on the Mac, as the workspace's
    /// chart does; touch and drag on iPhone and iPad.
    func pointerSelection(_ selection: Binding<Date?>, click: ((Date) -> Void)? = nil) -> some View {
        #if os(macOS)
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(.rect)
                    .onTapGesture { location in
                        guard let click, let plot = proxy.plotFrame, let date = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self) else { return }
                        click(date)
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            selection.wrappedValue = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self)
                        case .ended:
                            selection.wrappedValue = nil
                        }
                    }
            }
        }
        #else
        chartXSelection(value: selection)
        #endif
    }
}

/// The hovered bucket: when, its value, and the period before's.
private struct ChartTooltip: View {
    let point: Point
    let before: Point?
    let hourly: Bool
    let metric: ChartMetric
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(point.at.formatted(hourly ? Dates.style.weekday(.abbreviated).hour().minute() : Dates.style.weekday(.abbreviated).day().month(.abbreviated)) + (running ? " · so far" : ""))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(metric.noun(point.value)).font(.caption.weight(.semibold)).foregroundStyle(.white)
            if let before {
                let change = Format.change(point.value, before.value)
                HStack(spacing: 4) {
                    Text("before: \(metric == .active ? Format.duration(milliseconds: before.value) : Format.count(Int(before.value)))")
                        .foregroundStyle(.white.opacity(0.7))
                    if !change.text.isEmpty {
                        Text(change.text).fontWeight(.semibold)
                            .foregroundStyle(change.direction == .up ? Color(red: 0.48, green: 0.83, blue: 0.63) : change.direction == .down ? Color(red: 0.95, green: 0.63, blue: 0.63) : .white)
                    }
                }
                .font(.caption2)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(light: 0x282421, dark: 0x3A3330), in: .rect(cornerRadius: 8))
    }
}

/// Which line is which, by its dates: "● 2–8 Oct  – – 25 Sep–1 Oct".
struct ChartLegend: View {
    let wording: PeriodWording
    let compared: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle().fill(Theme.brand).frame(width: 8, height: 8)
                Text(wording.this).fontWeight(.semibold).foregroundStyle(Theme.ink)
            }
            if compared {
                HStack(spacing: 5) {
                    Capsule().fill(Theme.muted).frame(width: 12, height: 2)
                    Text(wording.previous).foregroundStyle(Theme.ink2)
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// Adds a note to the chart: a day and a short label.
struct AddNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let client: Client
    let site: Site
    @State private var day = Date()
    @State private var label = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                    TextField("Note", text: $label, prompt: Text("Launch, newsletter, outage…"))
                } footer: {
                    Text("Notes show on every chart of \(site.name), for everyone on the team. Up to 60 characters.")
                }
                if let failure { Text(failure).foregroundStyle(Theme.bad) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do {
                                try await client.addNote(site: site.slug, day: Dates.iso(day), label: label.trimmingCharacters(in: .whitespaces))
                                dismiss()
                            } catch {
                                failure = "The note wasn’t saved. Notes need a short label, up to 60 characters, and the editor role."
                            }
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || label.count > 60)
                }
            }
        }
        .tint(Theme.brand)
        .presentationDetents([.medium])
        .frame(minWidth: 380, minHeight: 240)
    }
}

enum Dates {
    /// "2026-09-30", "2026-09-30T14:00Z" (hourly rows), "2026-09-30T14:05Z" (minutes) or a full timestamp.
    static func parse(_ text: String) -> Date? {
        if text.count == 10 { return try? Date(text + "T00:00:00Z", strategy: .iso8601) }
        if text.count == 17, text.hasSuffix("Z") { return try? Date(text.dropLast() + ":00Z", strategy: .iso8601) }
        return try? Date(text, strategy: .iso8601)
    }

    /// Midnight today on the instance's clock (UTC).
    static var today: Date { Calendar.utc.startOfDay(for: .now) }

    /// Dates as the instance keeps them, in the reader's words.
    static var style: Date.FormatStyle { Date.FormatStyle(timeZone: .gmt) }

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    static func short(_ day: String) -> String {
        parse(day)?.formatted(style.day().month(.abbreviated)) ?? day
    }

    /// "Sat 5 Oct".
    static func dayName(_ day: String) -> String {
        parse(day)?.formatted(style.weekday(.abbreviated).day().month(.abbreviated)) ?? day
    }
}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
