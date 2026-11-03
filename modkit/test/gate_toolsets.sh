#!/usr/bin/env bash
# gate_test4.sh SCRATCH REPO TOOLSET : installer behaviour on a simulated Audi unit
set -u
SCR="$1"; REPO="$2"; TS="$3"; export PATH="$SCR/stubs:$PATH"
M="$SCR/mkshwrap_$TS/mksh"
SYMS_SO=$SCR/zip34/Mods/ClusterIntegration/Update/gal_cluster.so
AA=de/audi/app/terminalmode/smartphone/androidauto2/AndroidAuto2Subsystem
SM=de/audi/app/car/adi/legacy/sportchrono/StorageMountHandler
CP=de/audi/app/terminalmode/smartphone/carplay/CarPlayDSIManager
res() { printf '%-60s %s\n' "$1" "$2"; }
mkjar() { # out.jar big? classes...   (central directory at the end, > 8 MB when big)
  local out="$1" big="$2"; shift 2; rm -rf "$SCR/jarsrc"; mkdir -p "$SCR/jarsrc"
  (cd "$SCR/jarsrc"; for c in "$@"; do mkdir -p "$(dirname "$c")"; head -c 300 /dev/urandom > "$c"; done
   [[ "$big" == 1 ]] && head -c 10485760 /dev/urandom > pad.bin
   rm -f "$out"; zip -q -0 -r "$out" . )
}
setup() { # $1 release  $2 lsd.jar: none|aa|aa+sm  $3 jxe: none|aa|aa+sm  $4 markers
  rm -rf /mnt/app /fs /ifs; mkdir -p /mnt/app/armle/usr/bin /mnt/app/armle/bin /mnt/app/eso/hmi/lsd/jars /mnt/app/eso/bin/apps /mnt/app/eso/lib /ifs
  ln -sf /usr/bin/wc /mnt/app/armle/usr/bin/wc      # the unit keeps wc here, off the ModKit PATH
  printf 'GALBIN\n' > /mnt/app/eso/bin/apps/gal; printf 'DIOBIN\n' > /mnt/app/eso/bin/apps/dio_manager; chmod 755 /mnt/app/eso/bin/apps/*
  printf '#!/bin/sh\nprintf "%%060d%%s\\n" 0 "'"$1"'"\n' > /mnt/app/armle/usr/bin/pc; chmod 755 /mnt/app/armle/usr/bin/pc
  # five small plugin jars like the unit's, none with the classes
  for j in AppDevelopment diag xEventRecorder xTcpKeyPanel xTcpLog; do mkjar /mnt/app/eso/hmi/lsd/jars/$j.jar 0 de/audi/plugins/$j/Plugin.class; done
  case "$2" in aa) mkjar /mnt/app/eso/hmi/lsd/lsd.jar 1 $AA.class $CP.class ;; aa+sm) mkjar /mnt/app/eso/hmi/lsd/lsd.jar 1 $AA.class $CP.class $SM.class ;; esac
  case "$3" in aa) { head -c 4000 /dev/urandom; printf '%s' "$AA"; head -c 4000 /dev/urandom; } > /ifs/lsd.jxe ;;
               aa+sm) { head -c 4000 /dev/urandom; printf '%s' "$AA"; head -c 100 /dev/urandom; printf '%s' "$SM"; head -c 4000 /dev/urandom; } > /ifs/lsd.jxe ;; esac
  { head -c 200 /dev/urandom; readelf --dyn-syms -W $SYMS_SO | awk '$7!="UND" && $4=="FUNC" && $5=="GLOBAL" {print $8}' | grep '^_ZN' | grep -v sendChannelOpenResp; head -c 200 /dev/urandom; } > /mnt/app/eso/lib/libautoreceiver.so
  rm -rf "$SCR/fakesd"; mkdir -p "$SCR/fakesd/Mods/ClusterIntegration"; cp -r "$REPO/modkit/Mods/ClusterIntegration/Update" "$SCR/fakesd/Mods/ClusterIntegration/"
  cp "$SCR/zip34/Mods/ClusterIntegration/Update/ClusterIntegration_v0034_beta2_candidate_90d0b76.jar" "$SCR/fakesd/Mods/ClusterIntegration/Update/"
  for f in cluster gal_cluster.so dio_cluster.so; do printf 'payload %s\n' "$f" > "$SCR/fakesd/Mods/ClusterIntegration/Update/$f"; done
  cp $SCR/zip34/Mods/ClusterIntegration/Update/cluster_config.json "$SCR/fakesd/Mods/ClusterIntegration/Update/"
  # keep the restricted PATH: the unit's /usr/bin is QNX, the harness box's is not
  sed -i 's|^export PATH=.*|export PATH="$PATH:/mnt/app/armle/usr/bin:/mnt/app/armle/bin"|' "$SCR/fakesd/Mods/ClusterIntegration/Update/install.sh" "$SCR/fakesd/Mods/ClusterIntegration/Update/uninstall.sh"
  for m in $4; do touch "$SCR/fakesd/Mods/ClusterIntegration/$m"; done
  export MOD_PATH="$SCR/fakesd/Mods/ClusterIntegration/Update"
}
STUB=/mnt/app/eso/hmi/lsd/jars/ClusterIntegration_StorageMountHandler_stub.jar
run() { "$M" "$MOD_PATH/install.sh" 2>&1; }
echo "##### toolset $TS"
echo "=== A: Audi, lsd.jar has AA but not SM, jxe has AA only"
setup MH2p_ER_AUG35_P2873 aa aa "diag.txt"; out=$(run); rc=$?
echo "$out" | grep -E 'tools missing|file compare|binary search|stock AA|hmi class|stand-in|hook symbols|backup verified|hmi reference|ERROR' | sed 's/^/    | /'
[[ $rc == 0 ]] && res "A install exit 0" PASS || res "A install exit 0" "FAIL ($rc)"
echo "$out" | grep -q 'tools missing:.* wc' && res "A wc found via armle PATH" FAIL || res "A wc found via armle PATH" PASS
if echo "$out" | grep -q 'binary search:     none'; then
  [[ -f $STUB ]] && res "A stub installed by default when unknown" PASS || res "A stub installed by default when unknown" FAIL
  echo "$out" | grep -q 'hook symbols:      skipped' && res "A symbols skipped (no binary search)" PASS || res "A symbols skipped" FAIL
else
  echo "$out" | grep -q 'stock AA class:    AndroidAuto2Subsystem found in: lsd/lsd.jar' && res "A control class found in lsd.jar tail" PASS || res "A control class found in lsd.jar tail" FAIL
  echo "$out" | grep -q 'StorageMountHandler NOT found' && [[ -f $STUB ]] && res "A SM not found -> stub installed" PASS || res "A SM not found -> stub installed" FAIL
  echo "$out" | grep -q 'hook symbols:      13/14' && res "A symbols 13/14 via self-tested search" PASS || res "A symbols 13/14" FAIL
  echo "$out" | grep -q 'hmi reference:     the shadowed classes are in /mnt/app/eso/hmi/lsd/lsd.jar' && res "A lsd.jar named for signature check" PASS || res "A lsd.jar named" FAIL
fi
grep -q "add $STUB" "$MOD_PATH/Backup/manifest.txt" && res "A stub recorded as add in manifest" PASS || res "A stub recorded" FAIL
[[ -f /mnt/app/eso/hmi/lsd/jars/ClusterIntegration_v0034_beta2_candidate_90d0b76_aa.jar && ! -f /mnt/app/eso/hmi/lsd/jars/ClusterIntegration_v0034_beta2_candidate_90d0b76.jar ]] && res "A aa_only jar installed, full jar not" PASS || res "A aa_only jar" FAIL
[[ ! -f /tmp/cluster_lsdtail.* ]] 2>/dev/null; ls /tmp/cluster_lsdtail.* >/dev/null 2>&1 && res "A tail temp file removed" FAIL || res "A tail temp file removed" PASS
echo "=== A2: re-run is idempotent (no stub churn)"
sleep 1; out=$(run)
echo "$out" | grep -q "skip identical:    $STUB" && res "A2 stub skip identical on re-run" PASS || res "A2 stub skip identical" FAIL
churn=$(ls "$MOD_PATH/Backup" | grep -E '^(ClusterIntegration_.*\.jar|cluster|gal_cluster\.so|dio_cluster\.so)\.backup\.' | wc -l)
[[ $churn -eq 0 ]] && res "A2 unchanged files not re-backed-up on re-run" PASS || res "A2 unchanged files re-backed-up ($churn)" FAIL
echo "$out" | grep -c 'skip identical' | awk '{ if ($1 >= 4) print "PASS"; else print "FAIL" }' | sed 's/^/A2 skip identical lines on re-run                             /'
echo "=== B: no_stub.txt removes an installed stub"
touch "$SCR/fakesd/Mods/ClusterIntegration/no_stub.txt"; out=$(run)
echo "$out" | grep -q 'stand-in class:    OFF' && [[ ! -f $STUB ]] && res "B no_stub.txt -> stub removed" PASS || res "B no_stub.txt" FAIL
echo "$out" | grep -q "remove stand-in:   $STUB" && res "B removal logged" PASS || res "B removal logged" FAIL
rm -f "$SCR/fakesd/Mods/ClusterIntegration/no_stub.txt"
echo "=== C: uninstall removes everything incl. stub"
run >/dev/null; out=$("$M" "$MOD_PATH/uninstall.sh" 2>&1)
[[ ! -f $STUB && ! -f /mnt/app/eso/bin/apps/gal.real && "$(cat /mnt/app/eso/bin/apps/gal)" == "GALBIN" && -z "$(ls /mnt/app/eso/hmi/lsd/jars | grep ClusterIntegration)" ]] && res "C uninstall clean" PASS || res "C uninstall clean" FAIL
echo "=== D: lsd.jar provides SM -> stub not needed (and removed if present)"
setup MH2p_ER_AUG35_P2873 aa+sm aa+sm ""; touch $STUB; out=$(run)
if echo "$out" | grep -q 'binary search:     none'; then
  [[ -f $STUB ]] && res "D (no search) stub kept by default" PASS || res "D (no search) stub kept" FAIL
else
  echo "$out" | grep -q 'stand-in class:    not needed' && [[ ! -f $STUB ]] && res "D SM found -> stub not installed, stale one removed" PASS || res "D SM found" FAIL
fi
echo "=== E: jxe only (no lsd.jar), grep toolsets search it"
setup MH2p_ER_AUG35_P2873 none aa+sm ""; out=$(run)
echo "$out" | grep -E 'binary search|stock AA|hmi class|stand-in' | sed 's/^/    | /'
if echo "$out" | grep -q 'binary search:     grep'; then
  echo "$out" | grep -q 'found in: /ifs/lsd.jxe' && res "E classes found in jxe" PASS || res "E classes found in jxe" FAIL
else
  echo "$out" | grep -q 'stand-in class:    ON' && res "E no grep -> stub on (unknown)" PASS || res "E stub on" FAIL
fi
echo "=== F: control class invisible -> SM negative treated as unknown"
setup MH2p_ER_AUG35_P2873 none none ""; out=$(run)
echo "$out" | grep -q 'stand-in class:    ON (presence of StorageMountHandler could not be checked' && res "F unknown -> default stub" PASS || res "F unknown -> default stub" FAIL
echo "=== G: Porsche never gets the stub"
setup MH2p_US_PO416_P2870 aa aa ""; out=$(run)
[[ ! -f $STUB ]] && ! echo "$out" | grep -q 'stand-in class:' && res "G Porsche: no stub line, no stub" PASS || res "G Porsche no stub" FAIL
echo "$out" | grep -q 'WARNING: StorageMountHandler not found in this Porsche' && res "G Porsche warning when SM missing (search worked)" PASS || res "G Porsche warning (or skipped)" "n/a"
echo "=== H: backup verification path"
setup MH2p_ER_AUG35_P2873 aa aa ""; run >/dev/null; printf 'changed\n' > "$MOD_PATH/cluster"; out=$(run)
echo "$out" | grep -E 'file compare|backup verified|backup target.*cluster ' | sed 's/^/    | /'
echo "$out" | grep -q 'backup target:     /mnt/app/eso/bin/apps/cluster/cluster ->' && res "H changed file backed up and replaced" PASS || res "H changed file replaced" FAIL
if echo "$out" | grep -q 'file compare:      wc'; then echo "$out" | grep -q 'backup verified:   by size, line and word counts' && res "H wc fingerprint verification reported" PASS || res "H wc fingerprint reported" FAIL; elif echo "$out" | grep -q 'file compare:      size only'; then echo "$out" | grep -q 'backup verified:   by size only' && res "H size-only verification reported" PASS || res "H size-only reported" FAIL; else res "H content comparator used" PASS; fi
rm -rf /mnt/app /fs /ifs "$SCR/jarsrc"
echo "=== I: block.key overrides and gal_env.txt"
setup MH2p_ER_AUG35_P2873 aa aa ""
printf 'gal_h264.mode="stretch"\r\ngal_h264.codecRes=1080\r\ngal_h264.zoomY=1.5\r\nmirror.panX=0.25\r\nforceRHD=true\r\nconfig.bad=1\r\ngal_h264.nested={1}\r\n' > "$SCR/fakesd/Mods/ClusterIntegration/config_overrides.txt"
printf '# insets\r\nGAL_CLUSTER_INSET_TOP=180\r\nGAL_CLUSTER_INSET_BOTTOM=180  # band\r\nGAL_CLUSTER_LOG=1\r\nPATH=/evil\r\nGAL_CLUSTER_X=a b\r\n' > "$SCR/fakesd/Mods/ClusterIntegration/gal_env.txt"
out=$(run); echo "$out" | grep -E 'config override|gal env' | sed 's/^/    | /'
python3 - /mnt/app/eso/bin/apps/cluster/cluster_config.json <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
g=c["config"]["gal_h264"]; m=c["config"]["mirror"]
def res(n,ok): print(("PASS " if ok else "FAIL ")+n)
res("I gal_h264.mode stretch", g["mode"]=="stretch")
res("I gal_h264.codecRes 1080", g["codecRes"]==1080)
res("I gal_h264.zoomY 1.5", g["zoomY"]==1.5)
res("I mirror.panX 0.25, other mirror keys intact", m["panX"]==0.25 and m["mode"]=="fill" and m["zoomX"]==1.0)
res("I forceRHD still works", c["config"]["forceRHD"] is True)
res("I carConfig untouched", all(v["gal_h264"]["mode"]=="letter" for v in c["carConfig"].values()))
PY
echo "$out" | grep -q "config override:   WARN 'config.bad'" && res "I unknown block.key ignored" PASS || res "I unknown block.key ignored" FAIL
echo "$out" | grep -q "WARN 'gal_h264.nested' value" && res "I non-scalar value rejected" PASS || res "I non-scalar value rejected" FAIL
GE=/mnt/app/eso/bin/apps/cluster/gal_env
[[ "$(cat $GE)" == $'GAL_CLUSTER_INSET_TOP=180\nGAL_CLUSTER_INSET_BOTTOM=180\nGAL_CLUSTER_LOG=1' ]] && res "I gal_env holds only valid lines (CR/comments/PATH/spaces dropped)" PASS || { res "I gal_env content" FAIL; cat $GE; }
grep -q "add $GE" "$MOD_PATH/Backup/manifest.txt" && res "I gal_env recorded as add" PASS || res "I gal_env recorded as add" FAIL
printf '#!/bin/sh\necho "TOP=$GAL_CLUSTER_INSET_TOP LOG=$GAL_CLUSTER_LOG MERGE=${GAL_CLUSTER_MERGE:-unset}"\n' > /mnt/app/eso/bin/apps/gal.real; chmod 755 /mnt/app/eso/bin/apps/gal.real
mksh /mnt/app/eso/bin/apps/gal 2>/dev/null | grep -q 'TOP=180 LOG=1 MERGE=unset' && res "I wrapper exports gal_env (live mode)" PASS || res "I wrapper exports gal_env" FAIL
grep -q 'gal env: GAL_CLUSTER_LOG=1' /tmp/gal_preload.log && res "I wrapper logs the env lines" PASS || res "I wrapper logs env" FAIL
rm -f "$SCR/fakesd/Mods/ClusterIntegration/gal_env.txt"; out=$(run)
[[ ! -f $GE ]] && echo "$out" | grep -q 'remove gal env:' && res "I gal_env removed when gal_env.txt is gone" PASS || res "I gal_env removed" FAIL
printf 'GAL_CLUSTER_LOG=1\n' > "$SCR/fakesd/Mods/ClusterIntegration/gal_env.txt"; run >/dev/null; "$M" "$MOD_PATH/uninstall.sh" >/dev/null 2>&1
[[ ! -f $GE && ! -d /mnt/app/eso/bin/apps/cluster ]] && res "I uninstall removes gal_env via manifest" PASS || res "I uninstall removes gal_env" FAIL
printf 'on\n' > "$SCR/fakesd/Mods/ClusterIntegration/daemon_log.txt"; out=$(run)
DV=/mnt/app/eso/bin/apps/cluster/daemon_verbose
[[ -f $DV ]] && echo "$out" | grep -q 'daemon log:        ON' && res "I daemon_log.txt installs the daemon_verbose marker" PASS || res "I daemon_log.txt marker" FAIL
rm -f "$SCR/fakesd/Mods/ClusterIntegration/daemon_log.txt"; out=$(run)
[[ ! -f $DV ]] && echo "$out" | grep -q 'daemon log:        OFF' && res "I daemon_verbose removed when daemon_log.txt is gone" PASS || res "I daemon_verbose removed" FAIL
rm -rf /mnt/app /fs /ifs "$SCR/jarsrc" /tmp/gal_preload.log
echo "=== J: review fixes (stub kept without audi/, weak comparator + mtime)"
setup MH2p_ER_AUG35_P2873 aa aa ""; run >/dev/null; [[ -f $STUB ]] || res "J precondition stub installed" FAIL
rm -rf "$MOD_PATH/audi"; out=$(run)
[[ -f $STUB ]] && echo "$out" | grep -q 'stand-in class:    kept' && res "J stub kept when the card has no audi/ folder" PASS || res "J stub kept without audi/" FAIL
setup MH2p_ER_AUG35_P2873 aa aa ""; run >/dev/null
# same-size edit on the card (2000 -> 3000): must be installed
sed -i 's/"heartbeatInterval": 2000/"heartbeatInterval": 3000/' "$MOD_PATH/cluster_config.json"; out=$(run)
grep -q '"heartbeatInterval": 3000' /mnt/app/eso/bin/apps/cluster/cluster_config.json && echo "$out" | grep -q 'backup target:     /mnt/app/eso/bin/apps/cluster/cluster_config.json' && res "J same-size config edit installed (not skipped)" PASS || res "J same-size config edit installed" FAIL
# same-size, same-counts binary with a new mtime: must be installed
printf 'payload cluster\n' > "$MOD_PATH/cluster"; run >/dev/null; printf 'payloae cluster\n' > "$MOD_PATH/cluster"; out=$(run)
[[ "$(cat /mnt/app/eso/bin/apps/cluster/cluster)" == "payloae cluster" ]] && res "J same-size same-counts binary installed" PASS || { res "J same-size binary installed" FAIL; echo "$out" | grep cluster/cluster; }
# unchanged file: still skipped on the next run
out=$(run); echo "$out" | grep -q 'skip identical:    /mnt/app/eso/bin/apps/cluster/cluster$' && res "J unchanged file still skipped" PASS || res "J unchanged file still skipped" FAIL
# backup verification still passes with cp -p copies
printf 'payloaf cluster\n' > "$MOD_PATH/cluster"; out=$(run); echo "$out" | grep -q 'ERROR: backup verify' && res "J backup verify ok with mtime rule" FAIL || res "J backup verify ok with mtime rule" PASS
echo "=== K: signature check ignores the mod's own jars"
rm -rf "$SCR/refk" && mkdir -p "$SCR/refk/Update/audi" && cp "$REPO/modkit/Mods/ClusterIntegration/Update/audi/ClusterIntegration_StorageMountHandler_stub.jar" "$SCR/refk/Update/audi/" && mkjar "$SCR/refk/lsd.jar" 0 $AA.class
out=$(JAVA_TOOL_OPTIONS= bash "$REPO/modkit/check_hmi_signatures.sh" "$SCR/zip34/Mods/ClusterIntegration/Update/ClusterIntegration_v0034_beta2_candidate_90d0b76.jar" "$SCR/refk" 2>&1)
echo "$out" | grep -q '^ABSENT' && res "K stub jar on the card is not counted as stock" PASS || { res "K stub jar not counted" FAIL; echo "$out" | head -3; }
rm -rf /mnt/app /fs /ifs "$SCR/jarsrc" "$SCR/refk" /tmp/gal_preload.log
echo "=== L: fresh Audi install without the stand-in jar aborts; jxe-only hit treated as unknown; UNKNOWN verdict"
setup MH2p_ER_AUG35_P2873 aa aa ""; rm -rf "$MOD_PATH/audi"; out=$(run); rc=$?
[[ $rc == 4 && ! -f /mnt/app/eso/bin/apps/gal.real && -z "$(ls /mnt/app/eso/hmi/lsd/jars | grep ClusterIntegration)" ]] && echo "$out" | grep -q 'no stand-in is installed on this unit. Aborting' && res "L abort before any change without stand-in source" PASS || res "L abort without stand-in source" "FAIL (rc=$rc)"
setup MH2p_ER_AUG35_P2873 aa aa+sm ""; out=$(run)
if echo "$out" | grep -q 'binary search:     grep'; then
  echo "$out" | grep -q 'only /ifs/lsd.jxe matched' && [[ -f $STUB ]] && res "L jxe-only hit with lsd.jar lacking the class -> unknown, stub kept" PASS || { res "L jxe-only hit -> unknown" FAIL; echo "$out" | grep -E 'hmi class|stand-in'; }
else
  res "L jxe-only hit -> unknown" "n/a (no grep search on this toolset)"
fi
rm -rf "$SCR/refl" && mkdir -p "$SCR/refl" && mkjar "$SCR/refl/plugin.jar" 0 de/audi/plugins/x/P.class
out=$(JAVA_TOOL_OPTIONS= bash "$REPO/modkit/check_hmi_signatures.sh" "$SCR/zip34/Mods/ClusterIntegration/Update/ClusterIntegration_v0034_beta2_candidate_90d0b76.jar" "$SCR/refl" 2>&1)
echo "$out" | grep -q '^UNKNOWN' && res "L signature check: UNKNOWN without the stock classes" PASS || { res "L UNKNOWN verdict" FAIL; echo "$out" | head -3; }
rm -rf /mnt/app /fs /ifs "$SCR/jarsrc" "$SCR/refl" /tmp/gal_preload.log
echo "=== M: reinstall.sh runs the installer from its own folder"
setup MH2p_ER_AUG35_P2873 aa aa ""; unset MOD_PATH; out=$(cd / && "$M" "$SCR/fakesd/Mods/ClusterIntegration/Update/reinstall.sh" 2>&1); rc=$?
[[ $rc == 0 && -f /mnt/app/eso/hmi/lsd/jars/ClusterIntegration_v0034_beta2_candidate_90d0b76_aa.jar ]] && echo "$out" | grep -q 'Backups:' && res "M reinstall.sh installs without MOD_PATH" PASS || res "M reinstall.sh" "FAIL (rc=$rc)"
rm -rf /mnt/app /fs /ifs "$SCR/jarsrc" /tmp/gal_preload.log
echo "=== N: FAT-like backup timestamps must not fail verification"
setup MH2p_ER_AUG35_P2873 aa aa ""; printf 'GAL_CLUSTER_LOG=1\n' > "$SCR/fakesd/Mods/ClusterIntegration/gal_env.txt"; run >/dev/null
sed -i 's/"heartbeatInterval": 2000/"heartbeatInterval": 2500/' "$MOD_PATH/cluster_config.json"
printf 'GAL_CLUSTER_LOG=1\nGAL_CLUSTER_INSET_LEFT=480\n' > "$SCR/fakesd/Mods/ClusterIntegration/gal_env.txt"
out=$(run)
echo "$out" | grep -q 'ERROR: backup verify failed' && { res "N no backup verify errors with FAT-like times" FAIL; echo "$out" | grep ERROR; } || res "N no backup verify errors with FAT-like times" PASS
grep -q '"heartbeatInterval": 2500' /mnt/app/eso/bin/apps/cluster/cluster_config.json && res "N changed config installed" PASS || res "N changed config installed" FAIL
grep -q 'GAL_CLUSTER_INSET_LEFT=480' /mnt/app/eso/bin/apps/cluster/gal_env && res "N changed gal_env installed" PASS || res "N changed gal_env installed" FAIL
out=$(run); echo "$out" | grep -q 'skip identical:    /mnt/app/eso/bin/apps/cluster/gal_env' && res "N unchanged gal_env skipped by content" PASS || res "N unchanged gal_env skipped" FAIL
ls "$MOD_PATH/Backup" | grep -q 'cluster_config.json.backup' && res "N backup of the replaced config exists" PASS || res "N backup exists" FAIL
rm -rf /mnt/app /fs /ifs "$SCR/jarsrc" /tmp/gal_preload.log
echo "=== O: gal wrapper starts the cluster daemon when it is missing"
setup MH2p_ER_AUG35_P2873 aa aa ""; run >/dev/null
printf '#!/bin/sh\necho "daemon-stub $*"\nsleep 20\n' > "$MOD_PATH/cluster"; run >/dev/null   # a daemon stand-in that stays alive
printf '#!/bin/sh\nexit 0\n' > /mnt/app/eso/bin/apps/gal.real; chmod 755 /mnt/app/eso/bin/apps/gal.real /mnt/app/eso/bin/apps/cluster/cluster
pkill -f '^/bin/sh /mnt/app/eso/bin/apps/cluster/cluster daemon' 2>/dev/null; rm -f /tmp/gal_preload.log
PATH="$SCR/stubs:$PATH" mksh /mnt/app/eso/bin/apps/gal >/dev/null 2>&1; sleep 1
grep -q 'cluster daemon: not running, started by the gal wrapper' /tmp/gal_preload.log && pgrep -f 'cluster daemon verbose=2' >/dev/null && res "O wrapper starts a missing daemon" PASS || { res "O wrapper starts a missing daemon" FAIL; cat /tmp/gal_preload.log; }
PATH="$SCR/stubs:$PATH" mksh /mnt/app/eso/bin/apps/gal >/dev/null 2>&1; sleep 1
[[ $(grep -c 'started by the gal wrapper' /tmp/gal_preload.log) -eq 1 && $(pgrep -fc 'cluster daemon verbose=2') -le 2 ]] && res "O running daemon not started twice" PASS || { res "O daemon not started twice" FAIL; grep -c 'started by' /tmp/gal_preload.log; pgrep -fa 'cluster daemon'; }
pkill -f '^/bin/sh /mnt/app/eso/bin/apps/cluster/cluster daemon' 2>/dev/null; pkill -f '^sleep 20$' 2>/dev/null
rm -rf /mnt/app /fs /ifs "$SCR/jarsrc" /tmp/gal_preload.log
