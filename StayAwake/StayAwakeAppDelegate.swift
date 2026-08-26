import AppKit

final class StayAwakeAppDelegate: NSObject, NSApplicationDelegate {
    private static let launchHintKey = "stayawake.hasShownLaunchHint"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        showFirstLaunchHintIfNeeded()
    }

    private func showFirstLaunchHintIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.launchHintKey) else { return }

        UserDefaults.standard.set(true, forKey: Self.launchHintKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "StayAwake is ready"
            alert.informativeText = "StayAwake runs from the menu bar. Click the cup icon at the top of your screen to change settings."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()

            NSApp.setActivationPolicy(.accessory)
        }
    }
}
