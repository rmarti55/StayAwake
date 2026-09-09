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

    private enum Keys {
        static let type = "Type"
        static let isPresent = "Is Present"
        static let currentCapacity = "Current Capacity"
        static let maxCapacity = "Max Capacity"
        static let powerSourceState = "Power Source State"
        static let internalBattery = "InternalBattery"
        static let acPower = "AC Power"
    }

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
        guard snapshot != BatterySnapshot(
            isOnAC: isOnAC,
            batteryPercent: batteryPercent,
            hasInternalBattery: hasInternalBattery
        ) else {
            return
        }

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
        if let snapshot = readSnapshotFromIOKit(), snapshot.hasInternalBattery {
            return snapshot
        }
        return readSnapshotFromPmset()
    }

    private static func readSnapshotFromIOKit() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else {
            return nil
        }

        var foundInternalBattery = false
        var onAC = true
        var percent: Int?

        let count = CFArrayGetCount(sourceList)
        for index in 0..<count {
            let value = CFArrayGetValueAtIndex(sourceList, index)
            let item = Unmanaged<CFTypeRef>.fromOpaque(value!).takeUnretainedValue()

            let description: [String: Any]?
            if let sourceID = item as? String {
                description = IOPSGetPowerSourceDescription(info, sourceID as CFString)?
                    .takeUnretainedValue() as? [String: Any]
            } else {
                description = item as? [String: Any]
            }

            guard let description,
                  parsePresent(description),
                  parseType(description) == Keys.internalBattery else {
                continue
            }

            foundInternalBattery = true
            percent = parsePercent(description) ?? percent
            onAC = parseOnAC(description)
        }

        guard foundInternalBattery else {
            return nil
        }

        return BatterySnapshot(isOnAC: onAC, batteryPercent: percent, hasInternalBattery: true)
    }

    private static func readSnapshotFromPmset() -> BatterySnapshot {
        guard let output = runPmsetBatteryOutput() else {
            return BatterySnapshot(isOnAC: true, batteryPercent: nil, hasInternalBattery: false)
        }

        let hasInternalBattery = output.contains("InternalBattery")
        guard hasInternalBattery else {
            return BatterySnapshot(isOnAC: true, batteryPercent: nil, hasInternalBattery: false)
        }

        let isOnAC = output.contains("AC Power")
        let percent = parsePercentFromPmset(output)

        return BatterySnapshot(isOnAC: isOnAC, batteryPercent: percent, hasInternalBattery: true)
    }

    private static func runPmsetBatteryOutput() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func parsePresent(_ description: [String: Any]) -> Bool {
        if let isPresent = description[Keys.isPresent] as? Bool {
            return isPresent
        }
        if let isPresent = description[Keys.isPresent] as? Int {
            return isPresent != 0
        }
        return false
    }

    private static func parseType(_ description: [String: Any]) -> String? {
        description[Keys.type] as? String
    }

    private static func parsePercent(_ description: [String: Any]) -> Int? {
        if let current = description[Keys.currentCapacity] as? Int {
            if let maxCapacity = description[Keys.maxCapacity] as? Int, maxCapacity > 0, maxCapacity <= 100 {
                return min(100, Swift.max(0, current))
            }
            if let maxCapacity = description[Keys.maxCapacity] as? Int, maxCapacity > 100 {
                return min(100, Swift.max(0, (current * 100) / maxCapacity))
            }
            return min(100, Swift.max(0, current))
        }
        return nil
    }

    private static func parseOnAC(_ description: [String: Any]) -> Bool {
        guard let powerSource = description[Keys.powerSourceState] as? String else {
            return false
        }
        return powerSource == Keys.acPower
    }

    private static func parsePercentFromPmset(_ output: String) -> Int? {
        guard let percentRange = output.range(of: #"\d+%"#, options: .regularExpression) else {
            return nil
        }
        let token = output[percentRange].dropLast()
        return Int(token)
    }
}
