import SwiftUI

@main
struct StayAwakeApp: App {
    @NSApplicationDelegateAdaptor(StayAwakeAppDelegate.self) private var appDelegate

    init() {
        guard AppInstanceLock.acquire() else {
            DuplicateLaunchHandler.handleAlreadyRunning()
        }

        atexit {
            AppInstanceLock.release()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
