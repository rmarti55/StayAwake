#!/bin/bash
# StayAwake lid-closed test helper
# Usage:
#   ./scripts/lid-test.sh before   # run, then close lid ~5 min
#   ./scripts/lid-test.sh after    # run after reopening lid

set -euo pipefail

REPORT_DIR="/Users/admin/StayAwake/test-results"
BEFORE="$REPORT_DIR/before.txt"
AFTER="$REPORT_DIR/after.txt"

mkdir -p "$REPORT_DIR"

capture() {
  local label="$1"
  local file="$2"

  {
    echo "=== StayAwake lid test: $label ==="
    echo "Captured: $(date)"
    echo

    echo "--- Power source ---"
    pmset -g batt 2>/dev/null || echo "(pmset batt unavailable)"
    echo

    echo "--- StayAwake process ---"
    pgrep -l StayAwake || echo "NOT RUNNING"
    echo

    echo "--- Toggle log (last 10 lines) ---"
    tail -10 "$HOME/Library/Logs/StayAwake.log" 2>/dev/null || echo "(no log yet)"
    echo

    echo "--- UserDefaults toggles ---"
    if defaults read com.stayawake.app stayawake.lidOpenAwake 2>/dev/null | rg -q "1"; then
      echo "  lidOpenAwake: on"
    else
      echo "  lidOpenAwake: off"
    fi
    if defaults read com.stayawake.app stayawake.lidClosedAwake 2>/dev/null | rg -q "1"; then
      echo "  lidClosedAwake: on"
    else
      echo "  lidClosedAwake: off"
    fi
    echo

    echo "--- Clamshell kernel state ---"
    ioreg -l 2>/dev/null | rg "AppleClamshell(CausesSleep|State)" | head -2 || echo "(unavailable)"
    echo

    echo "--- Uptime ---"
    uptime
    echo

    echo "--- Boot time ---"
    sysctl -n kern.boottime
    echo

    echo "--- Active power assertions (StayAwake) ---"
    pmset -g assertions 2>/dev/null | rg -i "stayawake|PreventSystemSleep|PreventUserIdle" || echo "(none matched)"
    echo

    echo "--- Recent sleep/wake log (last ~15 lines) ---"
    pmset -g log 2>/dev/null | rg -i "sleep|wake|clamshell" | tail -15 || pmset -g log 2>/dev/null | tail -15
    echo
  } | tee "$file"
}

compare() {
  if [[ ! -f "$BEFORE" || ! -f "$AFTER" ]]; then
    echo "Missing before/after snapshots. Run: before, then after."
    exit 1
  fi

  echo "=== Comparison ==="
  echo

  before_uptime=$(rg "up " "$BEFORE" | head -1 || true)
  after_uptime=$(rg "up " "$AFTER" | head -1 || true)
  echo "Uptime before: $before_uptime"
  echo "Uptime after:  $after_uptime"
  echo

  before_boot=$(rg "sec = " "$BEFORE" | head -1 || true)
  after_boot=$(rg "sec = " "$AFTER" | head -1 || true)
  if [[ "$before_boot" == "$after_boot" ]]; then
    echo "Boot time: UNCHANGED (Mac did not reboot)"
  else
    echo "Boot time: CHANGED (Mac may have rebooted)"
    echo "  before: $before_boot"
    echo "  after:  $after_boot"
  fi
  echo

  if rg -q "PreventUserIdleSystemSleep named: \"StayAwake: Prevent idle system sleep \(lid closed\)\"" "$AFTER"; then
    echo "StayAwake lid-closed idle assertion: ACTIVE after test"
  else
    echo "StayAwake lid-closed idle assertion: NOT FOUND after test"
  fi
  echo

  if rg -q "AppleClamshellCausesSleep\" = No" "$AFTER"; then
    echo "Clamshell override: ACTIVE (lid close should not sleep Mac)"
  elif rg -q "AppleClamshellCausesSleep\" = Yes" "$AFTER"; then
    echo "Clamshell override: INACTIVE (lid close will sleep Mac)"
  else
    echo "Clamshell override: unknown"
  fi
  echo

  before_time=$(rg "Captured:" "$BEFORE" | head -1 | sed 's/Captured: //')
  echo "Recent clamshell sleep events (pmset log tail):"
  pmset -g log 2>/dev/null | rg "Clamshell Sleep" | tail -5 || echo "(none found)"
  echo
  echo "Test window started: $before_time"
  echo

  echo "Full reports:"
  echo "  before: $BEFORE"
  echo "  after:  $AFTER"
}

case "${1:-}" in
  before)
    capture "BEFORE (close lid now)" "$BEFORE"
    echo
    echo "Next steps:"
    echo "  1. Set toggles manually in the StayAwake menu (this script does not change them)"
    echo "  2. Confirm cup icon is filled if lid-closed test is enabled"
    echo "  3. Close lid for ~5 minutes"
    echo "  4. Reopen and run: ./scripts/lid-test.sh after"
    ;;
  after)
    capture "AFTER (lid reopened)" "$AFTER"
    echo
    compare
    ;;
  *)
    echo "Usage: $0 before|after"
    exit 1
    ;;
esac
