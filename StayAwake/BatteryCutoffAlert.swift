import AppKit

enum BatteryCutoffAlert {
    private static weak var activeAlert: NSAlert?
    private static weak var activeHostWindow: NSWindow?

    static func present(percent: Int, threshold: Int, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            dismissIfPresent()

            let alert = NSAlert()
            alert.messageText = "Low battery — sleep?"
            alert.informativeText = """
            Battery is at \(percent)%. Your \(threshold)% sleep limit was reached. Put the computer to sleep?
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Sleep Now")
            alert.addButton(withTitle: "Keep Going")

            let hostWindow = makeSheetHostWindow()
            activeAlert = alert
            activeHostWindow = hostWindow

            alert.beginSheetModal(for: hostWindow) { response in
                activeAlert = nil
                activeHostWindow = nil
                hostWindow.orderOut(nil)
                completion(response == .alertFirstButtonReturn)
            }

            hostWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func dismissIfPresent() {
        guard let hostWindow = activeHostWindow else { return }

        if let sheet = hostWindow.attachedSheet {
            hostWindow.endSheet(sheet)
        }

        hostWindow.orderOut(nil)
        activeAlert = nil
        activeHostWindow = nil
    }

    private static func makeSheetHostWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.center()
        return window
    }
}
