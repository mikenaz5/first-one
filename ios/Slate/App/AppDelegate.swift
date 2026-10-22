import UIKit
import UserNotifications

/// UIKit's side of notifications: the device token Apple hands back, and taps on notifications.
/// SwiftUI has no hook for either, so a small delegate forwards them to `AppModel`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set once the app's model exists. Anything that arrives earlier waits in `queued`.
    @MainActor weak var model: AppModel?
    @MainActor private var queuedToken: Data?
    @MainActor private var queuedLink: URL?

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    @MainActor
    func attach(_ model: AppModel) {
        self.model = model
        if let token = queuedToken {
            queuedToken = nil
            Task { await model.didRegisterForRemoteNotifications(token: token) }
        }
        if let link = queuedLink {
            queuedLink = nil
            model.handle(url: link)
        }
    }

    // MARK: - Device token

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            if let model {
                await model.didRegisterForRemoteNotifications(token: deviceToken)
            } else {
                queuedToken = deviceToken
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            model?.didFailToRegisterForRemoteNotifications(error)
        }
    }

    // MARK: - Notifications

    /// A notification arrived while the app is open: show it, unless it's about the conversation on screen.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        return await MainActor.run { () -> UNNotificationPresentationOptions in
            guard let model else { return [.banner, .list, .sound, .badge] }
            Task { await model.refreshLiveData() }
            return model.shouldShowBanner(forUserInfo: userInfo) ? [.banner, .list, .sound, .badge] : []
        }
    }

    /// The person tapped a notification: go where it says.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            guard let url = NotificationRouting.url(fromUserInfo: userInfo) else { return }
            if let model {
                model.handle(url: url)
            } else {
                queuedLink = url
            }
        }
    }
}
