import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

final class ClamshellSleepController {
    private let kPMSetClamshellSleepState: UInt32 = 12

    private var idleSystemAssertionID: IOPMAssertionID = 0
    private var heartbeatTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    var isOverrideActive = false

    func setOverrideEnabled(_ enabled: Bool) {
        if enabled {
            applyOverride()
            startHeartbeat()
            registerWakeObserverIfNeeded()
        } else {
            stopHeartbeat()
            removeWakeObserverIfNeeded()
            releaseIdleAssertion()
            restoreClamshellSleepIfNeeded()
            isOverrideActive = false
        }
    }

    func cleanupOnQuit() {
        setOverrideEnabled(false)
    }

    static func clamshellCausesSleep() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellCausesSleep" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool else {
            return nil
        }

        return value
    }

    private func applyOverride() {
        let clamshellResult = setClamshellSleepDisabled(true)
        createIdleAssertion()

        if clamshellResult == kIOReturnSuccess {
            isOverrideActive = true
        } else {
            print("StayAwake: Failed to disable clamshell sleep: \(clamshellResult)")
            isOverrideActive = false
        }
    }

    private func setClamshellSleepDisabled(_ disable: Bool) -> IOReturn {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else {
            print("StayAwake: IOPMrootDomain not found")
            return kIOReturnNotFound
        }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard openResult == KERN_SUCCESS else {
            print("StayAwake: IOServiceOpen failed: \(openResult)")
            return openResult
        }
        defer { IOServiceClose(connection) }

        var input: UInt64 = disable ? 1 : 0
        var outputCount: UInt32 = 0
        return IOConnectCallScalarMethod(
            connection,
            kPMSetClamshellSleepState,
            &input,
            1,
            nil,
            &outputCount
        )
    }

    private func createIdleAssertion() {
        guard idleSystemAssertionID == 0 else { return }

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayAwake: Prevent idle system sleep (lid closed)" as CFString,
            &idleSystemAssertionID
        )

        if result != kIOReturnSuccess {
            idleSystemAssertionID = 0
            print("StayAwake: Failed to create idle assertion (lid closed): \(result)")
        }
    }

    private func releaseIdleAssertion() {
        guard idleSystemAssertionID != 0 else { return }

        let assertionID = idleSystemAssertionID
        idleSystemAssertionID = 0
        let result = IOPMAssertionRelease(assertionID)

        if result != kIOReturnSuccess {
            print("StayAwake: Failed to release idle assertion (lid closed): \(result)")
        }
    }

    private func restoreClamshellSleepIfNeeded() {
        if isOfficialClamshellModeActive() {
            return
        }

        let result = setClamshellSleepDisabled(false)
        if result != kIOReturnSuccess {
            print("StayAwake: Failed to re-enable clamshell sleep: \(result)")
        }
    }

    private func isOfficialClamshellModeActive() -> Bool {
        hasExternalDisplay() && isOnACPower()
    }

    private func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return false
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return false
        }

        return displays.contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private func isOnACPower() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return false
        }

        return output.contains("AC Power")
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.applyOverride()
        }
        if let heartbeatTimer {
            RunLoop.main.add(heartbeatTimer, forMode: .common)
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func registerWakeObserverIfNeeded() {
        guard wakeObserver == nil else { return }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyOverride()
        }
    }

    private func removeWakeObserverIfNeeded() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    deinit {
        setOverrideEnabled(false)
    }
}
