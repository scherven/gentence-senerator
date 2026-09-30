import UIKit
import UserNotifications

/// Registers for the one notification the app gets: a grading batch has
/// ended. The token is kept for `Store.watch`, which hands it to the worker
/// with each batch — so a reinstall's new token is picked up by the next
/// session rather than needing to be pasted anywhere.
final class Push: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("APNs token: \(token)")
        UserDefaults.standard.set(token, forKey: Vault.pushToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error)")
    }

    /// iOS launched the app to deliver the grading uploader's results. The
    /// store must exist to hear them, so it is touched here, and iOS is told
    /// once they have been handled.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == Sender.identifier else { return completionHandler() }
        Sender.finishedEvents = completionHandler
        _ = GentenceApp.store
    }

    static func allowed() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Shown even with the app open — the count on screen moves anyway, but
    /// the banner says it is done.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tapped: open the graded session it is about. On a cold launch this
    /// arrives before the first scene, which is fine — the store is made here
    /// and the screen reads it when it appears.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let tap = Store.Tap(response.notification.request.content.userInfo)
        await GentenceApp.store.open(tap)
    }
}
