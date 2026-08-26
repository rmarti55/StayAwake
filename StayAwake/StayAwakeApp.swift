import SwiftUI

@main
struct StayAwakeApp: App {
    @NSApplicationDelegateAdaptor(StayAwakeAppDelegate.self) private var appDelegate
    @StateObject private var powerManager = PowerAssertionManager()
    @StateObject private var launchAtLogin = LaunchAtLogin()

    init() {
        guard AppInstanceLock.acquire() else {
            DuplicateLaunchHandler.handleAlreadyRunning()
        }

        atexit {
            AppInstanceLock.release()
        }
    }

    var body: some Scene {
        MenuBarExtra("StayAwake", systemImage: menuBarIcon) {
            Toggle("Keep Awake (Lid Open)", isOn: $powerManager.isLidOpenAwakeEnabled)
            Toggle("Keep Awake (Lid Closed)", isOn: $powerManager.isLidClosedAwakeEnabled)

            if powerManager.isLidClosedAwakeEnabled {
                Text("Clamshell override: active")
                    .foregroundStyle(.secondary)
                Text("Lid closed runs hot — use with care")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Start at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))

            Divider()

            Button("Quit") {
                powerManager.cleanupOnQuit()
                AppInstanceLock.release()
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarIcon: String {
        if powerManager.isLidOpenAwakeEnabled || powerManager.isLidClosedAwakeEnabled {
            return "cup.and.saucer.fill"
        }
        return "cup.and.saucer"
    }
}
