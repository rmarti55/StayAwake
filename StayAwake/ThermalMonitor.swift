import Combine
import Foundation
import IOKit

final class ThermalMonitor: ObservableObject {
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var virtualTemperatureFahrenheit: Double?
    @Published private(set) var batteryTemperatureFahrenheit: Double?

    var isOverheating: Bool {
        thermalState == .serious || thermalState == .critical
    }

    var stateLabel: String {
        Self.label(for: thermalState)
    }

    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?

    private static let pollInterval: TimeInterval = 15

    init() {
        refresh()
        registerObserver()
        startPolling()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        pollTimer?.invalidate()
    }

    func refresh() {
        let nextState = ProcessInfo.processInfo.thermalState
        let temps = Self.readBatteryTemperatures()

        if nextState != thermalState {
            thermalState = nextState
        }
        if temps.battery != batteryTemperatureFahrenheit {
            batteryTemperatureFahrenheit = temps.battery
        }
        if temps.virtual != virtualTemperatureFahrenheit {
            virtualTemperatureFahrenheit = temps.virtual
        }
    }

    static func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }

    private func registerObserver() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    private func startPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private static func readBatteryTemperatures() -> (battery: Double?, virtual: Double?) {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else {
            return (nil, nil)
        }
        defer { IOObjectRelease(service) }

        return (
            fahrenheit(from: service, key: "Temperature"),
            fahrenheit(from: service, key: "VirtualTemperature")
        )
    }

    private static func fahrenheit(from service: io_object_t, key: String) -> Double? {
        guard let celsius = celsius(from: service, key: key) else {
            return nil
        }
        return celsiusToFahrenheit(celsius)
    }

    private static func celsius(from service: io_object_t, key: String) -> Double? {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }

        if let centi = value as? Int {
            return Double(centi) / 100
        }
        if let centi = value as? Double {
            return centi / 100
        }
        return nil
    }

    private static func celsiusToFahrenheit(_ celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }
}
