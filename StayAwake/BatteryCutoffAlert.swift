import AppKit

enum BatteryCutoffAlert {
    static func present(percent: Int, threshold: Int, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Low battery — sleep?"
            alert.informativeText = """
            Battery is at \(percent)%. Your \(threshold)% sleep limit was reached. Put the computer to sleep?
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Sleep Now")
            alert.addButton(withTitle: "Keep Going")

            let sleepNow = alert.runModal() == .alertFirstButtonReturn
            completion(sleepNow)
        }
    }
}
