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
2. Click the cup to open the menu.
3. If you don't see the cup, click **StayAwake** in Applications — that reveals the icon and opens the menu.

### Menu options

| Option | What it does |
|---|---|
| **Keep Awake (Lid Open)** | Prevents idle system and display sleep while the lid is open |
| **Keep Awake (Lid Closed)** | Disables clamshell sleep so the Mac stays awake with the lid shut (runs hot — use with care) |
| **Start at Login** | Registers StayAwake to launch at login via `SMAppService` |
| **Quit** | Releases power assertions and exits |

Toggle states persist across relaunch in UserDefaults.

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
