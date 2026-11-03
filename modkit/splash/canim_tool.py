#!/usr/bin/env python3
"""
canim_tool.py - make, inspect and install the cluster daemon's boot splash.

The cluster daemon (Update/cluster) paints an image into the virtual cockpit
for about two seconds when the Android Auto map first appears, while the
H.264 decoder warms up. That image is a "canim" (the PCM's own splash format:
a zlib stream whose payload is a 56-byte header and raw RGB pixels) compiled
into the binary as the boot_canim_data array (src/boot_canim_data.h). There
is no QNX toolchain here, so instead of rebuilding the daemon this tool swaps
the zlib stream inside the shipped binary. That is safe because:

  - the stream sits at one unique offset and the daemon reads it with
    zlib uncompress(), which stops at the stream's own end marker, so a
    shorter stream padded with zeros to the original length is read exactly
    the same way and the length constant in the code stays valid;
  - nothing else in the binary moves: the patch is a same-length overwrite,
    verified afterwards by decompressing from the patched file.

The only constraint is that the new image must compress to no more than the
original stream (45954 bytes in v0034): flat colours, text and simple shapes
fit easily (a 1920x1080 dark card with text is ~10-45 KB); photographs and
noisy gradients do not. The daemon centre-crops/pads the image into the
decoder frame (1920x1080 at codecRes=1080) and then shows it through the same
mode/zoom/pan as the map, so author at the frame size and keep what matters
inside the band the cockpit shows (`template` draws it for the e-tron recipe:
fill, panY=0.248 on 1920x722 -> rows 358..1079).

Layout (little-endian), as read by canim_load_from_mem() in src/cluster.c:
    0x00  "ANIM1   "            0x08 u32 width      0x0C u32 height
    0x10  u32 cmdblock_len=24   0x14 u32 0
    0x18  u32 cmd=0x11          0x1C u32 0
    0x20  u32 width  0x24 u32 height  0x28 u32 bpp=3  0x2C u32 data_start=0
    0x30  8 zero bytes
    0x38  pixels, RGB, row-major, top row first

Pure Python (no Pillow): reads 8-bit non-interlaced PNG (grey, RGB, RGBA,
palette) and writes 8-bit RGB PNG.

Usage:
  canim_tool.py info     <cluster>                   offset/size of the stream
  canim_tool.py export   <cluster> <out.png>         extract the current splash
  canim_tool.py build    <in.png> <out.canim>        PNG -> canim (reports size)
  canim_tool.py patch    <cluster> <in.canim> <out>  write a patched daemon
  canim_tool.py template <out.png>                   1920x1080 design template
  canim_tool.py preview  <in.png> <out.png>          what the e-tron cockpit shows
"""
import struct
import sys
import zlib

MAGIC = b"ANIM1   "
FRAME_W, FRAME_H = 1920, 1080      # decoder frame at codecRes=1080
BAND_TOP, BAND_H = 358, 722        # e-tron recipe: fill, panY=0.248, 1920x722


# ---- PNG ------------------------------------------------------------------

def png_read(path):
    """Return (w, h, rgb bytes) for an 8-bit non-interlaced PNG."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"error: {path} is not a PNG")
    pos, idat, plte, w = 8, [], None, None
    while pos < len(data):
        ln, typ = struct.unpack_from(">I4s", data, pos)
        body = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or interlace:
                raise SystemExit("error: only 8-bit non-interlaced PNG is supported")
        elif typ == b"PLTE":
            plte = body
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
    chans = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(b"".join(idat))
    stride = w * chans
    prev = bytearray(stride)
    out = bytearray()
    for y in range(h):
        f = raw[y * (stride + 1)]
        cur = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:
            for i in range(chans, stride):
                cur[i] = (cur[i] + cur[i - chans]) & 0xFF
        elif f == 2:
            for i in range(stride):
                cur[i] = (cur[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = cur[i - chans] if i >= chans else 0
                cur[i] = (cur[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = cur[i - chans] if i >= chans else 0
                b = prev[i]
                c = prev[i - chans] if i >= chans else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[i] = (cur[i] + pr) & 0xFF
        elif f != 0:
            raise SystemExit(f"error: bad PNG filter {f}")
        out += cur
        prev = cur
    # to RGB
    if ctype == 2:
        rgb = bytes(out)
    elif ctype == 6:
        rgb = bytes(b for i in range(0, len(out), 4) for b in out[i:i + 3])
    elif ctype == 0:
        rgb = bytes(b for v in out for b in (v, v, v))
    elif ctype == 4:
        rgb = bytes(b for i in range(0, len(out), 2) for b in (out[i], out[i], out[i]))
    else:  # palette
        rgb = bytes(b for v in out for b in plte[3 * v:3 * v + 3])
    return w, h, rgb


def png_write(path, w, h, rgb):
    rows = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n"
                           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


# ---- canim ----------------------------------------------------------------

def find_stream(data):
    """Return (offset, consumed length, raw payload) of the embedded canim."""
    pos = 0
    while True:
        pos = data.find(b"\x78\xda", pos)
        if pos < 0:
            raise SystemExit("error: no canim zlib stream found in the binary")
        d = zlib.decompressobj()
        try:
            raw = d.decompress(data[pos:pos + 4 * 1024 * 1024])
        except zlib.error:
            pos += 1
            continue
        if raw[:8] == MAGIC and d.eof:
            consumed = len(data[pos:pos + 4 * 1024 * 1024]) - len(d.unused_data)
            return pos, consumed, raw
        pos += 1


def elf_symbol(data, name):
    """(file offset, size) of a symbol in a 32-bit little-endian ELF, or None.
    The shipped daemon is not stripped, so boot_canim_data's own size tells
    us the slot exactly, patched or not."""
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        return None
    shoff, = struct.unpack_from("<I", data, 0x20)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x2E)
    secs = [struct.unpack_from("<IIIIIIIIII", data, shoff + i * shentsize) for i in range(shnum)]
    for s in secs:                                   # sh_type 2 = SYMTAB
        if s[1] != 2:
            continue
        strtab = secs[s[6]]
        off, size = s[4], s[5]
        for p in range(off, off + size, 16):
            st_name, st_value, st_size, _, _, st_shndx = struct.unpack_from("<IIIBBH", data, p)
            end = data.index(b"\0", strtab[4] + st_name)
            if data[strtab[4] + st_name:end] == name.encode():
                sec = secs[st_shndx]                 # sh_addr=sec[3], sh_offset=sec[4]
                return sec[4] + (st_value - sec[3]), st_size
    return None


def slot_length(data, off, consumed):
    """The array length as compiled: from the ELF symbol when the binary has
    one (then the offset must agree with the stream found), otherwise the
    stream length plus any zero padding up to the length constant that
    appears exactly once in the binary (a patched, stripped binary)."""
    sym = elf_symbol(data, "boot_canim_data")
    if sym and sym[0] == off:
        return sym[1]
    for cand in range(consumed, consumed + 65536):
        if data.count(struct.pack("<I", cand)) == 1 and data[off + consumed:off + cand] == b"\0" * (cand - consumed):
            return cand
    return consumed


def parse(raw):
    if raw[:8] != MAGIC:
        raise SystemExit("error: not a canim payload (bad magic)")
    cmdblock_len = struct.unpack_from("<I", raw, 0x10)[0]
    for off in range(24, 24 + 240, 120):
        if struct.unpack_from("<I", raw, off)[0] == 0x11:
            w, h, bpp, ds = struct.unpack_from("<IIII", raw, off + 8)
            break
    else:
        raise SystemExit("error: canim has no 0x11 image command")
    pix = 0x20 + cmdblock_len + ds
    return w, h, bpp, raw[pix:pix + w * h * bpp]


def header(w, h):
    return (MAGIC + struct.pack("<IIII", w, h, 24, 0) + struct.pack("<II", 0x11, 0)
            + struct.pack("<IIII", w, h, 3, 0) + b"\0" * 8)


# ---- commands ---------------------------------------------------------------

def cmd_info(path):
    data = open(path, "rb").read()
    off, consumed, raw = find_stream(data)
    w, h, bpp, _ = parse(raw)
    print(f"stream at offset {off}: {consumed} bytes used of a {slot_length(data, off, consumed)}-byte slot, image {w}x{h} bpp={bpp}")


def cmd_export(path, out_png):
    data = open(path, "rb").read()
    _, _, raw = find_stream(data)
    w, h, bpp, pix = parse(raw)
    if bpp == 4:
        pix = bytes(b for i in range(0, len(pix), 4) for b in pix[i:i + 3])
    png_write(out_png, w, h, pix)
    print(f"wrote {out_png} ({w}x{h})")


def cmd_build(in_png, out_canim):
    w, h, rgb = png_read(in_png)
    z = zlib.compress(header(w, h) + rgb, 9)
    open(out_canim, "wb").write(z)
    print(f"wrote {out_canim}: {w}x{h}, {len(z)} bytes compressed")


def cmd_patch(cluster_in, canim_in, cluster_out):
    orig = open(cluster_in, "rb").read()
    off, consumed, _ = find_stream(orig)
    slot = slot_length(orig, off, consumed)
    new = open(canim_in, "rb").read()
    if len(new) > slot:
        raise SystemExit(f"error: new stream is {len(new)} bytes, the slot is {slot}: "
                         f"simplify the image (fewer colours, no noisy gradients)")
    data = orig[:off] + new + b"\0" * (slot - len(new)) + orig[off + slot:]
    assert len(data) == len(orig)
    _, _, raw = find_stream(data)
    if raw != zlib.decompress(new):
        raise SystemExit("error: verification failed, patched stream differs")
    w, h, _, _ = parse(raw)
    open(cluster_out, "wb").write(data)
    print(f"wrote {cluster_out}: {w}x{h} splash, {len(new)} of {slot} bytes at offset {off}; "
          f"only bytes {off}..{off + slot} changed; verified by decompressing the result")


def cmd_template(out_png):
    """1920x1080 frame: dark outside the cockpit band, guides inside it."""
    w, h = FRAME_W, FRAME_H
    row_out = bytes((28, 28, 32)) * w
    row_in = bytes((8, 10, 14)) * w
    rows = []
    for y in range(h):
        inband = BAND_TOP <= y < BAND_TOP + BAND_H
        r = bytearray(row_in if inband else row_out)
        if y in (BAND_TOP, BAND_TOP + BAND_H - 1):
            r = bytearray(bytes((220, 60, 60)) * w)        # band edges
        elif inband and y == BAND_TOP + BAND_H // 2:
            r = bytearray(bytes((60, 60, 70)) * w)         # horizontal centre
        if inband:
            cx = w // 2
            r[cx * 3:cx * 3 + 3] = bytes((60, 60, 70))     # vertical centre
            for x in (w // 2 - 640, w // 2 + 640):          # 1280-wide centre area
                r[x * 3:x * 3 + 3] = bytes((90, 90, 100))
        rows.append(bytes(r))
    png_write(out_png, w, h, b"".join(rows))
    print(f"wrote {out_png}: {w}x{h}; the cockpit shows rows {BAND_TOP}..{BAND_TOP + BAND_H - 1} "
          f"(red lines); keep text inside the inner 1280-wide guides to clear the housing")


def cmd_preview(in_png, out_png):
    """Crop a 1920x1080 design to the 1920x722 band the e-tron cockpit shows
    (the daemon centre-pads other sizes into the frame first, as here)."""
    w, h, rgb = png_read(in_png)
    frame = bytearray(FRAME_W * FRAME_H * 3)
    cw, ch = min(w, FRAME_W), min(h, FRAME_H)
    sx, sy = (w - cw) // 2, (h - ch) // 2
    dx, dy = (FRAME_W - cw) // 2, (FRAME_H - ch) // 2
    for y in range(ch):
        src = ((sy + y) * w + sx) * 3
        dst = ((dy + y) * FRAME_W + dx) * 3
        frame[dst:dst + cw * 3] = rgb[src:src + cw * 3]
    band = bytes(frame[BAND_TOP * FRAME_W * 3:(BAND_TOP + BAND_H) * FRAME_W * 3])
    png_write(out_png, FRAME_W, BAND_H, band)
    print(f"wrote {out_png}: {FRAME_W}x{BAND_H}, rows {BAND_TOP}..{BAND_TOP + BAND_H - 1} of the frame")


def main(argv):
    try:
        if len(argv) == 4 and argv[1] == "preview":
            cmd_preview(argv[2], argv[3])
        elif len(argv) == 3 and argv[1] == "info":
            cmd_info(argv[2])
        elif len(argv) == 4 and argv[1] == "export":
            cmd_export(argv[2], argv[3])
        elif len(argv) == 4 and argv[1] == "build":
            cmd_build(argv[2], argv[3])
        elif len(argv) == 5 and argv[1] == "patch":
            cmd_patch(argv[2], argv[3], argv[4])
        elif len(argv) == 3 and argv[1] == "template":
            cmd_template(argv[2])
        else:
            print(__doc__)
            return 2
    except KeyError:
        raise SystemExit("error: unsupported PNG colour type")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
