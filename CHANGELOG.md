# Changelog

All notable changes to StayAwake. Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning: `CFBundleShortVersionString` (marketing) + `CFBundleVersion` / `CURRENT_PROJECT_VERSION` (build).

## [Unreleased]

### Added

- **Sleep failure diagnostics** — `[sleep] blocked:` when StayAwake still holds assertions; `[sleep] assertions:` snapshot from `pmset -g assertions` on each battery retry; one-time notification after 6 failed sleep attempts
- **Verbose log flag** — `defaults write com.stayawake.app stayawake.verboseLog -bool true` for hourly clamshell heartbeat lines (default: state-change only)

### Changed

- **Snooze semantics** — Keep Going snoozes lid-open warnings only; lid-closed silent sleep at the battery limit still runs while snoozed
- **Battery cutoff episode state** — no duplicate silent cutoff lines after `willSleep`; handoff explicitly releases clamshell before `sleepnow`
- Popover shows **Trying to sleep — attempt N** during battery retry; updated snooze copy in dialog and popover

### Added (earlier unreleased)

- **Event-driven diagnostics** — lid, battery drain, AC, thermal state, clamshell override, cutoff skip reasons, and sleep lifecycle (`sleepnow`, `willSleep`, `didWake`) logged to `~/Library/Logs/StayAwake.log`; crash-survivable snapshot at `~/Library/Logs/StayAwake-last-state.json`; launch reconcile distinguishes panic reboot vs missed sleep
- **Sleep verify + retry** — if `pmset sleepnow` does not put the Mac to sleep within 20s, StayAwake logs it and retries up to 3 times per episode
- **Open log** button in the popover (reveals log in Finder)
- **Sleep & Lock** button in the popover — locks the screen, then sleeps immediately
- **Sleep when too hot** — silent `pmset sleepnow` when macOS thermal pressure is Fair, Serious, or Critical; after-wake alert explains why
- Heat row in the popover (Nominal / Fair / Serious / Critical, plus approximate temperature)
- **Menu popover UI** — click the cup icon to open a panel with uptime stats, 24h sleep/wake timeline, and keep-awake toggles
- **Two uptime clocks** — "Up since reboot" (sleep does not reset) and "Awake since sleep" (resets on sleep)
- **Session tracking** — `SessionStore` seeds from `pmset -g log`, records live sleep/wake events, persists to Application Support
- Documentation suite: `README.md`, `docs/TROUBLESHOOTING.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`

### Changed

- **Battery cutoff handoff** — lid-closed silent cutoff drops clamshell override, waits 1.5s, then `sleepnow`; logs `[battery] handoff` lines with clamshell state
- **Battery sleep retry** — persistent retry with 20s → 40s → 60s backoff while still on battery at/under threshold; thermal retries stay capped at 3
- **Thermal sleep is lid-closed only** — with the lid open, StayAwake no longer forces sleep or shows the heat alert; clamshell Serious/Critical (or Fair at ~140°F internal) still sleeps silently
- **Lid-closed heat sleep** — Fair alone no longer sleeps in clamshell mode unless internal sensors read ~140°F (~20% above the prior Fair floor); Serious/Critical still sleep immediately
- Replaced dropdown `NSMenu` with `NSPopover` hosting SwiftUI (`StatusPopoverView`)
- Reveal-on-reopen and duplicate launch now open the popover instead of the old menu

### Fixed

- **Thermal sleep fired with lid open:** heat cutoff and after-wake alert now run only when the lid is closed
- **Silent battery cutoff log spam:** one cutoff decision + one handoff sequence per episode instead of a line on every battery tick
- **Battery drained past cutoff after first sleep request failed:** staged clamshell handoff plus persistent battery retry instead of giving up after three attempts
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
