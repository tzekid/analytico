import AnalyticoKit
import SwiftUI

/// How one catalog report is shown: which column names the row, which
/// columns are values and how they read, and what tapping a row filters.
struct ReportSpec {
    enum Kind { case count, duration, percent, money, vital, text }

    struct Column {
        var key: String
        var title: String
        var kind: Kind
    }

    var report: String
    var parameters: [String: String] = [:]
    var label: String
    var detail: String?
    var columns: [Column]
    /// Tapping a row adds this filter, keyed by the label column.
    var filter: String?
    var empty: String

    static func of(_ screen: Screen) -> ReportSpec {
        switch screen {
        case .pages:
            ReportSpec(report: "pages", label: "path", columns: [.init(key: "views", title: "Views", kind: .count), .init(key: "visitors", title: "Visitors", kind: .count), .init(key: "avg_active_ms", title: "Active", kind: .duration), .init(key: "avg_scroll", title: "Scroll", kind: .percent)], filter: "page", empty: "No page views in this period.")
        case .sources:
            ReportSpec(report: "acquisition", label: "source", detail: "medium", columns: [.init(key: "views", title: "Views", kind: .count), .init(key: "visitors", title: "Visitors", kind: .count)], filter: "source", empty: "No visits in this period.")
        case .campaigns:
            ReportSpec(report: "campaigns", label: "campaign", detail: "source", columns: [.init(key: "views", title: "Views", kind: .count), .init(key: "visitors", title: "Visitors", kind: .count), .init(key: "sessions", title: "Visits", kind: .count)], filter: "campaign", empty: "No tagged campaigns in this period. Add utm_campaign to your links to see them.")
        case .search:
            ReportSpec(report: "search", label: "term", columns: [.init(key: "searches", title: "Searches", kind: .count), .init(key: "no_results", title: "No results", kind: .count)], empty: "No site searches in this period.")
        case .countries:
            ReportSpec(report: "breakdown", parameters: ["dimension": "country"], label: "value", columns: [.init(key: "page_views", title: "Views", kind: .count), .init(key: "visitor_days", title: "Visitors", kind: .count)], filter: "country", empty: "No visits in this period.")
        case .devices:
            ReportSpec(report: "breakdown", parameters: ["dimension": "device"], label: "value", columns: [.init(key: "page_views", title: "Views", kind: .count), .init(key: "visitor_days", title: "Visitors", kind: .count)], filter: "device", empty: "No visits in this period.")
        case .events:
            ReportSpec(report: "events", label: "name", detail: "source", columns: [.init(key: "occurrences", title: "Times", kind: .count), .init(key: "sessions", title: "Visits", kind: .count)], empty: "No events in this period.")
        case .goals:
            ReportSpec(report: "goals", label: "goal", detail: "match", columns: [.init(key: "completions", title: "Completions", kind: .count), .init(key: "visitor_days", title: "Visitors", kind: .count)], empty: "No goals yet. Add them in the workspace under Events.")
        case .errors:
            ReportSpec(report: "errors", label: "message", detail: "path", columns: [.init(key: "occurrences", title: "Times", kind: .count), .init(key: "visits", title: "Visits", kind: .count)], empty: "No JavaScript errors in this period.")
        case .performance:
            ReportSpec(report: "performance", label: "metric", detail: "page_type", columns: [.init(key: "p75", title: "p75", kind: .vital), .init(key: "samples", title: "Samples", kind: .count)], empty: "No Web Vitals yet. Use the RUM tracker to measure them.")
        case .revenue:
            ReportSpec(report: "revenue", label: "product", columns: [.init(key: "orders", title: "Orders", kind: .count), .init(key: "revenue_minor", title: "Revenue", kind: .money), .init(key: "add_to_carts", title: "Carts", kind: .count)], empty: "No orders in this period.")
        case .overview, .live, .paths, .retention:
            fatalError("\(screen) has its own screen")
        }
    }
}

/// One catalog report as a table on wide screens and a list on narrow ones.
struct ReportScreen: View {
    let client: Client
    let site: Site
    let screen: Screen
    @Binding var view: ViewState
    @State private var rows: [Report.Row]?
    @State private var failure: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var spec: ReportSpec { .of(screen) }

    var body: some View {
        Group {
            if let failure {
                Problem(title: "\(screen.title) didn’t load", detail: failure).padding()
            } else if let rows, rows.isEmpty {
                ContentUnavailableView(screen.title, systemImage: screen.symbol, description: Text(spec.empty))
            } else if let rows {
                list(rows)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(screen.title)
        .task(id: view) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            rows = try await client.report(spec.report, site: site.slug, view: view, parameters: spec.parameters).rows
            failure = nil
        } catch is CancellationError {
        } catch ClientError.server(_, "session_mode_required") {
            failure = "This report needs visits, which Lite mode doesn’t record."
        } catch {
            failure = "Check the connection and pull to try again."
        }
    }

    @ViewBuilder private func list(_ rows: [Report.Row]) -> some View {
        let indexed = rows.enumerated().map { IndexedRow(index: $0.offset, row: $0.element) }
        if sizeClass == .compact {
            List(indexed) { item in
                Button { filter(item.row) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(item.row)).lineLimit(2)
                            if let detail = spec.detail, let text = item.row[detail]?.text, !text.isEmpty {
                                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(value(item.row, spec.columns[0])).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(spec.filter == nil)
            }
        } else {
            Table(indexed) {
                TableColumn(spec.label == "value" ? screen.title : Labels.dimension(spec.label)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(item.row)).lineLimit(2)
                        if let detail = spec.detail, let text = item.row[detail]?.text, !text.isEmpty {
                            Text(text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onTapGesture { filter(item.row) }
                }
                TableColumnForEach(spec.columns.indices, id: \.self) { index in
                    TableColumn(spec.columns[index].title) { item in
                        Text(value(item.row, spec.columns[index])).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90, max: 140)
                }
            }
        }
    }

    private func label(_ row: Report.Row) -> String {
        let text = row[spec.label]?.text ?? ""
        return Labels.value(text.isEmpty ? "(none)" : text, dimension: spec.filter ?? spec.label)
    }

    private func value(_ row: Report.Row, _ column: ReportSpec.Column) -> String {
        guard let number = row[column.key]?.number else { return row[column.key]?.text ?? "—" }
        switch column.kind {
        case .count: return Format.count(Int(number))
        case .duration: return Format.duration(milliseconds: number)
        case .percent: return "\(Int(number.rounded()))%"
        case .money: return Format.money(minor: Int(number), currency: site.currency)
        case .vital: return Format.vital(number, layoutShift: row["metric"]?.text == "cls")
        case .text: return row[column.key]?.text ?? ""
        }
    }

    private func filter(_ row: Report.Row) {
        guard let dimension = spec.filter, let key = row[spec.label]?.text, !key.isEmpty else { return }
        view.filters.removeAll { $0.dimension == dimension }
        view.filters.append(.init(dimension: dimension, value: key))
    }
}

struct IndexedRow: Identifiable {
    var index: Int
    var row: Report.Row
    var id: Int { index }
}

/// People on the site right now and the latest page views, as they happen.
struct LiveView: View {
    let client: Client
    let site: Site
    @State private var update: LiveUpdate?
    @State private var recent: [Report.Row] = []
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(update.map { Format.count($0.online) } ?? "–")
                        .font(Theme.display(44))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("people on \(site.host) in the last five minutes").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            Section("Latest") {
                ForEach(Array(recent.prefix(30).enumerated()), id: \.offset) { _, row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row["path"]?.text ?? row["name"]?.text ?? "").lineLimit(1)
                            Text(Labels.value(row["source"]?.text ?? "", dimension: "source")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let at = row["received_at_ms"]?.number {
                            Text(Date(timeIntervalSince1970: at / 1000), style: .relative).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            if let failure { Problem(title: "Live updates stopped", detail: failure) }
        }
        .navigationTitle("Live")
        .task { await follow() }
    }

    private func follow() async {
        await refreshRecent()
        do {
            for try await next in await client.live(site: site.slug) {
                let changed = next.last != update?.last
                withAnimation { update = next }
                if changed { await refreshRecent() }
            }
        } catch is CancellationError {
        } catch {
            failure = "The connection to \(site.host) closed. Leave and reopen Live to reconnect."
        }
    }

    private func refreshRecent() async {
        recent = (try? await client.report("recent", site: site.slug, view: ViewState(period: .day), parameters: ["limit": "30"]).rows) ?? recent
    }
}
