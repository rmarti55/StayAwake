import AppKit

enum DuplicateLaunchHandler {
    private static let bundleIdentifier = "com.stayawake.app"

    static func handleAlreadyRunning() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            running.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        }

        let alert = NSAlert()
        alert.messageText = "StayAwake is already running"
        alert.informativeText = "Look for the cup icon in your menu bar at the top of the screen."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()

        exit(0)
    }
}
