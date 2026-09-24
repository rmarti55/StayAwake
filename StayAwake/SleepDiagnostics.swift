import Foundation

enum SleepDiagnostics {
    private static let fetchTimeout: TimeInterval = 2

    static func fetchPowerAssertionsSummary(
        maxLines: Int = 20,
        completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let summary = runPmsetAssertions(maxLines: maxLines)
            DispatchQueue.main.async {
                completion(summary)
            }
        }
    }

    private static func runPmsetAssertions(maxLines: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        var output: String?

        DispatchQueue.global(qos: .utility).async {
            defer { semaphore.signal() }
            do {
                try process.run()
            } catch {
                return
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines)
            let compact = lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            output = compact.isEmpty ? nil : compact
        }

        if semaphore.wait(timeout: .now() + fetchTimeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            return nil
        }

        return output
    }
}
