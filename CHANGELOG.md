# Changelog

All notable changes to StayAwake. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning: `CFBundleShortVersionString` (marketing) + `CFBundleVersion` / `CURRENT_PROJECT_VERSION` (build).

## [Unreleased]

### Added

- **Sleep when too hot** — silent `pmset sleepnow` when macOS thermal pressure is Fair, Serious, or Critical; after-wake alert explains why
- Heat row in the popover (Nominal / Fair / Serious / Critical, plus approximate temperature)
- **Menu popover UI** — click the cup icon to open a panel with uptime stats, 24h sleep/wake timeline, and keep-awake toggles
- **Two uptime clocks** — "Up since reboot" (sleep does not reset) and "Awake since sleep" (resets on sleep)
- **Session tracking** — `SessionStore` seeds from `pmset -g log`, records live sleep/wake events, persists to Application Support
- Documentation suite: `README.md`, `docs/TROUBLESHOOTING.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`

### Changed

- Replaced dropdown `NSMenu` with `NSPopover` hosting SwiftUI (`StatusPopoverView`)
- Reveal-on-reopen and duplicate launch now open the popover instead of the old menu

### Fixed

- **Lid-closed battery sleep showed a modal and drained past 5%:** lid state was stale while clamshell keep-awake held the Mac up; lid is now polled and subscribed via IOPM, re-read before every cutoff, and silent sleep wins over the dialog when the lid is closed
- **Heat at Fair (~117°F) did not sleep:** Fair now counts as too hot, not only Serious/Critical
- **Lid-open keep-awake ran with the lid closed:** idle/display assertions now apply only when the lid is actually open
- **StayAwake pegged at ~99% CPU:** clamshell override was re-applied on every battery/lid tick, and monitors published even when nothing changed — a self-feeding IOKit loop. Override and heartbeat are now idempotent; monitors publish only on real changes
- **Sleep clock and timeline wrong after launch:** pmset full-log seed often timed out, leaving `events.json` empty; now uses filtered `grep | tail` pipeline (~3s), quick last-wake fallback, popover retry, and safe persistence

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
