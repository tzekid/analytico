import AnalyticoKit
import Charts
import SwiftUI

/// Who comes back: weekly new and returning visitors, return rates by first
/// source and weekly cohorts. Full mode only; refreshed daily on the server.
struct RetentionView: View {
    let client: Client
    let site: Site
    @State private var retention: Retention?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if site.mode != "full" {
                    ContentUnavailableView("Retention needs Full mode", systemImage: "arrow.uturn.backward.circle", description: Text("Lite and Session modes never follow visitors across days. Switch the site to Full in the workspace under Settings → Websites."))
                } else if let failure {
                    Problem(title: "Retention didn’t load", detail: failure)
                } else if let retention {
                    weekly(retention)
                    sources(retention)
                    cohorts(retention)
                    Text("Updated once a day.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding()
        }
        .background(Color.secondary.opacity(0.06))
        .navigationTitle("Retention")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard site.mode == "full" else { return }
        do {
            retention = try await client.retention(site: site.slug)
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = "Check the connection and pull to try again."
        }
    }

    private func week(_ retention: Retention, _ index: Int) -> Date {
        (Dates.parse(retention.firstWeek) ?? .now).addingTimeInterval(Double(index) * 7 * 86_400)
    }

    private func weekly(_ retention: Retention) -> some View {
        let last = retention.active.last ?? 0
        let share = Format.share(Double(retention.returning.last ?? 0), of: Double(last))
        return Card(title: "New and returning visitors", subtitle: "Returning visitors are \(share) of this week.") {
            Chart {
                ForEach(0..<min(8, retention.active.count), id: \.self) { index in
                    BarMark(x: .value("Week", week(retention, index), unit: .weekOfYear), y: .value("Visitors", retention.returning[index]))
                        .foregroundStyle(by: .value("Kind", "Returning"))
                    BarMark(x: .value("Week", week(retention, index), unit: .weekOfYear), y: .value("Visitors", retention.active[index] - retention.returning[index]))
                        .foregroundStyle(by: .value("Kind", "New"))
                }
            }
            .chartForegroundStyleScale(["Returning": Theme.brand, "New": Theme.brand.opacity(0.3)])
            .frame(height: 200)
        }
    }

    private func sources(_ retention: Retention) -> some View {
        Card(title: "Who comes back", subtitle: "Came back within 4 weeks of their first visit, by first source") {
            if retention.sources.isEmpty {
                Text("Shows once visitors first seen at least 4 weeks ago have had time to come back.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(retention.sources, id: \.self) { source in
                let rate = Double(source.back) / Double(max(1, source.total))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(source.label).fontWeight(.semibold)
                        Spacer()
                        Text(Format.share(Double(source.back), of: Double(source.total))).monospacedDigit()
                        Text("of \(Format.count(source.total))").foregroundStyle(.secondary).font(.caption)
                    }
                    ProgressView(value: rate).tint(Theme.brand)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func cohorts(_ retention: Retention) -> some View {
        Card(title: "Weekly cohorts", subtitle: "Share of each week’s new visitors who came back in the weeks after") {
            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Text("Week").gridColumnAlignment(.leading)
                        Text("New")
                        ForEach(1..<8, id: \.self) { Text("+\($0)") }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(0..<min(8, retention.cohorts.count), id: \.self) { cohort in
                        let row = retention.cohorts[cohort]
                        GridRow {
                            Text(week(retention, cohort).formatted(.dateTime.day().month(.abbreviated))).gridColumnAlignment(.leading)
                            Text(Format.count(row.first ?? 0)).monospacedDigit()
                            ForEach(1..<8, id: \.self) { offset in
                                if cohort + offset > 7 || (row.first ?? 0) == 0 {
                                    Color.clear.frame(width: 44, height: 26)
                                } else {
                                    let rate = Double(row[offset]) / Double(row[0])
                                    Text(rate.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .frame(width: 44, height: 26)
                                        .background(Theme.brand.opacity(rate == 0 ? 0.04 : min(0.5, 0.06 + rate * 1.2)), in: .rect(cornerRadius: 4))
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

/// Where visitors go next from a page, chosen from the period's top pages.
struct PathsView: View {
    let client: Client
    let site: Site
    @Binding var view: ViewState
    @State private var pages: [String] = []
    @State private var from: String?
    @State private var next: [Report.Row] = []
    @State private var failure: String?

    var body: some View {
        List {
            if site.mode == "lite" {
                ContentUnavailableView("Paths need visits", systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text("Lite mode never links page views into visits. Switch the site to Session or Full in the workspace."))
            } else {
                Section {
                    Picker("After visiting", selection: $from) {
                        ForEach(pages, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                }
                Section("Next pages") {
                    let total = next.reduce(0) { $0 + ($1["transitions"]?.number ?? 0) }
                    ForEach(Array(next.enumerated()), id: \.offset) { _, row in
                        let count = row["transitions"]?.number ?? 0
                        HStack {
                            Text(row["next_path"]?.text ?? "").lineLimit(1)
                            Spacer()
                            Text(Format.count(Int(count))).monospacedDigit().foregroundStyle(.secondary)
                            Text(Format.share(count, of: total)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                    if next.isEmpty && from != nil { Text("Nobody went on from this page in this period.").foregroundStyle(.secondary) }
                }
                if let failure { Problem(title: "Paths didn’t load", detail: failure) }
            }
        }
        .navigationTitle("Paths")
        .task(id: view) { await loadPages() }
        .task(id: PathsKey(view: view, from: from)) { await loadNext() }
    }

    private func loadPages() async {
        guard site.mode != "lite" else { return }
        do {
            pages = try await client.report("pages", site: site.slug, view: view, parameters: ["limit": "30"]).rows.compactMap { $0["path"]?.text }
            if from == nil || !pages.contains(from!) { from = pages.first }
        } catch is CancellationError {
        } catch {
            failure = "Check the connection and pull to try again."
        }
    }

    private func loadNext() async {
        guard let from else { return }
        do {
            next = try await client.report("paths", site: site.slug, view: view, parameters: ["from_path": from, "limit": "20"]).rows
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = "Check the connection and pull to try again."
        }
    }
}

private struct PathsKey: Hashable {
    var view: ViewState
    var from: String?
}

/// A white card with a heading, as on the workspace.
struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 12))
    }
}
