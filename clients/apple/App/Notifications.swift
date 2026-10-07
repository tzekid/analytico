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

/// Which notifications this device gets.
struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        Form {
            if model.pushStatus == .denied {
                Section {
                    Text("Notifications are turned off for Analytico.")
                    #if os(iOS)
                    Button("Open Settings") { openURL(URL(string: UIApplication.openNotificationSettingsURLString)!) }
                    #else
                    Button("Open System Settings") { openURL(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
                    #endif
                }
            }
            Section {
                ForEach(PushKind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { model.pushKinds.contains(kind) },
                        set: { on in
                            if on { model.pushKinds.insert(kind) } else { model.pushKinds.remove(kind) }
                        }
                    ))
                }
            } footer: {
                Text("Alerts you set up in the workspace, goals as they’re reached, and days with unusual traffic. Notifications are encrypted for this device; only it can read them.")
            }
            if let problem = model.pushProblem {
                Section { Text(problem).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .task { await model.enablePush() }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        #else
        .frame(width: 440)
        #endif
    }
}
