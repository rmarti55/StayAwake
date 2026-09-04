import AppKit
import Combine
import SwiftUI

enum StayAwakeNotifications {
    static let reveal = Notification.Name("com.stayawake.app.reveal")
}

final class StayAwakeAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let powerManager = PowerAssertionManager()
    private let launchAtLogin = LaunchAtLogin()
    private let sessionStore = SessionStore()
    private var cancellables = Set<AnyCancellable>()
    private var revealObserver: NSObjectProtocol?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverHostingController: NSHostingController<StatusPopoverView>!
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        bindStateChanges()
        registerRevealObserver()
        updateStatusItemIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeOutsideClickMonitor()
        sessionStore.stopLiveUpdates()
        if let revealObserver {
            DistributedNotificationCenter.default().removeObserver(revealObserver)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealStatusItem()
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        sessionStore.stopLiveUpdates()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if #available(macOS 14.0, *) {
            statusItem.behavior = []
        }
        statusItem.isVisible = true
        statusItem.button?.toolTip = "StayAwake"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
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

    private func revealStatusItem() {
        statusItem.isVisible = true
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

    private func updateStatusItemIcon() {
        let symbolName: String
        if powerManager.isLidOpenAwakeEnabled || powerManager.isLidClosedAwakeEnabled {
            symbolName = "cup.and.saucer.fill"
        } else {
            symbolName = "cup.and.saucer"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "StayAwake") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
    }

    private func quit() {
        popover.performClose(nil)
        powerManager.cleanupOnQuit()
        AppInstanceLock.release()
        NSApp.terminate(nil)
    }
}
