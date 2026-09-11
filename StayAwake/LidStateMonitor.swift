import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit

final class LidStateMonitor: ObservableObject {
    @Published private(set) var isLidClosed = false

    private var workspaceObservers: [NSObjectProtocol] = []
    private var notificationPort: IONotificationPortRef?
    private var clamshellNotification: io_object_t = IO_OBJECT_NULL
    private var pollTimer: Timer?

    private static let pollInterval: TimeInterval = 10
    private static let kIOPMMessageClamshellStateChange: UInt32 = 26
    private static let kClamshellStateBit = 0x1

    init() {
        refresh()
        registerObservers()
        registerClamshellNotification()
        startPolling()
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }

        pollTimer?.invalidate()

        if clamshellNotification != IO_OBJECT_NULL {
            IOObjectRelease(clamshellNotification)
        }

        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
    }

    func refresh() {
        applyIfChanged(Self.readLidClosed())
    }

    private func applyIfChanged(_ closed: Bool) {
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

    private func registerClamshellNotification() {
        guard let notificationPort = IONotificationPortCreate(kIOMainPortDefault) else {
            print("StayAwake: Failed to create IONotificationPort for lid state")
            return
        }

        self.notificationPort = notificationPort
        IONotificationPortSetDispatchQueue(notificationPort, DispatchQueue.main)

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else {
            print("StayAwake: IOPMrootDomain not found for lid state")
            return
        }
        defer { IOObjectRelease(service) }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            notificationPort,
            service,
            kIOGeneralInterest,
            Self.clamshellInterestCallback,
            selfPtr,
            &clamshellNotification
        )

        if result != KERN_SUCCESS {
            print("StayAwake: Failed to register clamshell notification: \(result)")
        }
    }

    private static let clamshellInterestCallback: IOServiceInterestCallback = { refcon, _, messageType, messageArgument in
        guard messageType == kIOPMMessageClamshellStateChange else { return }
        guard let refcon else { return }

        let closed = (Int(bitPattern: messageArgument) & kClamshellStateBit) != 0
        let monitor = Unmanaged<LidStateMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.applyIfChanged(closed)
    }

    private func startPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
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

        for key in ["AppleClamshellClosed", "AppleClamshellState"] {
            guard let value = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() else {
                continue
            }

            if let closed = value as? Bool {
                return closed
            }
            if let closed = value as? Int {
                return closed != 0
            }
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
