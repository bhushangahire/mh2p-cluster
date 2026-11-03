#!/usr/bin/env bash
#
# build_sd_package.sh — rebuild a flashable MH2p SD ModKit package from an
# existing release zip, overlaying the ModKit mod scripts tracked in this
# repository (modkit/Mods/**) on top of the shipped binaries.
#
# The release zips under builds/ carry the signed LawPaul ModKit (Data/, Meta/)
# plus the compiled mod (JAR, cluster daemon, gal_cluster.so, dio_cluster.so,
# cluster_config.json). Only Mods/ is unsigned and unchecksummed, so this is
# the safe place to change install behaviour without a QNX toolchain.
#
# It also derives an Android-Auto-only JAR (Update/aa_only/<name>_aa.jar,
# without the CarPlay classes) that install.sh prefers on Audi unless
# enable_carplay.txt is present. The Audi stand-in jar for the Porsche-only
# StorageMountHandler class (Update/audi/, built by modkit/stub/build_stub.sh)
# is tracked under modkit/Mods and copied in with the overlay.
#
# Usage:
#   modkit/build_sd_package.sh <source-release.zip> <output.zip>
#
# Example:
#   modkit/build_sd_package.sh \
#       builds/ClusterIntegration_v0034_beta2_candidate_90d0b76.zip \
#       builds/ClusterIntegration_v0034_beta2_candidate_90d0b76_audi.zip
#
# Requires: bash, python3, zip. Runs on Linux/macOS/WSL (not on the head unit).

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <source-release.zip> <output.zip>" >&2
    exit 1
fi

SRC="$1"
OUT="$2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="$HERE/Mods"

[[ -f "$SRC" ]] || { echo "error: source zip not found: $SRC" >&2; exit 1; }
[[ -d "$OVERLAY" ]] || { echo "error: overlay dir not found: $OVERLAY" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 1; }
command -v zip >/dev/null || { echo "error: zip is required" >&2; exit 1; }

case "$OUT" in
    /*) OUT_ABS="$OUT" ;;
    *)  OUT_ABS="$(pwd)/$OUT" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/pkg"
mkdir -p "$PKG"

# Extract with Python: the upstream zips were built on Windows and store
# backslash path separators, which unzip(1) refuses to normalise.
python3 - "$SRC" "$PKG" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zf:
    for info in zf.infolist():
        name = info.filename.replace("\\", "/")
        if name.endswith("/") or not name:
            continue
        if name.startswith("/") or ".." in name.split("/"):
            raise SystemExit(f"refusing unsafe zip entry: {info.filename}")
        target = os.path.join(dst, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as out:
            out.write(zf.read(info))
PY

echo "source:  $SRC"
echo "overlay: $OVERLAY"
changed=0
while IFS= read -r -d '' f; do
    rel="${f#"$OVERLAY"/}"
    dest="$PKG/Mods/$rel"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]] && cmp -s "$f" "$dest"; then
        echo "  same:    Mods/$rel"
    else
        if [[ -f "$dest" ]]; then echo "  replace: Mods/$rel"; else echo "  add:     Mods/$rel"; fi
        changed=$((changed + 1))
    fi
    cp "$f" "$dest"
    chmod 755 "$dest"
done < <(find "$OVERLAY" -type f -print0 | sort -z)

# Derive an Android-Auto-only JAR next to each release JAR. install.sh uses it
# on Audi unless enable_carplay.txt is present. The carplay package and the
# androidauto2 package have no cross-references (verified with javap/grep on
# v0034), so dropping the CarPlay classes needs no recompilation. Every
# androidauto2 class stays, AndroidAuto2EventListener included: its
# constructor is the only place that subscribes the DSI attributes, and the
# mod's copy subscribes {3,5,6,7,8} where the stock Audi class subscribes
# {3,5,6}; 7 and 8 are the next-turn event and the distance to the next turn,
# without which the mod never receives a manoeuvre (no BAP_MANEUVER lines).
# An earlier build dropped it as a "pure stock copy" because its method
# signatures match stock; the difference is in the constructor body.
python3 - "$PKG/Mods/ClusterIntegration/Update" <<'PY'
import os, sys, zipfile
upd = sys.argv[1]
DROP_PREFIX = "de/audi/app/terminalmode/smartphone/carplay/"
DROP_EXACT = set()
out_dir = os.path.join(upd, "aa_only")
os.makedirs(out_dir, exist_ok=True)
# A tracked aa_only jar may have been overlaid from modkit/Mods; drop any
# that does not belong to a release JAR present in this package, so the
# installer's "newest aa jar" choice is never ambiguous.
release = {n[:-4] for n in os.listdir(upd) if n.startswith("ClusterIntegration_") and n.endswith(".jar")}
for stale in os.listdir(out_dir):
    if stale.endswith("_aa.jar") and stale[:-7] not in release:
        os.remove(os.path.join(out_dir, stale))
        print(f"  drop:    Mods/ClusterIntegration/Update/aa_only/{stale} (no matching release JAR)")
for name in sorted(os.listdir(upd)):
    if not (name.startswith("ClusterIntegration_") and name.endswith(".jar")):
        continue
    src = os.path.join(upd, name)
    dst = os.path.join(out_dir, name[:-4] + "_aa.jar")
    kept = dropped = 0
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            if info.filename.startswith(DROP_PREFIX) or info.filename in DROP_EXACT:
                dropped += 1
                continue
            zout.writestr(info, zin.read(info))
            kept += 1
    print(f"  derive:  Mods/ClusterIntegration/Update/aa_only/{os.path.basename(dst)} ({kept} entries kept, {dropped} CarPlay entries dropped)")
PY

# The derived jar holds the release classes only. This fork changes
# AndroidAuto2Subsystem and adds nav/KombiMapHandback (the cluster map
# hand-back after Android Auto ends); build_aa_jar.sh compiles them for the
# HMI's Java 1.4 JVM and replaces them in the jar. It needs the unit's stock
# classes and the ECJ jar (see its header); without them the package would
# silently ship without the hand-back, so this is an error, not a warning.
for f in "$PKG"/Mods/ClusterIntegration/Update/aa_only/ClusterIntegration_*_aa.jar; do
    [[ -f "$f" ]] || continue
    AA_JAR="$f" "$HERE/build_aa_jar.sh" "${STOCK_CLASSES:-$HOME/etron-stock/lsd}" "${ECJ_JAR:-$HOME/.cache/ecj-3.20.0.jar}" \
        || { echo "error: build_aa_jar.sh failed for ${f##*/}; set STOCK_CLASSES / ECJ_JAR (see modkit/build_aa_jar.sh)" >&2; exit 1; }
done

# Cockpit loading splash. With modkit/splash/splash.png present (or
# SPLASH_PNG=<file>), the boot splash compiled into the cluster daemon is
# swapped for it: a same-length overwrite of the zlib stream inside the
# binary, verified by decompressing the result (modkit/splash/canim_tool.py).
# Without the file the daemon ships as released. The tool aborts when the
# image does not fit the original stream's length.
SPLASH_PNG="${SPLASH_PNG:-$HERE/splash/splash.png}"
if [[ -f "$SPLASH_PNG" ]]; then
    CLUSTER_BIN="$PKG/Mods/ClusterIntegration/Update/cluster"
    python3 "$HERE/splash/canim_tool.py" build "$SPLASH_PNG" "$WORK/splash.canim" | sed 's/^/  splash:  /'
    python3 "$HERE/splash/canim_tool.py" patch "$CLUSTER_BIN" "$WORK/splash.canim" "$WORK/cluster.patched" | sed 's/^/  splash:  /'
    cp "$WORK/cluster.patched" "$CLUSTER_BIN" && chmod 755 "$CLUSTER_BIN"
    echo "  splash:  Mods/ClusterIntegration/Update/cluster boot splash replaced from ${SPLASH_PNG##*/}"
fi

# Byte patches to the daemon proved on other cars (modkit/patches/
# cluster.patches.txt, applied by apply_patches.py after verifying the bytes
# they replace). Without the file the daemon ships as released.
CLUSTER_PATCHES="${CLUSTER_PATCHES:-$HERE/patches/cluster.patches.txt}"
if [[ -f "$CLUSTER_PATCHES" ]]; then
    CLUSTER_BIN="$PKG/Mods/ClusterIntegration/Update/cluster"
    python3 "$HERE/patches/apply_patches.py" "$CLUSTER_BIN" "$CLUSTER_PATCHES" "$WORK/cluster.bytepatched" | sed 's/^/  patches: /'
    cp "$WORK/cluster.bytepatched" "$CLUSTER_BIN" && chmod 755 "$CLUSTER_BIN"
fi

# Cluster display entry offered to the phone. With modkit/template/template.txt
# present (or TEMPLATE_TXT=<file>), the 54-byte entry inside gal_cluster.so is
# rebuilt with those margins/insets (modkit/template/cluster_template_tool.py:
# same-length overwrite at the dhu_cluster_service symbol, verified). Without
# the file the hook ships as released, and the phone lays its cluster UI out
# for the whole frame.
TEMPLATE_TXT="${TEMPLATE_TXT:-$HERE/template/template.txt}"
if [[ -f "$TEMPLATE_TXT" ]]; then
    HOOK_SO="$PKG/Mods/ClusterIntegration/Update/gal_cluster.so"
    mapfile -t TPL_KEYS < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$TEMPLATE_TXT" | grep '=')
    python3 "$HERE/template/cluster_template_tool.py" build "$WORK/template.bin" "${TPL_KEYS[@]}" | sed 's/^/  template: /'
    python3 "$HERE/template/cluster_template_tool.py" patch "$HOOK_SO" "$WORK/template.bin" "$WORK/gal_cluster.patched" | head -1 | sed 's/^/  template: /'
    cp "$WORK/gal_cluster.patched" "$HOOK_SO" && chmod 755 "$HOOK_SO"
    echo "  template: Mods/ClusterIntegration/Update/gal_cluster.so cluster entry replaced from ${TEMPLATE_TXT##*/}"
fi

# Keep the tracked copy of the derived Audi jar in step with the package, so
# the overlay in this repository ships the same bytes the build produced.
for f in "$PKG"/Mods/ClusterIntegration/Update/aa_only/ClusterIntegration_*_aa.jar; do
    [[ -f "$f" ]] || continue
    dest="$OVERLAY/ClusterIntegration/Update/aa_only/${f##*/}"
    if [[ ! -f "$dest" ]] || ! cmp -s "$f" "$dest"; then
        mkdir -p "$(dirname "$dest")"; cp "$f" "$dest"; echo "  tracked: modkit/Mods/ClusterIntegration/Update/aa_only/${f##*/} refreshed"
    fi
done

rm -f "$OUT_ABS"
( cd "$PKG" && zip -q -r -X "$OUT_ABS" . )
echo "output:  $OUT ($changed file(s) changed vs source, $(du -h "$OUT_ABS" | cut -f1))"
