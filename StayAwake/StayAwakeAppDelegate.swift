import AppKit
import Combine
import SwiftUI

enum StayAwakeNotifications {
    static let reveal = Notification.Name("com.stayawake.app.reveal")
}

final class StayAwakeAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let statusItemAutosaveName = "StayAwakeStatusItem"
    /// Distance from the screen's right edge; lower = further right.
    private static let preferredPosition: Double = 0
    private static let menuBarIconPointSize: CGFloat = 16
    private static let menuBarIconDimension: CGFloat = 18

    private let powerManager = PowerAssertionManager()
    private let launchAtLogin = LaunchAtLogin()
    private let sessionStore = SessionStore()
    private var cancellables = Set<AnyCancellable>()
    private var revealObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverHostingController: NSHostingController<StatusPopoverView>!
    private var outsideClickMonitor: Any?
    private var hasLoggedMenuBarVisibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        bindStateChanges()
        registerRevealObserver()
        registerAppearanceObserver()
        updateStatusItemIcon()

        DispatchQueue.main.async { [weak self] in
            self?.verifyStatusItemVisibility()
            self?.powerManager.presentPendingThermalAlertIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeOutsideClickMonitor()
        sessionStore.stopLiveUpdates()
        if let revealObserver {
            DistributedNotificationCenter.default().removeObserver(revealObserver)
        }
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealStatusItem()
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        sessionStore.stopLiveUpdates()
        updateStatusItemIcon()
    }

    private func setupStatusItem() {
        pinStatusItemPosition()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.statusItemAutosaveName
        if #available(macOS 14.0, *) {
            statusItem.behavior = []
        }
        statusItem.isVisible = true
        statusItem.button?.toolTip = "StayAwake"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.imageScaling = .scaleProportionallyDown
    }

    private func pinStatusItemPosition() {
        let positionKey = "NSStatusItem Preferred Position \(Self.statusItemAutosaveName)"
        let visibleKey = "NSStatusItem Visible \(Self.statusItemAutosaveName)"

        UserDefaults.standard.set(Self.preferredPosition, forKey: positionKey)

        if let controlCenterDefaults = UserDefaults(suiteName: "com.apple.controlcenter") {
            controlCenterDefaults.set(Self.preferredPosition, forKey: positionKey)
            controlCenterDefaults.set(true, forKey: visibleKey)
        }
    }

    private func recreateStatusItem() {
        if let existingItem = statusItem {
            NSStatusBar.system.removeStatusItem(existingItem)
        }
        pinStatusItemPosition()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.statusItemAutosaveName
        if #available(macOS 14.0, *) {
            statusItem.behavior = []
        }
        statusItem.isVisible = true
        statusItem.button?.toolTip = "StayAwake"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.imageScaling = .scaleProportionallyDown
        updateStatusItemIcon()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self

        let contentView = StatusPopoverView(
            sessionStore: sessionStore,
            powerManager: powerManager,
            launchAtLogin: launchAtLogin,
            onSleepAndLock: { [weak self] in
                self?.sleepAndLock()
            },
            onQuit: { [weak self] in
                self?.quit()
            }
        )

        popoverHostingController = NSHostingController(rootView: contentView)
        popover.contentViewController = popoverHostingController
    }

    private func bindStateChanges() {
        powerManager.$isLidOpenAwakeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemIcon()
            }
            .store(in: &cancellables)

        powerManager.$isLidClosedAwakeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemIcon()
            }
            .store(in: &cancellables)
    }

    private func registerRevealObserver() {
        revealObserver = DistributedNotificationCenter.default().addObserver(
            forName: StayAwakeNotifications.reveal,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.revealStatusItem()
        }
    }

    private func registerAppearanceObserver() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusItemIcon()
        }
    }

    private func revealStatusItem() {
        statusItem.isVisible = true
        updateStatusItemIcon()
        showPopover()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        installOutsideClickMonitor()
        sessionStore.startLiveUpdates()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopoverIfClickedOutside()
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func closePopoverIfClickedOutside() {
        guard popover.isShown else { return }

        let clickLocation = NSEvent.mouseLocation
        if isClickOnStatusItem(at: clickLocation) {
            return
        }

        popover.performClose(nil)
    }

    private func isClickOnStatusItem(at screenLocation: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }

        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonFrame.contains(screenLocation)
    }

    private func verifyStatusItemVisibility() {
        logMenuBarVisibilityIfNeeded()

        guard isStatusItemLikelyHiddenInMenuBar() else { return }

        recreateStatusItem()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.logMenuBarVisibilityIfNeeded(force: true)
        }
    }

    private func statusItemButtonFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func notchGap(on screen: NSScreen) -> NSRect? {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return nil
        }

        let gapMinX = leftArea.maxX
        let gapMaxX = rightArea.minX
        guard gapMaxX > gapMinX else { return nil }

        return NSRect(x: gapMinX, y: 0, width: gapMaxX - gapMinX, height: screen.frame.height)
    }

    private func logMenuBarVisibilityIfNeeded(force: Bool = false) {
        guard force || !hasLoggedMenuBarVisibility else { return }
        guard let frame = statusItemButtonFrame() else { return }

        if !force {
            hasLoggedMenuBarVisibility = true
        }

        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let notch = screen.flatMap { notchGap(on: $0) }
        let notchRange = notch.map { "\(Int($0.minX))..\(Int($0.maxX))" }
        let likelyHidden = isStatusItemLikelyHiddenInMenuBar()

        ToggleLogger.logMenuBarVisibility(
            itemFrame: frame,
            notchRange: notchRange,
            visible: !likelyHidden,
            blocked: likelyHidden
        )
    }

    /// On macOS 26+, Control Center hosts the on-screen icon. The app's own status-item
    /// window is not occluded/positioned like the visible icon, so only treat clearly
    /// parked windows (below the menu bar) as hidden — never show an alert for this.
    private func isStatusItemLikelyHiddenInMenuBar() -> Bool {
        guard statusItem.isVisible, let button = statusItem.button, let window = button.window else {
            return true
        }

        let frame = statusItemButtonFrame() ?? window.frame
        return frame.origin.y < 0
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem.button else { return }

        let filled = powerManager.isLidOpenAwakeEnabled || powerManager.isLidClosedAwakeEnabled

        if let image = makeMenuBarIcon(filled: filled) {
            button.title = ""
            button.image = image
        } else {
            button.title = ""
            button.image = makeFallbackCupIcon(filled: filled)
        }
    }

    private func makeMenuBarIcon(filled: Bool) -> NSImage? {
        let symbolName = filled ? "cup.and.saucer.fill" : "cup.and.saucer"
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "StayAwake") else {
            return nil
        }

        let config = NSImage.SymbolConfiguration(pointSize: Self.menuBarIconPointSize, weight: .medium)
            .applying(.preferringMonochrome())
        guard let configured = base.withSymbolConfiguration(config) else {
            return nil
        }

        configured.isTemplate = true
        configured.size = NSSize(width: Self.menuBarIconDimension, height: Self.menuBarIconDimension)
        return configured
    }

    private func makeFallbackCupIcon(filled: Bool) -> NSImage {
        let dimension = Self.menuBarIconDimension
        let image = NSImage(size: NSSize(width: dimension, height: dimension))
        image.lockFocus()

        NSColor.black.setStroke()
        NSColor.black.setFill()

        let saucer = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: dimension - 2, height: 5))
        if filled {
            saucer.fill()
        } else {
            saucer.lineWidth = 1.5
            saucer.stroke()
        }

        let cup = NSBezierPath(
            roundedRect: NSRect(x: 5, y: 6, width: dimension - 10, height: dimension - 7),
            xRadius: 2,
            yRadius: 2
        )
        if filled {
            cup.fill()
        } else {
            cup.lineWidth = 1.5
            cup.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        image.size = NSSize(width: dimension, height: dimension)
        return image
    }

    private func sleepAndLock() {
        popover.performClose(nil)
        powerManager.sleepAndLockNow()
    }

    private func quit() {
        popover.performClose(nil)
        powerManager.cleanupOnQuit()
        AppInstanceLock.release()
        NSApp.terminate(nil)
    }
}
