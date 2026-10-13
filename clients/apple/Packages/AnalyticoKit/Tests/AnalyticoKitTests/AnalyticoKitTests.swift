import CryptoKit
import Foundation
import Testing
@testable import AnalyticoKit

@Suite struct AddressTests {
    @Test(arguments: [
        ("analytics.example.com", "https://analytics.example.com"),
        ("  https://Analytics.Example.com/shop?range=7d#x ", "https://analytics.example.com"),
        ("analytics.example.com:8443/", "https://analytics.example.com:8443"),
        ("http://localhost:4318", "http://localhost:4318"),
    ])
    func normalises(input: String, expected: String) {
        #expect(Address.origin(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "plosca", "http://analytics.example.com", "ftp://example.com", "two words.com"])
    func rejects(input: String) {
        #expect(Address.origin(from: input) == nil)
    }
}

@Suite struct FormatTests {
    let english = Locale(identifier: "en_US")

    @Test func changes() {
        #expect(Format.change(112.4, 100, locale: english).text == "+12.4%")
        #expect(Format.change(97.9, 100, locale: english).text == "−2.1%")
        #expect(Format.change(100, 100, locale: english).text == "0.0%")
        #expect(Format.change(0, 0, locale: english).text == "")
        #expect(Format.change(640, 100, locale: english).text == "6.4×")
        #expect(Format.change(2246, 100, locale: english).text == "22×")
        #expect(Format.change(5, 0, locale: english).text == "new")
        #expect(Format.change(97.9, 100, locale: english).direction == .down)
    }

    @Test func durations() {
        #expect(Format.duration(milliseconds: 38_000) == "38s")
        #expect(Format.duration(milliseconds: 161_000) == "2m 41s")
        #expect(Format.duration(milliseconds: 3_900_000) == "1h 05m")
    }

    @Test func vitals() {
        #expect(Format.vital(340, locale: english) == "340 ms")
        #expect(Format.vital(1800, locale: english) == "1.8 s")
        #expect(Format.vital(1800, locale: Locale(identifier: "de_DE")) == "1,8 s")
        #expect(Format.change(112.4, 100, locale: Locale(identifier: "de_DE")).text == "+12,4%")
    }
}

@Suite struct ViewTests {
    @Test func roundTrips() {
        let view = ViewState(period: .month, filters: [.init(dimension: "source", value: "google"), .init(dimension: "page", value: "/pricing", negated: true)])
        let url = view.workspaceURL(origin: URL(string: "https://analytics.example.com")!, site: "shop", page: "pages")
        #expect(url.absoluteString == "https://analytics.example.com/shop/pages?range=30d&f=source:google&f=page!:/pricing")
        #expect(ViewState(url: url) == view)
    }

    @Test func comparisonOffAndAnyConditionRoundTrip() {
        var view = ViewState(period: .week, filters: [.init(dimension: "source", value: "google"), .init(dimension: "country", value: "DE")])
        view.compare = false
        view.any = true
        let url = view.workspaceURL(origin: URL(string: "https://analytics.example.com")!, site: "shop")
        #expect(url.absoluteString == "https://analytics.example.com/shop?range=7d&cmp=0&fm=any&f=source:google&f=country:DE")
        #expect(ViewState(url: url) == view)
    }

    @Test func previousPeriod() {
        let before = ViewState(period: .week).previous(from: "2026-10-01", to: "2026-10-07")
        #expect(before?.queryItems.map(\.value) == ["custom", "2026-09-24", "2026-09-30"])
        let daylightChange = ViewState(period: .week).previous(from: "2026-10-24", to: "2026-10-26")
        #expect(daylightChange?.queryItems.map(\.value) == ["custom", "2026-10-21", "2026-10-23"])
    }
}

private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        lock.withLock { requests.append(captured) }
    }
    var all: [URLRequest] { lock.withLock { requests } }
}

private final class TransportProtocol: URLProtocol, @unchecked Sendable {
    // These transport tests run serially and never use a network connection.
    nonisolated(unsafe) static var respond: @Sendable (URLRequest) -> Data = { _ in Data("{}".utf8) }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct TransportTests {
    static let instance = try! JSONDecoder().decode(Instance.self, from: Data("""
    {"product":"analytico","name":"transport.example.test","version":"1.0.0","api":{"level":1,"base":"/api/v1"},
     "oauth":{"issuer":"https://transport.example.test","authorization_endpoint":"https://transport.example.test/oauth/authorize","token_endpoint":"https://transport.example.test/oauth/token"},
     "sign_in":["passkey"],"setup_complete":true}
    """.utf8))

    private func transport(expires: Date = Date().addingTimeInterval(3600), reply: String) -> (Client, URLSession, RecordedRequests) {
        let records = RecordedRequests()
        TransportProtocol.respond = { request in records.append(request); return Data(reply.utf8) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = Client(instance: Self.instance, tokens: .init(access: "fixture-access", refresh: "fixture-refresh", expiresAt: expires), store: TokenStore(), session: session)
        return (client, session, records)
    }

    @Test func notesUseSelectedDates() async throws {
        let (client, session, records) = transport(reply: "{\"notes\":[]}")
        defer { session.invalidateAndCancel() }
        _ = try await client.notes(site: "shop", view: .custom(from: "2026-09-30", to: "2026-10-01"))
        let request = try #require(records.all.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(request.url!.path == "/api/v1/sites/shop/notes")
        #expect(query.first { $0.name == "range" }?.value == "custom")
        #expect(query.first { $0.name == "from" }?.value == "2026-09-30")
        #expect(query.first { $0.name == "to" }?.value == "2026-10-01")
    }

    @Test func noteTextPreservesPlusAndUnicode() async throws {
        let (client, session, records) = transport(reply: "{}")
        defer { session.invalidateAndCancel() }
        try await client.addNote(site: "shop", day: "2026-10-01", label: "C++ release + café")
        let body = String(decoding: try #require(records.all.first?.httpBody), as: UTF8.self)
        #expect(!body.contains("+"))
        var form = URLComponents()
        form.percentEncodedQuery = body
        #expect(form.queryItems?.first { $0.name == "label" }?.value == "C++ release + café")
    }

    @Test func signOutUsesRefreshGrantAndEndsTransport() async throws {
        let (client, session, records) = transport(expires: .distantPast, reply: "{}")
        defer { session.invalidateAndCancel() }
        try await client.signOut()
        let request = try #require(records.all.first)
        #expect(request.url!.path == "/oauth/revoke")
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
        var form = URLComponents()
        form.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(form.queryItems?.first { $0.name == "token" }?.value == "fixture-refresh")
        await #expect(throws: ClientError.signedOut) { _ = try await client.sites() }
        #expect(records.all.count == 1)
    }
}

@Suite struct SignInTests {
    static let instance = try! JSONDecoder().decode(Instance.self, from: Data("""
    {"product":"analytico","name":"analytics.example.com","version":"1.0.0","api":{"level":1,"base":"/api/v1"},
     "oauth":{"issuer":"https://analytics.example.com","authorization_endpoint":"https://analytics.example.com/oauth/authorize","token_endpoint":"https://analytics.example.com/oauth/token"},
     "sign_in":["passkey","google"],"setup_complete":true}
    """.utf8))

    @Test func authorizationURL() {
        let signIn = SignIn(instance: Self.instance, deviceName: "Test iPhone")
        let items = URLComponents(url: signIn.url, resolvingAgainstBaseURL: false)!.queryItems!
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(signIn.url.path() == "/oauth/authorize")
        #expect(value("client_id") == "analytico-apple")
        #expect(value("redirect_uri") == "analytico://oauth")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("device_name") == "Test iPhone")
        #expect((value("code_challenge") ?? "").count == 43)
        #expect(Self.instance.signInSummary == "a passkey or Google")
    }

    @Test func rejectsForeignState() async {
        let signIn = SignIn(instance: Self.instance, deviceName: "Mac")
        await #expect(throws: AuthError.invalidCallback) {
            _ = try await signIn.finish(callback: URL(string: "analytico://oauth?code=abc&state=other")!)
        }
        await #expect(throws: AuthError.cancelled) {
            _ = try await signIn.finish(callback: URL(string: "analytico://oauth?error=access_denied&state=x")!)
        }
    }
}

@Suite struct DecodingTests {
    @Test func report() throws {
        let report = try JSONDecoder().decode(Report.self, from: Data("""
        {"site":"shop","report":"overview","from":"2026-10-01","to":"2026-10-07","rows":[{"from":"2026-10-01","page_views":1284,"active_ms":12.5,"currency":"EUR","orders":null}]}
        """.utf8))
        #expect(report.rows[0]["page_views"] == .int(1284))
        #expect(report.rows[0]["active_ms"]?.number == 12.5)
        #expect(report.rows[0]["orders"] == .null)
    }
}

@Suite struct PushTests {
    static func base64URL(_ text: String) -> Data {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)!
    }

    /// The example message from RFC 8291, section 5.
    @Test func opensTheRFCExample() throws {
        let key = try PushKey(privateKey: P256.KeyAgreement.PrivateKey(rawRepresentation: Self.base64URL("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")), authSecret: Self.base64URL("BTBZMqHH6r4Tts7J_aSIgg"))
        #expect(key.publicKey.base64URL == "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
        let sealed = Self.base64URL("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
        #expect(String(decoding: try key.open(sealed), as: UTF8.self) == "When I grow up, I want to be a watermelon")
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) { try key.open(tampered) }
    }
}

@Suite struct PeriodTests {
    static let english = Locale(identifier: "en_GB")
    // Thursday 8 Oct 2026, 14:40 UTC.
    static let now = try! Date("2026-10-08T14:40:00Z", strategy: .iso8601)

    @Test func oneDayReadsHourByHour() throws {
        let day = try #require(PeriodWording(from: "2026-09-30", to: "2026-09-30", now: Self.now, locale: Self.english))
        #expect(day.oneDay && !day.running)
        // The reader's locale decides punctuation ("Wed, 30 Sep 2026" in en_GB).
        #expect(day.title == "Wed, 30 Sep 2026 · hour by hour")
        #expect(day.versus == "vs Tue 29 Sep")
        #expect(day.button == "30 Sep")
    }

    @Test func todayIsSoFar() throws {
        let today = try #require(PeriodWording(from: "2026-10-08", to: "2026-10-08", now: Self.now, locale: Self.english))
        #expect(today.isToday && today.running)
        #expect(today.title == "Today so far, until 14:40")
        #expect(today.versus == "vs yesterday by 14:40")
        #expect(today.compared == "compared with yesterday until 14:40")
        #expect(today.this == "Today" && today.previous == "Yesterday")
        #expect(abs(today.elapsedDays - 1) < 0.0001)
    }

    @Test func spansNameTheirComparison() throws {
        let month = try #require(PeriodWording(from: "2026-09-01", to: "2026-09-30", now: Self.now, locale: Self.english))
        let squeeze = { (text: String) in text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{2009}", with: "") }
        #expect(squeeze(month.this) == "1–30Sep")
        #expect(squeeze(month.previous) == "2–31Aug")
        #expect(squeeze(month.versus) == "vs2–31Aug")
        #expect(squeeze(month.compared) == "comparedwith2–31Aug")
        let week = try #require(PeriodWording(from: "2026-10-02", to: "2026-10-08", now: Self.now, locale: Self.english))
        #expect(abs(week.elapsedDays - (6 + 14.0 / 24 + 40.0 / 1440)) < 0.001)
    }

    @Test func customLinksRoundTrip() {
        let view = ViewState.custom(from: "2026-09-30", to: "2026-09-30")
        let url = view.workspaceURL(origin: URL(string: "https://analytics.example.com")!, site: "shop")
        #expect(url.absoluteString == "https://analytics.example.com/shop?range=custom&from=2026-09-30&to=2026-09-30")
        #expect(ViewState(url: url) == view)
    }
}
