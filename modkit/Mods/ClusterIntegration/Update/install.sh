#!/bin/ksh
#
# Copyright (c) 2026 fifthBro
# https://fifthbro.github.io
#
# Licensed under CC BY-NC-SA 4.0
# https://creativecommons.org/licenses/by-nc-sa/4.0/
# NOT FOR COMMERCIAL USE
#
# install.sh 
#
# Idempotent installer. Re-runs are safe.
# - Supported head units: Porsche PCM5 (OEM=PO, firmware 26xx/28xx, tested)
#   and Audi MH2p (OEM=AU, experimental). Other OEMs abort unless
#   Mods/ClusterIntegration/force_install.txt exists on the SD card.
# - Marker files next to the Update/ folder on the SD card:
#     force_install.txt   skip the OEM / firmware gate
#     diag.txt            hook logs only, no cluster service injected,
#                         installed config set to turn-by-turn only
#     enable_carplay.txt  install the CarPlay hook and full JAR on Audi
#     config_overrides.txt  key=value lines applied to the installed
#                         cluster_config.json "config" block (e.g. forceRHD=true)
#     no_stub.txt         Audi: do not install the StorageMountHandler stand-in
#     gal_env.txt         GAL_CLUSTER_*=value lines exported to the Android
#                         Auto hook by the gal wrapper (insets, live logging)
#     daemon_log.txt      start the cluster daemon with verbose=2
#                         (cluster_daemon.log on USB or /tmp)
#     uninstall.txt       ModKit convention: run uninstall.sh instead
# - Copies JAR, cluster, gal_cluster.so, dio_cluster.so to their target dirs.
# - On Audi also installs Update/audi/ClusterIntegration_StorageMountHandler_
#   stub.jar, a no-op copy of a Porsche-only class the mod's Java code
#   constructs, unless the HMI image is seen to provide the class or
#   no_stub.txt exists.
# - Skips copies when the target file is identical to the source (by
#   content where the unit has a comparison tool, else by size, wc counts
#   and modification time).
# - Backs up any existing target before overwriting (timestamped, into
#   $MOD_PATH/Backup/).
# - Replaces /mnt/app/eso/bin/apps/gal with a wrapper script that sets
#   LD_PRELOAD=gal_cluster.so before execing the real gal binary.
#   The original binary is preserved at /mnt/app/eso/bin/apps/gal.real so
#   uninstall.sh can restore it.
# - Same for dio_manager.
# - Writes Backup/manifest.txt (add / replace / swap / remove / override
#   lines with the backup path for each) as the record of what was changed.
#   uninstall.sh / rollback.sh restore the swapped binaries and remove the
#   mod's own files (its fixed list plus any "add" entries in the manifest
#   under the mod's own directories).
#

set -u

export MOD_PATH="${modPath:-${MOD_PATH:-}}"
[[ -z "$MOD_PATH" ]] && { print -u2 "ERROR: MOD_PATH not set"; exit 1; }

[[ ! -e /mnt/app ]] && mount -t qnx6 /dev/mnanda0t177.1 /mnt/app
mount -uw /mnt/app/

# The ModKit runs this script with a short PATH, and part of the unit's
# toolset lives under /mnt/app/armle (wc, awk and sed on an e-tron).
# Appended, never prepended, so the ModKit's own choices win.
export PATH="${PATH:-/bin:/usr/bin}:/mnt/app/armle/usr/bin:/mnt/app/armle/bin:/usr/bin:/bin"

# The MH2p QNX image carries a trimmed toolset: an e-tron has no tr, sum,
# cmp, od, cksum, md5sum, unzip or strings, and its grep has no -a. Only
# commands the upstream scripts already use are relied on unconditionally
# (awk, sed, cut, head, ls, cp, mv, rm, mkdir, chmod, dd, date, sync, slay,
# mount). Everything else is probed: a check that needs a missing tool is
# reported as skipped, never as a negative result, and file comparison
# degrades to a size check.
have() { whence "$1" >/dev/null 2>&1; }
TOOLS_MISSING=""
for t in grep find awk sed cut head wc sum cmp diff od dd; do
    have "$t" || TOOLS_MISSING="$TOOLS_MISSING $t"
done

# ---- file size and content comparison with whatever this unit offers ----
# Size: wc -c, or ls -l field 5 (the same in every POSIX ls) without wc.
file_size() {
    typeset sz
    sz=""
    if have wc; then sz=$(wc -c < "$1" 2>/dev/null | awk '{print $1}'); fi
    [[ "$sz" == +([0-9]) ]] || sz=$(ls -l "$1" 2>/dev/null | awk '{print $5}')
    [[ "$sz" == +([0-9]) ]] || sz=""
    print -r -- "$sz"
}
# Content: the first of cmp, diff, sum, cksum, md5sum, od, wc that exists
# and tells two small known files apart. wc is the weakest (byte, line and
# word counts, not a checksum) but it is binary-safe and the e-tron has it.
# FILE_CMP stays empty when none works.
same_content_with() { # TOOL A B: 0 same, 1 different, 2 could not compare
    typeset h1 h2
    h1=""; h2=""
    case "$1" in
        cmp)    cmp -s "$2" "$3" >/dev/null 2>&1
                case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac ;;
        diff)   diff "$2" "$3" >/dev/null 2>&1
                case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac ;;
        sum)    h1=$(sum < "$2" 2>/dev/null);    h2=$(sum < "$3" 2>/dev/null) ;;
        cksum)  h1=$(cksum < "$2" 2>/dev/null);  h2=$(cksum < "$3" 2>/dev/null) ;;
        md5sum) h1=$(md5sum < "$2" 2>/dev/null); h2=$(md5sum < "$3" 2>/dev/null) ;;
        od)     h1=$(od -An -v -tu1 "$2" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) h = (h * 31 + $i) % 4294967296 } END { print h + 0 }')
                h2=$(od -An -v -tu1 "$3" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) h = (h * 31 + $i) % 4294967296 } END { print h + 0 }') ;;
        wc)     h1=$(wc -l -w -c < "$2" 2>/dev/null | awk 'NF == 3 { print $1 "/" $2 "/" $3 }')
                h2=$(wc -l -w -c < "$3" 2>/dev/null | awk 'NF == 3 { print $1 "/" $2 "/" $3 }') ;;
        *)      return 2 ;;
    esac
    [[ -n "$h1" && -n "$h2" ]] || return 2
    [[ "$h1" == "$h2" ]] && return 0
    return 1
}
FILE_CMP=""
file_cmp_probe() {
    typeset t a b
    a="/tmp/cluster_cmp_a.$$"; b="/tmp/cluster_cmp_b.$$"
    print "cluster probe one" > "$a"; print "cluster probe two, longer" > "$b"
    for t in cmp diff sum cksum md5sum od wc; do
        have "$t" || continue
        same_content_with "$t" "$a" "$a"; [[ $? -eq 0 ]] || continue
        same_content_with "$t" "$a" "$b"; [[ $? -eq 1 ]] || continue
        FILE_CMP="$t"; break
    done
    rm -f "$a" "$b"
}
file_cmp_probe
# files_same A B: 0 = same size and content (as far as this unit can tell),
# 1 = different, 2 = same size but the content cannot be compared. Used to
# verify a backup copy: a FAT card stores times in 2-second steps, so a copy
# made there never carries the unit file's exact time, and times are not
# part of this check.
files_same() {
    typeset sz1 sz2
    [[ -f "$1" && -f "$2" ]] || return 1
    sz1=$(file_size "$1"); sz2=$(file_size "$2")
    [[ -n "$sz1" && -n "$sz2" && "$sz1" == "$sz2" ]] || return 1
    [[ -n "$FILE_CMP" ]] || return 2
    same_content_with "$FILE_CMP" "$1" "$2"
    case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}
# files_identical SRC DST: is the unit's copy current? files_same plus,
# with only the wc fingerprint (counts, not a checksum: a same-length edit
# such as 2000 -> 3000 keeps it), the same modification time. Every install
# copy is cp -p from the card, which keeps the card file's time exactly, so
# an unchanged file matches and anything new on the card does not.
files_identical() {
    typeset rc
    files_same "$1" "$2"; rc=$?
    if [[ $rc -eq 0 && "$FILE_CMP" == wc ]]; then
        [[ "$1" -nt "$2" || "$1" -ot "$2" ]] && return 1
    fi
    return $rc
}

# ex: MH2p_US_PO416_P2870 (Porsche), MH2p_ER_AUG35_P2873 (Audi e-tron),
#     MH2p_ER_AU_P2873 (Audi units without a TYPE code, e.g. Q3/A1)
export RELEASE_VERSION=`/mnt/app/armle/usr/bin/pc b:46924065:401 | cut -c 61- | sed ':a;N;$!ba;s/\n//g' | sed -e 's/\.//g' | sed -e 's/ //g'`
# AS, CN, ER, US, ...
export REGION="$(echo $RELEASE_VERSION | cut -d'_' -f2)"
# VW, AU, PO, LB, ...
export OEM="$(echo $RELEASE_VERSION | cut -d'_' -f3 | cut -b -2)"
# 416, 636, G33, G35, G36, ...
export TYPE="$(echo $RELEASE_VERSION | cut -d'_' -f3 | cut -b 3-)"
# 9830, 2870, ...
export SOFTWARE_VERSION="$(echo $RELEASE_VERSION | cut -d'_' -f4 | cut -b 2-)"

# Override marker. Create Mods/ClusterIntegration/force_install.txt on the
# SD card (next to the Update/ folder) to skip the OEM / firmware gate.
# Only for people who know their head unit is MH2p and accept the risk.
MOD_ROOT="${MOD_PATH%/*}"
FORCE_INSTALL=0
[[ -e "$MOD_ROOT/force_install.txt" ]] && FORCE_INSTALL=1

print "Head unit:         release=$RELEASE_VERSION oem=$OEM type=$TYPE region=$REGION sw=$SOFTWARE_VERSION force=$FORCE_INSTALL"
print "tools missing:    ${TOOLS_MISSING:- none}"
case "$FILE_CMP" in
    "")  print "file compare:      size only (no cmp, diff, sum, cksum, md5sum, od or wc on this unit)" ;;
    wc)  print "file compare:      wc (byte, line and word counts; no checksum tool on this unit)" ;;
    *)   print "file compare:      $FILE_CMP" ;;
esac

# Supported head units:
#   PO  Porsche PCM5 (MH2P) firmware 26xx / 28xx     - tested
#   AU  Audi MH2p firmware 26xx / 27xx / 28xx        - EXPERIMENTAL
#       Firmware build numbers are one VAG-wide counter. Public e-tron GE
#       strings are AUG35 P2711 / P2718 / K2716_1 / P2873; P2873 sits in the
#       same build window as the Porsche P2870/P2874 the hooks were built
#       against and is the best-case target. MY2021+ e-tron is MIB3 (3xxx)
#       and out of scope.
# Anything else aborts unless force_install.txt is present.
case "$OEM" in
    PO|AU)
        if [[ "$OEM" == "PO" ]]; then
            brand="Porsche"; range="26xx / 28xx"
            in_range=0
            [[ "$SOFTWARE_VERSION" == 26?? || "$SOFTWARE_VERSION" == 28?? ]] && in_range=1
        else
            brand="Audi"; range="26xx / 27xx / 28xx"
            in_range=0
            [[ "$SOFTWARE_VERSION" == 26?? || "$SOFTWARE_VERSION" == 27?? || "$SOFTWARE_VERSION" == 28?? ]] && in_range=1
        fi
        if [[ $in_range -eq 0 ]]; then
            if [[ $FORCE_INSTALL -eq 1 ]]; then
                print "WARNING: $brand firmware $RELEASE_VERSION outside tested range ($range), continuing because force_install.txt is present."
            else
                print "Firmware $RELEASE_VERSION not in supported range ($range). Aborting."
                print "To override, create Mods/ClusterIntegration/force_install.txt on the SD card."
                exit 0
            fi
        else
            print "$brand firmware $RELEASE_VERSION OK, installing..."
        fi
        if [[ "$OEM" == "AU" ]]; then
            print "Audi support is EXPERIMENTAL: the JAR and native hooks were built against Porsche PCM5."
            if [[ "$SOFTWARE_VERSION" != 28?? ]]; then
                print "WARNING: Audi build $SOFTWARE_VERSION is outside the 28xx window the hooks were built against (P2873 is the closest known match). Run the diagnostic pass first."
            fi
            print "If Android Auto or CarPlay stop working: put uninstall.txt in Mods/ClusterIntegration/ and re-run the ModKit."
        fi
        ;;
    *)
        if [[ $FORCE_INSTALL -eq 1 ]]; then
            print "WARNING: unsupported head unit (OEM='$OEM', release='$RELEASE_VERSION'), continuing because force_install.txt is present."
        else
            print "Unsupported head unit (OEM='$OEM', release='$RELEASE_VERSION'). Aborting."
            print "Supported: Porsche (PO) firmware 26xx/28xx, Audi (AU, experimental)."
            print "To override, create Mods/ClusterIntegration/force_install.txt on the SD card."
            exit 0
        fi
        ;;
esac

JAR_DIR=/mnt/app/eso/hmi/lsd/jars
CLUSTER_DIR=/mnt/app/eso/bin/apps/cluster
APPS_DIR=/mnt/app/eso/bin/apps

# Preflight: refuse to touch anything if the MH2p layout we expect is not
# there. Protects against running on a head unit whose /mnt/app differs.
if [[ ! -d "$JAR_DIR" ]]; then
    print -u2 "ERROR: $JAR_DIR not found. This does not look like an MH2p HMI layout. Aborting before any change."
    exit 4
fi
if [[ ! -d "$APPS_DIR" ]]; then
    print -u2 "ERROR: $APPS_DIR not found. This does not look like an MH2p HMI layout. Aborting before any change."
    exit 4
fi
if [[ ! -f "$APPS_DIR/gal" && ! -f "$APPS_DIR/gal.real" ]]; then
    print "WARN: $APPS_DIR/gal not found. Android Auto cluster video hook cannot be installed on this unit; BAP turn-by-turn (JAR) will still be installed."
fi

# CarPlay is opt-in on Audi (enable_carplay.txt). Without it the Android-
# Auto-only JAR from aa_only/ is required; refuse to fall back to the full
# JAR, which would shadow Audi's CarPlay DSI manager.
CARPLAY_HOOK=1
[[ "$OEM" == "AU" && ! -e "$MOD_ROOT/enable_carplay.txt" ]] && CARPLAY_HOOK=0
if [[ $CARPLAY_HOOK -eq 0 ]]; then
    AA_JAR="$(ls -1t "$MOD_PATH"/aa_only/ClusterIntegration_*_aa.jar 2>/dev/null | head -1)"
    if [[ -z "$AA_JAR" || ! -f "$AA_JAR" ]]; then
        print -u2 "ERROR: $MOD_PATH/aa_only/ClusterIntegration_*_aa.jar not found. Aborting before any change."
        print -u2 "       This folder is part of the Audi (_audi.zip) package and of the tracked modkit/Mods tree; it is missing when the Porsche"
        print -u2 "       package is used with only the scripts copied over it. Extract the Audi zip to an empty card (or copy the whole"
        print -u2 "       modkit/Mods/ClusterIntegration folder), or create Mods/ClusterIntegration/enable_carplay.txt to install the full JAR instead."
        exit 4
    fi
fi

# A cluster_config.json at the root of an inserted card or stick takes
# precedence over the installed copy for every reader (JAR, cluster daemon,
# gal hook). Warn, because config_overrides.txt and diag mode only touch the
# installed copy and would be ignored while that file is present.
typeset rootcfg
for rootcfg in /fs/usb0_0 /fs/usb1_0 /fs/sda0 /fs/sdb0; do
    if [[ -f "$rootcfg/cluster_config.json" ]]; then
        print "WARN: $rootcfg/cluster_config.json exists and overrides the installed config while inserted; config_overrides.txt and diag mode have no effect until it is removed."
    fi
done

NEW_JAR="$(ls -1t "$MOD_PATH"/ClusterIntegration_*.jar 2>/dev/null | head -1)"
[[ -z "$NEW_JAR" || ! -f "$NEW_JAR" ]] && {
    print -u2 "ERROR: no ClusterIntegration_*.jar in $MOD_PATH"
    exit 3
}

# ---- Which stock classes does this HMI image provide? --------------------
# The mod's AndroidAuto2Subsystem shadows the stock one and constructs
# de.audi.app.car.adi.legacy.sportchrono.StorageMountHandler, a Porsche-side
# class ("Sport Chrono"). Without that class the shadowed subsystem dies
# with NoClassDefFoundError and Android Auto stops working; on Audi the
# stand-in jar under Update/audi/ provides a no-op copy.
#
# Where the stock classes live: /ifs/lsd.jxe is what lsd.sh puts on the JVM
# boot class path (a J9 ROM class image); /mnt/app/eso/hmi/lsd/lsd.jar is a
# plain jar of the same code on the units seen so far; lsd/jars holds small
# plugin jars. Jar entry names sit uncompressed in the central directory,
# so a text search finds them, and only the last 8 MB of a big jar is
# searched (copied out with dd).
#
# The QNX grep on an e-tron has no -a and never matched inside a jar, so
# each candidate command is self-tested on the mod's own JAR (whose central
# directory lists the probe class, and does not list a made-up one) and the
# first that passes is used. With none, the checks are reported as skipped,
# never as "not found".
LSD_DIR=/mnt/app/eso/hmi/lsd
LSD_JXE=/ifs/lsd.jxe
BIN_SEARCH=""
bin_search() { # NEEDLE FILE: 0 match, 1 no match or error, 2 no usable command
    typeset rc
    [[ -f "$2" ]] || return 1
    case "$BIN_SEARCH" in
        grep-aq) grep -a -q "$1" "$2" 2>/dev/null; rc=$? ;;
        grep-q)  grep -q "$1" "$2" 2>/dev/null; rc=$? ;;
        grep)    grep "$1" "$2" >/dev/null 2>&1; rc=$? ;;
        awk)     awk -v n="$1" 'index($0, n) { f = 1; exit } END { exit !f }' "$2" 2>/dev/null; rc=$? ;;
        *)       return 2 ;;
    esac
    [[ $rc -eq 0 ]] && return 0
    return 1
}
bin_search_probe() {
    typeset cand yes no
    yes="de/audi/app/terminalmode/smartphone/androidauto2/AndroidAuto2Subsystem.class"
    no="de/audi/app/terminalmode/smartphone/androidauto2/NoSuchClassForTheProbe.class"
    for cand in grep-aq grep-q grep awk; do
        case "$cand" in grep*) have grep || continue ;; awk) have awk || continue ;; esac
        BIN_SEARCH="$cand"
        bin_search "$yes" "$NEW_JAR" || continue
        bin_search "$no" "$NEW_JAR" && continue
        return 0
    done
    BIN_SEARCH=""
    return 1
}
bin_search_probe
case "$BIN_SEARCH" in
    grep-aq)     print "binary search:     grep -a (self-test on ${NEW_JAR##*/} passed)" ;;
    grep-q|grep) print "binary search:     grep (self-test on ${NEW_JAR##*/} passed)" ;;
    awk)         print "binary search:     awk (self-test on ${NEW_JAR##*/} passed; grep cannot read a binary file on this unit)" ;;
    *)           print "binary search:     none (neither grep nor awk finds a class name inside ${NEW_JAR##*/} on this unit; class and symbol checks skipped)" ;;
esac

# Last 8 MB of lsd.jar (its central directory) copied to /tmp with dd, or
# the file itself when it is small or dd fails. Sets LSD_TAIL.
LSD_TAIL=""
lsd_jar_tail() {
    typeset sz skip
    [[ -f "$LSD_DIR/lsd.jar" ]] || return 1
    sz="$(file_size "$LSD_DIR/lsd.jar")"
    if [[ "$sz" == +([0-9]) && "$sz" -gt 8388608 ]]; then
        LSD_TAIL="/tmp/cluster_lsdtail.$$"
        skip=$(( (sz - 8388608) / 65536 ))
        if ! dd if="$LSD_DIR/lsd.jar" of="$LSD_TAIL" bs=65536 skip="$skip" >/dev/null 2>&1 || [[ ! -s "$LSD_TAIL" ]]; then
            rm -f "$LSD_TAIL"; LSD_TAIL="$LSD_DIR/lsd.jar"
        fi
    else
        LSD_TAIL="$LSD_DIR/lsd.jar"
    fi
    return 0
}
[[ -n "$BIN_SEARCH" ]] && lsd_jar_tail
# The JXE is searched in full, with grep only (awk is too slow on a file
# that size).
JXE_SEARCHED=0
case "$BIN_SEARCH" in grep*) [[ -f "$LSD_JXE" ]] && JXE_SEARCHED=1 ;; esac
SEARCHED="lsd/jars"
[[ -n "$LSD_TAIL" ]] && SEARCHED="lsd/lsd.jar, $SEARCHED"
[[ $JXE_SEARCHED -eq 1 ]] && SEARCHED="/ifs/lsd.jxe, $SEARCHED"

# find_stock_class CLASS (slash form, no .class): prints where it was found,
# returns 0 found, 1 not found, 2 skipped.
find_stock_class() {
    typeset hits j
    [[ -n "$BIN_SEARCH" ]] || return 2
    hits=""
    if [[ -n "$LSD_TAIL" ]]; then
        bin_search "$1.class" "$LSD_TAIL" && hits="$hits lsd/lsd.jar"
    fi
    if [[ $JXE_SEARCHED -eq 1 ]]; then
        bin_search "$1" "$LSD_JXE" && hits="$hits /ifs/lsd.jxe"
    fi
    for j in "$JAR_DIR"/*.jar "$JAR_DIR"/*/*.jar; do
        [[ -f "$j" ]] || continue
        case "$j" in */ClusterIntegration_*|*/AndroidAutoCluster_*) continue ;; esac
        bin_search "$1.class" "$j" && hits="$hits lsd/jars/${j#$JAR_DIR/}"
    done
    print -r -- "${hits# }"
    [[ -n "$hits" ]] && return 0
    return 1
}
AA_CLS=de/audi/app/terminalmode/smartphone/androidauto2/AndroidAuto2Subsystem
SM_CLS=de/audi/app/car/adi/legacy/sportchrono/StorageMountHandler
aa_where="$(find_stock_class "$AA_CLS")"; aa_rc=$?
sm_where="$(find_stock_class "$SM_CLS")"; sm_rc=$?
case $aa_rc in
    0) print "stock AA class:    AndroidAuto2Subsystem found in: $aa_where" ;;
    1) print "stock AA class:    AndroidAuto2Subsystem NOT found in $SEARCHED (the search cannot see this unit's class image; report this with the ModKit log)" ;;
    *) print "stock AA class:    skipped" ;;
esac
case $sm_rc in
    0) print "hmi class check:   StorageMountHandler found in: $sm_where" ;;
    1) print "hmi class check:   StorageMountHandler NOT found in $SEARCHED" ;;
    *) print "hmi class check:   skipped" ;;
esac
# The stock subsystem is the control: when it is not seen either, a
# negative result says nothing about the image and is treated as unknown.
if [[ $sm_rc -eq 1 && $aa_rc -ne 0 ]]; then
    print "hmi class check:   control class not found either, so this result is unreliable (treated as unknown)"
    sm_rc=2
fi
# A hit only in the JXE (searched by bare name, which a mere reference to
# the class also matches) while lsd.jar was searched and does not list the
# class is contradictory; treated as unknown so the stand-in stays.
if [[ $sm_rc -eq 0 && -n "$LSD_TAIL" && "$sm_where" == "/ifs/lsd.jxe" ]]; then
    print "hmi class check:   only /ifs/lsd.jxe matched (a reference matches too) while lsd/lsd.jar does not list the class; treated as unknown"
    sm_rc=2
fi

# Stand-in for StorageMountHandler (Audi only). Installed to $JAR_DIR, which
# lsd.sh puts on the boot class path ahead of lsd.jxe, so it is used only
# when no earlier entry provides the class; a real class in a plugin jar
# ahead of it would still win, and shadowing the JXE copy loses nothing the
# mod needs.
STUB_SRC="$MOD_PATH/audi/ClusterIntegration_StorageMountHandler_stub.jar"
STUB_DST="$JAR_DIR/${STUB_SRC##*/}"
INSTALL_STUB=0
if [[ "$OEM" == "AU" ]]; then
    if [[ -e "$MOD_ROOT/no_stub.txt" ]]; then
        print "stand-in class:    OFF (no_stub.txt present)"
    elif [[ $sm_rc -eq 0 ]]; then
        print "stand-in class:    not needed (this HMI image provides StorageMountHandler)"
    elif [[ ! -f "$STUB_SRC" ]]; then
        if [[ -f "$STUB_DST" ]]; then
            INSTALL_STUB=2
            print "stand-in class:    kept (${STUB_DST##*/} is already installed; the card has no audi/ folder to refresh it from)"
        else
            print -u2 "ERROR: $STUB_SRC not found and no stand-in is installed on this unit. Aborting before any change."
            print -u2 "       The shadowed AndroidAuto2Subsystem needs StorageMountHandler, which this HMI image was not seen to provide; without"
            print -u2 "       the stand-in jar Android Auto would stop working. Extract the Audi zip to an empty card (its Update/audi/ folder"
            print -u2 "       carries the jar), or create Mods/ClusterIntegration/no_stub.txt if you know the class exists on this unit."
            [[ -n "$LSD_TAIL" && "$LSD_TAIL" != "$LSD_DIR/lsd.jar" ]] && rm -f "$LSD_TAIL"
            exit 4
        fi
    else
        INSTALL_STUB=1
        if [[ $sm_rc -eq 1 ]]; then
            print "stand-in class:    ON (StorageMountHandler is not in this HMI image; ${STUB_SRC##*/} provides a no-op copy)"
        else
            print "stand-in class:    ON (presence of StorageMountHandler could not be checked; installed by default on Audi, create Mods/ClusterIntegration/no_stub.txt to skip it)"
        fi
    fi
elif [[ $sm_rc -eq 1 ]]; then
    print "WARNING: StorageMountHandler not found in this HMI image (OEM=$OEM); the mod's AndroidAuto2Subsystem needs it and the stand-in is only installed on Audi. Continuing (rollback is available)."
fi

BACKUP_DIR="$MOD_PATH/Backup"
mkdir -p "$BACKUP_DIR" || {
    print -u2 "ERROR: cannot mkdir $BACKUP_DIR"
    [[ -n "$LSD_TAIL" && "$LSD_TAIL" != "$LSD_DIR/lsd.jar" ]] && rm -f "$LSD_TAIL"
    exit 2
}
mkdir -p "$CLUSTER_DIR"

ts() { date +"%Y%m%d_%H%M%S"; }

# Change manifest: one line per file the installer adds, replaces, swaps or
# removes, with the backup copy it made. Appended on every run so the
# history of the head unit's modifications stays on the SD card.
# Rollback = uninstall.sh (via uninstall.txt + ModKit, or Update/rollback.sh
# over SSH): restores gal/dio_manager from .real (or from Backup/ if .real
# is gone) and removes everything listed as "add".
MANIFEST="$BACKUP_DIR/manifest.txt"
RUN_TS="$(ts)"
note() { print "$RUN_TS $*" >> "$MANIFEST" 2>/dev/null; }
note "run   install $RELEASE_VERSION"

print "Slaying running processes before install..."
for proc in cluster gal gal.real dio_manager dio_manager.real; do
    slay -f "$proc" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        print "slay:              $proc"
    fi
done
print ""

# cmp first; if identical skip. Otherwise backup any existing DST and copy.
install_file() {
    src="$1"; dst="$2"
    if [[ ! -f "$src" ]]; then
        print "missing source:    $src"
        return 1
    fi
    files_identical "$src" "$dst"
    if [[ $? -eq 0 ]]; then
        print "skip identical:    $dst"
        return 0
    fi
    if [[ -f "$dst" ]]; then
        bk="$BACKUP_DIR/${dst##*/}.backup.$(ts)"
        cp -p "$dst" "$bk" || { print -u2 "ERROR: backup failed: $dst"; return 2; }
        # Never overwrite a file whose backup is not a verified copy (the
        # size must match; the content too when this unit can compare it).
        files_same "$dst" "$bk"
        vrc=$?
        [[ $vrc -eq 1 ]] && { print -u2 "ERROR: backup verify failed: $bk"; rm -f "$bk"; return 2; }
        [[ $vrc -eq 2 ]] && print "backup verified:   by size only (no content comparison tool on this unit)"
        [[ $vrc -eq 0 && "$FILE_CMP" == wc ]] && print "backup verified:   by size, line and word counts (no checksum tool on this unit)"
        print "backup target:     $dst -> $bk"
        note "replace $dst backup=$bk"
    else
        note "add $dst"
    fi
    cp -p "$src" "$dst" || { print -u2 "ERROR: copy failed: $src -> $dst"; return 3; }
    print "install:           $dst"
}

# Replace $APPS_DIR/NAME (binary) with the wrapper script from $MOD_PATH/NAME.
# Preserves the original binary at $APPS_DIR/NAME.real so uninstall can
# restore it. Idempotent — if NAME.real already exists, the original is
# already saved and we just refresh the wrapper.
swap_binary_for_wrapper() {
    name="$1"
    wrapper_src="$MOD_PATH/$name"
    dst_active="$APPS_DIR/$name"
    dst_real="$APPS_DIR/${name}.real"
    local_real_backup="$BACKUP_DIR/${name}.real"

    if [[ ! -f "$wrapper_src" ]]; then
        print "missing wrapper:   $wrapper_src"
        return 1
    fi

    if [[ -f "$dst_real" ]]; then
        # already swapped before; original safely at .real on device — never
        # overwrite. Always refresh BOTH local backups (stable-name + new
        # timestamped) from the device's .real so the modkit Backup folder
        # always has a current copy of the real binary.
        cp -p "$dst_real" "$local_real_backup" && \
            print "backup .real:      $dst_real -> $local_real_backup"
        bk="$BACKUP_DIR/${name}.original.$(ts)"
        cp -p "$dst_real" "$bk" && \
            print "backup .real (ts): $dst_real -> $bk"
        files_identical "$wrapper_src" "$dst_active"
        if [[ $? -eq 0 ]]; then
            print "skip identical:    $dst_active (wrapper already current)"
            return 0
        fi
        bk="$BACKUP_DIR/${name}.wrapper.backup.$(ts)"
        cp -p "$dst_active" "$bk" 2>/dev/null && print "backup wrapper:    $dst_active -> $bk"
        cp -p "$wrapper_src" "$dst_active" || { print -u2 "ERROR: wrapper copy failed"; return 2; }
        chmod 755 "$dst_active"
        print "refresh wrapper:   $dst_active"
        return 0
    fi

    # first install: original is still the real binary. Backup, then move.
    if [[ ! -f "$dst_active" ]]; then
        print -u2 "WARN: $dst_active not present — nothing to swap"
        return 0
    fi
    # Timestamped historical backup (each run gets its own).
    bk="$BACKUP_DIR/${name}.original.$(ts)"
    cp -p "$dst_active" "$bk" || { print -u2 "ERROR: backup of original $name failed"; return 2; }
    files_same "$dst_active" "$bk"
    vrc=$?
    [[ $vrc -eq 1 ]] && { print -u2 "ERROR: backup verify failed: $bk"; rm -f "$bk"; return 2; }
    [[ $vrc -eq 2 ]] && print "backup verified:   by size only (no content comparison tool on this unit)"
    [[ $vrc -eq 0 && "$FILE_CMP" == wc ]] && print "backup verified:   by size, line and word counts (no checksum tool on this unit)"
    print "backup original:   $dst_active -> $bk"
    # Stable-name local backup (always reflects the original binary content).
    cp -p "$dst_active" "$local_real_backup" && \
        print "backup .real:      $dst_active -> $local_real_backup"
    files_same "$dst_active" "$local_real_backup"
    [[ $? -eq 1 ]] && { print -u2 "ERROR: backup verify failed: $local_real_backup"; return 2; }
    mv "$dst_active" "$dst_real" || { print -u2 "ERROR: mv $name -> $name.real failed"; return 3; }
    print "preserve original: $dst_active -> $dst_real"
    note "swap $dst_active original=$dst_real backup=$bk"
    cp -p "$wrapper_src" "$dst_active" || { print -u2 "ERROR: install wrapper failed"; return 4; }
    chmod 755 "$dst_active"
    print "install wrapper:   $dst_active"
}

# Java classes: on Audi without enable_carplay.txt install the Android-Auto-
# only JAR (Update/aa_only/*_aa.jar, built by modkit/build_sd_package.sh,
# presence checked in the preflight). It lacks the CarPlay classes, so the
# stock CarPlayDSIManager stays in charge of CarPlay and only
# AndroidAuto2Subsystem is shadowed. The full JAR is used on Porsche and on
# Audi with enable_carplay.txt.
if [[ $CARPLAY_HOOK -eq 0 ]]; then
    NEW_JAR="$AA_JAR"
    print "java classes:      Android Auto only (${NEW_JAR##*/}; CarPlay classes not installed)"
else
    print "java classes:      full JAR (${NEW_JAR##*/})"
fi

# Remove any older versions of our jar so only the new one remains (the
# stand-in jar is handled separately below).
typeset j
for j in "$JAR_DIR"/ClusterIntegration_* "$JAR_DIR"/AndroidAutoCluster_*; do
    if [[ -f "$j" && "${j##*/}" != "${NEW_JAR##*/}" && "${j##*/}" != "${STUB_DST##*/}" ]]; then
        bk="$BACKUP_DIR/${j##*/}.backup.$(ts)"
        cp -p "$j" "$bk" && rm -f "$j" && print "remove old jar:    $j -> $bk" && note "remove $j backup=$bk"
    fi
done

install_file "$NEW_JAR"                  "$JAR_DIR/${NEW_JAR##*/}"
if [[ $INSTALL_STUB -eq 1 ]]; then
    install_file "$STUB_SRC" "$STUB_DST"
elif [[ $INSTALL_STUB -eq 0 && -f "$STUB_DST" ]]; then
    bk="$BACKUP_DIR/${STUB_DST##*/}.backup.$(ts)"
    if cp -p "$STUB_DST" "$bk"; then
        rm -f "$STUB_DST" && print "remove stand-in:   $STUB_DST -> $bk" && note "remove $STUB_DST backup=$bk"
    else
        print -u2 "ERROR: could not back up $STUB_DST to $bk; stand-in left in place"
    fi
fi
install_file "$MOD_PATH/cluster"         "$CLUSTER_DIR/cluster"
install_file "$MOD_PATH/gal_cluster.so"  "$CLUSTER_DIR/gal_cluster.so"
install_file "$MOD_PATH/dio_cluster.so"  "$CLUSTER_DIR/dio_cluster.so"

# cluster_config.json — read by Java (AA + CarPlay), cluster daemon, and
# gal_cluster.so at init time. Single source of truth for per-car settings.
# SD-card override path (/fs/sda0/cluster_config.json) takes precedence
# over this installed copy; readers fall through to defaults if neither
# exists. No longer embedded in the JAR.
install_file "$MOD_PATH/cluster_config.json" "$CLUSTER_DIR/cluster_config.json"

chmod 755 "$CLUSTER_DIR/cluster"        2>/dev/null
chmod 755 "$CLUSTER_DIR/gal_cluster.so" 2>/dev/null
chmod 755 "$CLUSTER_DIR/dio_cluster.so" 2>/dev/null
chmod 644 "$CLUSTER_DIR/cluster_config.json" 2>/dev/null

# apply_override KEY VALUE: set KEY in the top-level "config" block of the
# installed cluster_config.json. A plain KEY must start its own line inside
# that block (scalars such as forceRHD). BLOCK.KEY (mirror.mode,
# gal_h264.codecRes, gal_h264.zoomY, ...) sets a scalar inside the inline
# "mirror" / "gal_h264" object of the config block, which is what the
# readers use when carConfig has no entry for the car. carConfig,
# dynamicThresholds and countries are never touched. The shipped file has
# CRLF line endings; they are dropped on rewrite so the block tracking and
# the JSON stay consistent. Returns 1 if the key was not found (file
# unchanged).
apply_override() {
    typeset cfg blk key
    cfg="$CLUSTER_DIR/cluster_config.json"
    case "$1" in
        *.*) blk="${1%%.*}"; key="${1#*.}" ;;
        *)   blk=""; key="$1" ;;
    esac
    if awk -v blk="$blk" -v key="$1" -v sub_key="$key" -v val="$2" '
        BEGIN { inblk = 0; done = 0 }
        { sub(/\r$/, "") }
        /^[ \t]*"config"[ \t]*:[ \t]*\{[ \t]*$/ { inblk = 1 }
        inblk && !done && blk == "" {
            pat = "^[ \t]*\"" key "\"[ \t]*:[ \t]*"
            if (match($0, pat)) {
                rest = substr($0, RLENGTH + 1)
                if (rest !~ /^[\[{]/) {
                    tail = rest
                    sub(/^[^,]*/, "", tail)
                    $0 = substr($0, 1, RLENGTH) val tail
                    done = 1
                }
            }
        }
        inblk && !done && blk != "" {
            pat = "^[ \t]*\"" blk "\"[ \t]*:[ \t]*[{]"
            if (match($0, pat)) {
                pat2 = "\"" sub_key "\"[ \t]*:[ \t]*"
                if (match($0, pat2)) {
                    pre = substr($0, 1, RSTART + RLENGTH - 1)
                    rest = substr($0, RSTART + RLENGTH)
                    if (rest !~ /^[\[{]/ && match(rest, /[,}]/)) {
                        $0 = pre val substr(rest, RSTART)
                        done = 1
                    }
                }
            }
        }
        inblk && /^[ \t]*\},?[ \t]*$/ { inblk = 0 }
        { print }
        END { if (!done) exit 3 }
    ' "$cfg" > "$cfg.ovr"; then
        mv -f "$cfg.ovr" "$cfg" && chmod 644 "$cfg" 2>/dev/null
        return 0
    fi
    rm -f "$cfg.ovr"
    return 1
}

# Per-car config overrides. Mods/ClusterIntegration/config_overrides.txt on
# the SD card holds "key=value" lines (value written as JSON: true, false,
# a number, or "a string"; '#' starts a comment). Each key is applied with
# apply_override above (scalar keys of the "config" block such as forceRHD,
# forceImperial, imperialSmallUnit, bargraphMode, enableMapRender,
# aaClusterMode, heartbeatInterval). Nested objects (mirror, gal_h264) and
# carConfig entries are not touched; use a carConfig entry in the installed
# file for those. Re-running without the file reinstalls the shipped config.
OVERRIDES="$MOD_ROOT/config_overrides.txt"
if [[ -f "$OVERRIDES" ]]; then
    # strip CR and '#' comments, keep key=value lines (awk only: no tr/grep)
    awk '{ sub(/\r$/, ""); sub(/[ \t]*#.*$/, ""); if (index($0, "=") > 0) print }' "$OVERRIDES" | while IFS='=' read -r k v; do
        k="$(print -r -- "$k" | sed -e 's/^[ 	]*//' -e 's/[ 	]*$//')"
        v="$(print -r -- "$v" | sed -e 's/^[ 	]*//' -e 's/[ 	]*$//')"
        [[ -z "$k" || -z "$v" ]] && continue
        case "$k" in
            +([A-Za-z0-9_])|+([A-Za-z0-9_]).+([A-Za-z0-9_])) ;;
            *) print "config override:   WARN '$k' is not a key name (letters, digits, _ and one dot), ignored"; continue ;;
        esac
        # value must be a JSON scalar: true, false, a number, or a quoted string
        vok=0
        case "$v" in
            true|false) vok=1 ;;
            +([0-9])|-+([0-9])|+([0-9]).+([0-9])|-+([0-9]).+([0-9])) vok=1 ;;
            \"*\")
                inner="${v#\"}"; inner="${inner%\"}"
                [[ "$inner" != *\"* ]] && vok=1
                ;;
        esac
        if [[ $vok -eq 0 ]]; then
            print "config override:   WARN '$k' value $v is not true/false, a number or a double-quoted string, ignored"
            continue
        fi
        if apply_override "$k" "$v"; then
            print "config override:   $k = $v"
            note "override $CLUSTER_DIR/cluster_config.json $k=$v"
        else
            print "config override:   WARN '$k' is not a scalar key of the config block (or of its mirror / gal_h264 object), ignored"
        fi
    done
fi

# Environment for the Android Auto hook. Mods/ClusterIntegration/gal_env.txt
# on the SD card holds GAL_CLUSTER_*=value lines (insets in codec-frame
# pixels, GAL_CLUSTER_LOG=1 for live logging, ...); the installer copies the
# valid lines to $CLUSTER_DIR/gal_env and the gal wrapper exports them before
# starting gal.real. Without the file an installed gal_env is removed.
GAL_ENV_SRC="$MOD_ROOT/gal_env.txt"
GAL_ENV_DST="$CLUSTER_DIR/gal_env"
if [[ -f "$GAL_ENV_SRC" ]]; then
    awk '{ sub(/\r$/, ""); sub(/[ \t]*#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
         /^GAL_CLUSTER_[A-Z0-9_]+=[A-Za-z0-9_.:\/-]*$/ { print; n++ }
         END { exit (n > 0 ? 0 : 1) }' "$GAL_ENV_SRC" > "/tmp/cluster_gal_env.$$" 2>/dev/null
    if [[ -s "/tmp/cluster_gal_env.$$" ]]; then
        # the staged file is new every run, so compare by content, not time
        files_same "/tmp/cluster_gal_env.$$" "$GAL_ENV_DST"
        if [[ $? -eq 0 ]]; then
            print "skip identical:    $GAL_ENV_DST"
        else
            install_file "/tmp/cluster_gal_env.$$" "$GAL_ENV_DST" && chmod 644 "$GAL_ENV_DST" 2>/dev/null
        fi
        awk '{ printf "gal env:           %s\n", $0 }' "$GAL_ENV_DST"
    else
        print "gal env:           WARN gal_env.txt has no valid GAL_CLUSTER_NAME=value line, ignored"
    fi
    rm -f "/tmp/cluster_gal_env.$$"
elif [[ -f "$GAL_ENV_DST" ]]; then
    bk="$BACKUP_DIR/gal_env.backup.$(ts)"
    cp -p "$GAL_ENV_DST" "$bk" && rm -f "$GAL_ENV_DST" && print "remove gal env:    $GAL_ENV_DST -> $bk" && note "remove $GAL_ENV_DST backup=$bk"
fi

# Daemon log. Mods/ClusterIntegration/daemon_log.txt on the card installs the
# marker $CLUSTER_DIR/daemon_verbose; the Persist script and the gal wrapper
# then start the cluster daemon with verbose=2 (cluster_daemon.log on the
# first writable USB stick, else /tmp, capped at 1 MB). Without the file the
# daemon runs quiet and an installed marker is removed.
DAEMON_LOG_SRC="$MOD_ROOT/daemon_log.txt"
DAEMON_LOG_DST="$CLUSTER_DIR/daemon_verbose"
if [[ -f "$DAEMON_LOG_SRC" ]]; then
    if [[ ! -f "$DAEMON_LOG_DST" ]]; then
        : > "$DAEMON_LOG_DST" && note "add $DAEMON_LOG_DST"
    fi
    print "daemon log:        ON ($DAEMON_LOG_DST; cluster_daemon.log on USB or /tmp)"
elif [[ -f "$DAEMON_LOG_DST" ]]; then
    rm -f "$DAEMON_LOG_DST" && print "daemon log:        OFF (removed $DAEMON_LOG_DST)" && note "remove $DAEMON_LOG_DST"
else
    print "daemon log:        OFF (create Mods/ClusterIntegration/daemon_log.txt to turn it on)"
fi

swap_binary_for_wrapper gal

# CarPlay hook (dio_manager wrapper + dio_cluster.so). On Porsche it is always
# installed. On Audi it is opt-in via Mods/ClusterIntegration/enable_carplay.txt:
# the hook patches every iAP2 Identify inside the wireless-CarPlay process with
# Porsche-derived object layouts, so on an untested unit it is risk without
# benefit for an Android Auto user. Without the marker any earlier wrapper is
# restored so the unit runs the stock dio_manager.
if [[ $CARPLAY_HOOK -eq 1 ]]; then
    swap_binary_for_wrapper dio_manager
    print "carplay hook:      ON"
else
    if [[ -f "$APPS_DIR/dio_manager.real" ]]; then
        bk="$BACKUP_DIR/dio_manager.wrapper.removed.$(ts)"
        cp -p "$APPS_DIR/dio_manager" "$bk" 2>/dev/null
        mv "$APPS_DIR/dio_manager.real" "$APPS_DIR/dio_manager" && \
            print "restore original:  $APPS_DIR/dio_manager.real -> $APPS_DIR/dio_manager (carplay hook disabled)" && \
            note "restore $APPS_DIR/dio_manager from=$APPS_DIR/dio_manager.real"
    fi
    print "carplay hook:      OFF (Audi default; create Mods/ClusterIntegration/enable_carplay.txt to install it)"
fi

# Diagnostic mode. If Mods/ClusterIntegration/diag.txt exists on the SD card,
# leave a marker that makes the gal wrapper start the hook with
# GAL_CLUSTER_MERGE=0 (no cluster service injected into the phone's service
# discovery, no endpoint table write) plus full logging, and the dio_manager
# wrapper with DIO_CLUSTER_LOG=1. Android Auto then behaves as stock while
# /tmp/gal_cluster.log shows whether the hook loaded, which symbols resolved
# and what the stock service discovery looks like. Re-run without diag.txt
# (or delete the marker over SSH) to go live.
DIAG_MARKER="$CLUSTER_DIR/diag_mode"
if [[ -e "$MOD_ROOT/diag.txt" ]]; then
    if [[ ! -f "$DIAG_MARKER" ]]; then
        : > "$DIAG_MARKER" && chmod 644 "$DIAG_MARKER" && note "add $DIAG_MARKER"
    fi
    # Also switch the installed config to BAP-only ("enableMapRender": false):
    # with the cluster service not injected there is no video to show, and
    # an empty cluster window must not be posted over the native map. The
    # next non-diag run reinstalls the shipped config (install_file sees the
    # difference, backs this copy up and overwrites it).
    if apply_override enableMapRender false; then
        note "override $CLUSTER_DIR/cluster_config.json enableMapRender=false (diag)"
        print "diag mode:         installed cluster_config.json has enableMapRender=false (turn-by-turn only)"
    else
        print "diag mode:         WARN could not set enableMapRender=false in cluster_config.json; video path left enabled"
    fi
    print "diag mode:         ON  ($DIAG_MARKER) - hook logs only, cluster service NOT injected"
    # Stage the small stock jars that contain the classes this mod shadows,
    # so constructor signatures can be compared on a PC with javap
    # (modkit/check_hmi_signatures.sh) before going live. lsd.jar is too
    # big to copy here; its location is printed instead.
    REF_DIR="$BACKUP_DIR/hmi_reference"
    mkdir -p "$REF_DIR" 2>/dev/null
    typeset refjar refn w cp_where
    cp_where="$(find_stock_class de/audi/app/terminalmode/smartphone/carplay/CarPlayDSIManager)"
    for w in $aa_where $cp_where; do
        case "$w" in
            lsd/jars/*)
                refjar="$JAR_DIR/${w#lsd/jars/}"
                if [[ -f "$refjar" && ! -f "$REF_DIR/${refjar##*/}" ]]; then
                    cp -p "$refjar" "$REF_DIR/${refjar##*/}" && print "hmi reference:     ${refjar##*/} -> Backup/hmi_reference/"
                fi
                ;;
            lsd/lsd.jar)
                print "hmi reference:     the shadowed classes are in $LSD_DIR/lsd.jar ($(file_size "$LSD_DIR/lsd.jar") bytes, not copied); copy it to the card over SSH for modkit/check_hmi_signatures.sh"
                ;;
        esac
    done
    refn=0
    for refjar in "$REF_DIR"/*; do [[ -f "$refjar" ]] && refn=$((refn + 1)); done
    print "hmi reference:     $refn stock jar(s) staged for modkit/check_hmi_signatures.sh"
else
    if [[ -f "$DIAG_MARKER" ]]; then
        rm -f "$DIAG_MARKER" && note "remove $DIAG_MARKER"
        print "diag mode:         OFF (marker removed)"
    else
        print "diag mode:         OFF"
    fi
fi

# Informational: does this unit's Android Auto receiver export the symbols
# gal_cluster.so interposes? A missing symbol means that hook is a silent
# pass-through (cluster stays blank), never a crash. Object layouts cannot
# be checked here. Output goes to the ModKit log for the first-boot review.
check_hook_symbols() {
    typeset lib sym present missing cand
    if [[ -z "$BIN_SEARCH" ]]; then
        print "hook symbols:      skipped (no command on this unit finds a name inside a binary file)"
        return 0
    fi
    lib=""
    if have find; then
        lib="$(find /mnt/app/eso /mnt/app/armle -name 'libautoreceiver*' 2>/dev/null | head -1)"
        [[ -z "$lib" ]] && lib="$(find /mnt/app -name 'libautoreceiver*' 2>/dev/null | head -1)"
    else
        for cand in /mnt/app/eso/lib/libautoreceiver* /mnt/app/eso/lib/*/libautoreceiver* /mnt/app/armle/lib/libautoreceiver* \
                    /mnt/app/armle/usr/lib/libautoreceiver* /mnt/app/eso/bin/apps/libautoreceiver* /mnt/app/eso/bin/apps/*/libautoreceiver* \
                    /mnt/app/*/lib/libautoreceiver* /mnt/app/*/*/lib/libautoreceiver*; do
            if [[ -f "$cand" ]]; then lib="$cand"; break; fi
        done
    fi
    if [[ -z "$lib" ]]; then
        print "hook symbols:      libautoreceiver not found under /mnt/app (check skipped$(have find || print ', no find on this unit'))"
        return 0
    fi
    set -A HOOK_SYMS \
        _ZN13MessageRouter32populateServiceDiscoveryResponseEP24ServiceDiscoveryResponse \
        _ZN13MessageRouter13queueOutgoingEhPvj \
        _ZN13MessageRouter19sendChannelOpenRespEhi \
        _ZN13MessageRouter20handleChannelOpenReqEhRK18ChannelOpenRequest \
        _ZN13MessageRouter12routeMessageEhRK10shared_ptrI8IoBufferE \
        _ZN10Controller12routeMessageEhtRK10shared_ptrI8IoBufferE \
        _ZN13MediaSinkBase12routeMessageEhtRK10shared_ptrI8IoBufferE \
        _ZN24NavigationStatusEndpoint16addDiscoveryInfoEP24ServiceDiscoveryResponse \
        _ZN24NavigationStatusEndpoint22handleNavigationStatusERK16NavigationStatus \
        _ZN24NavigationStatusEndpoint29handleNavigationDistanceEventERK31NavigationNextTurnDistanceEvent \
        _ZN24NavigationStatusEndpoint29handleNavigationNextTurnEventERK23NavigationNextTurnEvent \
        _ZN24NavigationStatusEndpoint4stopEv \
        _ZN24NavigationStatusEndpoint5startEv \
        _ZN27NavFocusRequestNotification27MergePartialFromCodedStreamEPN6google8protobuf2io16CodedInputStreamE
    present=0; missing=""
    for sym in "${HOOK_SYMS[@]}"; do
        if bin_search "$sym" "$lib"; then
            present=$((present + 1))
        else
            missing="$missing $sym"
        fi
    done
    print "hook symbols:      $present/14 present in $lib"
    [[ -n "$missing" ]] && print "hook symbols:      missing:$missing"
    return 0
}
check_hook_symbols
[[ -n "$LSD_TAIL" && "$LSD_TAIL" != "$LSD_DIR/lsd.jar" ]] && rm -f "$LSD_TAIL"

sync
print ""
print "Backups:           $BACKUP_DIR (manifest.txt lists every change)"
print "Diagnostics:       put diag.txt in Mods/ClusterIntegration/ and re-run to log without injecting (see README)"
print "Rollback:          put uninstall.txt in Mods/ClusterIntegration/ and re-run the ModKit,"
print "                   or over SSH: ksh $MOD_PATH/rollback.sh"
print "Done."

