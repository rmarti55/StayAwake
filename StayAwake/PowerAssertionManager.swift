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
    private var willSleepObserver: NSObjectProtocol?
    private var screensSleepObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var sleepRequestedForCurrentCutoff = false
    private var thermalSleepRequestedForEpisode = false
    private var lastSleepRequestTime: Date?
    private var dialogShownForEpisode = false
    private var batteryCutoffSuspended = false
    private var thermalCutoffSuspended = false
    private var sleepVerifyTimer: Timer?
    private var sleepVerifyAttempt = 0
    private var pendingSleepReason = "unknown"
    private var silentCutoffLoggedForEpisode = false
    private var batteryHandoffScheduled = false
    private var batteryHandoffWorkItem: DispatchWorkItem?
    private var manualSleepSuspended = false
    private var manualSleepRestoreWorkItem: DispatchWorkItem?
    private var lastLoggedBatteryPercent: Int?
    private var lastLoggedIsOnAC: Bool?
    private var lastLoggedThermalState: String?
    private var lastLoggedLidClosed: Bool?
    private var lastLoggedCutoffSkipReason: String?

    private static let sleepRequestCooldown: TimeInterval = 10
    private static let snoozeDuration: TimeInterval = 30 * 60
    private static let sleepVerifyInterval: TimeInterval = 20
    private static let maxThermalSleepVerifyAttempts = 3
    private static let batteryHandoffDelay: TimeInterval = 1.5
    private static let maxBatterySleepVerifyInterval: TimeInterval = 60
    private static let userSleepLockDelay: TimeInterval = 0.3
    private static let userSleepRestoreDelay: TimeInterval = 5

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

    var virtualTemperatureFahrenheit: Double? {
        thermalMonitor.virtualTemperatureFahrenheit
    }

    var batteryTemperatureFahrenheit: Double? {
        thermalMonitor.batteryTemperatureFahrenheit
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
        lastLoggedBatteryPercent = batteryMonitor.batteryPercent
        lastLoggedIsOnAC = batteryMonitor.isOnAC
        lastLoggedThermalState = thermalMonitor.stateLabel
        lastLoggedLidClosed = lidStateMonitor.isLidClosed

        ToggleLogger.reconcileOnLaunch(currentSnapshot: diagnosticSnapshot())
        ToggleLogger.logStartup(toggle: "Keep Awake (Lid Open)", enabled: isLidOpenAwakeEnabled)
        ToggleLogger.logStartup(toggle: "Keep Awake (Lid Closed)", enabled: isLidClosedAwakeEnabled)
        ToggleLogger.logStartup(toggle: "Sleep at battery", enabled: batterySleepThreshold != .off)
        ToggleLogger.logStartup(toggle: "Sleep when too hot", enabled: isThermalSleepEnabled)

        bindBatteryMonitor()
        bindLidStateMonitor()
        bindThermalMonitor()
        registerSleepObservers()
        evaluateCutoffs()
        registerDefaultsObserver()
        startSyncTimer()
    }

    func sleepAndLockNow() {
        if isClamshellOverrideActive {
            manualSleepSuspended = true
            updateAssertions()
            scheduleManualSleepRestore()
        }

        if !ScreenLock.lock() {
            print("StayAwake: Failed to lock screen")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.userSleepLockDelay) { [weak self] in
            self?.requestSleepNow(reason: "user", verify: false)
        }
    }

    func cleanupOnQuit() {
        cancelSleepVerifyTimer()
        cancelBatteryHandoff()
        cancelManualSleepRestore()

        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }

        let center = NSWorkspace.shared.notificationCenter
        if let wakeObserver {
            center.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let willSleepObserver {
            center.removeObserver(willSleepObserver)
            self.willSleepObserver = nil
        }
        if let screensSleepObserver {
            center.removeObserver(screensSleepObserver)
            self.screensSleepObserver = nil
        }

        stopSyncTimer()
        cancellables.removeAll()

        clamshellController.cleanupOnQuit()
        releaseAssertion(id: &idleSystemAssertionID)
        releaseAssertion(id: &idleDisplayAssertionID)
    }

    func presentPendingThermalAlertIfNeeded() {
        guard UserDefaults.standard.object(forKey: Keys.thermalSleepReason) != nil else { return }

        let wasLidClosedSleep = UserDefaults.standard.bool(forKey: Keys.thermalSleepLidClosed)
        clearPendingThermalSleepState()

        guard wasLidClosedSleep else { return }

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
        static let thermalSleepLidClosed = "stayawake.thermalSleepLidClosed"
    }

    private var cutoffSuspended: Bool {
        batteryCutoffSuspended || thermalCutoffSuspended || manualSleepSuspended
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

    private func diagnosticSnapshot(
        cutoffKind: String? = nil,
        sleepRequested: Bool? = nil
    ) -> DiagnosticSnapshot {
        let resolvedCutoff: String?
        if let cutoffKind {
            resolvedCutoff = cutoffKind
        } else if thermalCutoffSuspended {
            resolvedCutoff = "thermal"
        } else if batteryCutoffSuspended {
            resolvedCutoff = "battery"
        } else {
            resolvedCutoff = nil
        }

        let thermalTemp: String?
        if let virtual = virtualTemperatureFahrenheit {
            if let battery = batteryTemperatureFahrenheit, abs(battery - virtual) >= 5 {
                thermalTemp = String(format: "%.0f-%.0f", battery, virtual)
            } else {
                thermalTemp = String(format: "%.0f", virtual)
            }
        } else {
            thermalTemp = nil
        }

        return DiagnosticSnapshot(
            bootTime: ToggleLogger.readBootTime(),
            batteryPercent: batteryPercent,
            isOnAC: isOnAC,
            lidClosed: lidStateMonitor.isLidClosed,
            openAwake: isLidOpenAwakeEnabled,
            closedAwake: isLidClosedAwakeEnabled,
            threshold: batterySleepThreshold.rawValue,
            thermalState: thermalStateLabel,
            thermalTempF: thermalTemp,
            clamshellOverride: isClamshellOverrideActive,
            cutoffKind: resolvedCutoff,
            sleepRequested: sleepRequested ?? (sleepRequestedForCurrentCutoff || thermalSleepRequestedForEpisode)
        )
    }

    private func bindBatteryMonitor() {
        batteryMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.logPowerChangesIfNeeded()
                self.objectWillChange.send()
                self.evaluateCutoffs()
            }
            .store(in: &cancellables)
    }

    private func bindLidStateMonitor() {
        lidStateMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.logLidChangeIfNeeded()
                self.objectWillChange.send()
                self.evaluateCutoffs()
            }
            .store(in: &cancellables)
    }

    private func bindThermalMonitor() {
        thermalMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.logThermalChangeIfNeeded()
                self.objectWillChange.send()
                self.evaluateCutoffs()
            }
            .store(in: &cancellables)
    }

    private func logPowerChangesIfNeeded() {
        let snapshot = diagnosticSnapshot()

        if let lastAC = lastLoggedIsOnAC, lastAC != isOnAC {
            ToggleLogger.logACChange(onAC: isOnAC, snapshot: snapshot)
            lastLoggedCutoffSkipReason = nil
        }
        lastLoggedIsOnAC = isOnAC

        guard let percent = batteryPercent else { return }
        guard !isOnAC else {
            lastLoggedBatteryPercent = percent
            return
        }

        let threshold = batterySleepThreshold.rawValue
        let nearCutoff = threshold > 0 && percent <= threshold + 5
        let lidClosed = lidStateMonitor.isLidClosed
        let percentChanged = lastLoggedBatteryPercent != percent

        if percentChanged && (lidClosed || nearCutoff) {
            ToggleLogger.logBatteryChange(
                from: lastLoggedBatteryPercent,
                to: percent,
                snapshot: snapshot
            )
            lastLoggedCutoffSkipReason = nil
        }

        lastLoggedBatteryPercent = percent
    }

    private func logLidChangeIfNeeded() {
        let closed = lidStateMonitor.isLidClosed
        guard lastLoggedLidClosed != closed else { return }

        ToggleLogger.logLid(closed: closed, snapshot: diagnosticSnapshot())
        lastLoggedLidClosed = closed
        lastLoggedCutoffSkipReason = nil
    }

    private func logThermalChangeIfNeeded() {
        let state = thermalStateLabel
        guard lastLoggedThermalState != state else { return }

        let oldState = lastLoggedThermalState ?? "unknown"
        ToggleLogger.logThermalStateChange(
            from: oldState,
            to: state,
            snapshot: diagnosticSnapshot()
        )
        lastLoggedThermalState = state
    }

    private func registerSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter

        willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cancelSleepVerifyTimer()
            self.cancelBatteryHandoff()
            self.cancelManualSleepRestore()
            self.silentCutoffLoggedForEpisode = false
            ToggleLogger.logWillSleep(snapshot: self.diagnosticSnapshot())
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cancelSleepVerifyTimer()
            self.cancelManualSleepRestore()
            self.manualSleepSuspended = false
            self.sleepVerifyAttempt = 0
            ToggleLogger.logDidWake(snapshot: self.diagnosticSnapshot())
            self.lidStateMonitor.refresh()
            self.lastLoggedLidClosed = self.lidStateMonitor.isLidClosed
            if self.lidStateMonitor.isLidClosed && self.isBatteryLow && self.isLidClosedAwakeEnabled {
                self.sleepRequestedForCurrentCutoff = false
                self.lastLoggedCutoffSkipReason = nil
            }
            self.thermalSleepRequestedForEpisode = false
            self.presentPendingThermalAlertIfNeeded()
            self.evaluateCutoffs()
        }

        screensSleepObserver = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ToggleLogger.logScreensDidSleep(snapshot: self.diagnosticSnapshot())
        }
    }

    private func evaluateCutoffs() {
        lidStateMonitor.refresh()

        let lidClosed = lidStateMonitor.isLidClosed
        let thermalHot = isThermalSleepEnabled
            && lidClosed
            && thermalMonitor.isOverheating(lidClosed: true)

        if thermalHot {
            thermalCutoffSuspended = true
        } else {
            thermalCutoffSuspended = false
            thermalSleepRequestedForEpisode = false
            if !lidClosed {
                clearPendingThermalSleepState()
            }
        }

        if !isBatteryLow {
            clearBatteryCutoffEpisode()
        } else if shouldUseSilentCutoff {
            batteryCutoffSuspended = true
        }

        updateAssertions()

        if thermalHot {
            requestThermalSleepNowIfNeeded()
            logBatteryCutoffSkipIfNeeded()
            return
        }

        if shouldUseSilentCutoff {
            takeSilentBatteryCutoff()
            return
        }

        if shouldOfferLidOpenCutoff {
            presentLidOpenCutoffDialogIfNeeded()
            return
        }

        logBatteryCutoffSkipIfNeeded()
    }

    private func logBatteryCutoffSkipIfNeeded() {
        guard isBatteryLow || (batteryPercent != nil && isBatteryCutoffSnoozed) else {
            lastLoggedCutoffSkipReason = nil
            return
        }

        let reason: String?
        if isBatteryCutoffSnoozed {
            reason = "snoozed for 30 minutes"
        } else if sleepRequestedForCurrentCutoff {
            reason = "sleep already requested at \(batterySleepThreshold.label)"
        } else if !isLidClosedAwakeEnabled && !isLidOpenAwakeEnabled {
            reason = "no keep-awake mode enabled"
        } else if lidStateMonitor.isLidClosed && !isLidClosedAwakeEnabled && isLidOpenAwakeEnabled {
            reason = "lid closed but only lid-open keep-awake is on (dialog path inactive)"
        } else if !lidStateMonitor.isLidClosed && !isLidOpenAwakeEnabled && isLidClosedAwakeEnabled {
            reason = "lid open but only lid-closed keep-awake is on"
        } else if dialogShownForEpisode {
            reason = "lid-open dialog already shown for this episode"
        } else if let lastSleepRequestTime,
                  Date().timeIntervalSince(lastSleepRequestTime) < Self.sleepRequestCooldown {
            reason = "sleep request cooldown active"
        } else {
            reason = nil
        }

        guard let reason, reason != lastLoggedCutoffSkipReason else { return }

        ToggleLogger.logCutoffSkipped(reason: reason, snapshot: diagnosticSnapshot())
        lastLoggedCutoffSkipReason = reason
    }

    private func takeSilentBatteryCutoff() {
        guard !batteryHandoffScheduled else { return }

        BatteryCutoffAlert.dismissIfPresent()
        batteryCutoffSuspended = true
        updateAssertions()

        if silentCutoffLoggedForEpisode {
            return
        }

        silentCutoffLoggedForEpisode = true

        if let percent = batteryPercent {
            ToggleLogger.logBatteryCutoffDecision(
                path: "silent",
                percent: percent,
                threshold: batterySleepThreshold.rawValue,
                lidClosed: lidStateMonitor.isLidClosed
            )
            ToggleLogger.persistState(
                event: "battery-cutoff-silent",
                snapshot: diagnosticSnapshot(cutoffKind: "battery", sleepRequested: true)
            )
        }

        scheduleBatterySleepHandoff()
    }

    private func scheduleBatterySleepHandoff() {
        cancelBatteryHandoff()
        batteryHandoffScheduled = true

        let snapshot = diagnosticSnapshot(cutoffKind: "battery", sleepRequested: true)
        ToggleLogger.logBatteryHandoff(
            clamshellCausesSleep: ClamshellSleepController.clamshellCausesSleep(),
            delaySeconds: Self.batteryHandoffDelay,
            snapshot: snapshot
        )

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.batteryHandoffScheduled = false
            self.batteryHandoffWorkItem = nil

            ToggleLogger.logBatteryHandoffReady(
                clamshellCausesSleep: ClamshellSleepController.clamshellCausesSleep(),
                snapshot: self.diagnosticSnapshot(cutoffKind: "battery", sleepRequested: true)
            )
            self.requestSleepNowIfNeeded(reason: "battery cutoff silent")
        }
        batteryHandoffWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.batteryHandoffDelay, execute: work)
    }

    private func cancelBatteryHandoff() {
        batteryHandoffWorkItem?.cancel()
        batteryHandoffWorkItem = nil
        batteryHandoffScheduled = false
    }

    private func scheduleManualSleepRestore() {
        cancelManualSleepRestore()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.manualSleepSuspended else { return }
            self.manualSleepSuspended = false
            self.manualSleepRestoreWorkItem = nil
            self.updateAssertions()
        }
        manualSleepRestoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.userSleepRestoreDelay, execute: work)
    }

    private func cancelManualSleepRestore() {
        manualSleepRestoreWorkItem?.cancel()
        manualSleepRestoreWorkItem = nil
    }

    private func presentLidOpenCutoffDialogIfNeeded() {
        lidStateMonitor.refresh()

        if shouldUseSilentCutoff {
            takeSilentBatteryCutoff()
            return
        }

        guard shouldOfferLidOpenCutoff else { return }
        guard !dialogShownForEpisode else { return }
        guard let percent = batteryPercent else { return }

        dialogShownForEpisode = true
        let threshold = batterySleepThreshold.rawValue

        ToggleLogger.logBatteryCutoffDecision(
            path: "dialog",
            percent: percent,
            threshold: threshold,
            lidClosed: lidStateMonitor.isLidClosed
        )

        BatteryCutoffAlert.present(percent: percent, threshold: threshold) { [weak self] sleepNow in
            guard let self else { return }
            if sleepNow {
                self.batteryCutoffSuspended = true
                self.updateAssertions()
                ToggleLogger.persistState(
                    event: "battery-cutoff-dialog-sleep",
                    snapshot: self.diagnosticSnapshot(cutoffKind: "battery", sleepRequested: true)
                )
                self.requestSleepNowIfNeeded(reason: "battery cutoff dialog")
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
        silentCutoffLoggedForEpisode = false
        sleepVerifyAttempt = 0
        cancelSleepVerifyTimer()
        cancelBatteryHandoff()
        lastLoggedCutoffSkipReason = nil
    }

    private func requestSleepNowIfNeeded(reason: String) {
        if sleepRequestedForCurrentCutoff {
            logBatteryCutoffSkipIfNeeded()
            return
        }

        if let lastSleepRequestTime,
           Date().timeIntervalSince(lastSleepRequestTime) < Self.sleepRequestCooldown {
            ToggleLogger.logCutoffSkipped(
                reason: "sleep request cooldown active",
                snapshot: diagnosticSnapshot()
            )
            return
        }

        guard batteryPercent != nil || reason.contains("thermal") else { return }

        sleepRequestedForCurrentCutoff = true
        lastSleepRequestTime = Date()
        pendingSleepReason = reason

        if let percent = batteryPercent, sleepVerifyAttempt == 0 {
            ToggleLogger.logBatteryCutoff(
                percent: percent,
                threshold: batterySleepThreshold.rawValue
            )
        }

        requestSleepNow(reason: reason)
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
        pendingSleepReason = "thermal cutoff"
        persistThermalSleepReason()
        ToggleLogger.logThermalCutoff(state: thermalMonitor.stateLabel)
        ToggleLogger.persistState(
            event: "thermal-cutoff",
            snapshot: diagnosticSnapshot(cutoffKind: "thermal", sleepRequested: true)
        )
        requestSleepNow(reason: "thermal cutoff")
    }

    private func persistThermalSleepReason() {
        UserDefaults.standard.set(thermalMonitor.stateLabel.lowercased(), forKey: Keys.thermalSleepReason)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.thermalSleepAt)
        UserDefaults.standard.set(true, forKey: Keys.thermalSleepLidClosed)
    }

    private func clearPendingThermalSleepState() {
        UserDefaults.standard.removeObject(forKey: Keys.thermalSleepReason)
        UserDefaults.standard.removeObject(forKey: Keys.thermalSleepAt)
        UserDefaults.standard.removeObject(forKey: Keys.thermalSleepLidClosed)
    }

    private func requestSleepNow(reason: String, verify: Bool = true) {
        let cutoffKind: String
        if reason.contains("thermal") {
            cutoffKind = "thermal"
        } else if reason == "user" {
            cutoffKind = "user"
        } else {
            cutoffKind = "battery"
        }

        let snapshot = diagnosticSnapshot(
            cutoffKind: cutoffKind,
            sleepRequested: true
        )
        ToggleLogger.persistState(event: "sleepnow", snapshot: snapshot)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]

        do {
            try process.run()
            ToggleLogger.logSleepNowSpawned(success: true, reason: reason, snapshot: snapshot)
            if verify {
                scheduleSleepVerifyTimer(isBattery: isBatterySleepReason(reason))
            }
        } catch {
            ToggleLogger.logSleepNowSpawned(success: false, reason: reason, snapshot: snapshot)
            print("StayAwake: Failed to request sleep: \(error)")
            sleepRequestedForCurrentCutoff = false
            thermalSleepRequestedForEpisode = false
        }
    }

    private func isBatterySleepReason(_ reason: String) -> Bool {
        reason.contains("battery")
    }

    private func batterySleepVerifyInterval() -> TimeInterval {
        switch sleepVerifyAttempt {
        case 0, 1:
            return Self.sleepVerifyInterval
        case 2:
            return 40
        default:
            return Self.maxBatterySleepVerifyInterval
        }
    }

    private func scheduleSleepVerifyTimer(isBattery: Bool) {
        cancelSleepVerifyTimer()

        sleepVerifyAttempt += 1
        let interval = isBattery ? batterySleepVerifyInterval() : Self.sleepVerifyInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleSleepVerifyTimeout(isBattery: isBattery)
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepVerifyTimer = timer
    }

    private func cancelSleepVerifyTimer() {
        sleepVerifyTimer?.invalidate()
        sleepVerifyTimer = nil
    }

    private func handleSleepVerifyTimeout(isBattery: Bool) {
        sleepVerifyTimer = nil

        let snapshot = diagnosticSnapshot()

        if isBattery {
            ToggleLogger.logBatterySleepVerifyTimeout(attempt: sleepVerifyAttempt, snapshot: snapshot)

            guard shouldUseSilentCutoff || (isBatteryLow && batteryCutoffSuspended) else { return }

            sleepRequestedForCurrentCutoff = false
            lastSleepRequestTime = nil
            lastLoggedCutoffSkipReason = nil
            scheduleBatterySleepHandoff()
            return
        }

        ToggleLogger.logSleepVerifyTimeout(
            attempt: sleepVerifyAttempt,
            maxAttempts: Self.maxThermalSleepVerifyAttempts,
            snapshot: snapshot
        )

        guard sleepVerifyAttempt < Self.maxThermalSleepVerifyAttempts else { return }

        guard thermalCutoffSuspended && isThermalSleepEnabled else { return }

        sleepRequestedForCurrentCutoff = false
        thermalSleepRequestedForEpisode = false
        lastSleepRequestTime = nil
        lastLoggedCutoffSkipReason = nil

        requestSleepNow(reason: "\(pendingSleepReason) retry \(sleepVerifyAttempt)")
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
        if isLidOpenAwakeEnabled && !cutoffSuspended && !lidStateMonitor.isLidClosed {
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
