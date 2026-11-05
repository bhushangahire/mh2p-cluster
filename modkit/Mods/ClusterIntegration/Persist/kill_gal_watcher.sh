#!/bin/ksh
#
# kill_gal_watcher: the airplane-mode trick from shell. Slays gal.real once
# per boot so Android Auto reconnects after Audi's navigation is up and its
# video takes the whole cockpit map slot. KombiMapGuard decides: it writes
# /tmp/kill_gal_now (AA connected too early, reconnect) or /tmp/kill_gal_skip
# (navigation was ready first, nothing to do). Without either within
# FALLBACK_WAIT of gal.real appearing, slay on the timer.
#

export PATH="$PATH:/mnt/app/armle/usr/bin:/mnt/app/armle/bin:/usr/bin:/bin"
LOG=/tmp/kill_gal_watcher.log
DONE=/tmp/kill_gal_watcher.done
FLAG=/tmp/kill_gal_now
SKIP=/tmp/kill_gal_skip

FALLBACK_WAIT=120
# One slay only: a second one killed the session the user (or the guard's
# auto-connect) had just started, 2026-11-04 logs.
MAX_SLAYS=1
RETRY_WAIT=30

echo "kill_gal_watcher started $(date)" > "$LOG"

if [ -f "$DONE" ]; then
    echo "already done this boot, exiting" >> "$LOG"
    exit 0
fi

# Find gal.real pid via pidin (QNX; /proc/<pid>/pathname is Linux-only).
# Format: "   PID TID NAME ..." — strip leading spaces, awk column 1.
gal_pid() {
    pidin ar 2>/dev/null | awk '/[g]al\.real/ {print $1; exit}'
}

skip_exit() {
    echo "guard: navigation was ready before AA, no reconnect ($1)" >> "$LOG"
    touch "$DONE"
    rm -f "$SKIP"
    exit 0
}

# Wait up to 10 min for gal.real to appear (AA may not be plugged in yet).
i=0
pid=""
while [ $i -lt 600 ]; do
    [ -f "$SKIP" ] && skip_exit "before gal.real at ${i}s"
    pid=$(gal_pid)
    if [ -n "$pid" ]; then
        echo "gal.real seen pid=$pid at ${i}s" >> "$LOG"
        break
    fi
    sleep 2
    i=$((i + 2))
done

if [ -z "$pid" ]; then
    echo "gal.real never appeared in 10 min, giving up" >> "$LOG"
    exit 0
fi

# Wait for the guard's verdict, else fall back to the timer.
w=0
while [ $w -lt $FALLBACK_WAIT ]; do
    [ -f "$SKIP" ] && skip_exit "${w}s after gal.real"
    if [ -f "$FLAG" ]; then
        echo "guard: AA connected before navigation was ready, reconnecting (${w}s after gal.real)" >> "$LOG"
        break
    fi
    sleep 1
    w=$((w + 1))
done
[ $w -ge $FALLBACK_WAIT ] && echo "no guard signal in ${FALLBACK_WAIT}s, reconnecting on the timer" >> "$LOG"

# Re-check gal.real pid in case it died and respawned during the wait.
pid=$(gal_pid)
if [ -z "$pid" ]; then
    echo "gal.real gone before slay, nothing to do" >> "$LOG"
    touch "$DONE"
    rm -f "$FLAG"
    exit 0
fi

# Slay-and-check loop. After each slay, give gal.real 20s to respawn and
# stay up — a pid that's steady for the whole 20s means AA reconnected
# cleanly; stop. Otherwise wait RETRY_WAIT and slay again, up to MAX_SLAYS.
try=1
while [ $try -le $MAX_SLAYS ]; do
    pid=$(gal_pid)
    if [ -z "$pid" ]; then
        echo "try $try: gal.real not running, skip slay" >> "$LOG"
    else
        echo "try $try: slaying gal.real pid=$pid at $(date)" >> "$LOG"
        slay gal.real >> "$LOG" 2>&1
        rc=$?
        echo "try $try: slay rc=$rc" >> "$LOG"
        if [ $rc -ne 0 ]; then
            kill -9 $pid >> "$LOG" 2>&1
            echo "try $try: kill -9 rc=$?" >> "$LOG"
        fi
    fi

    # Respawn takes 20-60 s on this unit (the phone has to reconnect).
    # A new gal.real pid within 60 s means AA came back: done.
    new_pid=""
    w=0
    while [ $w -lt 60 ]; do
        sleep 5
        w=$((w + 5))
        new_pid=$(gal_pid)
        [ -n "$new_pid" ] && [ "$new_pid" != "$pid" ] && break
        new_pid=""
    done
    echo "try $try: post-slay new pid=$new_pid after ${w}s" >> "$LOG"
    if [ -n "$new_pid" ]; then
        echo "try $try: gal.real respawned, AA reconnected, stopping" >> "$LOG"
        break
    fi

    try=$((try + 1))
    if [ $try -le $MAX_SLAYS ]; then
        echo "try $try: not stable yet, waiting ${RETRY_WAIT}s before retry" >> "$LOG"
        sleep $RETRY_WAIT
    fi
done

touch "$DONE"
rm -f "$FLAG"
echo "done at $(date) after $try tr(y|ies)" >> "$LOG"
