import Foundation
import IOKit.pwr_mgt

final class PowerAssertionManager: ObservableObject {
    private var idleSystemAssertionID: IOPMAssertionID = 0
    private var idleDisplayAssertionID: IOPMAssertionID = 0
    private let clamshellController = ClamshellSleepController()
    private var isApplyingLocalChange = false
    private var defaultsObserver: NSObjectProtocol?
    private var syncTimer: Timer?

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

    var isClamshellOverrideActive: Bool {
        clamshellController.isOverrideActive
    }

    init() {
        ToggleLogger.logStartup(toggle: "Keep Awake (Lid Open)", enabled: isLidOpenAwakeEnabled)
        ToggleLogger.logStartup(toggle: "Keep Awake (Lid Closed)", enabled: isLidClosedAwakeEnabled)

        updateLidOpenAssertion()
        updateLidClosedAssertion()
        registerDefaultsObserver()
        startSyncTimer()
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

    func cleanupOnQuit() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }

        stopSyncTimer()

        clamshellController.cleanupOnQuit()
        releaseAssertion(id: &idleSystemAssertionID)
        releaseAssertion(id: &idleDisplayAssertionID)
    }

    private enum Keys {
        static let lidOpenAwake = "stayawake.lidOpenAwake"
        static let lidClosedAwake = "stayawake.lidClosedAwake"
    }

    private func applyLocalChange(to key: String, value: Bool, name: String, oldValue: Bool) {
        ToggleLogger.log(toggle: name, from: oldValue, to: value, source: .user)

        isApplyingLocalChange = true
        UserDefaults.standard.set(value, forKey: key)
        isApplyingLocalChange = false

        if key == Keys.lidOpenAwake {
            updateLidOpenAssertion()
        } else if key == Keys.lidClosedAwake {
            updateLidClosedAssertion()
        }
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
            updateLidOpenAssertion()
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
            updateLidClosedAssertion()
        }
    }

    private func updateLidOpenAssertion() {
        if isLidOpenAwakeEnabled {
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
        clamshellController.setOverrideEnabled(isLidClosedAwakeEnabled)
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
