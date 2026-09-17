import AppKit
import Foundation

enum ToggleLogSource: String {
    case user
    case `init`
    case external
}

struct DiagnosticSnapshot: Codable, Equatable {
    let bootTime: TimeInterval
    let batteryPercent: Int?
    let isOnAC: Bool
    let lidClosed: Bool
    let openAwake: Bool
    let closedAwake: Bool
    let threshold: Int
    let thermalState: String
    let thermalTempF: String?
    let clamshellOverride: Bool
    let cutoffKind: String?
    let sleepRequested: Bool

    func compactDescription() -> String {
        let battery = batteryPercent.map { "\($0)%" } ?? "unknown"
        let ac = isOnAC ? "true" : "false"
        let lid = lidClosed ? "closed" : "open"
        let open = openAwake ? "on" : "off"
        let closed = closedAwake ? "on" : "off"
        let thresholdLabel = threshold == 0 ? "off" : "\(threshold)"
        let thermal = thermalTempF.map { "\(thermalState) ~\($0)F" } ?? thermalState
        let clamshell = clamshellOverride ? "on" : "off"
        let cutoff = cutoffKind ?? "none"
        let sleep = sleepRequested ? "true" : "false"

        return "battery=\(battery) ac=\(ac) lid=\(lid) openAwake=\(open) closedAwake=\(closed) " +
            "threshold=\(thresholdLabel) thermal=\(thermal) clamshell=\(clamshell) cutoff=\(cutoff) " +
            "sleepRequested=\(sleep)"
    }
}

private struct PersistedDiagnosticState: Codable {
    let savedAt: TimeInterval
    let bootTime: TimeInterval
    let event: String
    let snapshot: DiagnosticSnapshot
}

enum ToggleLogger {
    private static let logURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("StayAwake.log")
    }()

    private static let stateURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("StayAwake-last-state.json")
    }()

    private static let maxLogBytes = 2 * 1024 * 1024

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func readBootTime() -> TimeInterval {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        let result = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        guard result == 0 else { return 0 }
        return TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000
    }

    static func reconcileOnLaunch(currentSnapshot: DiagnosticSnapshot) {
        write("\(timestamp()) [init] launch | \(currentSnapshot.compactDescription())")

        guard let persisted = loadPersistedState() else { return }

        let sameBoot = abs(persisted.bootTime - currentSnapshot.bootTime) < 1
        let sleepEvents: Set<String> = ["sleepnow", "willSleep", "sleepnow-spawned"]
        let lastWasSleep = sleepEvents.contains(persisted.event)
            || persisted.event.hasSuffix("cutoff")
            || persisted.event.hasSuffix("cutoff-silent")

        if sameBoot {
            write(
                "\(timestamp()) [init] reconcile: same boot, last event=\(persisted.event) " +
                "| \(currentSnapshot.compactDescription())"
            )
        } else if lastWasSleep {
            write(
                "\(timestamp()) [init] reconcile: reboot during sleep/wake " +
                "(last=\(persisted.event)) | \(currentSnapshot.compactDescription())"
            )
        } else {
            write(
                "\(timestamp()) [init] reconcile: new boot since last event=\(persisted.event) " +
                "| \(currentSnapshot.compactDescription())"
            )
        }
    }

    static func persistState(event: String, snapshot: DiagnosticSnapshot) {
        let state = PersistedDiagnosticState(
            savedAt: Date().timeIntervalSince1970,
            bootTime: snapshot.bootTime,
            event: event,
            snapshot: snapshot
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    static func log(toggle name: String, from oldValue: Bool, to newValue: Bool, source: ToggleLogSource) {
        guard oldValue != newValue else { return }
        write("\(timestamp()) [\(source.rawValue)] \(name): \(oldValue) -> \(newValue)")
    }

    static func logStartup(toggle name: String, enabled: Bool) {
        write("\(timestamp()) [init] \(name): enabled=\(enabled)")
    }

    static func logLid(closed: Bool, snapshot: DiagnosticSnapshot) {
        let state = closed ? "closed" : "open"
        write("\(timestamp()) [lid] lid \(state) | \(snapshot.compactDescription())")
        persistState(event: closed ? "lid-closed" : "lid-open", snapshot: snapshot)
    }

    static func logBatteryChange(from oldPercent: Int?, to newPercent: Int?, snapshot: DiagnosticSnapshot) {
        let fromLabel = oldPercent.map { "\($0)%" } ?? "unknown"
        let toLabel = newPercent.map { "\($0)%" } ?? "unknown"
        write("\(timestamp()) [power] battery \(fromLabel) -> \(toLabel) | \(snapshot.compactDescription())")
    }

    static func logACChange(onAC: Bool, snapshot: DiagnosticSnapshot) {
        let state = onAC ? "plugged in" : "on battery"
        write("\(timestamp()) [power] AC \(state) | \(snapshot.compactDescription())")
    }

    static func logThermalStateChange(from oldState: String, to newState: String, snapshot: DiagnosticSnapshot) {
        write(
            "\(timestamp()) [thermal] \(oldState) -> \(newState) | \(snapshot.compactDescription())"
        )
    }

    static func logClamshellOverride(enabled: Bool, success: Bool, iokitResult: Int32? = nil) {
        let state = enabled ? "on" : "off"
        let ok = success ? "ok" : "failed"
        let result = iokitResult.map { " iokit=\($0)" } ?? ""
        write("\(timestamp()) [power] clamshell override \(state) \(ok)\(result)")
    }

    static func logCutoffSkipped(reason: String, snapshot: DiagnosticSnapshot) {
        write("\(timestamp()) [battery] cutoff skipped: \(reason) | \(snapshot.compactDescription())")
    }

    static func logBatteryCutoff(percent: Int, threshold: Int) {
        write("\(timestamp()) [battery] battery cutoff: \(percent)% <= \(threshold)% → sleep")
    }

    static func logBatteryCutoffDecision(path: String, percent: Int, threshold: Int, lidClosed: Bool) {
        write(
            "\(timestamp()) [battery] battery cutoff \(path): \(percent)% <= \(threshold)%, " +
            "lidClosed=\(lidClosed)"
        )
    }

    static func logBatteryCutoffSnoozed(minutes: Int) {
        write("\(timestamp()) [battery] battery cutoff snoozed for \(minutes) minutes")
    }

    static func logThermalCutoff(state: String) {
        write("\(timestamp()) [thermal] thermal cutoff: \(state) → sleep")
    }

    static func logThermalAlertShown() {
        write("\(timestamp()) [thermal] showed after-wake heat alert")
    }

    static func logSleepNowSpawned(success: Bool, reason: String, snapshot: DiagnosticSnapshot) {
        let status = success ? "spawned" : "spawn failed"
        write("\(timestamp()) [sleep] sleepnow \(status) (\(reason)) | \(snapshot.compactDescription())")
        persistState(event: success ? "sleepnow-spawned" : "sleepnow-failed", snapshot: snapshot)
    }

    static func logWillSleep(snapshot: DiagnosticSnapshot) {
        write("\(timestamp()) [sleep] willSleep | \(snapshot.compactDescription())")
        persistState(event: "willSleep", snapshot: snapshot)
    }

    static func logDidWake(snapshot: DiagnosticSnapshot) {
        write("\(timestamp()) [sleep] didWake | \(snapshot.compactDescription())")
        persistState(event: "didWake", snapshot: snapshot)
    }

    static func logScreensDidSleep(snapshot: DiagnosticSnapshot) {
        write("\(timestamp()) [sleep] screensDidSleep | \(snapshot.compactDescription())")
    }

    static func logSleepVerifyTimeout(attempt: Int, snapshot: DiagnosticSnapshot) {
        write(
            "\(timestamp()) [sleep] sleepnow issued but still awake " +
            "(attempt \(attempt)/3) | \(snapshot.compactDescription())"
        )
    }

    static func logMenuBarVisibility(
        itemFrame: NSRect,
        notchRange: String?,
        visible: Bool,
        blocked: Bool
    ) {
        let notch = notchRange ?? "none"
        write(
            "\(timestamp()) [menubar] item x=\(Int(itemFrame.minX))..\(Int(itemFrame.maxX)), " +
            "notch=\(notch), visible=\(visible), blocked=\(blocked)"
        )
    }

    static func openLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    private static func loadPersistedState() -> PersistedDiagnosticState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(PersistedDiagnosticState.self, from: data)
    }

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }

    private static func write(_ message: String) {
        let line = message + "\n"
        print("StayAwake: \(message)")

        guard let data = line.data(using: .utf8) else { return }
        trimLogIfNeeded()
        append(data)
    }

    private static func trimLogIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int,
              size > maxLogBytes else {
            return
        }

        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let keepFrom = lines.count / 2
        let trimmed = lines.dropFirst(keepFrom).joined(separator: "\n")
        let output = trimmed.hasSuffix("\n") ? trimmed : trimmed + "\n"
        try? output.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private static func append(_ data: Data) {
        let fileManager = FileManager.default
        let directory = logURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
