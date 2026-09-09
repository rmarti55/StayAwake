import AppKit

enum ThermalSleepAlert {
    static func present() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Your computer was put to sleep because it got too hot."
            alert.informativeText = "StayAwake slept the Mac to protect it. It’s safe to keep working now."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
        }
    }
}
