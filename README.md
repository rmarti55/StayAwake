# StayAwake

Personal macOS menu bar utility that prevents sleep — with the lid open or closed.

## What it is

StayAwake lives in the **menu bar** (cup icon, top-right). It is **not** a normal window app: there is no Dock icon and no main window. That is intentional.

## Install

From the repo root:

```bash
./scripts/install.sh
```

This builds Release, copies to `/Applications/StayAwake.app`, and launches it.

Requirements: Xcode command-line tools (`xcodebuild`, `iconutil`).

## Daily use

1. Look for the **cup icon** in the menu bar (filled when a keep-awake mode is on).
2. Click the cup to open the **popover panel**.
3. If you don't see the cup, click **StayAwake** in Applications — that reveals the icon and opens the panel.

### Popover

| Section | What it shows |
|---|---|
| **Up since reboot** | Time since last boot (`kern.boottime`). Sleep does **not** reset this. |
| **Awake since sleep** | Time since the last full wake. Sleep **does** reset this. |
| **Last 24 hours** | A bar of awake (accent) vs asleep (gray) stretches over the past day |
| **Heat** | macOS thermal pressure (Nominal / Fair / Serious / Critical) and approximate temperature |
| **Keep Awake toggles** | Lid-open / lid-closed controls, plus **Sleep when too hot** |
| **Start at Login** | Registers StayAwake to launch at login via `SMAppService` |
| **Quit** | Releases power assertions and exits |

The two clocks are different: a Mac that slept overnight can still show days of reboot uptime while "awake since sleep" shows only the current stretch.

Toggle states persist across relaunch in UserDefaults. Sleep/wake history is persisted at `~/Library/Application Support/StayAwake/events.json`.

## Rebuild after code changes

Same command as install:

```bash
./scripts/install.sh
```

If **Start at Login** is enabled, toggle it off and on once in the menu after reinstall so macOS registers the `/Applications` path.

## Logs

Toggle changes are written to:

```
~/Library/Logs/StayAwake.log
```

Watch live:

```bash
tail -f ~/Library/Logs/StayAwake.log
```

## More docs

- [Troubleshooting](docs/TROUBLESHOOTING.md) — invisible app, already running, force quit, login item issues
- [Architecture](docs/ARCHITECTURE.md) — how launch, menu bar, and sleep prevention work
- [Changelog](CHANGELOG.md) — version history

## Lid-closed testing

Optional test helper for verifying clamshell override:

```bash
./scripts/lid-test.sh before   # snapshot, then close lid ~5 min
./scripts/lid-test.sh after    # snapshot after reopening
```

Results go to `test-results/` (gitignored).
