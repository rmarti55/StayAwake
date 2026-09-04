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

    static func fetchEvents(since cutoff: Date) -> [PowerEvent] {
        guard let output = runPmsetLog() else { return [] }
        return parse(log: output, since: cutoff)
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

    private static func runPmsetLog() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            print("StayAwake: Failed to run pmset -g log: \(error)")
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
