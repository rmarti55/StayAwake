import Foundation

enum ToggleLogSource: String {
    case user
    case `init`
    case external
}

enum ToggleLogger {
    private static let logURL: URL = {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return logsDir.appendingPathComponent("StayAwake.log")
    }()

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(toggle name: String, from oldValue: Bool, to newValue: Bool, source: ToggleLogSource) {
        guard oldValue != newValue else { return }

        write("\(timestamp()) [\(source.rawValue)] \(name): \(oldValue) -> \(newValue)")
    }

    static func logStartup(toggle name: String, enabled: Bool) {
        write("\(timestamp()) [init] \(name): enabled=\(enabled)")
    }

    static func logBatteryCutoff(percent: Int, threshold: Int) {
        write("\(timestamp()) [battery] battery cutoff: \(percent)% <= \(threshold)% → sleep")
    }

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }

    private static func write(_ message: String) {
        let line = message + "\n"
        print("StayAwake: \(message)")

        guard let data = line.data(using: .utf8) else { return }
        append(data)
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
