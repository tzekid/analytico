import AnalyticoKit
import UserNotifications

/// Opens each notification with this device's key before it is shown. The
/// relay only ever carries ciphertext; without the key, the placeholder
/// text Apple delivered stays.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        if let sealed = request.content.userInfo["p"] as? String, let message = try? PushKey.stored()?.message(sealed) {
            content.title = message.title
            content.body = message.body
            content.threadIdentifier = message.site
            content.userInfo = ["site": message.site, "kind": message.kind]
        }
        contentHandler(content)
    }
}
