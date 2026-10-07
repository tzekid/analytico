import CryptoKit
import Foundation
import Security

/// The app's OAuth client, registered by every Analytico server.
public enum AppClient {
    public static let id = "analytico-apple"
    public static let scheme = "analytico"
    public static let redirect = "analytico://oauth"
}

/// Tokens for one signed-in instance.
public struct Tokens: Codable, Sendable, Equatable {
    public var access: String
    public var refresh: String
    public var expiresAt: Date

    public var isExpiring: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

/// One sign-in in progress: where to send the browser, and what proves the
/// returning code is ours.
public struct SignIn: Sendable {
    public let instance: Instance
    public let url: URL
    let verifier: String
    let state: String

    public init(instance: Instance, deviceName: String) {
        self.instance = instance
        verifier = Self.random(32)
        state = Self.random(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var parts = URLComponents(string: instance.oauth.authorizationEndpoint)!
        parts.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: AppClient.id),
            URLQueryItem(name: "redirect_uri", value: AppClient.redirect),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "device_name", value: deviceName),
        ]
        url = parts.url!
    }

    /// Exchanges the code from the `analytico://oauth` callback for tokens.
    public func finish(callback: URL, session: URLSession = .shared) async throws -> Tokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if value("error") == "access_denied" { throw AuthError.cancelled }
        guard value("state") == state, let code = value("code") else { throw AuthError.invalidCallback }
        return try await TokenEndpoint(url: URL(string: instance.oauth.tokenEndpoint)!).request([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": AppClient.id,
            "redirect_uri": AppClient.redirect,
            "code_verifier": verifier,
        ], session: session)
    }

    static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URL
    }
}

public enum AuthError: Error, Equatable {
    case cancelled
    case invalidCallback
    /// The refresh token was revoked or expired: sign in again.
    case signedOut
    case server(String)
}

struct TokenEndpoint {
    let url: URL

    func request(_ form: [String: String], session: URLSession) async throws -> Tokens {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        struct Reply: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Double?
            var error: String?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = reply.access_token, let refresh = reply.refresh_token else {
            throw reply.error == "invalid_grant" ? AuthError.signedOut : AuthError.server(reply.error ?? "unknown")
        }
        return Tokens(access: access, refresh: refresh, expiresAt: Date().addingTimeInterval(reply.expires_in ?? 3600))
    }
}

/// Keeps tokens in the Keychain, shared with the widgets through the app's
/// access group when one is given.
public struct TokenStore: Sendable {
    let service = "ru.plosca.analytico.tokens"
    let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    func query(_ origin: URL) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: origin.absoluteString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load(_ origin: URL) -> Tokens? {
        var query = query(origin)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    public func save(_ tokens: Tokens, for origin: URL) {
        let data = try! JSONEncoder().encode(tokens)
        let query = query(origin)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    public func remove(_ origin: URL) {
        SecItemDelete(query(origin) as CFDictionary)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
