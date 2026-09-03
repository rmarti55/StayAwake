import AppKit
import Combine

enum StayAwakeNotifications {
    static let reveal = Notification.Name("com.stayawake.app.reveal")
}

final class StayAwakeAppDelegate: NSObject, NSApplicationDelegate {
    private let powerManager = PowerAssertionManager()
    private let launchAtLogin = LaunchAtLogin()
    private var cancellables = Set<AnyCancellable>()
    private var revealObserver: NSObjectProtocol?

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var lidOpenMenuItem: NSMenuItem!
    private var lidClosedMenuItem: NSMenuItem!
    private var clamshellActiveMenuItem: NSMenuItem!
    private var clamshellWarningMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        bindStateChanges()
        registerRevealObserver()
        updateStatusItemIcon()
        updateClamshellMenuItems()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let revealObserver {
            DistributedNotificationCenter.default().removeObserver(revealObserver)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealStatusItem()
        return true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if #available(macOS 14.0, *) {
            statusItem.behavior = []
        }
        statusItem.isVisible = true
        statusItem.button?.toolTip = "StayAwake"
    }

    private func setupMenu() {
        menu = NSMenu()

        lidOpenMenuItem = NSMenuItem(
            title: "Keep Awake (Lid Open)",
            action: #selector(toggleLidOpen(_:)),
            keyEquivalent: ""
        )
        lidOpenMenuItem.target = self
        menu.addItem(lidOpenMenuItem)

        lidClosedMenuItem = NSMenuItem(
            title: "Keep Awake (Lid Closed)",
            action: #selector(toggleLidClosed(_:)),
            keyEquivalent: ""
        )
        lidClosedMenuItem.target = self
        menu.addItem(lidClosedMenuItem)

        clamshellActiveMenuItem = NSMenuItem(
            title: "Clamshell override: active",
            action: nil,
            keyEquivalent: ""
        )
        clamshellActiveMenuItem.isEnabled = false
        menu.addItem(clamshellActiveMenuItem)

        clamshellWarningMenuItem = NSMenuItem(
            title: "Lid closed runs hot — use with care",
            action: nil,
            keyEquivalent: ""
        )
        clamshellWarningMenuItem.isEnabled = false
        let warningFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        clamshellWarningMenuItem.attributedTitle = NSAttributedString(
            string: "Lid closed runs hot — use with care",
            attributes: [.font: warningFont, .foregroundColor: NSColor.secondaryLabelColor]
        )
        menu.addItem(clamshellWarningMenuItem)

        menu.addItem(.separator())

        launchAtLoginMenuItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        syncMenuStates()
    }

    private func bindStateChanges() {
        powerManager.$isLidOpenAwakeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncMenuStates()
                self?.updateStatusItemIcon()
            }
            .store(in: &cancellables)

        powerManager.$isLidClosedAwakeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncMenuStates()
                self?.updateStatusItemIcon()
                self?.updateClamshellMenuItems()
            }
            .store(in: &cancellables)

        launchAtLogin.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncMenuStates()
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
        statusItem.button?.performClick(nil)
    }

    private func syncMenuStates() {
        lidOpenMenuItem.state = powerManager.isLidOpenAwakeEnabled ? .on : .off
        lidClosedMenuItem.state = powerManager.isLidClosedAwakeEnabled ? .on : .off
        launchAtLoginMenuItem.state = launchAtLogin.isEnabled ? .on : .off
    }

    private func updateClamshellMenuItems() {
        let showClamshellInfo = powerManager.isLidClosedAwakeEnabled
        clamshellActiveMenuItem.isHidden = !showClamshellInfo
        clamshellWarningMenuItem.isHidden = !showClamshellInfo
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

    @objc private func toggleLidOpen(_ sender: NSMenuItem) {
        powerManager.isLidOpenAwakeEnabled.toggle()
    }

    @objc private func toggleLidClosed(_ sender: NSMenuItem) {
        powerManager.isLidClosedAwakeEnabled.toggle()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        powerManager.cleanupOnQuit()
        AppInstanceLock.release()
        NSApp.terminate(nil)
    }
}
