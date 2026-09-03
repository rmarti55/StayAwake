import AppKit

enum DuplicateLaunchHandler {
    private static let bundleIdentifier = "com.stayawake.app"

    static func handleAlreadyRunning() -> Never {
        DistributedNotificationCenter.default().post(
            name: StayAwakeNotifications.reveal,
            object: bundleIdentifier
        )

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            running.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        }

        exit(0)
    }
}
