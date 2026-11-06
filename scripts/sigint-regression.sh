#!/bin/bash
# Regression check: Ctrl+C in the launching terminal runs the same cleanup as Quit.
#
# Runs the app in a private tmux session against a fake backend (scripts/fixtures/fake_backend.py) that
# serves the canonical "Bot Chat" flow (lookup, create + title, resume, one streamed turn). After the turn
# finishes it presses Ctrl+C, and again 0.2 s later, then asserts what the fake backend saw:
#   attach   attached backend: the Bot Chat is only detached (NO session.close / session.delete); the
#            quit completes; the backend is left running
#   spawn    app-owned backend (fake `hermes` binary): own process group, never gets SIGINT, no
#            session.close / session.delete, then SIGTERM; nothing left running
#
# Never touches a real Hermes backend: discovery uses a temp lock dir, spawn uses the fake binary.
# Only processes this script started are signalled (PID + command checked). Opens app windows: needs a
# GUI session, and it takes focus, so do not run it while something else is capturing screenshots.
#
# usage: scripts/sigint-regression.sh [--app <HermesBotApp executable>] [attach|spawn ...]
#        default app: .build/debug/HermesBotApp; default scenarios: both
# exit:  0 = all scenarios passed, 1 = an assertion failed, 2 = setup problem
set -u

repo=$(cd "$(dirname "$0")/.." && pwd)
app=$repo/.build/debug/HermesBotApp
if [ "${1:-}" = --app ]; then app=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2; fi
fake=$repo/scripts/fixtures/fake_backend.py
python=/usr/bin/python3
[ -x "$app" ] || { echo "missing $app (run swift build, or pass --app)" >&2; exit 2; }
[ -x "$python" ] || { echo "missing $python" >&2; exit 2; }
command -v tmux >/dev/null || { echo "tmux is required (brew install tmux)" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/hba-sigint.XXXXXX")
session="hba-sigint-$$"
echo "app: $app"
echo "logs: $work"

# --- process ownership: "pid|command substring"; an entry is dropped once the process is gone ------
owned=()
own() { owned+=("$1|$2"); }
alive_owned() {  # alive_owned <pid> <substr>: running AND still the command we started
    kill -0 "$1" 2>/dev/null && ps -o command= -p "$1" 2>/dev/null | grep -qF -- "$2"
}
stop_owned() {  # stop_owned <pid> <substr>: SIGTERM, bounded wait, SIGKILL, read back; 0 = gone
    local pid=$1 sub=$2 i
    alive_owned "$pid" "$sub" || return 0
    kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 50); do alive_owned "$pid" "$sub" || return 0; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null
    for i in $(seq 1 20); do alive_owned "$pid" "$sub" || return 0; sleep 0.1; done
    echo "  WARN could not stop pid $pid ($sub)" >&2; return 1
}
disown_gone() {  # drop entries whose process has exited
    local keep=() e
    for e in "${owned[@]+"${owned[@]}"}"; do alive_owned "${e%%|*}" "${e#*|}" && keep+=("$e"); done
    owned=("${keep[@]+"${keep[@]}"}")
}
cleanup() {
    tmux kill-session -t "$session" 2>/dev/null
    local e
    for e in "${owned[@]+"${owned[@]}"}"; do stop_owned "${e%%|*}" "${e#*|}"; done
    owned=()
}
trap cleanup EXIT

fail=0
check() {  # check <label> <actual> <expected>
    if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"; else echo "  FAIL $1 = $2 (expected $3)"; fail=1; fi
}
count() { grep -c -E "$1" "$2" 2>/dev/null || true; }
# The fake appends under one lock, so line order is event order.
first_line() { grep -n -E "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1; }
wait_for() {  # wait_for <seconds> <command...>
    local end=$(( $(date +%s) + $1 )); shift
    until "$@"; do [ "$(date +%s)" -ge "$end" ] && return 1; sleep 0.1; done
}

run() {
    local scenario=$1 dir=$work/$1
    mkdir -p "$dir/locks"; chmod 700 "$dir/locks"
    local calls=$dir/calls.log applog=$dir/app.log pidfile=$dir/app.pid
    local env=(HERMES_BOT_APP_LOCK_DIR="$dir/locks" "HERMES_BOT_APP_AUTOCHAT=fixture|hello")
    local fake_pid="" serve_pid="" serve_pgid=""
    echo "== $scenario"
    case $scenario in
        attach)
            "$python" -I "$fake" attach "$dir/locks" "$calls" > "$dir/fake.out" 2>&1 &
            fake_pid=$!; own "$fake_pid" "$fake"
            wait_for 10 grep -q READY "$dir/fake.out" || { echo "  fake backend did not start" >&2; return 2; }
            env+=(HERMES_BOT_APP_NO_SPAWN=1)
            ;;
        spawn)
            printf '#!/bin/sh\nHBA_FAKE_CALLS=%q exec %q -I %q "$@"\n' "$calls" "$python" "$fake" > "$dir/hermes"
            chmod +x "$dir/hermes"
            env+=(HERMES_BOT_APP_FORCE_SPAWN=1 HERMES_BOT_APP_HERMES_BIN="$dir/hermes")
            ;;
        *) echo "unknown scenario $scenario" >&2; return 2 ;;
    esac

    # The pane's shell runs `sh -c 'echo $$ > pidfile; exec env … app'`: the app is the pane's
    # foreground job (real terminal Ctrl+C) and its PID is known without searching.
    local cmd
    cmd=$(printf '%q ' sh -c 'echo $$ > "$0"; exec env "$@"' "$pidfile" "${env[@]}" "$app")
    tmux new-session -d -s "$session" -x 200 -y 50
    tmux send-keys -t "$session" "$cmd > $(printf %q "$applog") 2>&1" Enter
    wait_for 10 test -s "$pidfile" || { echo "  app did not start" >&2; return 2; }
    local app_pid; app_pid=$(cat "$pidfile"); own "$app_pid" "$app"

    if [ "$scenario" = spawn ]; then  # own the spawned backend as soon as it announces itself
        wait_for 15 grep -qs " START " "$calls" || { echo "  spawned backend did not start" >&2; return 2; }
        serve_pid=$(sed -n 's/.* pid=\([0-9]*\) pgid=[0-9]* START.*/\1/p' "$calls" | head -1)
        serve_pgid=$(sed -n 's/.* pid=[0-9]* pgid=\([0-9]*\) START.*/\1/p' "$calls" | head -1)
        [ -n "$serve_pid" ] && own "$serve_pid" "$fake"
    fi
    wait_for 30 grep -q "ui message.complete" "$applog" || { echo "  chat turn did not complete" >&2; return 2; }

    check "Bot Chat looked up by title" "$(count 'RPC session\.list' "$calls")" 1
    check "Bot Chat created once" "$(count 'RPC session\.create' "$calls")" 1

    tmux send-keys -t "$session" C-c
    sleep 0.2
    tmux send-keys -t "$session" C-c  # a second press while cleanup runs must not break the quit
    if wait_for 20 bash -c "! kill -0 $app_pid 2>/dev/null"; then check "quit completed after Ctrl+C" yes yes
    else check "quit completed after Ctrl+C" no yes; fi
    tmux kill-session -t "$session" 2>/dev/null

    local l_term
    l_term=$(first_line 'SIGNAL SIGTERM' "$calls")
    check "quit requested (cleanup started)" "$(count 'quit requested' "$applog")" 1
    check "bot chats detached" "$(count 'bot chats detached' "$applog")" 1
    check "session.close calls" "$(count 'RPC session\.close' "$calls")" 0
    check "session.delete calls" "$(count 'RPC session\.delete' "$calls")" 0
    case $scenario in
        spawn)
            check "SIGINT reached backend" "$(count 'SIGNAL SIGINT' "$calls")" 0
            check "backend SIGTERM count" "$(count 'SIGNAL SIGTERM' "$calls")" 1
            check "SIGTERM seen" "$([ -n "$l_term" ] && echo yes || echo no)" yes
            check "backend in its own process group" "$([ -n "$serve_pid" ] && [ "$serve_pid" = "$serve_pgid" ] && echo yes || echo no)" yes
            local gone=no
            [ -n "$serve_pid" ] && wait_for 5 bash -c "! kill -0 $serve_pid 2>/dev/null" && gone=yes
            check "backend stopped by the app" "$gone" yes ;;
    esac
    if [ -n "$fake_pid" ]; then
        check "attached backend still running" "$(alive_owned "$fake_pid" "$fake" && echo yes || echo no)" yes
        stop_owned "$fake_pid" "$fake"
    fi
    stop_owned "$app_pid" "$app"
    [ -n "$serve_pid" ] && stop_owned "$serve_pid" "$fake"
    disown_gone
    return 0
}

scenarios=("$@"); [ ${#scenarios[@]} -eq 0 ] && scenarios=(attach spawn)
for s in "${scenarios[@]}"; do
    run "$s"; rc=$?
    [ $rc -eq 2 ] && { echo "SETUP PROBLEM in $s (logs in $work)" >&2; exit 2; }
done
if [ $fail -eq 0 ]; then echo "PASS"; exit 0; fi
echo "FAIL"; exit 1
