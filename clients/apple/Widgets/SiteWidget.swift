import AnalyticoKit
import AppIntents
import Charts
import SwiftUI
import WidgetKit

@main
struct AnalyticoWidgets: WidgetBundle {
    var body: some Widget {
        SiteWidget()
    }
}

/// Today's visitors on one website against yesterday by the same time,
/// with the last six full days.
struct SiteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "site", intent: SiteWidgetIntent.self, provider: Provider()) { entry in
            SiteWidgetView(entry: entry)
                .containerBackground(Theme.canvas, for: .widget)
                // A tap opens the widget's site, not whichever the app had open.
                .widgetURL(entry.site.flatMap { URL(string: "analytico://open/\($0)") })
        }
        .configurationDisplayName("Visitors today")
        .description("Today’s visitors so far against yesterday by now, and the six days before.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium])
        #endif
    }
}

struct SiteEntry: TimelineEntry {
    struct Today {
        var name: String
        var visitors: Int
        var pageViews: Int
        /// Against yesterday up to the same time of day.
        var change: Format.Change
        var week: [Int]
    }

    enum State {
        case ready(Today)
        case signedOut
        case unavailable
    }

    var date: Date
    var state: State
    var site: String?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SiteEntry {
        SiteEntry(date: .now, state: .ready(.init(name: "Field Notes", visitors: 412, pageViews: 1284, change: .init(text: "+8.0%", direction: .up), week: [920, 1010, 980, 1150, 1210, 1190])))
    }

    func snapshot(for configuration: SiteWidgetIntent, in context: Context) async -> SiteEntry {
        context.isPreview ? placeholder(in: context) : await entry(for: configuration)
    }

    func timeline(for configuration: SiteWidgetIntent, in context: Context) async -> Timeline<SiteEntry> {
        // Analytics change slowly enough for a refresh every half hour.
        Timeline(entries: [await entry(for: configuration)], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: SiteWidgetIntent) async -> SiteEntry {
        guard let client = Shared.client() else { return SiteEntry(date: .now, state: .signedOut) }
        do {
            let sites = try await client.sites()
            guard let site = sites.first(where: { $0.slug == configuration.site?.id }) ?? sites.first(where: { $0.slug == Shared.site }) ?? sites.first else {
                return SiteEntry(date: .now, state: .unavailable)
            }
            let today = Date.now.formatted(.iso8601.year().month().day())
            async let totals = client.report("overview", site: site.slug, view: .custom(from: today, to: today))
            // Today is still running; its partial count would end the line in a cliff.
            async let series = client.report("timeseries", site: site.slug, view: ViewState(period: .week), parameters: ["metric": "visitor_days"])
            let row = try await totals.rows.first
            let visitors = row?["visitor_days"]?.number ?? Double(site.today.visitors)
            let week = try await series.rows.map { Int($0["value"]?.number ?? 0) }.dropLast()
            return SiteEntry(date: .now, state: .ready(.init(name: site.name, visitors: Int(visitors), pageViews: Int(row?["page_views"]?.number ?? 0),
                                                             change: Format.change(visitors, row?["previous_visitor_days"]?.number ?? 0), week: Array(week.suffix(6)))), site: site.slug)
        } catch {
            return SiteEntry(date: .now, state: .unavailable)
        }
    }
}

struct SiteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SiteEntry

    var body: some View {
        switch entry.state {
        case .signedOut:
            Text("Open Analytico to sign in").font(.caption).foregroundStyle(Theme.ink2)
        case .unavailable:
            Text("Couldn’t reach your Analytico").font(.caption).foregroundStyle(Theme.ink2)
        case .ready(let today):
            switch family {
            case .accessoryInline:
                Text("\(Format.count(today.visitors)) visitors today")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 0) {
                    Text(today.name).font(.caption2).lineLimit(1)
                    Text("\(Format.count(today.visitors)) today").font(.custom("Quando-Regular", size: 19, relativeTo: .title3)).lineLimit(1)
                    change(today, short: false).font(.caption2)
                }
            case .systemMedium:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 16) {
                        summary(today, short: false)
                        line(today.week).frame(maxWidth: .infinity, maxHeight: 76)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Text("\(Format.count(today.pageViews)) page views").foregroundStyle(Theme.muted)
                        Spacer()
                        Text("Last 6 full days").foregroundStyle(Theme.muted)
                    }
                    .font(.caption2)
                }
            default:
                VStack(alignment: .leading, spacing: 2) {
                    summary(today, short: true)
                    Spacer(minLength: 0)
                    change(today, short: true).font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func summary(_ today: SiteEntry.Today, short: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(today.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink2).lineLimit(1)
            Text(Format.count(today.visitors))
                .font(.custom("Quando-Regular", size: 40, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("visitors today").font(.caption).foregroundStyle(Theme.ink2)
            if !short { change(today, short: false).font(.caption.weight(.semibold)).padding(.top, 2) }
        }
    }

    /// "↑ 8% vs yesterday by now"; small widgets say "vs yesterday".
    private func change(_ today: SiteEntry.Today, short: Bool) -> some View {
        let arrow = today.change.direction == .up ? "↑" : today.change.direction == .down ? "↓" : ""
        let text = today.change.text.trimmingCharacters(in: CharacterSet(charactersIn: "+−"))
        return Text(today.change.text.isEmpty ? " " : "\(arrow) \(text) vs yesterday\(short ? "" : " by now")")
            .foregroundStyle(today.change.direction == .up ? Theme.good : today.change.direction == .down ? Theme.bad : Theme.ink2)
            .lineLimit(1)
    }

    private func line(_ week: [Int]) -> some View {
        Chart(Array(week.enumerated()), id: \.offset) { item in
            AreaMark(x: .value("Day", item.offset), y: .value("Visitors", item.element))
                .foregroundStyle(LinearGradient(colors: [Theme.brand.opacity(0.18), Theme.brand.opacity(0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Day", item.offset), y: .value("Visitors", item.element))
                .foregroundStyle(Theme.brand)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if item.offset == week.count - 1 {
                PointMark(x: .value("Day", item.offset), y: .value("Visitors", item.element))
                    .symbol { Circle().strokeBorder(Theme.brand, lineWidth: 2).background(Circle().fill(Theme.surface)).frame(width: 8, height: 8) }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityLabel("Visitors over the last six full days")
    }
}
