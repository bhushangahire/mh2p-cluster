#!/bin/ksh
#
# Copyright (c) 2026 fifthBro
# https://fifthbro.github.io
#
# Licensed under CC BY-NC-SA 4.0
# https://creativecommons.org/licenses/by-nc-sa/4.0/
# NOT FOR COMMERCIAL USE
#
# cluster.sh
#

# The gal wrapper starts the daemon too when AA comes up before this runs.
# Two daemons race for /tmp/cluster_ctl and drop commands (blank cockpit until
# a reconnect, native map not restored after unplug), so only one may run.
# Whoever starts it records its pid in /tmp/cluster_daemon.pid. The check uses
# shell built-ins only (read, test): pidin/grep are not reliably reachable this
# early in boot, and kill -0 fails across users, but /proc/<pid> is visible to
# everyone. One line per decision goes to /tmp/cluster_daemon_start.log.
DAEMON_PID=/tmp/cluster_daemon.pid
DAEMON_LOG=/tmp/cluster_daemon_start.log

# On cold boot AAWireless connects before Audi's native nav (navStartup)
# initializes (~15-20 s). If the cluster daemon starts and the hook tries to
# post AA video to displayable 33 before navStartup has set up the display,
# the first AA session's cockpit is broken until the user disconnects and
# reconnects the adapter. Wait up to 30 s for navStartup here so the daemon
# only starts once the cockpit is ready. On warm restarts navStartup is
# already running and this returns immediately.
PATH="$PATH:/mnt/app/armle/usr/bin:/mnt/app/armle/bin:/usr/bin:/bin"
i=0
while [ $i -lt 30 ]; do
    if pidin ar 2>/dev/null | grep 'navStartup' >/dev/null 2>&1; then
        print "persist: navStartup detected after ${i}s" >> "$DAEMON_LOG" 2>/dev/null
        break
    fi
    sleep 1
    i=$((i + 1))
done
[ $i -ge 30 ] && print "persist: navStartup wait timed out at 30s, proceeding anyway" >> "$DAEMON_LOG" 2>/dev/null

if [[ -x "/eso/bin/apps/cluster/cluster" ]]; then
        if { read p < "$DAEMON_PID" && [[ -n "$p" && -d "/proc/$p" ]]; } 2>/dev/null; then
                print "persist: daemon already running, pid $p" >> "$DAEMON_LOG" 2>/dev/null
        else
                # verbose=2 (cluster_daemon.log) only with the marker the
                # installer sets from Mods/ClusterIntegration/daemon_log.txt
                V=""
                [[ -f /eso/bin/apps/cluster/daemon_verbose ]] && V="verbose=2"
                /eso/bin/apps/cluster/cluster daemon $V >/dev/null 2>&1 &
                p=$!
                print $p > "$DAEMON_PID" 2>/dev/null
                print "persist: started daemon pid $p (pid file written: $?)" >> "$DAEMON_LOG" 2>/dev/null
        fi
fi


# kill_gal_watcher: on P2711 the Java KombiMapGuard still misses the first
# cold-boot cycle even with the ServiceTracker fix, so run the airplane-
# mode trick from shell: wait for gal.real to come up, give Audi maps
# 30 s to load, slay gal.real so the phone AA session reconnects clean
# and the mod can hide the cockpit map on first try. MOD_PATH isn't set
# in Persist context, so resolve relative to $0.
WATCHER="${0%/*}/kill_gal_watcher.sh"
if [ -r "$WATCHER" ]; then
    ( /bin/ksh "$WATCHER" >/dev/null 2>&1 ) &
    print "persist: kill_gal_watcher started pid $! from $WATCHER" >> "$DAEMON_LOG" 2>/dev/null
else
    print "persist: kill_gal_watcher not found at $WATCHER" >> "$DAEMON_LOG" 2>/dev/null
fi

