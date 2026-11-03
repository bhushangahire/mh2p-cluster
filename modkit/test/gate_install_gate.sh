#!/usr/bin/env bash
set -u
SCR="$1"; REPO="$2"
STUBS="$SCR/stubs"; mkdir -p "$STUBS"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/slay"; printf '#!/bin/sh\nexit 0\n' > "$STUBS/mount"; chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"
reset_tree() {
    rm -rf /mnt/app
    mkdir -p /mnt/app/armle/usr/bin /mnt/app/eso/hmi/lsd/jars /mnt/app/eso/bin/apps
    printf 'GALBIN\n' > /mnt/app/eso/bin/apps/gal; printf 'DIOBIN\n' > /mnt/app/eso/bin/apps/dio_manager
    chmod 755 /mnt/app/eso/bin/apps/*
    printf '#!/bin/sh\nprintf "%%060d%%s\\n" 0 "$FAKE_RELEASE"\n' > /mnt/app/armle/usr/bin/pc; chmod 755 /mnt/app/armle/usr/bin/pc
    # stock HMI jar carrying the Porsche-side class the preflight looks for
    rm -rf "$SCR/fakejars"; mkdir -p "$SCR/fakejars/de/audi/app/car/adi/legacy/sportchrono"; echo y > "$SCR/fakejars/de/audi/app/car/adi/legacy/sportchrono/StorageMountHandler.class"
    (cd "$SCR/fakejars" && zip -q /mnt/app/eso/hmi/lsd/jars/de.audi.app.car.jar de/audi/app/car/adi/legacy/sportchrono/StorageMountHandler.class)
}
make_sd() {
    rm -rf "$SCR/fakesd"; mkdir -p "$SCR/fakesd/Mods/ClusterIntegration"
    cp -r "$REPO/modkit/Mods/ClusterIntegration/Update" "$SCR/fakesd/Mods/ClusterIntegration/"
    for f in ClusterIntegration_vTEST.jar cluster gal_cluster.so dio_cluster.so cluster_config.json; do printf 'payload %s\n' "$f" > "$SCR/fakesd/Mods/ClusterIntegration/Update/$f"; done
    mkdir -p "$SCR/fakesd/Mods/ClusterIntegration/Update/aa_only"; printf 'payload aa jar\n' > "$SCR/fakesd/Mods/ClusterIntegration/Update/aa_only/ClusterIntegration_vTEST_aa.jar"
}
export MOD_PATH="$SCR/fakesd/Mods/ClusterIntegration/Update"
gate_case() { # name release force expect
    reset_tree; make_sd; [[ "$3" == 1 ]] && touch "$SCR/fakesd/Mods/ClusterIntegration/force_install.txt"
    export FAKE_RELEASE="$2"; out=$(mksh "$MOD_PATH/install.sh" 2>&1); rc=$?
    inst=0; [[ ( -f /mnt/app/eso/hmi/lsd/jars/ClusterIntegration_vTEST.jar || -f /mnt/app/eso/hmi/lsd/jars/ClusterIntegration_vTEST_aa.jar ) && -f /mnt/app/eso/bin/apps/gal.real ]] && inst=1
    printf '%-34s rc=%s installed=%s expected=%s %s\n' "$1" "$rc" "$inst" "$4" "$([[ $inst == $4 ]] && echo PASS || echo FAIL)"
    echo "$out" | grep -E "Head unit|Aborting|EXPERIMENTAL|WARNING|OK, installing|ERROR|Backups:|Rollback:" | sed 's/^/    | /'
}
gate_case "AU user string P2873"      "MH2p_ER_AUG35_P2873" 0 1
gate_case "AU out-of-range P2210"     "MH2p_ER_AUG35_P2210" 0 0
gate_case "AU out-of-range +force"    "MH2p_ER_AUG35_P2210" 1 1
gate_case "AU 26xx"                   "MH2p_ER_AUG36_P2650" 0 1
gate_case "PO in-range (regression)"  "MH2p_US_PO416_P2870" 0 1
gate_case "VW abort (regression)"     "MH2p_ER_VW416_P2870" 0 0

echo "=== manifest after install ==="; cat "$MOD_PATH/Backup/manifest.txt" | sed 's/^/    | /'
echo "=== Backup dir ==="; ls "$MOD_PATH/Backup" | sed 's/^/    | /'

echo "=== uninstall fallback: .real deleted, wrapper in place, SD backup present ==="
reset_tree; make_sd; export FAKE_RELEASE="MH2p_ER_AUG35_P2873"; mksh "$MOD_PATH/install.sh" >/dev/null 2>&1
rm -f /mnt/app/eso/bin/apps/gal.real
out=$(mksh "$MOD_PATH/uninstall.sh" 2>&1); rc=$?
[[ "$(cat /mnt/app/eso/bin/apps/gal)" == "GALBIN" && ! -f /mnt/app/eso/bin/apps/gal.real && ! -f /mnt/app/eso/hmi/lsd/jars/ClusterIntegration_vTEST.jar && ! -f /mnt/app/eso/hmi/lsd/jars/ClusterIntegration_vTEST_aa.jar ]] && echo "fallback restore                   rc=$rc PASS" || echo "fallback restore                   rc=$rc FAIL"
echo "$out" | grep -E "restore original|ERROR|skip restore" | sed 's/^/    | /'

echo "=== uninstall with wrapper but no backups anywhere -> ERROR, wrapper left untouched ==="
reset_tree; make_sd; mksh "$MOD_PATH/install.sh" >/dev/null 2>&1
rm -f /mnt/app/eso/bin/apps/gal.real "$MOD_PATH/Backup/gal.real"
out=$(mksh "$MOD_PATH/uninstall.sh" 2>&1); rc=$?
head -1 /mnt/app/eso/bin/apps/gal | grep -q '#!/bin/ksh' && echo "$out" | grep -q "cannot restore gal" && echo "no-backup error path               PASS" || echo "no-backup error path               FAIL"
echo "$out" | grep -E "ERROR" | sed 's/^/    | /'

echo "=== rollback.sh (no MOD_PATH in env) ==="
reset_tree; make_sd; mksh "$MOD_PATH/install.sh" >/dev/null 2>&1
( unset MOD_PATH; cd /; out=$(mksh "$SCR/fakesd/Mods/ClusterIntegration/Update/rollback.sh" 2>&1); rc=$?
  [[ "$(cat /mnt/app/eso/bin/apps/gal)" == "GALBIN" && "$(cat /mnt/app/eso/bin/apps/dio_manager)" == "DIOBIN" && ! -f /mnt/app/eso/hmi/lsd/jars/ClusterIntegration_vTEST.jar && ! -d /mnt/app/eso/bin/apps/cluster ]] && echo "rollback.sh                        rc=$rc PASS" || echo "rollback.sh                        rc=$rc FAIL"
  echo "$out" | grep -E "Head unit|restore original|remove:|rmdir" | sed 's/^/    | /' )
echo "=== manifest tail ==="; tail -6 "$MOD_PATH/Backup/manifest.txt" | sed 's/^/    | /'

echo "=== re-install after rollback (fresh .real, idempotent) ==="
out=$(mksh "$MOD_PATH/install.sh" 2>&1); mksh "$MOD_PATH/install.sh" 2>&1 | grep -c "skip identical" | sed 's/^/    | skip-identical on 2nd run: /'
[[ "$(cat /mnt/app/eso/bin/apps/gal.real)" == "GALBIN" ]] && echo "re-install preserves original      PASS" || echo "re-install preserves original      FAIL"
rm -rf /mnt/app
