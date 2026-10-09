import AnalyticoKit
import SwiftUI

/// The period's dates for a report the API answered.
private func periodWording(_ report: Report, _ view: ViewState) -> PeriodWording? {
    PeriodWording(from: report.from, to: report.to, rolling: !view.isCustom && view.period == .day)
}

/// The same report over the period before, when comparing.
private func previous(_ client: Client, _ site: Site, _ name: String, _ view: ViewState, _ report: Report, parameters: [String: String] = [:]) async -> Report? {
    guard view.compare, let before = view.previous(from: report.from, to: report.to) else { return nil }
    return try? await client.report(name, site: site.slug, view: before, parameters: parameters)
}

private func number(_ row: Report.Row?, _ key: String) -> Double { row?[key]?.number ?? 0 }

/// Segments under the controls, as on the workspace's tabbed reports.
struct Segments<Value: Hashable & Identifiable & RawRepresentable>: View where Value.RawValue == String {
    let all: [Value]
    @Binding var selection: Value

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(all) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - Sources

/// Channels, sources and campaigns; each source keeps its channel's colour.
struct SourcesView: View {
    @Environment(SiteState.self) private var state
    @State private var tab: Tab = .sources
    @State private var data = Loaded<SourcesData>()

    enum Tab: String, CaseIterable, Identifiable {
        case channels = "Channels", sources = "Sources", campaigns = "Campaigns"
        var id: String { rawValue }
    }

    var body: some View {
        ScreenScaffold(screen: .sources, wording: data.value?.wording, stale: data.stale, reload: load) {
            Segments(all: Tab.allCases, selection: $tab)
            if let sources = data.value {
                switch tab {
                case .channels: channels(sources)
                case .sources: list(sources)
                case .campaigns: CampaignList(rows: sources.campaigns)
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "Sources didn’t load")
            }
        }
        .task(id: state.view) { await load() }
    }

    private func load() async {
        data.apply(await fetch { try await SourcesData.load(client: state.client, site: state.site, view: state.view) })
    }

    private func list(_ sources: SourcesData) -> some View {
        SectionCard(title: "Source", padding: 14) {
            Text("Visitors")
        } content: {
            let top = sources.rows.map { number($0, "visitor_days") }.max() ?? 1
            VStack(spacing: 8) {
                ForEach(Array(sources.rows.enumerated()), id: \.offset) { _, row in
                    let tone = Theme.channel(row["channel"]?.text)
                    Button { state.filter("source", row["value"]?.text ?? "", label: row["label"]?.text) } label: {
                        ShareRow(title: row["label"]?.text ?? "", detail: row["channel"]?.text, value: Format.count(Int(number(row, "visitor_days"))),
                                 share: share(number(row, "visitor_days"), top) * 0.8, color: tone.color, wash: tone.wash)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .rowMenu("source", row["value"]?.text ?? "", label: row["label"]?.text)
                    .accessibilityHint("Filters every report by this source")
                }
                if sources.rows.isEmpty { Text("No visits in this period.").foregroundStyle(Theme.ink2) }
            }
        }
    }

    private func channels(_ sources: SourcesData) -> some View {
        let total = sources.channels.reduce(0) { $0 + $1.views }
        return SectionCard(title: "Channel mix") {
            Text("Share of page views")
        } content: {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(sources.channels, id: \.name) { channel in
                        Theme.channel(channel.name).color.frame(width: max(2, (geometry.size.width - Double(sources.channels.count) * 2) * share(channel.views, total)))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 12)
            VStack(spacing: 4) {
                ForEach(sources.channels, id: \.name) { channel in
                    HStack(spacing: 10) {
                        Circle().fill(Theme.channel(channel.name).color).frame(width: 9, height: 9)
                        Text(channel.name).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(Format.count(Int(channel.views))).monospacedDigit().foregroundStyle(Theme.ink)
                        Text(Format.share(channel.views, of: total)).monospacedDigit().foregroundStyle(Theme.muted).frame(width: 44, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 6)
                }
            }
            Text("Search, social and AI assistants by referrer; email and paid by utm_medium.").font(.caption).foregroundStyle(Theme.muted)
        }
    }
}

struct SourcesData {
    struct Channel { var name: String; var views: Double }
    var rows: [Report.Row]
    var channels: [Channel]
    var campaigns: [Report.Row]
    var wording: PeriodWording?

    static func load(client: Client, site: Site, view: ViewState) async throws -> SourcesData {
        async let sources = client.report("breakdown", site: site.slug, view: view, parameters: ["dimension": "source", "limit": "50"])
        async let acquisition = client.report("acquisition", site: site.slug, view: view, parameters: ["limit": "1000"])
        async let campaigns = client.report("campaigns", site: site.slug, view: view, parameters: ["limit": "50"])
        let report = try await sources
        var views: [String: Double] = [:]
        for row in try await acquisition.rows { views[row["channel"]?.text ?? "Referral", default: 0] += number(row, "views") }
        return try await SourcesData(rows: report.rows, channels: views.map { Channel(name: $0.key, views: $0.value) }.sorted { $0.views > $1.views }, campaigns: campaigns.rows, wording: periodWording(report, view))
    }
}

/// UTM campaigns: source, campaign and content with views, visitors and visits.
struct CampaignList: View {
    @Environment(SiteState.self) private var state
    let rows: [Report.Row]

    var body: some View {
        if rows.isEmpty {
            StageView(art: "calendar", title: "No tagged campaigns", text: "Add utm_campaign to the links you share — newsletters, ads, posts — and each campaign appears here with its visits.")
        } else {
            SectionCard(title: "Campaigns") {
                Text("Visitors · visits")
            } content: {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        Button { state.filter("campaign", row["campaign"]?.text ?? "") } label: {
                            ValueRow(title: row["campaign"]?.text ?? "", detail: [row["source"]?.text, row["content"]?.text].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
                                     value: "\(Format.count(Int(number(row, "visitors")))) · \(Format.count(Int(number(row, "sessions"))))")
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .rowMenu("campaign", row["campaign"]?.text ?? "")
                    }
                }
            }
        }
    }
}

struct CampaignsView: View {
    @Environment(SiteState.self) private var state
    @State private var data = Loaded<(Report, PeriodWording?)>()

    var body: some View {
        ScreenScaffold(screen: .campaigns, wording: data.value?.1, stale: data.stale, reload: load) {
            if let report = data.value?.0 {
                CampaignList(rows: report.rows)
            } else {
                LoadingOrProblem(failure: data.failure, title: "Campaigns didn’t load")
            }
        }
        .task(id: state.view) { await load() }
    }

    private func load() async {
        data.apply(await fetch {
            let report = try await state.client.report("campaigns", site: state.site.slug, view: state.view, parameters: ["limit": "100"])
            return (report, periodWording(report, state.view))
        })
    }
}

// MARK: - Site search

struct SiteSearchView: View {
    @Environment(SiteState.self) private var state
    @State private var data = Loaded<(Report, PeriodWording?)>()

    var body: some View {
        ScreenScaffold(screen: .search, wording: data.value?.1, stale: data.stale, reload: load) {
            if let report = data.value?.0 {
                if report.rows.isEmpty {
                    StageView(art: "filter", title: "No site searches \(data.value?.1?.between ?? "in this period")", text: "Searches on \(state.site.host) appear here when the search page’s address carries the term, as in ?q= or ?search=.")
                } else {
                    SectionCard(title: "What visitors searched for") {
                        Text("Searches")
                    } content: {
                        VStack(spacing: 0) {
                            ForEach(Array(report.rows.enumerated()), id: \.offset) { index, row in
                                if index > 0 { Divider() }
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row["term"]?.text ?? "").foregroundStyle(Theme.ink)
                                        let missed = Int(number(row, "no_results"))
                                        if missed > 0 {
                                            Text(missed == Int(number(row, "searches")) ? "No results" : "\(Format.count(missed)) with no results")
                                                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.warning)
                                                .padding(.horizontal, 7).padding(.vertical, 2)
                                                .background(Theme.amberWash, in: .capsule)
                                        }
                                    }
                                    Spacer()
                                    Text(Format.count(Int(number(row, "searches")))).monospacedDigit().foregroundStyle(Theme.ink)
                                }
                                .padding(.vertical, 9)
                            }
                        }
                    }
                    Text("Searches with no results are worth a page or a product.").font(.caption).foregroundStyle(Theme.muted)
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "Site search didn’t load")
            }
        }
        .task(id: state.view) { await load() }
    }

    private func load() async {
        data.apply(await fetch {
            let report = try await state.client.report("search", site: state.site.slug, view: state.view, parameters: ["limit": "100"])
            return (report, periodWording(report, state.view))
        })
    }
}

// MARK: - Audience

/// Countries, devices and browsers as shares of page views.
struct AudienceView: View {
    @Environment(SiteState.self) private var state
    @State private var tab: Tab = .countries
    @State private var data = Loaded<(Report, PeriodWording?)>()

    enum Tab: String, CaseIterable, Identifiable {
        case countries = "Countries", devices = "Devices", browsers = "Browsers"
        var id: String { rawValue }
        var dimension: String { self == .countries ? "country" : self == .devices ? "device" : "browser" }
    }

    var body: some View {
        ScreenScaffold(screen: .audience, wording: data.value?.1, stale: data.stale, reload: load) {
            Segments(all: Tab.allCases, selection: $tab)
            if let report = data.value?.0 {
                let total = report.rows.reduce(0) { $0 + number($1, "page_views") }
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                        let key = row["value"]?.text ?? ""
                        Button { state.filter(tab.dimension, key, label: tab == .countries ? row["label"]?.text : nil) } label: {
                            MeterRow(code: tab == .countries ? (key == "unknown" ? "?" : key) : nil,
                                     title: tab == .countries ? (row["label"]?.text ?? key) : Labels.value(key, dimension: tab.dimension),
                                     value: Format.share(number(row, "page_views"), of: total), share: share(number(row, "page_views"), total))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .rowMenu(tab.dimension, key, label: tab == .countries ? row["label"]?.text : Labels.value(key, dimension: tab.dimension))
                    }
                    if report.rows.isEmpty { Text("No visits in this period.").foregroundStyle(Theme.ink2) }
                    if tab == .countries { Text("Country from the IP at collection · the IP is never stored").font(.caption).foregroundStyle(Theme.muted) }
                }
                .card()
            } else {
                LoadingOrProblem(failure: data.failure, title: "Audience didn’t load")
            }
        }
        .task(id: AudienceKey(view: state.view, tab: tab)) { await load() }
    }

    private func load() async {
        data.apply(await fetch {
            let report = try await state.client.report("breakdown", site: state.site.slug, view: state.view, parameters: ["dimension": tab.dimension, "limit": "12"])
            return (report, periodWording(report, state.view))
        })
    }

    private struct AudienceKey: Hashable { var view: ViewState; var tab: Tab }
}

// MARK: - Events and goals

struct EventsView: View {
    @Environment(SiteState.self) private var state
    @Environment(\.openURL) private var openURL
    @State private var data = Loaded<EventsData>()

    var body: some View {
        ScreenScaffold(screen: .events, wording: data.value?.wording, stale: data.stale, reload: load) {
            if let events = data.value {
                SectionCard(title: "Goals") {
                    Text("Conversion")
                } content: {
                    if events.goals.isEmpty {
                        Text("No goals yet. A goal is an event or a page that counts as success; add them in the workspace.").font(.callout).foregroundStyle(Theme.ink2)
                        Button("Add a goal in the workspace") { openURL(state.client.instance.origin.appending(path: "\(state.site.slug)/events").appending(queryItems: [URLQueryItem(name: "tab", value: "goals")])) }
                            .buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.brandDark)
                    }
                    ForEach(Array(events.goals.enumerated()), id: \.offset) { _, goal in
                        let rate = events.visitors == 0 ? 0 : number(goal, "visitor_days") / events.visitors
                        let before = events.before.first { $0["goal"]?.text == goal["goal"]?.text }
                        let previousRate = before.flatMap { row in events.visitorsBefore == 0 ? nil : number(row, "visitor_days") / events.visitorsBefore }
                        let change = state.view.compare ? pointsChange(rate, previousRate, decimals: 1) : nil
                        HStack(spacing: 12) {
                            Icon("flag", size: 18).foregroundStyle(Theme.brand)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(goal["goal"]?.text ?? "").foregroundStyle(Theme.ink)
                                Text(plural(Int(number(goal, "completions")), "completion")).font(.caption).foregroundStyle(Theme.ink2)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(rate.formatted(.percent.precision(.fractionLength(1)))).font(Theme.display(20, relativeTo: .title3)).foregroundStyle(Theme.ink).monospacedDigit()
                                if let change { Text(change.text).font(.caption.weight(.semibold)).foregroundStyle(change.direction == .up ? Theme.good : change.direction == .down ? Theme.bad : Theme.ink2) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                SectionCard(title: "Events") {
                    Text("Times · visits")
                } content: {
                    VStack(spacing: 0) {
                        ForEach(Array(events.events.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider() }
                            ValueRow(title: row["name"]?.text ?? "", detail: source(row["source"]?.text), value: "\(Format.count(Int(number(row, "occurrences")))) · \(Format.count(Int(number(row, "sessions"))))")
                        }
                        if events.events.isEmpty { Text("No events in this period.").font(.callout).foregroundStyle(Theme.ink2) }
                    }
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "Events didn’t load")
            }
        }
        .task(id: state.view) { await load() }
    }

    private func source(_ text: String?) -> String {
        switch text {
        case "server": "From your server"
        case "auto": "Automatic"
        default: "Tracker"
        }
    }

    private func load() async {
        data.apply(await fetch { try await EventsData.load(client: state.client, site: state.site, view: state.view) })
    }
}

struct EventsData {
    var goals: [Report.Row]
    var before: [Report.Row]
    var events: [Report.Row]
    var visitors: Double
    var visitorsBefore: Double
    var wording: PeriodWording?

    static func load(client: Client, site: Site, view: ViewState) async throws -> EventsData {
        async let goals = client.report("goals", site: site.slug, view: view)
        async let events = client.report("events", site: site.slug, view: view, parameters: ["limit": "50"])
        async let overview = client.report("overview", site: site.slug, view: view)
        let goalReport = try await goals
        let totals = try await overview.rows.first
        let before = await previous(client, site, "goals", view, goalReport)
        return try await EventsData(goals: goalReport.rows, before: before?.rows ?? [], events: events.rows,
                                    visitors: number(totals, "visitor_days"), visitorsBefore: number(totals, "previous_visitor_days"),
                                    wording: periodWording(goalReport, view))
    }
}

// MARK: - Errors

struct ErrorsView: View {
    @Environment(SiteState.self) private var state
    @State private var data = Loaded<(Report, PeriodWording?)>()

    var body: some View {
        ScreenScaffold(screen: .errors, wording: data.value?.1, stale: data.stale, reload: load) {
            if let report = data.value?.0 {
                if report.rows.isEmpty {
                    StageView(art: "waiting", title: "No JavaScript errors \(data.value?.1?.between ?? "in this period")", text: "Errors visitors run into appear here, grouped, with where and since when.")
                } else {
                    let times = report.rows.reduce(0) { $0 + number($1, "occurrences") }
                    HStack(spacing: 12) {
                        Icon("bug", size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(plural(report.rows.count, "error")) happened \(plural(Int(times), "time"))").font(.subheadline.weight(.semibold))
                            Text("Most often on \(report.rows.first?["path"]?.text ?? "")").font(.caption)
                        }
                        Spacer()
                    }
                    .foregroundStyle(Theme.bad)
                    .padding(14)
                    .background(Theme.brandWash, in: .rect(cornerRadius: Theme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.bad.opacity(0.2)))
                    VStack(spacing: 0) {
                        ForEach(Array(report.rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider() }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(row["message"]?.text ?? "").foregroundStyle(Theme.ink).lineLimit(3)
                                Text([row["path"]?.text, row["browsers"]?.text].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                                HStack {
                                    Text("\(plural(Int(number(row, "occurrences")), "time")) · \(plural(Int(number(row, "visits")), "visit"))")
                                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.bad)
                                        .padding(.horizontal, 10).padding(.vertical, 3)
                                        .background(Theme.brandWash, in: .capsule)
                                    Spacer()
                                    if let last = row["last_seen_ms"]?.number {
                                        Text("last \(Date(timeIntervalSince1970: last / 1000).formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(Theme.muted)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                    }
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "Errors didn’t load")
            }
        }
        .task(id: state.view) { await load() }
    }

    private func load() async {
        data.apply(await fetch {
            let report = try await state.client.report("errors", site: state.site.slug, view: state.view, parameters: ["limit": "50"])
            return (report, periodWording(report, state.view))
        })
    }
}

// MARK: - Performance

struct PerformanceView: View {
    @Environment(SiteState.self) private var state
    @State private var data = Loaded<(Report, Report?, PeriodWording?)>()

    var body: some View {
        ScreenScaffold(screen: .performance, wording: data.value?.2, stale: data.stale, reload: load) {
            if let (report, before, _) = data.value {
                let rows = report.rows.filter { $0["metric"]?.text != "ttfb" }
                if report.rows.allSatisfy({ number($0, "samples") == 0 }) {
                    StageView(art: "waiting", title: "No performance data yet", text: "Use the RUM variant of the tracker to measure Core Web Vitals from real visits. It adds about 1 KB and never records content.")
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VitalCard(row: row, before: before?.rows.first { $0["metric"]?.text == row["metric"]?.text })
                    }
                    Text("From \(Format.count(Int(report.rows.map { number($0, "samples") }.max() ?? 0))) page loads measured by the RUM tracker. p75: three in four loads were at least this fast.").font(.caption).foregroundStyle(Theme.muted)
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "Performance didn’t load")
            }
        }
        .task(id: state.view) { await load() }
    }

    private func load() async {
        data.apply(await fetch {
            let report = try await state.client.report("vitals", site: state.site.slug, view: state.view)
            return (report, await previous(state.client, state.site, "vitals", state.view, report), periodWording(report, state.view))
        })
    }
}

/// One Web Vital: p75 and its rating, and the good · needs work · poor split.
private struct VitalCard: View {
    let row: Report.Row
    let before: Report.Row?

    var body: some View {
        let key = row["metric"]?.text ?? ""
        let cls = key == "cls"
        let p75 = number(row, "p75")
        let rating = p75 <= number(row, "good_below") ? ("Good", Theme.good, Theme.goodWash) : p75 <= number(row, "poor_above") ? ("Needs work", Theme.warning, Theme.amberWash) : ("Poor", Theme.bad, Theme.brandWash)
        let samples = max(1, number(row, "samples"))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((row["name"]?.text ?? "").capitalizedFirst).font(.headline).foregroundStyle(Theme.ink)
                    Text("\(key.uppercased()) · p75").font(.caption).foregroundStyle(Theme.ink2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(number(row, "samples") == 0 ? "—" : Format.vital(p75, layoutShift: cls)).font(Theme.display(26, relativeTo: .title)).foregroundStyle(Theme.ink)
                    if let before, number(before, "samples") > 0, number(row, "samples") > 0 {
                        let change = Format.change(p75, number(before, "p75"))
                        // Faster is better: a drop is good news.
                        Text(change.text).font(.caption.weight(.semibold)).foregroundStyle(change.direction == .down ? Theme.good : change.direction == .up ? Theme.bad : Theme.ink2)
                    }
                }
            }
            if number(row, "samples") > 0 {
                Text(rating.0).font(.caption.weight(.semibold)).foregroundStyle(rating.1)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(rating.2, in: .capsule)
                GeometryReader { geometry in
                    HStack(spacing: 3) {
                        Capsule().fill(Theme.good).frame(width: geometry.size.width * number(row, "good") / samples)
                        Capsule().fill(Theme.amber).frame(width: geometry.size.width * number(row, "needs_work") / samples)
                        Capsule().fill(Theme.bad).frame(width: max(4, geometry.size.width * number(row, "poor") / samples))
                    }
                }
                .frame(height: 6)
                Text("\(Format.share(number(row, "good"), of: samples)) good · \(Format.share(number(row, "needs_work"), of: samples)) needs work · \(Format.share(number(row, "poor"), of: samples)) poor")
                    .font(.caption).foregroundStyle(Theme.ink2)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst().lowercased() }
}

// MARK: - Revenue

struct RevenueView: View {
    @Environment(SiteState.self) private var state
    @State private var data = Loaded<RevenueData>()

    var body: some View {
        ScreenScaffold(screen: .revenue, wording: data.value?.wording, stale: data.stale, reload: load) {
            if let revenue = data.value {
                if revenue.orders == 0 {
                    StageView(art: "calendar", title: "No orders \(revenue.wording?.between ?? "in this period")", text: "Orders appear here when your shop sends purchase events — from the tracker or, confirmed, from your server.")
                } else {
                    let compare = state.view.compare
                    MetricGrid {
                        MetricCard(label: "Revenue", value: revenue.money(revenue.revenue), change: compare ? Format.change(revenue.revenue, revenue.revenueBefore) : nil, versus: "vs \(revenue.money(revenue.revenueBefore))")
                        MetricCard(label: "Orders", value: Format.count(Int(revenue.orders)), change: compare ? Format.change(revenue.orders, revenue.ordersBefore) : nil, versus: "vs \(Format.count(Int(revenue.ordersBefore)))")
                        MetricCard(label: "Avg. order", value: revenue.money(revenue.revenue / max(1, revenue.orders)), change: compare && revenue.ordersBefore > 0 ? Format.change(revenue.revenue / revenue.orders, revenue.revenueBefore / revenue.ordersBefore) : nil)
                        MetricCard(label: "Refunds", value: revenue.money(revenue.refunds), change: compare && revenue.refundsBefore != nil ? Format.change(revenue.refunds, revenue.refundsBefore ?? 0).inverted : nil)
                    }
                    SectionCard(title: "What sells") {
                        Text("Revenue")
                    } content: {
                        VStack(spacing: 10) {
                            ForEach(Array(revenue.products.enumerated()), id: \.offset) { index, row in
                                HStack(spacing: 12) {
                                    Text("\(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink2)
                                        .frame(width: 24, height: 24).background(Theme.subtle, in: .rect(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row["product"]?.text ?? "").foregroundStyle(Theme.ink).lineLimit(1)
                                        Text(plural(Int(number(row, "orders")), "order")).font(.caption).foregroundStyle(Theme.ink2)
                                    }
                                    Spacer()
                                    Text(revenue.money(number(row, "revenue_minor"))).monospacedDigit().foregroundStyle(Theme.ink)
                                }
                            }
                        }
                    }
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "Revenue didn’t load")
            }
        }
        .task(id: state.view) { await load() }
    }

    private func load() async {
        data.apply(await fetch { try await RevenueData.load(client: state.client, site: state.site, view: state.view) })
    }
}

private extension Format.Change {
    /// For numbers where less is better (refunds): down is good news.
    var inverted: Format.Change {
        Format.Change(text: text, direction: direction == .up ? .down : direction == .down ? .up : .flat)
    }
}

struct RevenueData {
    var revenue: Double
    var revenueBefore: Double
    var orders: Double
    var ordersBefore: Double
    var refunds: Double
    var refundsBefore: Double?
    var products: [Report.Row]
    var currency: String
    var wording: PeriodWording?

    func money(_ minor: Double) -> String { Format.money(minor: Int(minor.rounded()), currency: currency) }

    static func load(client: Client, site: Site, view: ViewState) async throws -> RevenueData {
        async let overview = client.report("overview", site: site.slug, view: view)
        async let products = client.report("revenue", site: site.slug, view: view, parameters: ["limit": "100"])
        let totals = try await overview
        let row = totals.rows.first
        let report = try await products
        let before = await previous(client, site, "revenue", view, report, parameters: ["limit": "1000"])
        return RevenueData(
            revenue: number(row, "revenue_minor"), revenueBefore: number(row, "previous_revenue_minor"),
            orders: number(row, "orders"), ordersBefore: number(row, "previous_orders"),
            refunds: report.rows.reduce(0) { $0 + number($1, "refunds_minor") },
            refundsBefore: before.map { $0.rows.reduce(0) { $0 + number($1, "refunds_minor") } },
            products: report.rows, currency: row?["currency"]?.text ?? site.currency, wording: periodWording(totals, view))
    }
}

// MARK: - Paths

/// Where visitors go next from a page; tap a step to follow it.
struct PathsView: View {
    @Environment(SiteState.self) private var state
    @State private var pages: [String] = []
    @State private var from: String?
    @State private var data = Loaded<(Report, PeriodWording?)>()

    var body: some View {
        ScreenScaffold(screen: .paths, wording: data.value?.1, stale: data.stale, reload: load) {
            if state.site.mode == "lite" {
                StageView(art: "filter", title: "Paths need visits", text: "Lite mode never links page views into visits. Switch the site to Session or Full in the workspace to see where visitors go next.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("After visiting").font(.caption).foregroundStyle(Theme.ink2)
                    Picker("After visiting", selection: $from) {
                        ForEach(pages, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .frame(height: 40)
                    .background(Theme.subtle, in: .rect(cornerRadius: 10))
                    if let report = data.value?.0 {
                        let total = report.rows.reduce(0) { $0 + number($1, "transitions") }
                        Text("\(Format.count(Int(total))) visits went on from \(from ?? ""). Next, they opened:").font(.subheadline).foregroundStyle(Theme.ink2)
                        ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                            let next = row["next_path"]?.text ?? ""
                            Button { if !next.isEmpty { from = next } } label: {
                                HStack(spacing: 10) {
                                    ShareRow(title: next.isEmpty ? "Left the site" : next, value: Format.count(Int(number(row, "transitions"))), share: share(number(row, "transitions"), total), wash: next.isEmpty ? Theme.subtle : Theme.brandWash, rule: false)
                                    Text(Format.share(number(row, "transitions"), of: total)).fontWeight(.semibold).monospacedDigit().frame(width: 44, alignment: .trailing)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(next.isEmpty)
                        }
                        if report.rows.isEmpty { Text("Nobody went on from this page in this period.").foregroundStyle(Theme.ink2) }
                        Text("Tap a page to follow the path one step further.").font(.caption).foregroundStyle(Theme.muted)
                    } else {
                        LoadingOrProblem(failure: data.failure, title: "Paths didn’t load")
                    }
                }
                .card()
            }
        }
        .task(id: state.view) { await loadPages() }
        .task(id: PathsKey(view: state.view, from: from)) { await load() }
    }

    private func loadPages() async {
        guard state.site.mode != "lite" else { return }
        let rows = (try? await state.client.report("pages", site: state.site.slug, view: state.view, parameters: ["limit": "40"]).rows) ?? []
        pages = rows.compactMap { $0["path"]?.text }
        if from == nil || !pages.contains(from!) { from = pages.first }
    }

    private func load() async {
        guard let from else { return }
        data.apply(await fetch {
            let report = try await state.client.report("paths", site: state.site.slug, view: state.view, parameters: ["from_path": from, "exits": "1", "limit": "12"])
            return (report, periodWording(report, state.view))
        })
    }

    private struct PathsKey: Hashable { var view: ViewState; var from: String? }
}
