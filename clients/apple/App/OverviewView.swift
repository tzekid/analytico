import AnalyticoKit
import Charts
import SwiftUI

/// The site at a glance, as on the workspace Overview: four metrics with
/// their change, the trend against the previous period, the top lists and
/// the period's notes.
struct OverviewView: View {
    @Environment(\.openURL) private var openURL
    let client: Client
    let site: Site
    @Binding var view: ViewState
    @State private var data: OverviewData?
    @State private var failure: String?
    @State private var addingNote = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let failure { Problem(title: "The overview didn’t load", detail: failure) }
                if let data, data.pageViews == 0 {
                    nothingHere(data)
                } else if let data {
                    notes(data)
                    tiles(data)
                    VStack(alignment: .leading, spacing: 10) {
                        if let wording = data.wording { ChartLegend(wording: wording, compared: !data.previousTrend.isEmpty) }
                        TrendChart(current: data.trend, previous: data.previousTrend, notes: data.notes.filter { !$0.draft }, running: data.wording?.running ?? false, hourly: data.hourly)
                            .frame(height: 220)
                    }
                    .padding(16)
                    .background(.background, in: .rect(cornerRadius: 12))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], alignment: .leading, spacing: 16) {
                        TopList(title: "Sources", dimension: "source", rows: data.sources, view: $view)
                        TopList(title: "Pages", dimension: "page", rows: data.pages, view: $view)
                        TopList(title: "Countries", dimension: "country", rows: data.countries, view: $view)
                        TopList(title: "Devices", dimension: "device", rows: data.devices, view: $view)
                    }
                } else if failure == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding()
        }
        .background(Color.secondary.opacity(0.06))
        .navigationTitle("Overview")
        .task(id: view) { await load() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem {
                Button { addingNote = true } label: { Label("Add note", systemImage: "note.text.badge.plus") }
            }
        }
        .sheet(isPresented: $addingNote) {
            AddNoteSheet { day, label in
                try await client.addNote(site: site.slug, day: day, label: label)
                await load()
            }
        }
    }

    private func load() async {
        do {
            data = try await OverviewData.load(client: client, site: site, view: view)
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = "Check the connection and pull to try again."
        }
    }

    private func tiles(_ data: OverviewData) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            ForEach(data.tiles) { tile in
                VStack(alignment: .leading, spacing: 6) {
                    Text(tile.label).font(.subheadline).foregroundStyle(.secondary)
                    Text(tile.value).font(Theme.display(26, relativeTo: .title)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    ChangeLabel(change: tile.change, suffix: tile.change.text.isEmpty ? "" : data.wording?.versus ?? "")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background, in: .rect(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// No visits in this view: a site still waiting for its first visit,
    /// filters that match nothing, or a period without data. Each says which.
    @ViewBuilder private func nothingHere(_ data: OverviewData) -> some View {
        let between = data.wording?.between ?? "in this period"
        if site.firstDay == nil {
            ContentUnavailableView {
                Label("Waiting for your first visit", systemImage: "hourglass")
            } description: {
                Text("Charts appear here once the tracker on \(site.host) reports a page view. Dates and filters become useful then.")
            } actions: {
                Button("Open setup in the workspace") { openURL(client.instance.origin.appending(path: "\(site.slug)/setup")) }
                    .buttonStyle(.borderedProminent)
            }
        } else if !view.filters.isEmpty {
            ContentUnavailableView {
                Label("No visits match these filters", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing matched \(view.filters.map { "\(Labels.dimension($0.dimension)) \($0.negated ? "is not" : "is") \(Labels.value($0.value, dimension: $0.dimension))" }.joined(separator: " and ")) \(between).")
            } actions: {
                Button("Clear filters") { view.filters = [] }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            let first = site.firstDay.flatMap(Dates.parse)
            let before = if let first, let wording = data.wording { wording.end < first } else { false }
            ContentUnavailableView {
                Label(data.wording?.isToday == true ? "No visits yet today" : "No visits \(between)", systemImage: "calendar")
            } description: {
                if before, let first {
                    Text("\(site.name) has data from \(first.formatted(Dates.style.day().month(.abbreviated).year())). These dates are before tracking started, so there is nothing to show yet.")
                } else {
                    Text("The tracker reported nothing in these dates. Data health in the workspace shows whether collection stopped.")
                }
            } actions: {
                Button("Show the last 30 days") { view = ViewState(period: .month, filters: view.filters) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private func notes(_ data: OverviewData) -> some View {
        ForEach(data.notes.filter(\.draft)) { note in
            HStack(spacing: 10) {
                Text("Noticed on \(Dates.short(note.day)): ").foregroundStyle(.secondary) + Text(note.label).fontWeight(.semibold)
                Spacer()
                Button("Keep as a note") {
                    Task { try? await client.keepNote(site: site.slug, id: note.id); await load() }
                }
                Button("Dismiss") {
                    Task { try? await client.deleteNote(site: site.slug, id: note.id); await load() }
                }
                .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(14)
            .background(Theme.brand.opacity(0.08), in: .rect(cornerRadius: 12))
        }
    }
}

struct OverviewData {
    struct Tile: Identifiable {
        var label: String
        var value: String
        var change: AnalyticoKit.Format.Change
        var id: String { label }
    }

    var tiles: [Tile]
    /// What the period is called, for labels and comparisons.
    var wording: PeriodWording?
    var pageViews: Double
    var hourly: Bool
    var trend: [Point]
    var previousTrend: [Point]
    var sources: [Report.Row]
    var pages: [Report.Row]
    var countries: [Report.Row]
    var devices: [Report.Row]
    var notes: [Note]

    static func load(client: Client, site: Site, view: ViewState) async throws -> OverviewData {
        let slug = site.slug
        async let overview = client.report("overview", site: slug, view: view)
        async let series = client.report("timeseries", site: slug, view: view, parameters: ["metric": "visitors"])
        async let sources = client.report("breakdown", site: slug, view: view, parameters: ["dimension": "source", "limit": "5"])
        async let pages = client.report("breakdown", site: slug, view: view, parameters: ["dimension": "page", "limit": "5"])
        async let countries = client.report("breakdown", site: slug, view: view, parameters: ["dimension": "country", "limit": "6"])
        async let devices = client.report("breakdown", site: slug, view: view, parameters: ["dimension": "device", "limit": "4"])
        async let notes = client.notes(site: slug, view: view)
        let report = try await overview
        let totals = report.rows.first ?? [:]
        let number = { (key: String) in totals[key]?.number ?? 0 }
        let rolling = !view.isCustom && view.period == .day
        let wording = PeriodWording(from: report.from, to: report.to, rolling: rolling)
        // A running period averages over the days so far, like the workspace.
        let days = wording?.elapsedDays ?? 1
        var tiles = [
            Tile(label: wording?.oneDay == true ? "Visitors" : "Visitors / day", value: Format.count(Int((number("visitor_days") / days).rounded())), change: Format.change(number("visitor_days"), number("previous_visitor_days"))),
            Tile(label: "Page views", value: Format.count(Int(number("page_views"))), change: Format.change(number("page_views"), number("previous_page_views"))),
            // Lite mode has no visits; like the workspace, it shows visitor-days.
            site.mode == "lite"
                ? Tile(label: "Visitor-days", value: Format.count(Int(number("visitor_days"))), change: Format.change(number("visitor_days"), number("previous_visitor_days")))
                : Tile(label: "Visits", value: Format.count(Int(number("sessions"))), change: Format.change(number("sessions"), number("previous_sessions"))),
            Tile(label: "Active time", value: Format.duration(milliseconds: number("active_ms")), change: Format.change(number("active_ms"), number("previous_active_ms"))),
        ]
        if number("orders") > 0 {
            tiles.append(Tile(label: "Revenue", value: Format.money(minor: Int(number("revenue_minor")), currency: totals["currency"]?.text ?? site.currency), change: Format.Change(text: "\(Int(number("orders"))) orders", direction: .flat)))
        }
        // The previous period's series, shifted onto the current one.
        let current = try await series.rows.map(Point.init(row:))
        var previous: [Point] = []
        if !rolling, let before = view.previous(from: report.from, to: report.to) {
            previous = (try? await client.report("timeseries", site: slug, view: before, parameters: ["metric": "visitors"]).rows.map(Point.init(row:))) ?? []
        }
        return try await OverviewData(
            tiles: tiles,
            wording: wording,
            pageViews: number("page_views"),
            hourly: rolling || wording?.oneDay == true,
            trend: current,
            previousTrend: zip(current, previous).map { Point(at: $0.at, value: $1.value) },
            sources: sources.rows, pages: pages.rows, countries: countries.rows, devices: devices.rows,
            notes: notes
        )
    }
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
        value = row["value"]?.number ?? 0
    }
}

/// Visitors over the period, the previous period dashed, notes as rules.
/// A running period's last bucket is a "now" band, never a drop.
struct TrendChart: View {
    let current: [Point]
    let previous: [Point]
    let notes: [Note]
    let running: Bool
    let hourly: Bool

    private var complete: [Point] { running ? Array(current.dropLast()) : current }
    private var partial: Point? { running ? current.last : nil }
    private var bucket: TimeInterval { hourly ? 3600 : 86_400 }

    var body: some View {
        Chart {
            if let partial {
                RectangleMark(xStart: .value("Now", partial.at - bucket / 2), xEnd: .value("Now", partial.at + bucket / 2))
                    .foregroundStyle(Theme.brand.opacity(0.1))
                    .annotation(position: .top) {
                        Text("now").font(.caption2.weight(.semibold)).foregroundStyle(Theme.brand)
                    }
            }
            ForEach(previous) { point in
                LineMark(x: .value("Time", point.at), y: .value("Visitors", point.value), series: .value("Period", "Before"))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            ForEach(complete) { point in
                AreaMark(x: .value("Time", point.at), y: .value("Visitors", point.value))
                    .foregroundStyle(LinearGradient(colors: [Theme.brand.opacity(0.25), Theme.brand.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.at), y: .value("Visitors", point.value), series: .value("Period", "Now"))
                    .foregroundStyle(Theme.brand)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(notes) { note in
                if let day = Dates.parse(note.day) {
                    RuleMark(x: .value("Note", day))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, alignment: .leading) {
                            Text(note.label).font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .environment(\.timeZone, .gmt)
        .accessibilityLabel(hourly ? "Visitors hour by hour" : "Visitors over the period")
    }
}

/// Which line is which, by its dates: "● Wed 30 Sep  – – Tue 29 Sep".
struct ChartLegend: View {
    let wording: PeriodWording
    let compared: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text("Visitors").font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Theme.brand).frame(width: 8, height: 8)
                Text(wording.this).fontWeight(.semibold)
            }
            if compared {
                HStack(spacing: 6) {
                    Capsule().fill(.secondary).frame(width: 12, height: 2)
                    Text(wording.previous).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

/// A top-five card; tapping a row filters every report by it.
struct TopList: View {
    let title: String
    let dimension: String
    let rows: [Report.Row]
    @Binding var view: ViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            let top = rows.map { $0["page_views"]?.number ?? 0 }.max() ?? 1
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let key = row["value"]?.text ?? ""
                let views = row["page_views"]?.number ?? 0
                Button {
                    view.filters.removeAll { $0.dimension == dimension }
                    view.filters.append(.init(dimension: dimension, value: key))
                } label: {
                    HStack {
                        Text(Labels.value(key, dimension: dimension)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Format.count(Int(views))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(alignment: .leading) {
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 6).fill(Theme.brand.opacity(0.1)).frame(width: geometry.size.width * views / max(top, 1))
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Labels.value(key, dimension: dimension)), \(Int(views)) page views. Filter by it.")
            }
            if rows.isEmpty { Text("Nothing yet in this period").foregroundStyle(.secondary).font(.callout) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 12))
    }
}

struct AddNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String, String) async throws -> Void
    @State private var day = Date()
    @State private var label = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                TextField("Note", text: $label, prompt: Text("Launch, newsletter, outage…"))
                if let failure { Text(failure).foregroundStyle(Theme.bad) }
            }
            .navigationTitle("Add a note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do {
                                try await save(Dates.iso(day), label.trimmingCharacters(in: .whitespaces))
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
        .frame(minWidth: 360, minHeight: 220)
    }
}

enum Dates {
    /// "2026-09-30", "2026-09-30T14:00Z" (hourly rows) or a full timestamp.
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
        parse(day)?.formatted(.dateTime.day().month(.abbreviated)) ?? day
    }

}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
