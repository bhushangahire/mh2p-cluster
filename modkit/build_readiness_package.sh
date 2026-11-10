#!/usr/bin/env bash
# Patch the exact Q7 v1.5 SD package, preserving ALL non-AA-JAR entries.
# Stock HMI is used for compilation only, never executed or redistributed.
# Usage: ... stock-lsd.jar q7-v1.5.zip output.zip ecj.jar asm.jar
set -euo pipefail
[[ $# == 5 ]] || { echo "usage: $0 stock-lsd.jar q7-v1.5.zip output.zip ecj.jar asm.jar" >&2; exit 1; }
STOCK="$1"; BASE="$2"; OUT="$3"; ECJ="$4"; ASM="$5"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# The invisible warm-prepare and no-stop-splash guarantees rely on this exact
# native daemon. Refuse any other base instead of assuming source/binary parity.
python3 - "$BASE" "$STOCK" <<'PYHASH'
import hashlib, pathlib, sys
expected = ['7b703cf9978611e2efaab6bdd85a8248d16c7bd30ca5c19f211c0651ca7283fd', '96a49c355e5704db7713e4d5485495b631a5b54859d136f5d8ae9067ece718d8']
for path, want in zip(sys.argv[1:], expected):
    if hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() != want:
        raise SystemExit('Unverified input (expected original Q7 v1.5 and supplied ER P2711 HMI): ' + path)
PYHASH
TASK_WORK="$(mktemp -d)"
trap 'rm -rf "$TASK_WORK"' EXIT
python3 - "$BASE" "$TASK_WORK" <<'PY'
import pathlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    matches = [n for n in z.namelist() if '/aa_only/' in n and n.endswith('_aa.jar')]
    if len(matches) != 1: raise SystemExit('Expected exactly one AA JAR')
    pathlib.Path(sys.argv[2], 'base.jar').write_bytes(z.read(matches[0]))
PY
NAV=de/audi/app/terminalmode/smartphone/androidauto2/nav
java -jar "$ECJ" -1.4 -source 1.4 -target 1.4 -g:lines,source -nowarn \
    -cp "$TASK_WORK/base.jar:$STOCK" -d "$TASK_WORK/classes" \
    "$REPO/audi/q7-p2711/readiness/$NAV/KombiMapGuard.java" "$REPO/audi/q7-p2711/readiness/$NAV/Mh2pVideoGate.java"
javac -cp "$ASM" -d "$TASK_WORK/host" "$HERE/java/GateReleaseClass.java"
python3 - "$TASK_WORK/base.jar" "$TASK_WORK/original.class" <<'PY'
import hashlib, pathlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    data = z.read('de/audi/app/terminalmode/smartphone/androidauto2/nav/AndroidAutoClusterIntegration.class')
# Exact v1.5 release class only: refuse a different upstream or prior patch.
if hashlib.sha256(data).hexdigest() != '548ded88b87136e7b575a104561d9643a910737387126dae4493ecee95f97ea4':
    raise SystemExit('Unsupported integration class; use the original Q7 v1.5 package')
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
java -cp "$TASK_WORK/host:$ASM" GateReleaseClass "$TASK_WORK/original.class" "$TASK_WORK/classes/$NAV/AndroidAutoClusterIntegration.class"
python3 "$HERE/verify_readiness_class.py" "$TASK_WORK/original.class" "$TASK_WORK/classes/$NAV/AndroidAutoClusterIntegration.class"
python3 - "$BASE" "$TASK_WORK/base.jar" "$TASK_WORK/classes" "$OUT" <<'PY'
import io, pathlib, struct, sys, zipfile
base, jar, classes, out = sys.argv[1:]
replacements = {}
for p in pathlib.Path(classes).rglob('*.class'):
    data = p.read_bytes()
    if struct.unpack('>H', data[6:8])[0] != 48: raise SystemExit('Not a Java 1.4 class: ' + str(p))
    if b'java/lang/StringBuilder' in data: raise SystemExit('StringBuilder in ' + str(p))
    replacements[p.relative_to(classes).as_posix()] = data
buf = io.BytesIO()
with zipfile.ZipFile(jar) as zin, zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zout:
    for i in zin.infolist(): zout.writestr(i, replacements.pop(i.filename, zin.read(i)))
    for n, data in sorted(replacements.items()): zout.writestr(n, data)
with zipfile.ZipFile(base) as zin, zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zout:
    for i in zin.infolist():
        data = buf.getvalue() if '/aa_only/' in i.filename and i.filename.endswith('_aa.jar') else zin.read(i)
        zout.writestr(i, data)
with zipfile.ZipFile(base) as a, zipfile.ZipFile(out) as b:
    changed = [n for n in a.namelist() if a.read(n) != b.read(n)]
    assert len(changed) == 1 and '/aa_only/' in changed[0], changed
    assert a.namelist() == b.namelist()
print('Built:', out)
print('Only changed package entry:', changed[0])
print('Rollback scripts, installer, gal wrapper, native binaries and signed loader preserved byte-for-byte.')
PY
