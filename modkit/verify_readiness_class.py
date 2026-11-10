#!/usr/bin/env python3
"""Require every existing method attribute to be byte-identical after wrapping."""
import struct
import sys
from pathlib import Path


def methods(data):
    pos = 8
    def u2():
        nonlocal pos
        v = struct.unpack_from('>H', data, pos)[0]; pos += 2
        return v
    def u4():
        nonlocal pos
        v = struct.unpack_from('>I', data, pos)[0]; pos += 4
        return v
    pool = [None] * u2()
    i = 1
    while i < len(pool):
        tag = data[pos]; pos += 1
        if tag == 1:
            n = u2(); pool[i] = data[pos:pos+n].decode('utf-8', errors='replace'); pos += n
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18): pos += 4
        elif tag in (5, 6): pos += 8; i += 1
        elif tag in (7, 8, 16, 19, 20): pos += 2
        elif tag == 15: pos += 3
        else: raise ValueError('Unknown constant tag ' + str(tag))
        i += 1
    def attributes():
        result = []
        for _ in range(u2()):
            name = pool[u2()]; n = u4(); result.append((name, data[pos:pos+n])); advance(n)
        return result
    def advance(n):
        nonlocal pos
        pos += n
    advance(6)
    advance(u2() * 2)
    for _ in range(u2()):
        advance(6); attributes()
    result = {}
    for _ in range(u2()):
        access, name, desc = u2(), pool[u2()], pool[u2()]
        result[(name, desc)] = (access, attributes())
    return result


def verify(before, after):
    old, new = methods(before), methods(after)
    assert len(new) == len(old) + 1
    for (name, desc), body in old.items():
        key = ('sendMirrorCommandUngated' if name == 'sendMirrorCommand' else name, desc)
        assert body == new[key], 'Existing method changed: ' + name
    print('PASS: all', len(old), 'release method bodies/attributes preserved exactly; one sender wrapper added')

if __name__ == '__main__': verify(*(Path(p).read_bytes() for p in sys.argv[1:]))
