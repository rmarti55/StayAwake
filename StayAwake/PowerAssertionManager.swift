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
    private let lidStateMonitor = LidStateMonitor()
    private let thermalMonitor = ThermalMonitor()
    private var isApplyingLocalChange = false
    private var defaultsObserver: NSObjectProtocol?
    private var syncTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var sleepRequestedForCurrentCutoff = false
    private var thermalSleepRequestedForEpisode = false
    private var lastSleepRequestTime: Date?
    private var dialogShownForEpisode = false
    private var batteryCutoffSuspended = false
    private var thermalCutoffSuspended = false

    private static let sleepRequestCooldown: TimeInterval = 10
    private static let snoozeDuration: TimeInterval = 30 * 60

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

    @Published var isThermalSleepEnabled = UserDefaults.standard.object(forKey: Keys.thermalSleepEnabled) as? Bool ?? true {
        didSet {
            guard !isApplyingLocalChange else { return }
            applyThermalSleepChange(from: oldValue, to: isThermalSleepEnabled)
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

    var isLidClosed: Bool {
        lidStateMonitor.isLidClosed
    }

    var thermalStateLabel: String {
        thermalMonitor.stateLabel
    }

    var virtualTemperatureCelsius: Double? {
        thermalMonitor.virtualTemperatureCelsius
    }

    var isBatteryCutoffArmed: Bool {
        isBatteryCutoffConfigured && (isLidClosedAwakeEnabled || isLidOpenAwakeEnabled)
    }

    var isBatteryCutoffActive: Bool {
        batteryCutoffSuspended
    }

    var isThermalCutoffActive: Bool {
        thermalCutoffSuspended
    }

    var isBatteryCutoffSnoozed: Bool {
        let until = UserDefaults.standard.double(forKey: Keys.batteryCutoffSnoozeUntil)
        guard until > 0 else { return false }
        return Date().timeIntervalSince1970 < until
    }

    init() {
        ToggleLogger.logStartup(toggle: "Keep Awake (Lid Open)", enabled: isLidOpenAwakeEnabled)
        ToggleLogger.logStartup(toggle: "Keep Awake (Lid Closed)", enabled: isLidClosedAwakeEnabled)
        ToggleLogger.logStartup(toggle: "Sleep at battery", enabled: batterySleepThreshold != .off)
        ToggleLogger.logStartup(toggle: "Sleep when too hot", enabled: isThermalSleepEnabled)

        bindBatteryMonitor()
        bindLidStateMonitor()
        bindThermalMonitor()
        registerWakeObserver()
        evaluateCutoffs()
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

    func presentPendingThermalAlertIfNeeded() {
        guard UserDefaults.standard.object(forKey: Keys.thermalSleepReason) != nil else { return }

        UserDefaults.standard.removeObject(forKey: Keys.thermalSleepReason)
        UserDefaults.standard.removeObject(forKey: Keys.thermalSleepAt)
        ToggleLogger.logThermalAlertShown()
        ThermalSleepAlert.present()
    }

    private enum Keys {
        static let lidOpenAwake = "stayawake.lidOpenAwake"
        static let lidClosedAwake = "stayawake.lidClosedAwake"
        static let batterySleepThreshold = "stayawake.batterySleepThreshold"
        static let batteryCutoffSnoozeUntil = "stayawake.batteryCutoffSnoozeUntil"
        static let thermalSleepEnabled = "stayawake.thermalSleepEnabled"
        static let thermalSleepReason = "stayawake.thermalSleepReason"
        static let thermalSleepAt = "stayawake.thermalSleepAt"
    }

    private var cutoffSuspended: Bool {
        batteryCutoffSuspended || thermalCutoffSuspended
    }

    private var isBatteryCutoffConfigured: Bool {
        hasInternalBattery && batterySleepThreshold != .off && !isOnAC
    }

    private var isBatteryLow: Bool {
        guard isBatteryCutoffConfigured else { return false }
        guard !isBatteryCutoffSnoozed else { return false }
        guard let percent = batteryPercent else { return false }
        return percent <= batterySleepThreshold.rawValue
    }

    private var shouldUseSilentCutoff: Bool {
        isBatteryLow && isLidClosedAwakeEnabled && lidStateMonitor.isLidClosed
    }

    private var shouldOfferLidOpenCutoff: Bool {
        isBatteryLow && isLidOpenAwakeEnabled && !lidStateMonitor.isLidClosed
    }

    private static func readThermalSleepEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: Keys.thermalSleepEnabled) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: Keys.thermalSleepEnabled)
    }

    private func bindBatteryMonitor() {
        batteryMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.evaluateCutoffs()
            }
            .store(in: &cancellables)
    }

    private func bindLidStateMonitor() {
        lidStateMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.evaluateCutoffs()
            }
            .store(in: &cancellables)
    }

    private func bindThermalMonitor() {
        thermalMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.evaluateCutoffs()
            }
            .store(in: &cancellables)
    }

    private func registerWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lidStateMonitor.refresh()
            if self.lidStateMonitor.isLidClosed && self.isBatteryLow && self.isLidClosedAwakeEnabled {
                self.sleepRequestedForCurrentCutoff = false
            }
            self.thermalSleepRequestedForEpisode = false
            self.presentPendingThermalAlertIfNeeded()
            self.evaluateCutoffs()
        }
    }

    private func evaluateCutoffs() {
        let thermalHot = isThermalSleepEnabled && thermalMonitor.isOverheating
        if thermalHot {
            thermalCutoffSuspended = true
        } else {
            thermalCutoffSuspended = false
            thermalSleepRequestedForEpisode = false
        }

        if !isBatteryLow {
            clearBatteryCutoffEpisode()
        } else if shouldUseSilentCutoff {
            batteryCutoffSuspended = true
        }

        updateAssertions()

        if thermalHot {
            requestThermalSleepNowIfNeeded()
            return
        }

        if shouldUseSilentCutoff {
            requestSleepNowIfNeeded()
            return
        }

        if shouldOfferLidOpenCutoff {
            presentLidOpenCutoffDialogIfNeeded()
        }
    }

    private func presentLidOpenCutoffDialogIfNeeded() {
        guard !dialogShownForEpisode else { return }
        guard let percent = batteryPercent else { return }

        dialogShownForEpisode = true
        let threshold = batterySleepThreshold.rawValue

        BatteryCutoffAlert.present(percent: percent, threshold: threshold) { [weak self] sleepNow in
            guard let self else { return }
            if sleepNow {
                self.batteryCutoffSuspended = true
                self.updateAssertions()
                self.requestSleepNowIfNeeded()
            } else {
                self.snoozeBatteryCutoff()
            }
        }
    }

    private func snoozeBatteryCutoff() {
        let until = Date().timeIntervalSince1970 + Self.snoozeDuration
        UserDefaults.standard.set(until, forKey: Keys.batteryCutoffSnoozeUntil)
        ToggleLogger.logBatteryCutoffSnoozed(minutes: 30)
        clearBatteryCutoffEpisode()
        evaluateCutoffs()
    }

    private func clearBatteryCutoffEpisode() {
        batteryCutoffSuspended = false
        sleepRequestedForCurrentCutoff = false
        dialogShownForEpisode = false
    }

    private func requestSleepNowIfNeeded() {
        if sleepRequestedForCurrentCutoff {
            return
        }

        if let lastSleepRequestTime,
           Date().timeIntervalSince(lastSleepRequestTime) < Self.sleepRequestCooldown {
            return
        }

        guard let percent = batteryPercent else { return }

        sleepRequestedForCurrentCutoff = true
        lastSleepRequestTime = Date()
        ToggleLogger.logBatteryCutoff(
            percent: percent,
            threshold: batterySleepThreshold.rawValue
        )
        requestSleepNow()
    }

    private func requestThermalSleepNowIfNeeded() {
        if thermalSleepRequestedForEpisode {
            return
        }

        if let lastSleepRequestTime,
           Date().timeIntervalSince(lastSleepRequestTime) < Self.sleepRequestCooldown {
            return
        }

        thermalSleepRequestedForEpisode = true
        lastSleepRequestTime = Date()
        persistThermalSleepReason()
        ToggleLogger.logThermalCutoff(state: thermalMonitor.stateLabel)
        requestSleepNow()
    }

    private func persistThermalSleepReason() {
        UserDefaults.standard.set(thermalMonitor.stateLabel.lowercased(), forKey: Keys.thermalSleepReason)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.thermalSleepAt)
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

    private func updateAssertions() {
        updateLidOpenAssertion()
        updateLidClosedAssertion()
    }

    private func applyLocalChange(to key: String, value: Bool, name: String, oldValue: Bool) {
        ToggleLogger.log(toggle: name, from: oldValue, to: value, source: .user)

        isApplyingLocalChange = true
        UserDefaults.standard.set(value, forKey: key)
        isApplyingLocalChange = false

        evaluateCutoffs()
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

        UserDefaults.standard.removeObject(forKey: Keys.batteryCutoffSnoozeUntil)
        clearBatteryCutoffEpisode()
        evaluateCutoffs()
    }

    private func applyThermalSleepChange(from oldValue: Bool, to newValue: Bool) {
        ToggleLogger.log(toggle: "Sleep when too hot", from: oldValue, to: newValue, source: .user)

        isApplyingLocalChange = true
        UserDefaults.standard.set(newValue, forKey: Keys.thermalSleepEnabled)
        isApplyingLocalChange = false

        evaluateCutoffs()
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
        let storedThermal = Self.readThermalSleepEnabled()

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
            UserDefaults.standard.removeObject(forKey: Keys.batteryCutoffSnoozeUntil)
            clearBatteryCutoffEpisode()
            didChange = true
        }

        if storedThermal != isThermalSleepEnabled {
            ToggleLogger.log(
                toggle: "Sleep when too hot",
                from: isThermalSleepEnabled,
                to: storedThermal,
                source: .external
            )
            isApplyingLocalChange = true
            isThermalSleepEnabled = storedThermal
            isApplyingLocalChange = false
            didChange = true
        }

        if didChange {
            evaluateCutoffs()
        }
    }

    private func updateLidOpenAssertion() {
        if isLidOpenAwakeEnabled && !cutoffSuspended {
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
        let shouldEnable = isLidClosedAwakeEnabled && !cutoffSuspended
        clamshellController.setOverrideEnabled(shouldEnable, isOnAC: isOnAC)
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
