#!/usr/bin/env bash
#
# run_tests.sh [WORKDIR] [toolset ...] — run every ModKit script test under
# the simulated head-unit toolsets (see setup_env.sh). Must run as root: the
# scripts under test write to /mnt/app, /fs and /ifs, and the tests create
# and delete those trees (they refuse to run if any of them is a mount
# point or holds anything that is not theirs).
#
#   sudo modkit/test/run_tests.sh                 # all toolsets, work dir in /tmp
#   sudo modkit/test/run_tests.sh /tmp/mh2p-test audi_qnxgrep
#
# A single gate script can be run on its own once the environment exists:
#   sudo modkit/test/gate_toolsets.sh /tmp/mh2p-test . audi_qnxgrep
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${1:-/tmp/mh2p-test}"; shift || true
SETS="${*:-audi_blind audi_qnxgrep audi_cmp}"
[[ $(id -u) -eq 0 ]] || { echo "error: run as root (the scripts under test write to /mnt/app, /fs and /ifs)" >&2; exit 1; }
for d in /mnt/app /fs /ifs; do
    if mountpoint -q "$d" 2>/dev/null; then echo "error: $d is a mount point; refusing to use it as a test tree" >&2; exit 1; fi
done
"$HERE/setup_env.sh" "$WORK" || exit 1
fails=0
echo "### install gate / rollback (full toolset, mksh on PATH)"
bash "$HERE/gate_install_gate.sh" "$WORK" "$REPO" | grep -E 'PASS|FAIL' ; fails=$((fails + $(bash "$HERE/gate_install_gate.sh" "$WORK" "$REPO" 2>&1 | grep -c FAIL)))
echo "### config overrides / diag / manifest (full toolset)"
out=$(bash "$HERE/gate_overrides.sh" "$WORK" "$REPO" 2>&1); echo "$out" | grep -E 'PASS|FAIL'; fails=$((fails + $(echo "$out" | grep -c FAIL)))
for set in $SETS; do
    echo "### simulated toolset: $set"
    out=$(bash "$HERE/gate_toolsets.sh" "$WORK" "$REPO" "$set" 2>&1); echo "$out" | grep -E 'PASS|FAIL' | grep -v '^    |'; fails=$((fails + $(echo "$out" | grep -c FAIL)))
done
rm -rf /mnt/app /fs /ifs
echo "### total FAIL lines: $fails"
[[ $fails -eq 0 ]]
