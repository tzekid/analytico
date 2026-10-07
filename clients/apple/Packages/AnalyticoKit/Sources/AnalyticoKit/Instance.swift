import Foundation

/// An Analytico instance as `/.well-known/analytico` describes it.
public struct Instance: Codable, Hashable, Sendable {
    public struct API: Codable, Hashable, Sendable {
        public var level: Int
        public var base: String
    }

    public struct OAuth: Codable, Hashable, Sendable {
        public var issuer: String
        public var authorizationEndpoint: String
        public var tokenEndpoint: String

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
        }
    }

    public var product: String
    public var name: String
    public var version: String
    public var api: API
    public var oauth: OAuth
    public var signIn: [String]
    public var setupComplete: Bool

    enum CodingKeys: String, CodingKey {
        case product, name, version, api, oauth
        case signIn = "sign_in"
        case setupComplete = "setup_complete"
    }

    /// The API level this app speaks; an instance with a higher one needs a newer app.
    public static let supportedLevel = 1

    /// The instance's address, from its issuer: "https://analytics.example.com".
    public var origin: URL { URL(string: oauth.issuer)! }

    /// "analytics.example.com"
    public var host: String { origin.host(percentEncoded: false) ?? name }

    /// "Passkey or Google", from the sign-in methods it offers.
    public var signInSummary: String {
        let names = signIn.compactMap { method -> String? in
            switch method {
            case "passkey": "a passkey"
            case "google": "Google"
            case "chatgpt": "ChatGPT"
            case "password": "a password"
            default: nil
            }
        }
        return names.count <= 1 ? names.first ?? "your account" : names.dropLast().joined(separator: ", ") + " or " + names.last!
    }
}

/// What the setup screen shows about an address while and after checking it.
public enum InstanceCheck: Sendable, Equatable {
    case ready(Instance)
    case invalidAddress
    case unreachable(host: String)
    case untrusted(host: String)
    case notAnalytico(host: String)
    case needsUpdate(Instance)
    case newerAppNeeded(Instance)
    case notSetUp(Instance)

    public var instance: Instance? {
        switch self {
        case .ready(let instance): instance
        default: nil
        }
    }
}

public enum Address {
    /// The instance origin for what someone typed or pasted: a bare host, a
    /// full URL or a workspace link. Plain http only for local development.
    public static func origin(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty, host.contains(".") || isLocal(host)
        else { return nil }
        if scheme == "http" && !isLocal(host) { return nil }
        guard scheme == "https" || scheme == "http" else { return nil }
        parts.scheme = scheme
        parts.host = host
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") || host.hasSuffix(".localhost")
    }
}

public enum InstanceChecker {
    /// Checks an address: reachable, an Analytico instance, compatible and set up.
    public static func check(_ text: String, session: URLSession = .shared) async -> InstanceCheck {
        guard let origin = Address.origin(from: text), let host = origin.host() else { return .invalidAddress }
        var request = URLRequest(url: origin.appending(path: ".well-known/analytico"))
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed:
                return .untrusted(host: host)
            default:
                return .unreachable(host: host)
            }
        } catch {
            return .unreachable(host: host)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let instance = try? JSONDecoder().decode(Instance.self, from: data),
              instance.product == "analytico"
        else { return .notAnalytico(host: host) }
        if instance.api.level < Instance.supportedLevel { return .needsUpdate(instance) }
        if instance.api.level > Instance.supportedLevel { return .newerAppNeeded(instance) }
        if !instance.setupComplete { return .notSetUp(instance) }
        return .ready(instance)
    }
}
