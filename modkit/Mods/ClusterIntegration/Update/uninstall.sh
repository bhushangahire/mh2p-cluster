#!/bin/ksh
#
# Copyright (c) 2026 fifthBro
# https://fifthbro.github.io
#
# Licensed under CC BY-NC-SA 4.0
# https://creativecommons.org/licenses/by-nc-sa/4.0/
# NOT FOR COMMERCIAL USE
#
# uninstall.sh 
#
# Idempotent uninstaller. Re-runs are safe.
# - Restores original gal binary: removes wrapper at /mnt/app/eso/bin/apps/gal
#   and moves gal.real back to gal.
# - Same for dio_manager.
# - Backs up and removes JAR + native binaries from their install dirs
#   (every ClusterIntegration_* jar, which includes the Audi stand-in jar
#   ClusterIntegration_StorageMountHandler_stub.jar).
# - If NAME.real is missing but NAME is still our wrapper, restores the
#   original from Backup/NAME.real on the SD card.
# - Appends what it did to Backup/manifest.txt.

set -u

export MOD_PATH="${modPath:-${MOD_PATH:-}}"
[[ -z "$MOD_PATH" ]] && { print -u2 "ERROR: MOD_PATH not set"; exit 1; }

[[ ! -e /mnt/app ]] && mount -t qnx6 /dev/mnanda0t177.1 /mnt/app
mount -uw /mnt/app/

# Same PATH extension as install.sh (part of the unit's toolset lives under
# /mnt/app/armle); appended, never prepended.
export PATH="${PATH:-/bin:/usr/bin}:/mnt/app/armle/usr/bin:/mnt/app/armle/bin:/usr/bin:/bin"

export RELEASE_VERSION=`/mnt/app/armle/usr/bin/pc b:46924065:401 | cut -c 61- | sed ':a;N;$!ba;s/\n//g' | sed -e 's/\.//g' | sed -e 's/ //g'`
export OEM="$(echo $RELEASE_VERSION | cut -d'_' -f3 | cut -b -2)"

# No OEM gate on uninstall: every step below only restores or removes files
# this mod created (gal.real / dio_manager.real, our JAR, our cluster dir),
# so it is safe on Porsche, Audi, or any unit where the mod was forced in.
print "Head unit:         release=$RELEASE_VERSION oem=$OEM"

JAR_DIR=/mnt/app/eso/hmi/lsd/jars
CLUSTER_DIR=/mnt/app/eso/bin/apps/cluster
APPS_DIR=/mnt/app/eso/bin/apps

BACKUP_DIR="$MOD_PATH/Backup"
mkdir -p "$BACKUP_DIR" || { print -u2 "ERROR: cannot mkdir $BACKUP_DIR"; exit 2; }

ts() { date +"%Y%m%d_%H%M%S"; }

MANIFEST="$BACKUP_DIR/manifest.txt"
RUN_TS="$(ts)"
note() { print "$RUN_TS $*" >> "$MANIFEST" 2>/dev/null; }
note "run   uninstall $RELEASE_VERSION"

is_wrapper_script() {
    # Our wrappers start with "#!/bin/ksh"; the real binaries are ELF.
    # dd is what the ModKit itself uses for this kind of check on QNX.
    [[ -f "$1" ]] || return 1
    [[ "$(dd if="$1" bs=1 count=10 2>/dev/null)" == "#!/bin/ksh" ]]
}

print "Slaying running processes before uninstall..."
for proc in cluster gal gal.real dio_manager dio_manager.real; do
    slay -f "$proc" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        print "slay:              $proc"
    fi
done
print ""

# Reverse of swap_binary_for_wrapper. If NAME.real exists, remove the
# wrapper at NAME and move NAME.real -> NAME. If NAME.real doesn't exist,
# nothing was swapped �� skip.
restore_wrapped_binary() {
    name="$1"
    dst_active="$APPS_DIR/$name"
    dst_real="$APPS_DIR/${name}.real"
    sd_real_backup="$BACKUP_DIR/${name}.real"

    if [[ ! -f "$dst_real" ]]; then
        # Fallback: .real is gone but our wrapper is still in place and the
        # SD card still holds the stable-name copy of the original binary.
        if is_wrapper_script "$dst_active" && [[ -f "$sd_real_backup" ]]; then
            bk="$BACKUP_DIR/${name}.wrapper.removed.$(ts)"
            cp -p "$dst_active" "$bk" 2>/dev/null && print "backup wrapper:    $dst_active -> $bk"
            cp -p "$sd_real_backup" "$dst_active" || { print -u2 "ERROR: restore from $sd_real_backup failed"; return 2; }
            chmod 755 "$dst_active"
            print "restore original:  $sd_real_backup -> $dst_active (from SD backup)"
            note "restore $dst_active from=$sd_real_backup"
            return 0
        fi
        if is_wrapper_script "$dst_active"; then
            print -u2 "ERROR: $dst_active is our wrapper but neither $dst_real nor $sd_real_backup exists - cannot restore $name"
            return 3
        fi
        print "skip restore:      $name (no $dst_real present)"
        return 0
    fi
    if [[ -f "$dst_active" ]]; then
        bk="$BACKUP_DIR/${name}.wrapper.removed.$(ts)"
        cp -p "$dst_active" "$bk" 2>/dev/null && print "backup wrapper:    $dst_active -> $bk"
        rm -f "$dst_active"
    fi
    mv "$dst_real" "$dst_active" || { print -u2 "ERROR: mv $name.real -> $name failed"; return 2; }
    print "restore original:  $dst_real -> $dst_active"
    note "restore $dst_active from=$dst_real"
}

backup_and_remove() {
    f="$1"
    if [[ ! -f "$f" ]]; then
        print "skip absent:       $f"
        return 0
    fi
    bk="$BACKUP_DIR/${f##*/}.removed.$(ts)"
    cp -p "$f" "$bk" || { print -u2 "ERROR: backup failed: $f"; return 2; }
    rm -f "$f"
    print "remove:            $f -> $bk"
    note "remove $f backup=$bk"
}

# need our .so files until processes restart, but removing them after the
# restore is fine because next gal/dio_manager spawn won't use them). ──
restore_wrapped_binary gal
restore_wrapped_binary dio_manager

backup_and_remove "$CLUSTER_DIR/cluster"
backup_and_remove "$CLUSTER_DIR/gal_cluster.so"
backup_and_remove "$CLUSTER_DIR/dio_cluster.so"
backup_and_remove "$CLUSTER_DIR/cluster_config.json"
[[ -f "$CLUSTER_DIR/diag_mode" ]] && rm -f "$CLUSTER_DIR/diag_mode" && print "remove:            $CLUSTER_DIR/diag_mode" && note "remove $CLUSTER_DIR/diag_mode"
[[ -f "$CLUSTER_DIR/daemon_verbose" ]] && rm -f "$CLUSTER_DIR/daemon_verbose" && print "remove:            $CLUSTER_DIR/daemon_verbose" && note "remove $CLUSTER_DIR/daemon_verbose"

typeset j
for j in "$JAR_DIR"/ClusterIntegration_* "$JAR_DIR"/AndroidAutoCluster_*; do
    [[ -f "$j" ]] && backup_and_remove "$j"
done

# Anything else the installer recorded as "add" under the mod's own
# directories (future files this fixed list does not know about). Only
# paths inside $CLUSTER_DIR or our jar name pattern are considered, so a
# stale or edited manifest cannot make this remove stock files.
if [[ -f "$MANIFEST" ]]; then
    typeset addf
    awk '$2 == "add" && !seen[$3]++ { print $3 }' "$MANIFEST" 2>/dev/null | while read -r addf; do
        case "$addf" in
            "$CLUSTER_DIR"/*|"$JAR_DIR"/ClusterIntegration_*)
                [[ -f "$addf" ]] && backup_and_remove "$addf"
                ;;
        esac
    done
fi

if [[ -d "$CLUSTER_DIR" ]] && [[ -z "$(ls -A "$CLUSTER_DIR" 2>/dev/null)" ]]; then
    rmdir "$CLUSTER_DIR" 2>/dev/null && print "rmdir empty:       $CLUSTER_DIR"
fi

sync
print ""
print "Done."

