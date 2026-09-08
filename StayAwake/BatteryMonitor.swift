import Combine
import Foundation
import IOKit.ps

struct BatterySnapshot: Equatable {
    let isOnAC: Bool
    let batteryPercent: Int?
    let hasInternalBattery: Bool
}

final class BatteryMonitor: ObservableObject {
    @Published private(set) var isOnAC = false
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var hasInternalBattery = false

    private var runLoopSource: CFRunLoopSource?

    init() {
        apply(Self.readSnapshot())
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    func refresh() {
        apply(Self.readSnapshot())
    }

    private func apply(_ snapshot: BatterySnapshot) {
        isOnAC = snapshot.isOnAC
        batteryPercent = snapshot.batteryPercent
        hasInternalBattery = snapshot.hasInternalBattery
    }

    private func startMonitoring() {
        guard let runLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.refresh()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            return
        }

        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    private func stopMonitoring() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    private static func readSnapshot() -> BatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [String] else {
            return BatterySnapshot(isOnAC: true, batteryPercent: nil, hasInternalBattery: false)
        }

        var foundInternalBattery = false
        var onAC = true
        var percent: Int?

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source as CFString)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let type = description[kIOPSTypeKey] as? String
            let isPresent = description[kIOPSIsPresentKey] as? Bool ?? false
            guard isPresent else { continue }

            if type == kIOPSInternalBatteryType {
                foundInternalBattery = true

                if let current = description[kIOPSCurrentCapacityKey] as? Int,
                   let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
                   maxCapacity > 0 {
                    percent = min(100, Swift.max(0, (current * 100) / maxCapacity))
                }

                if let powerSource = description[kIOPSPowerSourceStateKey] as? String {
                    onAC = powerSource == kIOPSACPowerValue
                }
            }
        }

        if !foundInternalBattery {
            return BatterySnapshot(isOnAC: true, batteryPercent: nil, hasInternalBattery: false)
        }

        return BatterySnapshot(isOnAC: onAC, batteryPercent: percent, hasInternalBattery: true)
    }
}
