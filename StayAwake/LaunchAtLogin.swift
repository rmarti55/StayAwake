import Foundation
import ServiceManagement

final class LaunchAtLogin: ObservableObject {
    @Published var isEnabled: Bool

    init() {
        isEnabled = LaunchAtLogin.currentStatus()
        ToggleLogger.logStartup(toggle: "Start at Login", enabled: isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        let previous = isEnabled

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = LaunchAtLogin.currentStatus()
        } catch {
            print("StayAwake: Failed to update launch at login: \(error)")
            isEnabled = LaunchAtLogin.currentStatus()
        }

        ToggleLogger.log(
            toggle: "Start at Login",
            from: previous,
            to: isEnabled,
            source: .user
        )
    }

    func refreshStatus() {
        let previous = isEnabled
        isEnabled = LaunchAtLogin.currentStatus()

        ToggleLogger.log(
            toggle: "Start at Login",
            from: previous,
            to: isEnabled,
            source: .external
        )
    }

    private static func currentStatus() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}
