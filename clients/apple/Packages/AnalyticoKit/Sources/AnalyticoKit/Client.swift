import Foundation

/// A website the signed-in person can see, with today's numbers.
public struct Site: Codable, Hashable, Sendable, Identifiable {
    public struct Today: Codable, Hashable, Sendable {
        public var visitors: Int
        public var pageViews: Int

        enum CodingKeys: String, CodingKey {
            case visitors
            case pageViews = "page_views"
        }
    }

    public var slug: String
    public var name: String
    public var host: String
    public var mode: String
    public var currency: String
    public var today: Today

    public var id: String { slug }
    public var initial: String { String(name.first.map { String($0).uppercased() } ?? "?") }
}

/// A chart note, or a note the daily check drafted.
public struct Note: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var day: String
    public var label: String
    public var draft: Bool
}

/// One cell of a report row.
public enum Cell: Codable, Hashable, Sendable {
    case null
    case int(Int)
    case double(Double)
    case text(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else { self = .text(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    public var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    public var text: String {
        switch self {
        case .null: ""
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .text(let value): value
        }
    }
}

/// A catalog report's result: its period and rows keyed by column.
public struct Report: Codable, Sendable {
    public typealias Row = [String: Cell]
    public var site: String
    public var report: String
    public var from: String
    public var to: String
    public var rows: [Row]
}

/// What the live stream reports every few seconds.
public struct LiveUpdate: Codable, Sendable, Equatable {
    public var online: Int
    /// Milliseconds since the epoch of the newest page view.
    public var last: Int
}

public enum ClientError: Error, Equatable {
    case signedOut
    case notFound
    case forbidden
    case server(status: Int, code: String)
}

/// Reads one instance with one signed-in person's tokens. Refreshes the
/// access token when it expires; a revoked sign-in surfaces as `signedOut`.
public actor Client {
    public nonisolated let instance: Instance
    let store: TokenStore
    let session: URLSession
    var tokens: Tokens
    var refreshing: Task<Tokens, Error>?

    public init(instance: Instance, tokens: Tokens, store: TokenStore, session: URLSession = .shared) {
        self.instance = instance
        self.tokens = tokens
        self.store = store
        self.session = session
    }

    public func sites() async throws -> [Site] {
        struct Reply: Decodable { var sites: [Site] }
        return try await get(Reply.self, "sites").sites
    }

    /// A catalog report for a site and view, plus report-specific parameters.
    public func report(_ name: String, site: String, view: ViewState, parameters: [String: String] = [:]) async throws -> Report {
        try await get(Report.self, "sites/\(site)/\(name)", query: view.queryItems + parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
    }

    public func notes(site: String, view: ViewState) async throws -> [Note] {
        struct Reply: Decodable { var notes: [Note] }
        return try await get(Reply.self, "sites/\(site)/notes", query: [URLQueryItem(name: "range", value: view.period.rawValue)]).notes
    }

    public func addNote(site: String, day: String, label: String) async throws {
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "day", value: day), URLQueryItem(name: "label", value: label)]
        _ = try await send("POST", "sites/\(site)/notes", body: Data((body.percentEncodedQuery ?? "").utf8))
    }

    public func keepNote(site: String, id: Int) async throws {
        _ = try await send("POST", "sites/\(site)/notes/\(id)/keep")
    }

    public func deleteNote(site: String, id: Int) async throws {
        _ = try await send("DELETE", "sites/\(site)/notes/\(id)")
    }

    /// People online and the newest page view, as they change, until cancelled.
    public func live(site: String) -> AsyncThrowingStream<LiveUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await self.request("GET", "sites/\(site)/live")
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClientError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "live") }
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        if let update = try? JSONDecoder().decode(LiveUpdate.self, from: Data(line.dropFirst(6).utf8)) {
                            continuation.yield(update)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Transport

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send("GET", path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        for attempt in 0..<2 {
            var request = try await request(method, path, query: query)
            if let body {
                request.httpBody = body
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
            }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return data
            case 401 where attempt == 0:
                // The access token may have expired early; refresh once.
                tokens.expiresAt = .distantPast
                continue
            case 401: throw ClientError.signedOut
            case 403: throw ClientError.forbidden
            case 404: throw ClientError.notFound
            default:
                let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "unknown"
                throw ClientError.server(status: status, code: code)
            }
        }
        throw ClientError.signedOut
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        let access = try await validTokens().access
        var parts = URLComponents(url: instance.origin.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue("Bearer \(access)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }

    func validTokens() async throws -> Tokens {
        if !tokens.isExpiring { return tokens }
        if let refreshing { return try await refreshing.value }
        let endpoint = TokenEndpoint(url: URL(string: instance.oauth.tokenEndpoint)!)
        let refresh = tokens.refresh
        let task = Task { [session] in
            try await endpoint.request(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": AppClient.id], session: session)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            tokens = try await task.value
            store.save(tokens, for: instance.origin)
            return tokens
        } catch AuthError.signedOut {
            store.remove(instance.origin)
            throw ClientError.signedOut
        }
    }
}
