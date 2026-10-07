import Foundation

/// What the app and its widgets share: the signed-in instance in the app
/// group's defaults, and its tokens in the shared Keychain access group.
public enum Shared {
    public static let appGroup = "group.ru.plosca.analytico"
    public static let keychainGroup = "JVVN972Y79.ru.plosca.analytico"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    public static var store: TokenStore { TokenStore(accessGroup: keychainGroup) }

    public static var instance: Instance? {
        get { defaults.data(forKey: "instance").flatMap { try? JSONDecoder().decode(Instance.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "instance") }
    }

    /// The site open in the app, the default for widgets and Siri.
    public static var site: String? {
        get { defaults.string(forKey: "site") }
        set { defaults.set(newValue, forKey: "site") }
    }

    /// A client for the signed-in instance, or nil when signed out.
    public static func client() -> Client? {
        guard let instance, let tokens = store.load(instance.origin) else { return nil }
        return Client(instance: instance, tokens: tokens, store: store)
    }
}
