import AnalyticoKit
import Foundation
import Observation

/// The signed-in instance and its sites, or the setup flow when there is none.
@MainActor @Observable
final class AppModel {
    enum Phase {
        case setup
        case signedIn(Client)
    }

    private(set) var phase: Phase = .setup
    private(set) var sites: [Site] = []
    var sitesError: String?
    /// The site open in the main window; restored on the next launch.
    var selectedSite: String? {
        didSet { UserDefaults.standard.set(selectedSite, forKey: "site") }
    }

    /// A view opened from an `analytico://` or workspace link, applied once.
    var pendingLink: URL?

    let store = TokenStore()

    init() {
        selectedSite = UserDefaults.standard.string(forKey: "site")
        if let data = UserDefaults.standard.data(forKey: "instance"),
           let instance = try? JSONDecoder().decode(Instance.self, from: data),
           let tokens = store.load(instance.origin) {
            phase = .signedIn(Client(instance: instance, tokens: tokens, store: store))
        }
    }

    var client: Client? {
        if case .signedIn(let client) = phase { return client }
        return nil
    }

    func signedIn(_ instance: Instance, tokens: Tokens) {
        store.save(tokens, for: instance.origin)
        UserDefaults.standard.set(try? JSONEncoder().encode(instance), forKey: "instance")
        phase = .signedIn(Client(instance: instance, tokens: tokens, store: store))
    }

    func signOut() {
        if let client { store.remove(client.instance.origin) }
        UserDefaults.standard.removeObject(forKey: "instance")
        selectedSite = nil
        sites = []
        phase = .setup
    }

    func loadSites() async {
        guard let client else { return }
        do {
            sites = try await client.sites()
            sitesError = nil
            if selectedSite == nil || !sites.contains(where: { $0.slug == selectedSite }), sites.count == 1 {
                selectedSite = sites[0].slug
            }
        } catch ClientError.signedOut {
            signOut()
        } catch {
            sitesError = "Couldn’t load your sites. Check the connection and try again."
        }
    }

    /// Opens `analytico://<host>/<site>/<page>?range=…` or a workspace link.
    func open(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let site = parts.first, sites.contains(where: { $0.slug == site }) || sites.isEmpty {
            selectedSite = site
        }
        pendingLink = url
    }
}
