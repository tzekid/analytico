import AnalyticoKit
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Receives the push token and notification taps, and owns the app's model
/// so both can reach it.
@MainActor
final class AppDelegate: NSObject, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    func registered(_ token: Data) {
        model.pushToken = token
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap opens the notification's website.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let site = response.notification.request.content.userInfo["site"] as? String else { return }
        await MainActor.run { model.selectedSite = site }
    }
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        registered(deviceToken)
    }
}
#else
extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        registered(deviceToken)
    }
}
#endif
