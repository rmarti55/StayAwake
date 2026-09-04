# Changelog

All notable changes to StayAwake. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning: `CFBundleShortVersionString` (marketing) + `CFBundleVersion` / `CURRENT_PROJECT_VERSION` (build).

## [Unreleased]

### Added

- **Menu popover UI** — click the cup icon to open a panel with uptime stats, 24h sleep/wake timeline, and keep-awake toggles
- **Two uptime clocks** — "Up since reboot" (sleep does not reset) and "Awake since sleep" (resets on sleep)
- **Session tracking** — `SessionStore` seeds from `pmset -g log`, records live sleep/wake events, persists to Application Support
- Documentation suite: `README.md`, `docs/TROUBLESHOOTING.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`

### Changed

- Replaced dropdown `NSMenu` with `NSPopover` hosting SwiftUI (`StatusPopoverView`)
- Reveal-on-reopen and duplicate launch now open the popover instead of the old menu

## [1.0] — build 2 — 2026-09-03

### Fixed

- **Invisible app:** Replaced SwiftUI `MenuBarExtra` with AppKit `NSStatusItem` + `NSMenu` so the cup icon does not vanish
- **Duplicate launch dead end:** Removed "already running" alert; second launch now posts a reveal notification and exits
- **Click app to interact:** Running instance reveals status item and opens menu on reveal notification and `applicationShouldHandleReopen`
- **Icon drag-off:** Set `statusItem.behavior = []` (macOS 14+) so the icon cannot be removed from the bar

### Removed

- First-launch alert and activation-policy flip (`.regular` ↔ `.accessory`) that could break menu bar visibility

## [1.0] — build 1 — 2026-08-26

### Added

- Initial macOS menu bar app
- **Keep Awake (Lid Open)** — IOKit idle system and display sleep assertions
- **Keep Awake (Lid Closed)** — clamshell override via `AppleClamshellCausesSleep`
- **Start at Login** — `SMAppService.mainApp`
- Single-instance lock (`AppInstanceLock` with `flock`)
- Toggle logging to `~/Library/Logs/StayAwake.log`
- Coffee cup app icon generation (`scripts/generate-app-icon.swift`)
- Install script (`scripts/install.sh`) — build, icon fix, copy to `/Applications`
- Lid-closed test helper (`scripts/lid-test.sh`)
