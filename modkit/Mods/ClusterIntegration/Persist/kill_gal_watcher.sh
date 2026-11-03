#!/bin/ksh
#
# kill_gal_watcher: slay gal.real once per boot so Android Auto reconnects
# fresh after Audi's native nav has loaded. Mirrors the user's manual
# airplane-mode trick: on this Audi (P2711) the Java KombiMapGuard never
# fires, so the hide has to come from shell. One slay per boot — gal.real
# respawns on its own and the phone AA session reconnects clean.
#

export PATH="$PATH:/mnt/app/armle/usr/bin:/mnt/app/armle/bin:/usr/bin:/bin"
LOG=/tmp/kill_gal_watcher.log
DONE=/tmp/kill_gal_watcher.done
FLAG=/tmp/kill_gal_now

# Wait after gal.real first appears before the first slay. 30s is enough
# for Audi maps to come up on P2711.
STABLE_WAIT=30
# Retry: if the first slay doesn't take (adapter needed a manual re-select,
# gal.real respawned into the same bad state), slay again. Up to 3 total.
MAX_SLAYS=3
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

# Wait up to 10 min for gal.real to appear (AA may not be plugged in yet).
i=0
pid=""
while [ $i -lt 600 ]; do
    # Secondary trigger: Java mod flag — if KombiMapGuard ever starts
    # firing on this build, honor it immediately.
    if [ -f "$FLAG" ]; then
        echo "flag seen at ${i}s, killing immediately" >> "$LOG"
        pid=$(gal_pid)
        break
    fi
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

# Let Audi maps + AA stabilize before kicking it.
if [ ! -f "$FLAG" ]; then
    echo "waiting ${STABLE_WAIT}s for Audi maps to load before slay" >> "$LOG"
    sleep $STABLE_WAIT
fi

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

    # Wait for respawn and verify stability. Same pid at +10s and +20s
    # means the new gal.real stuck.
    sleep 10
    pid_mid=$(gal_pid)
    sleep 10
    pid_end=$(gal_pid)
    echo "try $try: post-slay pids mid=$pid_mid end=$pid_end" >> "$LOG"
    if [ -n "$pid_end" ] && [ "$pid_end" = "$pid_mid" ]; then
        echo "try $try: gal.real stable at $pid_end, assuming AA reconnected" >> "$LOG"
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
