#!/bin/sh
# Runs the SwiftUI app once for scripted evidence with a watchdog.
# usage: scripts/run-app-evidence.sh <evidence-dir> <max-seconds>   (HERMES_BOT_APP_* env passed through)
# The app quits itself with HERMES_BOT_APP_AUTOQUIT=1; past <max-seconds> it gets SIGTERM, which runs the
# same graceful cleanup as Quit.
# Exit status: the app's own status; 124 when the watchdog had to stop it (even if the app then exited 0),
# 137 if it also needed SIGKILL. Callers must not treat a watchdog stop as a pass. Exit 0 only means the
# app quit by itself: whether the flow settled is asserted from <dir>/ui-log.json, not from this status.
set -u
dir="$1"; max="${2:-300}"
mkdir -p "$dir"
cd "$(dirname "$0")/.." || exit 1
HERMES_BOT_APP_EVIDENCE="$dir" .build/debug/HermesBotApp > "$dir/console.log" 2>&1 &
app=$!
echo "app pid=$app"
i=0; watchdog=0
while kill -0 "$app" 2>/dev/null; do
  sleep 1; i=$((i + 1))
  if [ "$i" -ge "$max" ]; then
    echo "watchdog: SIGTERM after ${max}s"; watchdog=124; kill -TERM "$app"
    j=0; while kill -0 "$app" 2>/dev/null && [ "$j" -lt 15 ]; do sleep 1; j=$((j + 1)); done
    if kill -0 "$app" 2>/dev/null; then echo "watchdog: SIGKILL"; kill -KILL "$app"; watchdog=137; fi
    break
  fi
done
wait "$app"; rc=$?
echo "app exit=$rc after ${i}s watchdog=$watchdog"
if [ "$watchdog" -ne 0 ]; then exit "$watchdog"; fi
exit "$rc"
