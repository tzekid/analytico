import AnalyticoKit
import Charts
import SwiftUI

/// Who is on the site right now, the last half hour minute by minute, the
/// pages being read and the latest page views. The stream keeps the count
/// current and redraws the rest when a page view arrives.
struct LiveView: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var data = Loaded<LiveData>()

    var body: some View {
        ScreenScaffold(screen: .live, stale: data.stale, reload: load) {
            if let live = data.value {
                if sizeClass == .compact {
                    hero(live)
                    if !live.reading.isEmpty { reading(live) }
                    latest(live)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        hero(live)
                        reading(live)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    latest(live)
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "Live didn’t load")
            }
        }
        .task(id: state.last) { await load() }
    }

    private func load() async {
        data.apply(await fetch { try await LiveData.load(client: state.client, site: state.site) })
    }

    private func hero(_ live: LiveData) -> some View {
        let online = state.online ?? live.reading.reduce(0) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: 6) {
            Text(Format.count(online))
                .font(Theme.display(72, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .monospacedDigit()
            if online > 0 {
                Text("\(online == 1 ? "person" : "people") on \(state.site.host) right now").foregroundStyle(Theme.ink2)
            } else {
                Text("Nobody is on \(state.site.host) right now").foregroundStyle(Theme.ink2)
                // The stream knows the newest page view, even one older than a day.
                if let last = state.last.flatMap({ $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000) : nil }) ?? live.last {
                    Text("The last page view was \(last.formatted(.relative(presentation: .named))). This updates by itself.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Text("Page views per minute · last 30 minutes").font(.caption).foregroundStyle(Theme.muted).padding(.top, 14)
            MinuteBars(minutes: live.minutes)
                .frame(height: 80)
        }
        .card(padding: 20)
        .animation(.default, value: state.online)
    }

    private func reading(_ live: LiveData) -> some View {
        SectionCard(title: "On these pages now") {
            let top = Double(live.reading.first?.1 ?? 1)
            VStack(spacing: 8) {
                ForEach(live.reading, id: \.0) { path, count in
                    Button { state.inspect(path) } label: {
                        ShareRow(title: path, value: Format.count(count), share: Double(count) / top * 0.8, rule: false).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .rowMenu("page", path)
                }
                if live.reading.isEmpty { Text("No one is reading a page right now. Pages appear here the moment someone arrives.").font(.callout).foregroundStyle(Theme.ink2) }
            }
        }
    }

    private func latest(_ live: LiveData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Latest page views").font(.headline).foregroundStyle(Theme.ink).padding(16)
            if sizeClass != .compact {
                HStack(spacing: 0) {
                    Text("When").frame(width: 80, alignment: .leading)
                    Text("Page").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Source").frame(width: 170, alignment: .leading)
                    Text("Country").frame(width: 150, alignment: .leading)
                    Text("Device").frame(width: 90, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(Theme.subtle)
            }
            ForEach(Array(live.views.enumerated()), id: \.offset) { index, view in
                if index > 0 || sizeClass != .compact { Divider() }
                let fresh = Date.now.timeIntervalSince(view.at) < 60
                let when = fresh ? "now" : Self.ago(view.at)
                if sizeClass == .compact {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(view.path).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                            Text([view.source, view.country].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.ink2)
                        }
                        Spacer()
                        Text(when).font(.caption.weight(fresh ? .semibold : .regular)).foregroundStyle(fresh ? Theme.good : Theme.muted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                } else {
                    HStack(spacing: 0) {
                        Text(when).foregroundStyle(fresh ? Theme.good : Theme.muted).fontWeight(fresh ? .semibold : .regular).frame(width: 80, alignment: .leading)
                        Text(view.path).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        Text(view.source).foregroundStyle(Theme.ink).frame(width: 170, alignment: .leading)
                        Text(view.country).foregroundStyle(Theme.ink).frame(width: 150, alignment: .leading)
                        Text(view.device).foregroundStyle(Theme.ink2).frame(width: 90, alignment: .leading)
                    }
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                }
            }
            if live.views.isEmpty { Text("No page views in the last 24 hours.").foregroundStyle(Theme.ink2).padding(16) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
        .clipShape(.rect(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
    }

    /// "12s", "4m", "2h".
    static func ago(_ date: Date) -> String {
        let seconds = Int(Date.now.timeIntervalSince(date))
        if seconds < 60 { return "\(max(0, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

/// The last half hour, minute by minute; the newest minute is still
/// filling. Hover or touch a bar for its count.
struct MinuteBars: View {
    let minutes: [LiveData.Minute]
    @State private var selection: Date?

    private var selected: LiveData.Minute? {
        guard let selection else { return nil }
        return minutes.min { abs($0.at.timeIntervalSince(selection)) < abs($1.at.timeIntervalSince(selection)) }
    }

    var body: some View {
        let busiest = max(1, minutes.map(\.count).max() ?? 1)
        Chart(minutes, id: \.at) { minute in
            BarMark(x: .value("Minute", minute.at, unit: .minute), y: .value("Page views", minute.count == 0 ? Double(busiest) * 0.04 : Double(minute.count)))
                .foregroundStyle(minute.count == 0 ? Theme.border : minute.at == minutes.last?.at ? Theme.brand.opacity(0.45) : Theme.brand)
                .clipShape(.rect(cornerRadii: .init(topLeading: 2, topTrailing: 2)))
                .opacity(selected == nil || selected?.at == minute.at ? 1 : 0.5)
            if let selected, selected.at == minute.at {
                RuleMark(x: .value("Minute", minute.at, unit: .minute))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("\(minute.at.formatted(date: .omitted, time: .shortened)) · \(plural(minute.count, "page view"))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(light: 0x282421, dark: 0x3A3330), in: .rect(cornerRadius: 6))
                    }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        // Scaled to the busiest minute, so an empty half hour shows stubs, not full bars.
        .chartYScale(domain: 0...Double(busiest))
        .pointerSelection($selection)
        .accessibilityLabel("\(minutes.reduce(0) { $0 + $1.count }) page views in the last 30 minutes")
    }
}

struct LiveData {
    struct Minute {
        var at: Date
        var count: Int
    }

    struct View {
        var at: Date
        var path: String
        var source: String
        var country: String
        var device: String
    }

    var minutes: [Minute]
    var reading: [(String, Int)]
    var views: [View]
    var last: Date?

    static func load(client: Client, site: Site) async throws -> LiveData {
        async let minutes = client.report("minutes", site: site.slug, view: ViewState(period: .day))
        async let recent = client.report("recent", site: site.slug, view: ViewState(period: .day), parameters: ["limit": "60"])
        let views = try await recent.rows.filter { $0["kind"]?.text == "page_view" }.map { row in
            View(at: Date(timeIntervalSince1970: (row["received_at_ms"]?.number ?? 0) / 1000),
                 path: row["path"]?.text ?? "",
                 source: row["referrer_label"]?.text ?? "",
                 country: (row["country"]?.text).flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? "",
                 device: Labels.value(row["device"]?.text ?? "", dimension: "device"))
        }
        // The pages read in the last five minutes, as on the workspace.
        let since = Date.now.addingTimeInterval(-300)
        var reading: [String: Int] = [:]
        for view in views where view.at >= since { reading[view.path, default: 0] += 1 }
        return try await LiveData(minutes: minutes.rows.map { Minute(at: Dates.parse($0["at"]?.text ?? "") ?? .now, count: Int($0["page_views"]?.number ?? 0)) },
                                  reading: reading.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) },
                                  views: Array(views.prefix(12)), last: views.first?.at)
    }
}

// MARK: - Retention

/// Who comes back: each week's new visitors followed for 8 weeks, and the
/// first sources that bring people back. Full mode only; computed daily.
struct RetentionView: View {
    @Environment(SiteState.self) private var state
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var data = Loaded<Retention>()

    var body: some View {
        ScreenScaffold(screen: .retention, stale: data.stale, reload: load) {
            if state.site.mode != "full" {
                StageView(art: "calendar", title: "Retention needs Full mode", text: "Lite and Session modes never follow visitors across days. Switch the site to Full in the workspace under Settings → Websites.")
            } else if let retention = data.value {
                if sizeClass == .compact {
                    cohorts(retention)
                    sources(retention)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        cohorts(retention)
                        sources(retention).frame(maxWidth: 340)
                    }
                }
            } else {
                LoadingOrProblem(failure: data.failure, title: "Retention didn’t load")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard state.site.mode == "full" else { return }
        data.apply(await fetch { try await state.client.retention(site: state.site.slug) })
    }

    private func week(_ retention: Retention, _ index: Int) -> String {
        ((Dates.parse(retention.firstWeek) ?? .now).addingTimeInterval(Double(index) * 7 * 86_400)).formatted(Dates.style.day().month(.abbreviated))
    }

    private func cohorts(_ retention: Retention) -> some View {
        let compact = sizeClass == .compact
        return SectionCard(title: "Who came back, by first week") {
            Grid(alignment: .leading, horizontalSpacing: compact ? 4 : 6, verticalSpacing: compact ? 4 : 6) {
                GridRow {
                    Text(compact ? "Wk" : "First week")
                    Text("New")
                    ForEach(1..<8, id: \.self) { Text(compact ? "\($0)" : "Wk \($0)").gridColumnAlignment(.center) }
                }
                .font(.caption)
                .foregroundStyle(Theme.ink2)
                ForEach(0..<min(8, retention.cohorts.count), id: \.self) { cohort in
                    let row = retention.cohorts[cohort]
                    GridRow {
                        Text(week(retention, cohort)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(Format.count(row.first ?? 0)).foregroundStyle(Theme.ink2).monospacedDigit()
                        ForEach(1..<8, id: \.self) { offset in
                            if cohort + offset > 7 || (row.first ?? 0) == 0 || offset >= row.count {
                                Color.clear.frame(height: compact ? 30 : 34)
                            } else {
                                let rate = Double(row[offset]) / Double(row[0])
                                Text(compact ? "\(Int((rate * 100).rounded()))" : rate.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(rate > 0.3 ? .white : Theme.ink)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: compact ? 30 : 34)
                                    .background(Theme.brand.opacity(min(0.9, 0.18 + rate * 2)), in: .rect(cornerRadius: 6))
                            }
                        }
                    }
                    .font(.callout)
                }
            }
            Text("Percent of each week’s new visitors seen again in a later week.").font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private func sources(_ retention: Retention) -> some View {
        SectionCard(title: "Came back, by first source") {
            if retention.sources.isEmpty {
                Text("Shows once visitors first seen at least 4 weeks ago have had time to come back.").font(.callout).foregroundStyle(Theme.ink2)
            }
            ForEach(retention.sources, id: \.self) { source in
                HStack(alignment: .firstTextBaseline) {
                    Text(source.label).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(Format.share(Double(source.back), of: Double(source.total))).font(Theme.display(20, relativeTo: .title3)).foregroundStyle(Theme.ink).monospacedDigit()
                    Text("of \(Format.count(source.total))").font(.caption).foregroundStyle(Theme.muted).frame(minWidth: 56, alignment: .trailing)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
