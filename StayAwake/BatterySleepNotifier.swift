import Foundation
import UserNotifications

enum BatterySleepNotifier {
    private static let notificationID = "stayawake.battery-sleep-retry-cap"

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifySleepRetriesExhaustedVisibility(attempt: Int) {
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = "StayAwake could not put the Mac to sleep"
        content.body = """
        Battery sleep was requested \(attempt) times but the Mac stayed awake. \
        Plug in power or quit apps that prevent sleep. Retries will continue.
        """

        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
