import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

enum BatterySleepThreshold: Int, CaseIterable, Identifiable {
    case off = 0
    case five = 5
    case ten = 10
    case twenty = 20

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off:
            return "Off"
        default:
            return "\(rawValue)%"
        }
    }

    static func from(storedValue: Int) -> BatterySleepThreshold {
        BatterySleepThreshold(rawValue: storedValue) ?? .off
    }
}

final class PowerAssertionManager: ObservableObject {
    private var idleSystemAssertionID: IOPMAssertionID = 0
    private var idleDisplayAssertionID: IOPMAssertionID = 0
    private let clamshellController = ClamshellSleepController()
    private let batteryMonitor = BatteryMonitor()
    private var isApplyingLocalChange = false
    private var defaultsObserver: NSObjectProtocol?
    private var syncTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var sleepRequestedForCurrentCutoff = false

    @Published var isLidOpenAwakeEnabled = UserDefaults.standard.bool(forKey: Keys.lidOpenAwake) {
        didSet {
            guard !isApplyingLocalChange else { return }
            applyLocalChange(to: Keys.lidOpenAwake, value: isLidOpenAwakeEnabled, name: "Keep Awake (Lid Open)", oldValue: oldValue)
        }
    }

    @Published var isLidClosedAwakeEnabled = UserDefaults.standard.bool(forKey: Keys.lidClosedAwake) {
        didSet {
            guard !isApplyingLocalChange else { return }
            applyLocalChange(to: Keys.lidClosedAwake, value: isLidClosedAwakeEnabled, name: "Keep Awake (Lid Closed)", oldValue: oldValue)
        }
    }

    @Published var batterySleepThreshold = BatterySleepThreshold.from(
        storedValue: UserDefaults.standard.integer(forKey: Keys.batterySleepThreshold)
    ) {
        didSet {
            guard !isApplyingLocalChange else { return }
            applyThresholdChange(from: oldValue, to: batterySleepThreshold)
        }
    }

    var isClamshellOverrideActive: Bool {
        clamshellController.isOverrideActive
    }

    var isOnAC: Bool {
        batteryMonitor.isOnAC
    }

    var batteryPercent: Int? {
        batteryMonitor.batteryPercent
    }

    var hasInternalBattery: Bool {
        batteryMonitor.hasInternalBattery
    }

    var isBatteryCutoffArmed: Bool {
        isKeepAwakeEnabled && hasInternalBattery && batterySleepThreshold != .off
    }

    var isBatteryCutoffActive: Bool {
        shouldSuspendForBatteryCutoff
    }

    init() {
        ToggleLogger.logStartup(toggle: "Keep Awake (Lid Open)", enabled: isLidOpenAwakeEnabled)
        ToggleLogger.logStartup(toggle: "Keep Awake (Lid Closed)", enabled: isLidClosedAwakeEnabled)
        ToggleLogger.logStartup(toggle: "Sleep at battery", enabled: batterySleepThreshold != .off)

        bindBatteryMonitor()
        registerWakeObserver()
        evaluateBatteryCutoff()
        registerDefaultsObserver()
        startSyncTimer()
    }

    func cleanupOnQuit() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        stopSyncTimer()
        cancellables.removeAll()

        clamshellController.cleanupOnQuit()
        releaseAssertion(id: &idleSystemAssertionID)
        releaseAssertion(id: &idleDisplayAssertionID)
    }

    private enum Keys {
        static let lidOpenAwake = "stayawake.lidOpenAwake"
        static let lidClosedAwake = "stayawake.lidClosedAwake"
        static let batterySleepThreshold = "stayawake.batterySleepThreshold"
    }

    private var isKeepAwakeEnabled: Bool {
        isLidOpenAwakeEnabled || isLidClosedAwakeEnabled
    }

    private var shouldSuspendForBatteryCutoff: Bool {
        guard isKeepAwakeEnabled else { return false }
        guard hasInternalBattery else { return false }
        guard batterySleepThreshold != .off else { return false }
        guard !isOnAC else { return false }
        guard let percent = batteryPercent else { return false }
        return percent <= batterySleepThreshold.rawValue
    }

    private func bindBatteryMonitor() {
        batteryMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.evaluateBatteryCutoff()
            }
            .store(in: &cancellables)
    }

    private func registerWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sleepRequestedForCurrentCutoff = false
            self?.evaluateBatteryCutoff()
        }
    }

    private func evaluateBatteryCutoff() {
        if shouldSuspendForBatteryCutoff {
            updateLidOpenAssertion()
            updateLidClosedAssertion()

            if !sleepRequestedForCurrentCutoff,
               let percent = batteryPercent {
                sleepRequestedForCurrentCutoff = true
                ToggleLogger.logBatteryCutoff(
                    percent: percent,
                    threshold: batterySleepThreshold.rawValue
                )
                requestSleepNow()
            }
            return
        }

        sleepRequestedForCurrentCutoff = false
        updateLidOpenAssertion()
        updateLidClosedAssertion()
    }

    private func requestSleepNow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]

        do {
            try process.run()
        } catch {
            print("StayAwake: Failed to request sleep: \(error)")
        }
    }

    private func applyLocalChange(to key: String, value: Bool, name: String, oldValue: Bool) {
        ToggleLogger.log(toggle: name, from: oldValue, to: value, source: .user)

        isApplyingLocalChange = true
        UserDefaults.standard.set(value, forKey: key)
        isApplyingLocalChange = false

        evaluateBatteryCutoff()
    }

    private func applyThresholdChange(from oldValue: BatterySleepThreshold, to newValue: BatterySleepThreshold) {
        ToggleLogger.log(
            toggle: "Sleep at battery",
            from: oldValue != .off,
            to: newValue != .off,
            source: .user
        )

        isApplyingLocalChange = true
        UserDefaults.standard.set(newValue.rawValue, forKey: Keys.batterySleepThreshold)
        isApplyingLocalChange = false

        sleepRequestedForCurrentCutoff = false
        evaluateBatteryCutoff()
    }

    private func startSyncTimer() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.syncFromExternalDefaultsIfNeeded()
        }
        if let syncTimer {
            RunLoop.main.add(syncTimer, forMode: .common)
        }
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func registerDefaultsObserver() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncFromExternalDefaultsIfNeeded()
        }
    }

    private func syncFromExternalDefaultsIfNeeded() {
        guard !isApplyingLocalChange else { return }

        let storedLidOpen = UserDefaults.standard.bool(forKey: Keys.lidOpenAwake)
        let storedLidClosed = UserDefaults.standard.bool(forKey: Keys.lidClosedAwake)
        let storedThreshold = BatterySleepThreshold.from(
            storedValue: UserDefaults.standard.integer(forKey: Keys.batterySleepThreshold)
        )

        var didChange = false

        if storedLidOpen != isLidOpenAwakeEnabled {
            ToggleLogger.log(
                toggle: "Keep Awake (Lid Open)",
                from: isLidOpenAwakeEnabled,
                to: storedLidOpen,
                source: .external
            )
            isApplyingLocalChange = true
            isLidOpenAwakeEnabled = storedLidOpen
            isApplyingLocalChange = false
            didChange = true
        }

        if storedLidClosed != isLidClosedAwakeEnabled {
            ToggleLogger.log(
                toggle: "Keep Awake (Lid Closed)",
                from: isLidClosedAwakeEnabled,
                to: storedLidClosed,
                source: .external
            )
            isApplyingLocalChange = true
            isLidClosedAwakeEnabled = storedLidClosed
            isApplyingLocalChange = false
            didChange = true
        }

        if storedThreshold != batterySleepThreshold {
            ToggleLogger.log(
                toggle: "Sleep at battery",
                from: batterySleepThreshold != .off,
                to: storedThreshold != .off,
                source: .external
            )
            isApplyingLocalChange = true
            batterySleepThreshold = storedThreshold
            isApplyingLocalChange = false
            sleepRequestedForCurrentCutoff = false
            didChange = true
        }

        if didChange {
            evaluateBatteryCutoff()
        }
    }

    private func updateLidOpenAssertion() {
        if isLidOpenAwakeEnabled && !shouldSuspendForBatteryCutoff {
            createAssertion(
                type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                id: &idleSystemAssertionID,
                reason: "StayAwake: Prevent idle system sleep (lid open)"
            )
            createAssertion(
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                id: &idleDisplayAssertionID,
                reason: "StayAwake: Prevent idle display sleep (lid open)"
            )
        } else {
            releaseAssertion(id: &idleSystemAssertionID)
            releaseAssertion(id: &idleDisplayAssertionID)
        }
    }

    private func updateLidClosedAssertion() {
        let shouldEnable = isLidClosedAwakeEnabled && !shouldSuspendForBatteryCutoff
        clamshellController.setOverrideEnabled(shouldEnable)
    }

    private func createAssertion(
        type: String,
        id: inout IOPMAssertionID,
        reason: String
    ) {
        guard id == 0 else { return }

        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )

        if result != kIOReturnSuccess {
            id = 0
            print("StayAwake: Failed to create assertion (\(type)): \(result)")
        }
    }

    private func releaseAssertion(id: inout IOPMAssertionID) {
        guard id != 0 else { return }

        let assertionID = id
        id = 0
        let result = IOPMAssertionRelease(assertionID)

        if result != kIOReturnSuccess {
            print("StayAwake: Failed to release assertion: \(result)")
        }
    }

    deinit {
        cleanupOnQuit()
    }
}
