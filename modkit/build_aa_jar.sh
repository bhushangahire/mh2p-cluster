#!/usr/bin/env bash
#
# build_aa_jar.sh — rebuild the Audi (Android-Auto-only) JAR with the classes
# this fork changes, compiled for the MH2p HMI JVM (Java 1.4 class files).
#
# The release JAR's classes are newer than the sources under lsd/ except for
# AndroidAuto2Subsystem, which was verified byte-for-byte equivalent to the
# shipped class (modulo compiler idioms) on 2026-10-17; only that class and
# the classes added by this fork are compiled here. Everything else is taken
# from the release-derived aa_only JAR unchanged.
#
# Needs: a JDK (javap, java) and the Eclipse compiler jar (ECJ 3.20, the last
# line that still targets 1.4 and runs on Java 17), downloaded once:
#   curl -L -o ~/.cache/ecj-3.20.0.jar \
#     https://repo1.maven.org/maven2/org/eclipse/jdt/ecj/3.20.0/ecj-3.20.0.jar
# and the unit's stock classes extracted to a folder (default ~/etron-stock/lsd),
# which stay outside the repository.
#
# Usage: modkit/build_aa_jar.sh [stock-classes-dir] [ecj.jar]
#        (AA_JAR=<path> selects the jar to rebuild in place; default: the
#        tracked jar under modkit/Mods/ClusterIntegration/Update/aa_only)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
STOCK="${1:-$HOME/etron-stock/lsd}"
ECJ="${2:-$HOME/.cache/ecj-3.20.0.jar}"
AA_DIR="$HERE/Mods/ClusterIntegration/Update/aa_only"
STUB="$HERE/Mods/ClusterIntegration/Update/audi/ClusterIntegration_StorageMountHandler_stub.jar"
PKG=de/audi/app/terminalmode/smartphone/androidauto2
SOURCES=(
    "$REPO/lsd/$PKG/AndroidAuto2Subsystem.java"
    "$REPO/lsd/$PKG/nav/KombiMapGuard.java"
)

[[ -d "$STOCK/de/audi/tghu" ]] || { echo "error: stock classes not found under $STOCK" >&2; exit 1; }
[[ -f "$ECJ" ]] || { echo "error: ECJ jar not found: $ECJ" >&2; exit 1; }
command -v javap >/dev/null || { echo "error: javap not found (a JDK is required)" >&2; exit 1; }
AA_JAR="${AA_JAR:-$(ls -1 "$AA_DIR"/ClusterIntegration_*_aa.jar 2>/dev/null | head -1)}"
[[ -n "$AA_JAR" && -f "$AA_JAR" ]] || { echo "error: no aa_only jar in $AA_DIR" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/release" "$WORK/out"
( cd "$WORK/release" && unzip -q "$AA_JAR" )

# Compile against: the unit's stock classes, the release classes, the stub.
java -jar "$ECJ" -1.4 -source 1.4 -target 1.4 -g:lines,source -nowarn \
    -cp "$STOCK:$WORK/release:$STUB" -d "$WORK/out" "${SOURCES[@]}"

# Every produced class must be a 1.4 class file without post-1.4 constructs.
while IFS= read -r cls; do
    v="$(javap -v "$cls" | grep -m1 'major version' | awk '{print $3}')"
    [[ "$v" == 48 ]] || { echo "error: $cls has class-file version $v, expected 48" >&2; exit 1; }
    if javap -c -p "$cls" | grep -qE 'StringBuilder|invokedynamic'; then
        echo "error: $cls uses post-1.4 constructs" >&2; exit 1
    fi
done < <(find "$WORK/out" -name '*.class')

# Replace/add the compiled classes in a copy of the release-derived jar.
python3 - "$AA_JAR" "$WORK/out" "$WORK/new.jar" <<'PY'
import os, sys, zipfile
src, out, dst = sys.argv[1], sys.argv[2], sys.argv[3]
new = {}
for root, _, files in os.walk(out):
    for f in files:
        p = os.path.join(root, f)
        new[os.path.relpath(p, out).replace(os.sep, "/")] = open(p, "rb").read()
replaced = added = 0
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for info in zin.infolist():
        if info.filename in new:
            zout.writestr(info.filename, new.pop(info.filename)); replaced += 1
        else:
            zout.writestr(info, zin.read(info.filename))
    for name in sorted(new):
        zi = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0)); zi.compress_type = zipfile.ZIP_DEFLATED
        zout.writestr(zi, new[name]); added += 1
print(f"  classes replaced: {replaced}, added: {added}")
PY
cp "$WORK/new.jar" "$AA_JAR"
echo "built: $AA_JAR"
