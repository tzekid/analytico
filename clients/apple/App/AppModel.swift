import AnalyticoKit
import Foundation
import Observation
import UserNotifications
import WidgetKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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
    /// The site open in the main window; restored on the next launch and
    /// shared with the widgets and Siri.
    var selectedSite: String? {
        didSet {
            Shared.site = selectedSite
            followLive()
        }
    }

    /// People online now on the selected site, for the macOS menu bar.
    private(set) var online: Int?
    private var live: Task<Void, Never>?

    /// The push token Apple gave this device, and what it should be told.
    var pushToken: Data? {
        didSet { Task { await registerPush() } }
    }
    var pushKinds = Shared.pushKinds {
        didSet {
            Shared.pushKinds = pushKinds
            Task { await registerPush() }
        }
    }
    private(set) var pushStatus: UNAuthorizationStatus = .notDetermined
    private(set) var pushProblem: String?

    /// A view opened from an `analytico://` or workspace link, applied once.
    var pendingLink: URL?

    let store = Shared.store

    init() {
        selectedSite = Shared.site
        if let client = Shared.client() {
            phase = .signedIn(client)
        }
    }

    var client: Client? {
        if case .signedIn(let client) = phase { return client }
        return nil
    }

    func signedIn(_ instance: Instance, tokens: Tokens) {
        store.save(tokens, for: instance.origin)
        Shared.instance = instance
        WidgetCenter.shared.reloadAllTimelines()
        phase = .signedIn(Client(instance: instance, tokens: tokens, store: store))
    }

    func signOut() {
        if let client {
            // The instance forgets this device; its tokens still work until the request is sent.
            Task { try? await client.unregisterDevice() }
            store.remove(client.instance.origin)
        }
        Shared.instance = nil
        WidgetCenter.shared.reloadAllTimelines()
        live?.cancel()
        live = nil
        online = nil
        selectedSite = nil
        sites = []
        phase = .setup
    }

    /// Follows the selected site's live stream while the app runs (macOS menu bar).
    func followLive() {
        #if os(macOS)
        live?.cancel()
        online = nil
        guard let client, let site = selectedSite else { return }
        live = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await update in await client.live(site: site) {
                        self?.online = update.online
                    }
                } catch {}
                // Reconnect after a dropped stream, without hammering the server.
                try? await Task.sleep(for: .seconds(30))
            }
        }
        #endif
    }

    /// Asks once for permission, then for a push token.
    func enablePush() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        pushStatus = await center.notificationSettings().authorizationStatus
        guard pushStatus == .authorized || pushStatus == .provisional else { return }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private func registerPush() async {
        guard let client, let pushToken else { return }
        #if DEBUG
        let development = true
        #else
        let development = false
        #endif
        do {
            try await client.registerDevice(token: pushToken, key: PushKey.current(), kinds: pushKinds, development: development)
            pushProblem = nil
        } catch {
            pushProblem = "Couldn’t turn on notifications with your Analytico. Its server may need an update."
        }
    }

    func loadSites() async {
        guard let client else { return }
        do {
            sites = try await client.sites()
            sitesError = nil
            await enablePush()
            if selectedSite == nil || !sites.contains(where: { $0.slug == selectedSite }), sites.count == 1 {
                selectedSite = sites[0].slug
            } else if live == nil {
                followLive()
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
