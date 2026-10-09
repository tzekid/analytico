import Foundation

/// What the app and its widgets share: the signed-in instance in the app
/// group's defaults, and its tokens in the shared Keychain access group.
public enum Shared {
    /// A sandboxed Mac app may use a team-prefixed group without a profile
    /// that lists it; iOS needs the registered `group.` one.
    #if os(macOS)
    public static let appGroup = "JVVN972Y79.ru.plosca.analytico"
    #else
    public static let appGroup = "group.ru.plosca.analytico"
    #endif
    public static let keychainGroup = "JVVN972Y79.ru.plosca.analytico"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    public static var store: TokenStore { TokenStore(accessGroup: keychainGroup) }

    public static var instance: Instance? {
        get { defaults.data(forKey: "instance").flatMap { try? JSONDecoder().decode(Instance.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "instance") }
    }

    /// The last list of sites, so the app opens straight to its site and
    /// stays there when the instance can't be reached.
    public static var sites: [Site] {
        get { defaults.data(forKey: "sites").flatMap { try? JSONDecoder().decode([Site].self, from: $0) } ?? [] }
        set { defaults.set(newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue), forKey: "sites") }
    }

    /// The site open in the app, the default for widgets and Siri.
    public static var site: String? {
        get { defaults.string(forKey: "site") }
        set { defaults.set(newValue, forKey: "site") }
    }

    /// The notifications this device asked for; all of them by default.
    public static var pushKinds: Set<PushKind> {
        get { defaults.string(forKey: "pushKinds").map { Set($0.split(separator: ",").compactMap { PushKind(rawValue: String($0)) }) } ?? Set(PushKind.allCases) }
        set { defaults.set(newValue.map(\.rawValue).sorted().joined(separator: ","), forKey: "pushKinds") }
    }

    /// A client for the signed-in instance, or nil when signed out.
    public static func client() -> Client? {
        guard let instance, let tokens = store.load(instance.origin) else { return nil }
        return Client(instance: instance, tokens: tokens, store: store)
    }
}
