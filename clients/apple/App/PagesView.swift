import AnalyticoKit
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

    var body: some View {
        ScreenScaffold(screen: .pages, wording: data.value?.wording, stale: data.stale, reload: load) {
            if let pages = data.value {
                if pages.rows.isEmpty {
                    StageView(art: "calendar", title: "No page views \(pages.wording?.between ?? "in this period")", text: "Pages appear here as soon as visitors read them.",
                              primary: state.view.filters.isEmpty ? nil : ("Clear filters", { state.view.filters = [] }))
                } else if sizeClass == .compact {
                    list(pages)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        table(pages)
                        if let page = state.page {
                            PageDetail(path: page)
                                .frame(width: 330)
                                .clipShape(.rect(cornerRadius: Theme.cardRadius))
                                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                        }
                    }
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "Pages didn’t load")
            }
        }
        .task(id: state.view) { await load() }
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
                Text("\(Format.count(pages.rows.count)) pages").font(.subheadline).foregroundStyle(Theme.ink2)
                Spacer()
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(PageSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Sorted by \(sort.title.lowercased())")
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline)
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
                                        .font(.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(Format.count(row.views)).font(Theme.display(20, relativeTo: .title3)).foregroundStyle(Theme.ink).monospacedDigit()
                                    Text(row.views == 1 ? "view" : "views").font(.caption2).foregroundStyle(Theme.muted)
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
        let top = rows.map(\.views).max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Icon("search", size: 14).foregroundStyle(Theme.muted)
                    TextField("Filter \(Format.count(pages.rows.count)) pages", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(width: 260, height: 28)
                .background(Theme.subtle, in: .rect(cornerRadius: 7))
                Spacer()
            }
            .padding(14)
            HStack(spacing: 0) {
                header("Page", nil).frame(maxWidth: .infinity, alignment: .leading)
                header("Views", .views).frame(width: 80, alignment: .trailing)
                header("Visitors", .visitors).frame(width: 80, alignment: .trailing)
                header("Active", .active).frame(width: 70, alignment: .trailing)
                header("Scroll", .scroll).frame(width: 60, alignment: .trailing)
                if state.view.compare { header("Change", nil).frame(width: 70, alignment: .trailing) }
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Theme.subtle)
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.path) { row in
                    let selected = state.page == row.path
                    Button { state.page = selected ? nil : row.path } label: {
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.path).foregroundStyle(Theme.ink).fontWeight(selected ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                                GeometryReader { geometry in
                                    Capsule().fill(Theme.brand.opacity(0.55)).frame(width: max(4, geometry.size.width * 0.85 * share(Double(row.views), Double(top))), height: 3)
                                }
                                .frame(height: 3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Format.count(row.views)).fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                            Text(Format.count(row.visitors)).frame(width: 80, alignment: .trailing)
                            Text(Format.duration(milliseconds: row.active)).frame(width: 70, alignment: .trailing)
                            Text("\(row.scroll)%").frame(width: 60, alignment: .trailing)
                            if state.view.compare {
                                let change = Format.change(Double(row.views), Double(row.previous ?? 0))
                                Text(row.previous == nil ? "" : change.text)
                                    .foregroundStyle(change.direction == .up ? Theme.good : change.direction == .down ? Theme.bad : Theme.ink2)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(selected ? Theme.brandWash : .clear)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .rowMenu("page", row.path)
                    Divider()
                }
            }
            Text("Showing \(Format.count(rows.count)) of \(Format.count(pages.rows.count))").font(.caption).foregroundStyle(Theme.muted).padding(14)
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    private func header(_ title: String, _ column: PageSort?) -> some View {
        Button { if let column { sort = column } } label: {
            HStack(spacing: 3) {
                Text(title)
                if let column, column == sort { Image(systemName: "arrow.down").font(.caption2.weight(.bold)) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(column != nil && column == sort ? Theme.ink : Theme.ink2)
        }
        .buttonStyle(.plain)
        .disabled(column == nil)
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

    init(_ row: Report.Row, previous: Int? = nil) {
        path = row["path"]?.text ?? ""
        views = Int(row["views"]?.number ?? 0)
        visitors = Int(row["visitors"]?.number ?? 0)
        active = row["avg_active_ms"]?.number ?? 0
        scroll = Int(row["avg_scroll"]?.number ?? 0)
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

/// One page: its numbers against the period before, where visitors went
/// next and where they came from; then filter every report by it.
struct PageDetail: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    let path: String
    @State private var tab: Tab = .overview
    @State private var data = Loaded<PageDetailData>()

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", next = "Next pages", from = "Came from"
        var id: String { rawValue }
    }

    var body: some View {
        if sizeClass == .compact {
            ScrollView { content }.background(Theme.canvas)
        } else {
            content.background(Theme.surface)
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PAGE · \(data.value?.wording?.this.uppercased() ?? "")").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(Theme.ink2)
                        Text(path).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                    if sizeClass == .compact {
                        CloseButton { state.page = nil }
                    } else {
                        Button { state.page = nil } label: { Image(systemName: "xmark").font(.callout.weight(.semibold)).foregroundStyle(Theme.ink2) }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel("Close")
                    }
                }
                // What to do with the page, where a half-height sheet shows it.
                HStack(spacing: 8) {
                    Button {
                        state.filter("page", path)
                        state.page = nil
                    } label: {
                        Label(sizeClass == .compact ? "Filter by page" : "Filter by this page", image: "Icons/filter")
                    }
                    .buttonStyle(ActionCapsuleStyle(primary: true, tile: sizeClass == .compact))
                    if let url = URL(string: "https://\(state.site.host)\(path)") {
                        Button { openURL(url) } label: { Label("Open page", image: "Icons/external") }
                            .buttonStyle(ActionCapsuleStyle(primary: false, tile: sizeClass == .compact))
                    }
                    if sizeClass != .compact { Spacer(minLength: 0) }
                }
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let detail = data.value {
                    switch tab {
                    case .overview: overview(detail)
                    case .next: steps(title: "Where visitors go next", rows: detail.next, empty: "Nobody went on from this page in these dates.")
                    case .from: steps(title: "Where visitors came from", rows: detail.from, empty: "Nobody reached this page in these dates.")
                    }
                } else {
                    LoadingOrProblem(failure: data.failure, title: "The page didn’t load")
                }
            }
            .padding(16)
        .task(id: PageKey(path: path, view: state.view)) {
            data.apply(await fetch { try await PageDetailData.load(client: state.client, site: state.site, view: state.view, path: path) })
        }
    }

    private func overview(_ detail: PageDetailData) -> some View {
        let compare = state.view.compare
        let now = detail.now
        let before = detail.before
        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                MetricCard(label: "Views", value: Format.count(now.views), change: compare ? Format.change(Double(now.views), Double(before?.views ?? 0)) : nil)
                MetricCard(label: "Visitors", value: Format.count(now.visitors), change: compare ? Format.change(Double(now.visitors), Double(before?.visitors ?? 0)) : nil)
                MetricCard(label: "Avg. active", value: Format.duration(milliseconds: now.active), change: compare ? Format.change(now.active, before?.active ?? 0) : nil)
                MetricCard(label: "Scroll", value: "\(now.scroll)%", change: compare ? pointsChange(Double(now.scroll) / 100, before.map { Double($0.scroll) / 100 }) : nil)
            }
            .environment(\.horizontalSizeClass, .compact)
            steps(title: "Where visitors go next", rows: Array(detail.next.prefix(3)) + detail.next.filter(\.left), empty: "Nobody went on from this page in these dates.", unique: true)
        }
    }

    private func steps(title: String, rows: [Step], empty: String, unique: Bool = false) -> some View {
        let shown = unique ? rows.reduce(into: [Step]()) { list, step in if !list.contains(where: { $0.path == step.path }) { list.append(step) } } : rows
        let total = max(1, rows.first.map { _ in data.value?.total(for: rows) ?? 1 } ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            ForEach(shown, id: \.path) { step in
                let part = Double(step.count) / Double(total)
                ShareRow(title: step.label, value: part.formatted(.percent.precision(.fractionLength(0))), share: part, color: Theme.brand, wash: step.left ? Theme.subtle : Theme.brandWash, rule: false)
            }
            if rows.isEmpty { Text(empty).font(.callout).foregroundStyle(Theme.ink2) }
        }
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
    var now: PageRow
    var before: PageRow?
    var next: [Step]
    var from: [Step]
    var wording: PeriodWording?

    func total(for rows: [Step]) -> Int { rows.reduce(0) { $0 + $1.count } }

    static func load(client: Client, site: Site, view: ViewState, path: String) async throws -> PageDetailData {
        var scoped = view
        scoped.filters.removeAll { $0.dimension == "page" }
        scoped.filters.append(.init(dimension: "page", value: path))
        let page = scoped
        async let current = client.report("pages", site: site.slug, view: page)
        async let next = client.report("paths", site: site.slug, view: view, parameters: ["from_path": path, "exits": "1", "limit": "12"])
        async let from = client.report("came_from", site: site.slug, view: view, parameters: ["to_path": path, "limit": "12"])
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
            next: nextRows.map { row in
                let to = row["next_path"]?.text ?? ""
                return Step(path: to, count: Int(row["transitions"]?.number ?? 0), label: to.isEmpty ? "Left the site" : to, left: to.isEmpty)
            },
            from: fromRows.map { row in
                let before = row["previous_path"]?.text ?? ""
                return Step(path: before, count: Int(row["transitions"]?.number ?? 0), label: before.isEmpty ? "Entered the site here" : before, left: before.isEmpty)
            },
            wording: PeriodWording(from: report.from, to: report.to, rolling: !view.isCustom && view.period == .day)
        )
    }
}
