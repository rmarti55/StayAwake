import AppKit
import Combine
import SwiftUI

enum StayAwakeNotifications {
    static let reveal = Notification.Name("com.stayawake.app.reveal")
}

final class StayAwakeAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let statusItemAutosaveName = "StayAwakeStatusItem"
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
    private var hasAttemptedStatusItemRecovery = false
    private var hasShownBlockedAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        bindStateChanges()
        registerRevealObserver()
        registerAppearanceObserver()
        updateStatusItemIcon()

        DispatchQueue.main.async { [weak self] in
            self?.verifyStatusItemVisibility()
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

    private func recreateStatusItem() {
        if let existingItem = statusItem {
            NSStatusBar.system.removeStatusItem(existingItem)
        }
        setupStatusItem()
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

        if isStatusItemParkedOrBlocked() {
            verifyStatusItemVisibility()
            guard !isStatusItemParkedOrBlocked() else { return }
        }

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
        guard isStatusItemParkedOrBlocked() else { return }

        if !hasAttemptedStatusItemRecovery {
            hasAttemptedStatusItemRecovery = true
            recreateStatusItem()

            DispatchQueue.main.async { [weak self] in
                self?.finishStatusItemVisibilityCheck()
            }
            return
        }

        showMenuBarBlockedAlertIfNeeded()
    }

    private func finishStatusItemVisibilityCheck() {
        if isStatusItemParkedOrBlocked() {
            showMenuBarBlockedAlertIfNeeded()
        }
    }

    private func isStatusItemParkedOrBlocked() -> Bool {
        guard statusItem.isVisible, let button = statusItem.button else { return true }

        guard let window = button.window else { return true }

        if window.screen == nil {
            return true
        }

        let frame = window.frame
        if frame.origin.y < 0 {
            return true
        }

        if frame.height > 0, frame.height <= 22 {
            return true
        }

        return false
    }

    private func showMenuBarBlockedAlertIfNeeded() {
        guard !hasShownBlockedAlert else { return }
        hasShownBlockedAlert = true

        let alert = NSAlert()
        alert.messageText = "StayAwake menu bar icon is hidden"
        alert.informativeText = """
        macOS Control Center is blocking or hiding the StayAwake cup icon.

        Open System Settings → Menu Bar and make sure StayAwake is allowed.
        If the icon still does not appear, scroll to the bottom of Menu Bar settings and choose "Reset Control Center…".
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Menu Bar Settings")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            openMenuBarSettings()
        }
    }

    private func openMenuBarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
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

    private func quit() {
        popover.performClose(nil)
        powerManager.cleanupOnQuit()
        AppInstanceLock.release()
        NSApp.terminate(nil)
    }
}
