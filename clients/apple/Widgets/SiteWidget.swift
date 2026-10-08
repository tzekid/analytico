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

/// Today's visitors on one website, with the last seven days.
struct SiteWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "site", intent: SiteWidgetIntent.self, provider: Provider()) { entry in
            SiteWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Visitors today")
        .description("Today’s visitors so far, and the six days before.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium])
        #endif
    }
}

struct SiteEntry: TimelineEntry {
    enum State {
        case ready(name: String, visitors: Int, pageViews: Int, week: [Int])
        case signedOut
        case unavailable
    }

    var date: Date
    var state: State
    var site: String?
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SiteEntry {
        SiteEntry(date: .now, state: .ready(name: "shop.example", visitors: 1284, pageViews: 3912, week: [920, 1010, 980, 1150, 1210, 1190, 1284]))
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
            // Today is still running; its partial count would end the sparkline in a cliff.
            let week = try await client.report("timeseries", site: site.slug, view: ViewState(period: .week), parameters: ["metric": "visitors"]).rows.map { Int($0["value"]?.number ?? 0) }.dropLast()
            return SiteEntry(date: .now, state: .ready(name: site.name, visitors: site.today.visitors, pageViews: site.today.pageViews, week: Array(week)), site: site.slug)
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
            Text("Open Analytico to sign in").font(.caption).foregroundStyle(.secondary)
        case .unavailable:
            Text("Couldn’t reach your Analytico").font(.caption).foregroundStyle(.secondary)
        case .ready(let name, let visitors, let pageViews, let week):
            switch family {
            case .accessoryInline:
                Text("\(Format.count(visitors)) visitors today")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text(name).font(.caption).lineLimit(1)
                    Text(Format.count(visitors)).font(.title2).monospacedDigit()
                    Text("visitors today").font(.caption2)
                }
            case .systemMedium:
                HStack(alignment: .top, spacing: 16) {
                    summary(name: name, visitors: visitors, pageViews: pageViews)
                    sparkline(week).frame(maxWidth: .infinity)
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    summary(name: name, visitors: visitors, pageViews: pageViews)
                    sparkline(week).frame(height: 34)
                }
            }
        }
    }

    private func summary(name: String, visitors: Int, pageViews: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(Format.count(visitors))
                .font(.custom("Quando-Regular", size: 30, relativeTo: .title))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("visitors today").font(.caption).foregroundStyle(.secondary)
            Text("\(Format.count(pageViews)) page views").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sparkline(_ week: [Int]) -> some View {
        Chart(Array(week.enumerated()), id: \.offset) { item in
            AreaMark(x: .value("Day", item.offset), y: .value("Visitors", item.element))
                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Day", item.offset), y: .value("Visitors", item.element))
                .foregroundStyle(Color.accentColor)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityLabel("Visitors over the last seven days")
    }
}
