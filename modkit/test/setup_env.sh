#!/usr/bin/env bash
#
# setup_env.sh WORKDIR — build the simulated head-unit toolsets the gate
# tests run the ModKit scripts under. Everything lands in WORKDIR:
#
#   zip34/          the v0034 release zip extracted (real jar, hook, daemon,
#                   cluster_config.json for the tests that need them)
#   stubs/          slay, mount, pidin stand-ins
#   qnxwrap/        grep without -a that never matches inside a binary file
#                   (the e-tron's), a NUL-blind awk, a cp that rounds Backup/
#                   timestamps to even seconds like a FAT card
#   qnxbin_<set>/   restricted PATH directories, one per toolset:
#                   audi_none    GNU grep/awk, no wc/sum/cmp/diff/od on PATH
#                   audi_qnxgrep QNX-like grep, GNU awk          (the e-tron)
#                   audi_blind   QNX-like grep, NUL-blind awk    (worst case)
#                   audi_cmp     GNU grep -a plus cmp            (best case)
#   mkshwrap_<set>/mksh   runs mksh (the QNX ksh stand-in) with that PATH
#
# Requires: bash, mksh, python3, zip, unzip, readelf (binutils), coreutils.
set -euo pipefail
WORK="${1:?usage: setup_env.sh WORKDIR}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
for t in mksh python3 zip unzip readelf; do command -v "$t" >/dev/null || { echo "error: $t is required" >&2; exit 1; }; done
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"

# release zip (backslash entry names: extract with python, as build_sd_package.sh does)
ZIP="$(ls "$REPO"/builds/ClusterIntegration_v0034_*_90d0b76.zip | grep -v _audi | head -1)"
rm -rf "$WORK/zip34"; mkdir -p "$WORK/zip34"
python3 - "$ZIP" "$WORK/zip34" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zf:
    for info in zf.infolist():
        name = info.filename.replace("\\", "/")
        if name.endswith("/") or not name or name.startswith("/") or ".." in name.split("/"): continue
        t = os.path.join(dst, name); os.makedirs(os.path.dirname(t), exist_ok=True)
        open(t, "wb").write(zf.read(info))
PY

# stubs
mkdir -p "$WORK/stubs"
printf '#!/bin/sh\nexit 0\n' > "$WORK/stubs/slay"
printf '#!/bin/sh\nexit 0\n' > "$WORK/stubs/mount"
printf '#!/bin/bash\n# pidin stand-in: "pidin ar" lists process command lines\nps -eo args\n' > "$WORK/stubs/pidin"
chmod 755 "$WORK/stubs"/*

# QNX-like tool wrappers
mkdir -p "$WORK/qnxwrap"
cat > "$WORK/qnxwrap/grep" <<'W'
#!/bin/bash
# mimics the e-tron's grep: no -a, and no match on a binary file
for a in "$@"; do [[ "$a" == "-a" ]] && { echo "grep: invalid option -- a" >&2; exit 2; }; done
pat_seen=0; files=()
for a in "$@"; do
  case "$a" in -*) continue;; esac
  if [[ $pat_seen -eq 0 ]]; then pat_seen=1; else files+=("$a"); fi
done
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  n1=$(/usr/bin/head -c 2048 "$f" | /usr/bin/wc -c); n2=$(/usr/bin/head -c 2048 "$f" | /usr/bin/tr -d "\\0" | /usr/bin/wc -c)
  [[ "$n1" != "$n2" ]] && exit 1
done
exec /usr/bin/grep "$@"
W
cat > "$WORK/qnxwrap/awk_nulblind" <<'W'
#!/bin/bash
# mimics a C-string awk: no match inside a binary file
for a in "$@"; do
  [[ -f "$a" ]] || continue
  n1=$(/usr/bin/head -c 2048 "$a" | /usr/bin/wc -c); n2=$(/usr/bin/head -c 2048 "$a" | /usr/bin/tr -d "\\0" | /usr/bin/wc -c)
  [[ "$n1" != "$n2" ]] && exit 1
done
exec /usr/bin/awk "$@"
W
cat > "$WORK/qnxwrap/cp_fat" <<'W'
#!/bin/bash
# cp that mimics a FAT32 destination: copies under a /Backup/ folder get
# their mtime rounded down to an even second
/usr/bin/cp "$@" || exit $?
dst="${@: -1}"
if [[ "$dst" == */Backup/* ]]; then
  if [[ -d "$dst" ]]; then dst="$dst/$(basename "${@: -2:1}")"; fi
  t=$(/usr/bin/stat -c %Y "$dst" 2>/dev/null) && /usr/bin/touch -d "@$(( (t / 2) * 2 - 2 ))" "$dst"
fi
exit 0
W
chmod 755 "$WORK/qnxwrap"/*

# restricted toolsets
BASE="awk cat chmod cp cut date dd echo find grep head ls mkdir mv rm rmdir sed sleep sync touch"
for set in audi_none audi_qnxgrep audi_blind audi_cmp; do
    d="$WORK/qnxbin_$set"; rm -rf "$d"; mkdir -p "$d"
    for t in $BASE; do
        p="$(command -v "$t" || true)"; [[ -n "$p" ]] && ln -sf "$p" "$d/$t"
    done
    ln -sf "$(command -v mksh)" "$d/ksh"
    ln -sf "$WORK/qnxwrap/cp_fat" "$d/cp"
    case "$set" in
        audi_qnxgrep) ln -sf "$WORK/qnxwrap/grep" "$d/grep" ;;
        audi_blind)   ln -sf "$WORK/qnxwrap/grep" "$d/grep"; ln -sf "$WORK/qnxwrap/awk_nulblind" "$d/awk" ;;
        audi_cmp)     ln -sf "$(command -v cmp)" "$d/cmp" ;;
    esac
    mkdir -p "$WORK/mkshwrap_$set"
    printf '#!/bin/bash\nexec env PATH=%s/qnxbin_%s:%s/stubs %s "$@"\n' "$WORK" "$set" "$WORK" "$(command -v mksh)" > "$WORK/mkshwrap_$set/mksh"
    chmod 755 "$WORK/mkshwrap_$set/mksh"
done
echo "test environment ready in $WORK"
