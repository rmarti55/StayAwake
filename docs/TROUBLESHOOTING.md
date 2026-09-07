# Troubleshooting

Personal cheat sheet for when StayAwake feels broken or invisible.

## Quick commands

```bash
pgrep -l StayAwake                    # is it running?
killall StayAwake                     # force quit
open /Applications/StayAwake.app      # launch or reveal popover
tail -f ~/Library/Logs/StayAwake.log  # watch toggle log
defaults read com.stayawake.app       # read persisted toggles
```

## Symptom → cause → fix

### Clicked StayAwake in Applications, nothing happened

**Cause:** Menu-bar-only app (`LSUIElement = true`). No Dock icon, no window.

**Fix:**
1. Look for the **cup icon** in the menu bar (top-right, near WiFi/battery/time).
2. Click **StayAwake** in Applications again — the running instance reveals the icon and opens the popover.

---

### "Already running" but I can't see or use it

**Cause (old builds):** A ghost process held the instance lock while the SwiftUI `MenuBarExtra` icon had vanished. Relaunching only showed an alert and quit.

**Fix (current build):** Clicking StayAwake in Applications sends a reveal notification to the running instance instead of showing a dialog. The popover should appear.

If still stuck:

```bash
killall StayAwake
open /Applications/StayAwake.app
```

Or quit via **Activity Monitor** → search "StayAwake" → Quit.

---

### Cup icon missing from menu bar

**Cause:** One of:
- macOS menu bar overflow (`>>` / Control Center area hides extra icons)
- An old build where the SwiftUI `MenuBarExtra` icon vanished
- **macOS 26 (Tahoe):** Control Center hosts third-party menu bar icons and can block or park them off-screen while the app still runs (popover may open from an invisible slot)

**Fix:**
1. Click **StayAwake** in Applications — current builds try to reveal the cup and open the popover.
2. Check the **overflow area** on the right side of the menu bar.
3. Open **System Settings → Menu Bar** and make sure **StayAwake** is allowed.
4. If the cup is still missing, scroll to the bottom of Menu Bar settings and choose **Reset Control Center…** (restores menu bar layout; clears Tahoe's blocked-item ledger).
5. Reinstall if on an old build:

```bash
./scripts/install.sh
```

**Tahoe note:** If StayAwake was launched from Terminal, Cursor, or another IDE during development, macOS may have recorded its bundle id under that app's menu bar entry. Turning off the parent app's menu bar permission can block StayAwake even when StayAwake's own toggle is on. Reset Control Center or re-enable the parent app in Menu Bar settings.

---

### Start at Login stopped working after rebuild

**Cause:** Login item may still point at an old build path (e.g. Xcode `build/` folder instead of `/Applications`).

**Fix:**
1. Run `./scripts/install.sh` to install to `/Applications`.
2. Open the StayAwake popover → turn **Start at Login** **off**, then **on** again.

Verify in System Settings → General → Login Items.

---

### Keep Awake (Lid Closed) enabled but Mac still sleeps

**Cause:** macOS may ignore clamshell override on battery, or sleep for other reasons (low battery, manual sleep, official clamshell mode with external display).

**Fix:**
1. **Plug into AC power** — lid-closed override is most reliable on wall power.
2. Confirm StayAwake is running: `pgrep -l StayAwake`
3. Check the log for toggle state: `tail ~/Library/Logs/StayAwake.log`
4. Run the lid test helper — see [README](../README.md#lid-closed-testing)
5. See clamshell details in [Architecture](ARCHITECTURE.md#lid-closed-clamshell-override)

---

### Two copies / weird lock behavior

**Cause:** `AppInstanceLock` uses a file lock at `~/Library/Caches/StayAwake/stayawake.lock`. Only one instance should run.

**Fix:**

```bash
killall StayAwake
rm -f ~/Library/Caches/StayAwake/stayawake.lock
open /Applications/StayAwake.app
```

Only remove the lock file when no StayAwake process is running.

---

### App icon in Finder looks generic

**Cause:** Xcode's asset catalog sometimes produces an incomplete `AppIcon.icns`.

**Fix:** `install.sh` regenerates icons and replaces the `.icns` before copying to Applications. Re-run:

```bash
./scripts/install.sh
```

If Finder still shows the old icon, log out and back in (Launch Services cache).
