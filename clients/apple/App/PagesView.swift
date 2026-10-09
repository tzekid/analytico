import AnalyticoKit
import Charts
import SwiftUI

/// Every page with views, visitors, active time and scroll depth, sorted
/// by any of them. Selecting a page opens its details in the inspector
/// (Mac, iPad) or a sheet (iPhone) instead of navigating away.
struct PagesView: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var data = Loaded<PagesData>()
    @State private var sort: PageSort = .views
    @State private var query = ""

    /// With room, the details sit beside the list; with less, they lie over
    /// it, as the workspace's do under 1100 px. Decided by the width the
    /// screen is given, never by what it holds.
    @State private var beside = true

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onChange(of: proxy.size.width, initial: true) { _, width in beside = width >= 860 }
        }
    }

    private var content: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ScreenScaffold(screen: .pages, wording: data.value?.wording, stale: data.stale, lead: data.value.map { plural($0.rows.count, "page") }, reload: load) {
                    if let pages = data.value {
                        if pages.rows.isEmpty {
                            StageView(art: "calendar", title: "No page views \(pages.wording?.between ?? "in this period")", text: "Pages appear here as soon as visitors read them.",
                                      primary: state.view.filters.isEmpty ? nil : ("Clear filters", { state.view.filters = [] }))
                        } else if sizeClass == .compact {
                            list(pages)
                        } else {
                            table(pages)
                        }
                    } else {
                        LoadingOrProblem(failure: data.failure, title: "Pages didn’t load")
                    }
                }
                if sizeClass != .compact, beside, let page = state.page { inspector(page) }
            }
            if sizeClass != .compact, !beside, let page = state.page {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .onTapGesture { state.page = nil }
                    .transition(.opacity)
                inspector(page)
            }
        }
        .background(Theme.canvas)
        .animation(.easeOut(duration: 0.2), value: state.page == nil)
        .task(id: state.view) { await load() }
    }

    /// Mac and iPad: the page's details the height of the window, as the
    /// workspace's inspector.
    private func inspector(_ page: String) -> some View {
        PageDetail(path: page)
            .frame(width: 390)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(beside ? 0.06 : 0.16), radius: beside ? 12 : 24, y: 4)
            .padding([.top, .bottom, .trailing], 8)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func load() async {
        data.apply(await fetch { try await PagesData.load(client: state.client, site: state.site, view: state.view) })
    }

    private func sorted(_ pages: PagesData) -> [PageRow] {
        let words = query.trimmingCharacters(in: .whitespaces)
        let shown = words.isEmpty ? pages.rows : pages.rows.filter { $0.path.localizedStandardContains(words) }
        return shown.sorted { sort.value($0) > sort.value($1) }
    }

    // MARK: iPhone

    private func list(_ pages: PagesData) -> some View {
        let rows = sorted(pages)
        let top = rows.map(\.views).max() ?? 1
        return ScrollViewReader { proxy in VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(Format.count(pages.rows.count)) pages").font(Theme.subheadline).foregroundStyle(Theme.ink2)
                Spacer()
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(PageSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Sorted by \(sort.title.lowercased())")
                        Image(systemName: "chevron.down").font(Theme.caption2.weight(.semibold))
                    }
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.subtle, in: .capsule)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.path) { index, row in
                    if index > 0 { Divider() }
                    Button { state.page = row.path } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.path).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                    Text("\(Format.count(row.visitors)) \(row.visitors == 1 ? "visitor" : "visitors") · \(Format.duration(milliseconds: row.active)) active · \(row.scroll)% scroll")
                                        .font(Theme.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(Format.count(row.views)).font(Theme.display(20, relativeTo: .title3)).foregroundStyle(Theme.ink).monospacedDigit()
                                    Text(row.views == 1 ? "view" : "views").font(Theme.caption2).foregroundStyle(Theme.muted)
                                }
                            }
                            GeometryReader { geometry in
                                Capsule().fill(Theme.brand.opacity(0.55)).frame(width: max(4, geometry.size.width * share(Double(row.views), Double(top))), height: 3)
                            }
                            .frame(height: 3)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(state.page == row.path ? Theme.brandWash : .clear)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .rowMenu("page", row.path)
                    .accessibilityHint("Opens the page’s details")
                    .id(row.path)
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            // Every row can scroll clear of the half-height page sheet.
            Color.clear.frame(height: state.page == nil ? 0 : 400)
        }
        // The row whose details open scrolls into the part the sheet leaves visible.
        .onChange(of: state.page) { _, page in
            guard let page else { return }
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(page, anchor: UnitPoint(x: 0.5, y: 0.22)) }
        }
        }
    }

    // MARK: Mac and iPad

    private func table(_ pages: PagesData) -> some View {
        let rows = sorted(pages)
        // With the details open the table keeps what fits; the details show the rest.
        let wide = state.page == nil || !beside
        return TableCard(footer: "Showing \(Format.count(rows.count)) of \(plural(pages.rows.count, "page"))", hint: "Click a row for details") {
            TableFilterField(prompt: "Filter pages…", text: $query)
        } head: {
            TableHead(title: "Page").frame(maxWidth: .infinity, alignment: .leading)
            TableHead(title: "Views", sorted: sort == .views) { sort = .views }.frame(width: 90, alignment: .trailing)
            TableHead(title: "Visitors", sorted: sort == .visitors) { sort = .visitors }.frame(width: 90, alignment: .trailing)
            if wide {
                TableHead(title: "Avg. active time", sorted: sort == .active) { sort = .active }.frame(width: 130, alignment: .trailing)
                TableHead(title: "Scroll depth", sorted: sort == .scroll) { sort = .scroll }.frame(width: 110, alignment: .trailing)
                if state.view.compare { TableHead(title: "Change").frame(width: 90, alignment: .trailing) }
            }
        } rows: {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.path) { row in
                    let selected = state.page == row.path
                    Button { state.page = selected ? nil : row.path } label: {
                        HStack(spacing: 0) {
                            Text(row.path).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Format.count(row.views)).frame(width: 90, alignment: .trailing)
                            Text(Format.count(row.visitors)).frame(width: 90, alignment: .trailing)
                            if wide {
                                Text(Format.duration(milliseconds: row.active)).frame(width: 130, alignment: .trailing)
                                Text("\(row.scroll)%").frame(width: 110, alignment: .trailing)
                                if state.view.compare {
                                    Group {
                                        if row.previous != nil { ChangeBadge(change: Format.change(Double(row.views), Double(row.previous ?? 0))) }
                                    }
                                    .frame(width: 90, alignment: .trailing)
                                }
                            }
                        }
                        .tableRow(selected: selected)
                    }
                    .buttonStyle(.plain)
                    .rowMenu("page", row.path)
                }
            }
        }
    }
}

enum PageSort: String, CaseIterable, Identifiable {
    case views, visitors, active, scroll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .views: "Views"
        case .visitors: "Visitors"
        case .active: "Active time"
        case .scroll: "Scroll"
        }
    }

    func value(_ row: PageRow) -> Double {
        switch self {
        case .views: Double(row.views)
        case .visitors: Double(row.visitors)
        case .active: row.active
        case .scroll: Double(row.scroll)
        }
    }
}

struct PageRow {
    var path: String
    var views: Int
    var visitors: Int
    var active: Double
    var scroll: Int
    var previous: Int?
    var outbound: Int
    var downloads: Int
    var copies: Int
    var forms: Int

    init(_ row: Report.Row, previous: Int? = nil) {
        path = row["path"]?.text ?? ""
        views = Int(row["views"]?.number ?? 0)
        visitors = Int(row["visitors"]?.number ?? 0)
        active = row["avg_active_ms"]?.number ?? 0
        scroll = Int(row["avg_scroll"]?.number ?? 0)
        outbound = Int(row["outbound_clicks"]?.number ?? 0)
        downloads = Int(row["downloads"]?.number ?? 0)
        copies = Int(row["copies"]?.number ?? 0)
        forms = Int(row["form_attempts"]?.number ?? 0)
        self.previous = previous
    }
}

struct PagesData {
    var rows: [PageRow]
    var wording: PeriodWording?

    static func load(client: Client, site: Site, view: ViewState) async throws -> PagesData {
        async let pages = client.report("pages", site: site.slug, view: view, parameters: ["limit": "500"])
        async let before = client.report("breakdown", site: site.slug, view: view, parameters: ["dimension": "page", "limit": "500"])
        let report = try await pages
        let previous = Dictionary((try? await before.rows.map { ($0["value"]?.text ?? "", Int($0["previous_page_views"]?.number ?? 0)) }) ?? [], uniquingKeysWith: { first, _ in first })
        let rolling = !view.isCustom && view.period == .day
        return PagesData(rows: report.rows.map { PageRow($0, previous: previous[$0["path"]?.text ?? ""]) }, wording: PeriodWording(from: report.from, to: report.to, rolling: rolling))
    }
}

/// One page, as the workspace's page details: its numbers against the
/// period before and its views by day; what visitors did on it; where they
/// went next and came from. Then filter every report by it.
struct PageDetail: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    let path: String
    @State private var tab: Tab = .overview
    @State private var data = Loaded<PageDetailData>()

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", actions = "Actions", paths = "Paths"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView { content }
            .background(sizeClass == .compact ? Theme.canvas : Theme.surface)
    }

    private var lite: Bool { state.site.mode == "lite" }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PAGE · \(data.value?.wording?.this.uppercased() ?? "")").font(Theme.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(Theme.ink2)
                    Text(path).font(titleFont).foregroundStyle(Theme.ink).lineLimit(2).truncationMode(.middle)
                }
                Spacer()
                CloseButton { state.page = nil }
                    .keyboardShortcut(.cancelAction)
            }
            // What to do with the page, as the workspace offers it.
            HStack(spacing: 8) {
                Button {
                    state.filter("page", path)
                    state.page = nil
                } label: {
                    IconLabel("Filter by page", icon: "filter")
                }
                .buttonStyle(ActionCapsuleStyle(primary: true, tile: sizeClass == .compact))
                if let url = URL(string: "https://\(state.site.host)\(path)") {
                    Button { openURL(url) } label: { IconLabel("Open page", icon: "external") }
                        .buttonStyle(ActionCapsuleStyle(primary: false, tile: sizeClass == .compact))
                }
                if !lite {
                    Button { openURL(sessionsURL) } label: { IconLabel("Sessions", icon: "play") }
                        .buttonStyle(ActionCapsuleStyle(primary: false, tile: sizeClass == .compact))
                }
                if sizeClass != .compact { Spacer(minLength: 0) }
            }
            tabs
            if let detail = data.value {
                switch tab {
                case .overview: overview(detail)
                case .actions: actions(detail)
                case .paths: paths(detail)
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "The page didn’t load")
            }
        }
        .padding(sizeClass == .compact ? 16 : 20)
        .task(id: PageKey(path: path, view: state.view)) {
            data.apply(await fetch { try await PageDetailData.load(client: state.client, site: state.site, view: state.view, path: path) })
        }
    }

    #if os(macOS)
    private let titleFont = Font.system(size: 17, weight: .semibold)
    #else
    private let titleFont = Font.title3.weight(.semibold)
    #endif

    /// The workspace's sessions for this page.
    private var sessionsURL: URL {
        state.client.instance.origin.appending(path: "\(state.site.slug)/sessions").appending(queryItems: [URLQueryItem(name: "f", value: "page:\(path)")])
    }

    /// The web's tabs in its details: a grey track with the current one raised.
    @ViewBuilder private var tabs: some View {
        if sizeClass == .compact {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { item in
                    let current = item == tab
                    Button { tab = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? Theme.ink : Theme.ink2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background {
                                if current { RoundedRectangle(cornerRadius: 6).fill(Theme.surface).shadow(color: .black.opacity(0.08), radius: 2, y: 1) }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Theme.subtle, in: .rect(cornerRadius: 8))
        }
    }

    private func overview(_ detail: PageDetailData) -> some View {
        let compare = state.view.compare
        let now = detail.now
        let before = detail.before
        return VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                MetricCard(label: "Views", value: Format.count(now.views), change: compare ? Format.change(Double(now.views), Double(before?.views ?? 0)) : nil)
                MetricCard(label: "Visitors", value: Format.count(now.visitors), change: compare ? Format.change(Double(now.visitors), Double(before?.visitors ?? 0)) : nil)
                MetricCard(label: "Avg. active", value: Format.duration(milliseconds: now.active), change: compare ? Format.change(now.active, before?.active ?? 0) : nil)
                MetricCard(label: "Scroll", value: "\(now.scroll)%", change: compare ? pointsChange(Double(now.scroll) / 100, before.map { Double($0.scroll) / 100 }) : nil)
            }
            .environment(\.horizontalSizeClass, .compact)
            VStack(alignment: .leading, spacing: 10) {
                Text("Views by day").font(subheadFont).foregroundStyle(Theme.ink)
                PageViewsChart(points: detail.days)
            }
            .card()
            if !lite {
                steps(title: "Where visitors go next", rows: Array(detail.next.prefix(4)), empty: "Not enough sessions yet.")
            }
        }
    }

    private func actions(_ detail: PageDetailData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                MetricCard(label: "Outbound clicks", value: Format.count(detail.now.outbound))
                MetricCard(label: "Downloads", value: Format.count(detail.now.downloads))
                MetricCard(label: "Copies", value: Format.count(detail.now.copies))
                MetricCard(label: "Form attempts", value: Format.count(detail.now.forms))
            }
            .environment(\.horizontalSizeClass, .compact)
            VStack(alignment: .leading, spacing: 8) {
                Text("Events on this page").font(subheadFont).foregroundStyle(Theme.ink)
                ForEach(detail.events, id: \.name) { event in
                    HStack {
                        Text(event.name).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer()
                        Text(Format.count(event.count)).monospacedDigit().foregroundStyle(Theme.ink)
                    }
                    .font(Theme.callout)
                }
                if detail.events.isEmpty { Text("No custom events on this page in this period.").font(Theme.callout).foregroundStyle(Theme.ink2) }
            }
        }
    }

    @ViewBuilder private func paths(_ detail: PageDetailData) -> some View {
        if lite {
            HStack(alignment: .top, spacing: 10) {
                Icon("info", size: 16).foregroundStyle(Theme.ink2)
                Text("Paths need session mode, which links page views within one visit. Lite mode never links them.").font(Theme.callout).foregroundStyle(Theme.ink)
            }
            .padding(12)
            .background(Theme.subtle, in: .rect(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 16) {
                steps(title: "Where visitors go next", rows: Array(detail.next.prefix(8)), empty: "Not enough sessions yet.")
                steps(title: "Where visitors came from", rows: Array(detail.from.prefix(8)), empty: "Nobody reached this page in these dates.")
            }
        }
    }

    #if os(macOS)
    private let subheadFont = Theme.strong
    #else
    private let subheadFont = Font.subheadline.weight(.semibold)
    #endif

    private func steps(title: String, rows: [Step], empty: String) -> some View {
        let total = max(1, rows.reduce(0) { $0 + $1.count })
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(subheadFont).foregroundStyle(Theme.ink)
            ForEach(rows, id: \.path) { step in
                let part = Double(step.count) / Double(total)
                ShareRow(title: step.label, value: part.formatted(.percent.precision(.fractionLength(0))), share: part, color: Theme.brand, wash: step.left ? Theme.subtle : Theme.brandWash, rule: false)
            }
            if rows.isEmpty { Text(empty).font(Theme.callout).foregroundStyle(Theme.ink2) }
        }
    }
}

/// A page's views by day: the workspace's small trend, a line over a wash.
struct PageViewsChart: View {
    let points: [Point]

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Day", point.at, unit: .day), y: .value("Views", point.value))
                .foregroundStyle(LinearGradient(colors: [Theme.brand.opacity(0.18), Theme.brand.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Day", point.at, unit: .day), y: .value("Views", point.value))
                .foregroundStyle(Theme.brand)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: false)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel()
            }
        }
        .frame(height: 140)
    }
}

private struct PageKey: Hashable {
    var path: String
    var view: ViewState
}

/// A step to or from a page; an empty path is leaving or entering the site.
struct Step {
    var path: String
    var count: Int
    var label: String
    var left: Bool
}

struct PageDetailData {
    struct Event { var name: String; var count: Int }
    var now: PageRow
    var before: PageRow?
    var days: [Point]
    var next: [Step]
    var from: [Step]
    var events: [Event]
    var wording: PeriodWording?

    static func load(client: Client, site: Site, view: ViewState, path: String) async throws -> PageDetailData {
        var scoped = view
        scoped.filters.removeAll { $0.dimension == "page" }
        scoped.filters.append(.init(dimension: "page", value: path))
        let page = scoped
        async let current = client.report("pages", site: site.slug, view: page)
        async let next = client.report("paths", site: site.slug, view: view, parameters: ["from_path": path, "exits": "1", "limit": "12"])
        async let from = client.report("came_from", site: site.slug, view: view, parameters: ["to_path": path, "limit": "12"])
        async let days = client.report("timeseries", site: site.slug, view: page, parameters: ["metric": "views"])
        async let events = client.report("events", site: site.slug, view: page, parameters: ["limit": "12"])
        let report = try await current
        var before: PageRow?
        if view.compare, let previous = page.previous(from: report.from, to: report.to) {
            before = (try? await client.report("pages", site: site.slug, view: previous).rows.first).map { PageRow($0) }
        }
        // Lite mode keeps no visits, so there are no steps between pages.
        let nextRows = (try? await next.rows) ?? []
        let fromRows = (try? await from.rows) ?? []
        return PageDetailData(
            now: report.rows.first.map { PageRow($0) } ?? PageRow([:]),
            before: before,
            days: ((try? await days.rows) ?? []).map(Point.init(row:)),
            next: nextRows.map { row in
                let to = row["next_path"]?.text ?? ""
                return Step(path: to, count: Int(row["transitions"]?.number ?? 0), label: to.isEmpty ? "Left the site" : to, left: to.isEmpty)
            },
            from: fromRows.map { row in
                let before = row["previous_path"]?.text ?? ""
                return Step(path: before, count: Int(row["transitions"]?.number ?? 0), label: before.isEmpty ? "Entered the site here" : before, left: before.isEmpty)
            },
            events: ((try? await events.rows) ?? []).map { PageDetailData.Event(name: $0["name"]?.text ?? "", count: Int($0["occurrences"]?.number ?? 0)) },
            wording: PeriodWording(from: report.from, to: report.to, rolling: !view.isCustom && view.period == .day)
        )
    }
}
