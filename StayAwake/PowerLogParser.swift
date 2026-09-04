import Foundation

enum PowerEventKind: String, Codable, Equatable {
    case sleep
    case wake
    case darkWake
    case shutdown
    case restart
}

struct PowerEvent: Codable, Equatable, Identifiable {
    var id: String { "\(kind.rawValue)-\(date.timeIntervalSince1970)" }
    let date: Date
    let kind: PowerEventKind
}

enum PowerLogParser {
    private static let eventLinePattern = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})\s+(Sleep|Wake|DarkWake|Shutdown|Restart)\s+"#,
        options: []
    )

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    private static let eventGrepPattern = #"^\d{4}-.*\t(Sleep|Wake|DarkWake|Shutdown|Restart)[[:space:]]"#
    private static let wakeGrepPattern = #"^\d{4}-.*\tWake[[:space:]]"#
    private static let fetchTimeout: TimeInterval = 15

    static func fetchEvents(since cutoff: Date) -> [PowerEvent] {
        guard let output = runFilteredPmsetLog(grepPattern: eventGrepPattern, tailLines: 5000) else {
            return []
        }
        return parse(log: output, since: cutoff)
    }

    static func fetchLastWake(since bootTime: Date) -> Date? {
        guard let output = runFilteredPmsetLog(grepPattern: wakeGrepPattern, tailLines: 1) else {
            return nil
        }

        return parse(log: output, since: bootTime)
            .last(where: { $0.kind == .wake })?
            .date
    }

    static func parse(log: String, since cutoff: Date) -> [PowerEvent] {
        var events: [PowerEvent] = []

        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineString = String(line)
            let lineRange = NSRange(lineString.startIndex..., in: lineString)
            guard let match = eventLinePattern.firstMatch(in: lineString, range: lineRange) else {
                continue
            }

            guard
                let dateRange = Range(match.range(at: 1), in: lineString),
                let kindRange = Range(match.range(at: 2), in: lineString),
                let date = dateFormatter.date(from: String(lineString[dateRange]))
            else {
                continue
            }

            guard date >= cutoff else { continue }

            let kindToken = String(lineString[kindRange])
            guard let kind = kind(for: kindToken) else { continue }

            events.append(PowerEvent(date: date, kind: kind))
        }

        return events.sorted { $0.date < $1.date }
    }

    private static func kind(for token: String) -> PowerEventKind? {
        switch token {
        case "Sleep":
            return .sleep
        case "Wake":
            return .wake
        case "DarkWake":
            return .darkWake
        case "Shutdown":
            return .shutdown
        case "Restart":
            return .restart
        default:
            return nil
        }
    }

    private static func runFilteredPmsetLog(grepPattern: String, tailLines: Int) -> String? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stayawake-pmset-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let script = """
        /usr/bin/pmset -g log 2>/dev/null | /usr/bin/grep -E '\(grepPattern)' | /usr/bin/tail -\(tailLines) > '\(tempURL.path)'
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        var exitStatus: Int32 = -1

        DispatchQueue.global(qos: .utility).async {
            defer { semaphore.signal() }

            do {
                try process.run()
            } catch {
                print("StayAwake: Failed to run filtered pmset log: \(error)")
                return
            }

            process.waitUntilExit()
            exitStatus = process.terminationStatus
        }

        if semaphore.wait(timeout: .now() + fetchTimeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            print("StayAwake: filtered pmset log timed out after \(Int(fetchTimeout))s")
            return nil
        }

        guard exitStatus == 0 else { return nil }
        return try? String(contentsOf: tempURL, encoding: .utf8)
    }
}
