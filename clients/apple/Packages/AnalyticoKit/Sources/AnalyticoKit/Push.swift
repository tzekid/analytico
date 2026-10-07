import CryptoKit
import Foundation

/// What a notification says once the device has decrypted it.
public struct PushMessage: Decodable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let site: String
    public let kind: String
}

/// The kinds of notification a device can ask for.
public enum PushKind: String, CaseIterable, Identifiable, Sendable {
    case alert, goal, note

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .alert: "Alerts"
        case .goal: "Goals reached"
        case .note: "Unusual days"
        }
    }
}

/// The device's notification key: instances encrypt to its public half
/// (RFC 8291, as Web Push does), and only this device can read what the
/// relay delivers. Kept in the shared Keychain group so the notification
/// extension can open messages.
public struct PushKey: Sendable {
    public let privateKey: P256.KeyAgreement.PrivateKey
    public let authSecret: Data

    public init(privateKey: P256.KeyAgreement.PrivateKey, authSecret: Data) {
        self.privateKey = privateKey
        self.authSecret = authSecret
    }

    public var publicKey: Data { privateKey.publicKey.x963Representation }

    static let account = "push-key"

    /// The stored key, or a new one saved for next time.
    public static func current(accessGroup: String? = Shared.keychainGroup) -> PushKey {
        if let key = stored(accessGroup: accessGroup) { return key }
        var secret = Data(count: 16)
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = PushKey(privateKey: P256.KeyAgreement.PrivateKey(), authSecret: secret)
        var item = query(accessGroup)
        item[kSecValueData as String] = key.privateKey.rawRepresentation + secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
        return key
    }

    public static func stored(accessGroup: String? = Shared.keychainGroup) -> PushKey? {
        var item = query(accessGroup)
        item[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 48,
              let privateKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data.prefix(32)) else { return nil }
        return PushKey(privateKey: privateKey, authSecret: data.suffix(16))
    }

    static func query(_ accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ru.plosca.analytico.push",
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// Decrypts one `aes128gcm` message: salt, record size, the sender's
    /// key, then a single record ending in the 0x02 delimiter.
    public func open(_ sealed: Data) throws -> Data {
        let sealed = Data(sealed)
        guard sealed.count > 21 else { throw PushError.malformed }
        let keyLength = Int(sealed[20])
        let header = 21 + keyLength
        guard sealed.count >= header + 17 else { throw PushError.malformed }
        let salt = sealed[0..<16]
        let senderKey = sealed[21..<header]
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: senderKey))
        let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: authSecret, sharedInfo: Data("WebPush: info\0".utf8) + publicKey + senderKey, outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        let record = sealed[header...]
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }), ciphertext: record.dropLast(16), tag: record.suffix(16))
        let padded = try AES.GCM.open(box, using: key)
        // Padding is zeros after the delimiter; the last record's is 0x02.
        guard let end = padded.lastIndex(where: { $0 != 0 }), padded[end] == 2 else { throw PushError.malformed }
        return padded[padded.startIndex..<end]
    }

    public func message(_ base64: String) throws -> PushMessage {
        guard let sealed = Data(base64Encoded: base64) else { throw PushError.malformed }
        return try JSONDecoder().decode(PushMessage.self, from: open(sealed))
    }
}

public enum PushError: Error {
    case malformed
}

extension Client {
    /// Registers this device for notifications of the given kinds.
    public func registerDevice(token: Data, key: PushKey, kinds: Set<PushKind>, development: Bool) async throws {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "platform", value: "apns"),
            URLQueryItem(name: "environment", value: development ? "development" : "production"),
            URLQueryItem(name: "token", value: token.map { String(format: "%02x", $0) }.joined()),
            URLQueryItem(name: "public_key", value: key.publicKey.base64URL),
            URLQueryItem(name: "auth_secret", value: key.authSecret.base64URL),
            URLQueryItem(name: "kinds", value: PushKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ",")),
        ]
        // Base64url and hex need no escaping beyond what URLComponents does.
        _ = try await send("POST", "device", body: Data((body.percentEncodedQuery ?? "").utf8))
    }

    public func unregisterDevice() async throws {
        _ = try await send("DELETE", "device")
    }
}
