import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit

final class LidStateMonitor: ObservableObject {
    @Published private(set) var isLidClosed = false

    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        refresh()
        registerObservers()
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func refresh() {
        let closed = Self.readLidClosed()
        guard closed != isLidClosed else { return }
        isLidClosed = closed
    }

    private func registerObservers() {
        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        )

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        )

        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        )
    }

    private static func readLidClosed() -> Bool {
        if let clamshellClosed = readClamshellClosedFromRegistry() {
            return clamshellClosed
        }
        return !hasOnlineBuiltInDisplay()
    }

    private static func readClamshellClosedFromRegistry() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellClosed" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }

        if let closed = value as? Bool {
            return closed
        }
        if let closed = value as? Int {
            return closed != 0
        }
        return nil
    }

    private static func hasOnlineBuiltInDisplay() -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return false
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return false
        }

        return displays.contains { CGDisplayIsBuiltin($0) != 0 }
    }
}
