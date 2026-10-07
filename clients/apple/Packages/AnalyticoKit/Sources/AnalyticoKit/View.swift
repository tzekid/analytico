import Foundation

/// The period, comparison and filters of a screen, in the same form as the
/// workspace URL, so "Open in workspace" and `analytico://` links round-trip.
public struct ViewState: Hashable, Sendable, Codable {
    public enum Period: String, CaseIterable, Sendable, Codable, Identifiable {
        case day = "24h", week = "7d", month = "30d", quarter = "90d"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .day: "Last 24 hours"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            case .quarter: "Last 90 days"
            }
        }

        public var short: String {
            switch self {
            case .day: "24h"
            case .week: "7 days"
            case .month: "30 days"
            case .quarter: "90 days"
            }
        }

        /// "vs yesterday", as the workspace says it.
        public var comparison: String {
            switch self {
            case .day: "vs yesterday"
            case .week: "vs last week"
            case .month: "vs previous 30d"
            case .quarter: "vs previous 90d"
            }
        }
    }

    /// One condition: "source:google", or negated "source!:google".
    public struct Filter: Hashable, Sendable, Codable, Identifiable {
        public var dimension: String
        public var value: String
        public var negated: Bool

        public init(dimension: String, value: String, negated: Bool = false) {
            self.dimension = dimension
            self.value = value
            self.negated = negated
        }

        public var id: String { query }
        public var query: String { "\(dimension)\(negated ? "!" : ""):\(value)" }

        public init?(query: String) {
            guard let colon = query.firstIndex(of: ":") else { return nil }
            var dimension = String(query[..<colon])
            negated = dimension.hasSuffix("!")
            if negated { dimension.removeLast() }
            self.dimension = dimension
            value = String(query[query.index(after: colon)...])
            guard !dimension.isEmpty, !value.isEmpty else { return nil }
        }
    }

    public var period: Period
    public var filters: [Filter]
    /// Explicit days instead of the period, "2026-09-24"…"2026-09-30", for
    /// the previous period's series.
    public var from: String?
    public var to: String?

    public init(period: Period = .week, filters: [Filter] = []) {
        self.period = period
        self.filters = filters
    }

    /// Query items for the read API and the workspace: range, then one `f` per filter.
    public var queryItems: [URLQueryItem] {
        let range = if let from, let to {
            [URLQueryItem(name: "range", value: "custom"), URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)]
        } else {
            [URLQueryItem(name: "range", value: period.rawValue)]
        }
        return range + filters.map { URLQueryItem(name: "f", value: $0.query) }
    }

    /// The same view over the days just before "from"…"to" (inclusive dates).
    public func previous(from: String, to: String) -> ViewState? {
        let calendar = Calendar(identifier: .gregorian)
        guard let start = try? Date(from + "T00:00:00Z", strategy: .iso8601), let end = try? Date(to + "T00:00:00Z", strategy: .iso8601) else { return nil }
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        let format = Date.ISO8601FormatStyle().year().month().day()
        var out = self
        out.from = (start - Double(days) * 86_400).formatted(format)
        out.to = (start - 86_400).formatted(format)
        return out
    }

    /// The same view in the workspace: "https://analytics.example.com/shop/pages?range=30d&f=…".
    public func workspaceURL(origin: URL, site: String, page: String? = nil) -> URL {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = "/" + site + (page.map { "/" + $0 } ?? "")
        parts.queryItems = queryItems
        return parts.url!
    }

    /// Reads a workspace or `analytico://` link back into a view.
    public init(url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        period = items.first { $0.name == "range" }.flatMap { Period(rawValue: $0.value ?? "") } ?? .week
        filters = items.filter { $0.name == "f" }.compactMap { Filter(query: $0.value ?? "") }
    }
}
