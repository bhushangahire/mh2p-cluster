#!/usr/bin/env python3
"""
apply_patches.py - apply listed byte patches to a release binary, verifying
the bytes being replaced first.

There is no QNX toolchain here, so fixes to the native daemon and hook that
other people have proved on their cars are carried as byte patches, the way
the splash and the cluster display entry are. A patch file lists one patch
per line:

    <offset>  <expected bytes>  <new bytes>   # comment

offset in hex (0x...), both byte strings in hex of the same length. The tool
refuses to touch a binary whose bytes at the offset are not the expected
ones (a different release, or an already patched file is reported as such),
writes the output only when every patch applies, and verifies the result.

Usage:
  apply_patches.py <binary-in> <patches.txt> <binary-out>
  apply_patches.py check <binary> <patches.txt>      report applied/unapplied
"""
import sys


def read_patches(path):
    out = []
    for n, line in enumerate(open(path), 1):
        body = line.split("#", 1)[0].strip()
        if not body:
            continue
        parts = body.split()
        if len(parts) != 3:
            raise SystemExit(f"error: {path}:{n}: expected '<offset> <old hex> <new hex>'")
        off = int(parts[0], 16)
        old, new = bytes.fromhex(parts[1]), bytes.fromhex(parts[2])
        if len(old) != len(new):
            raise SystemExit(f"error: {path}:{n}: old and new bytes differ in length")
        out.append((off, old, new, line.split("#", 1)[1].strip() if "#" in line else ""))
    return out


def status(data, patches):
    res = []
    for off, old, new, comment in patches:
        cur = data[off:off + len(old)]
        res.append(("unapplied" if cur == old else "applied" if cur == new else "MISMATCH", off, old, new, comment, cur))
    return res


def main(argv):
    if len(argv) == 4 and argv[1] == "check":
        data = open(argv[2], "rb").read()
        for st, off, old, new, comment, cur in status(data, read_patches(argv[3])):
            print(f"{st:9} 0x{off:x} {comment} (now {cur.hex()})")
        return 0
    if len(argv) != 4:
        print(__doc__)
        return 2
    src, pfile, dst = argv[1], argv[2], argv[3]
    data = bytearray(open(src, "rb").read())
    patches = read_patches(pfile)
    for st, off, old, new, comment, cur in status(bytes(data), patches):
        if st == "MISMATCH":
            raise SystemExit(f"error: bytes at 0x{off:x} are {cur.hex()}, expected {old.hex()} ({comment}): "
                             f"not the release this patch was made for; nothing written")
    applied = 0
    for off, old, new, comment in patches:
        if data[off:off + len(old)] == old:
            data[off:off + len(new)] = new
            applied += 1
    out = bytes(data)
    for st, off, old, new, comment, cur in status(out, patches):
        if st != "applied":
            raise SystemExit("error: verification failed after patching")
    orig = open(src, "rb").read()
    changed = sum(1 for a, b in zip(orig, out) if a != b)
    open(dst, "wb").write(out)
    print(f"wrote {dst}: {applied} of {len(patches)} patch(es) applied ({len(patches) - applied} already present), "
          f"{changed} byte(s) changed; verified")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
