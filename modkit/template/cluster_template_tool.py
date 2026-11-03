#!/usr/bin/env python3
"""
cluster_template_tool.py - the cluster display the Android Auto hook offers
the phone: decode it, build one for a car, patch it into gal_cluster.so.

What it is: gal_cluster.so appends one Service entry to the head unit's
ServiceDiscoveryResponse so the phone opens a second video stream for the
cluster. That entry is a fixed 54-byte protobuf, dhu_cluster_service[] in
src/dhu_sdresp_data.h; at runtime the hook copies it verbatim and patches a
single byte, index 9, with the codec resolution from GAL_CLUSTER_RES. The
GAL_CLUSTER_INSET_* variables are read but never reach the phone: the
build_cluster_service() path that would carry them is not what is sent
(found by Bhushan Ahire on a Q7, PR #11; confirmed against the v0034 source
and binary). So the phone lays its cluster UI out for the whole frame, puts
the car marker near the bottom and the turn card flush right, and the
cockpit's crop and housing cut them off.

The lever is inside that entry: VideoConfiguration.ui_config carries two
Insets, in frame pixels (1920x1080 at codecRes=1080):
  margins         rows/columns of the frame the display does not show
                  (the phone lays everything out inside what is left);
  content_insets  within that, where the car's own graphics overlap
                  (the cockpit's bottom info bar, the curved housing);
                  the phone keeps the car marker, turn card and ETA out of it.
Field numbers (Android Auto protocol, community-documented, verified on a
Q7): Insets{top=1,bottom=2,left=3,right=4}; UiConfig{margins=1,
content_insets=2,stable_content_insets=3,ui_theme=4}; VideoConfiguration
{codec_resolution=1,frame_rate=2,width_margin=3,height_margin=4,density=5,
decoder_additional_depth=6,viewing_distance=7,pixel_aspect_ratio_e4=8,
real_density=9,video_codec_type=10,ui_config=11}.

Constraints the hook imposes: the entry must stay exactly 54 bytes (the copy
length is compiled in) and codec_resolution must stay at byte 9. The builder
drops zero-valued optional fields to make room and adds them back as padding
to land on 54 exactly; it refuses anything else.

The defaults are the Q7 entry from PR #11 (phone-accepted, framing verified
on the same 1920x722 cockpit): the daemon's fill crop centred (panY=0) shows
frame rows 179..900, so height_margin=358 with margins top=179 / bottom=180;
the Audi info bar and curved housing are content insets bottom=195 /
left=160 / right=160; density 200. `build` with no keys reproduces those 54
bytes exactly. Tune the insets per car from there; keep panY=0 with them.

Usage:
  cluster_template_tool.py decode <gal_cluster.so | template.bin | aa_sdresp_*.bin>
  cluster_template_tool.py build  <out.bin> key=value ...     (see DEFAULTS)
  cluster_template_tool.py patch  <gal_cluster.so> <template.bin> <out.so>
"""
import struct
import sys

SYMBOL = "dhu_cluster_service"
TEMPLATE_LEN = 54
CODEC_BYTE = 9

# The Q7 entry (PR #11); the shipped one is the same with density 160,
# height_margin 0 and all margins/insets 0.
DEFAULTS = {
    "service_id": 14, "codec_res": 1, "frame_rate": 1, "density": 200,
    "viewing_distance": 500, "pixel_aspect_ratio_e4": 10000, "real_density": 200,
    "video_codec_type": 3, "display_id": 1, "display_type": 1,
    "width_margin": 0, "height_margin": 358,
    "margin_top": 179, "margin_bottom": 180, "margin_left": 0, "margin_right": 0,
    "inset_top": 0, "inset_bottom": 195, "inset_left": 160, "inset_right": 160,
}


# ---- protobuf ---------------------------------------------------------------

def varint(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def field(num, v):
    return varint((num << 3) | 0) + varint(v)


def msg(num, body):
    return varint((num << 3) | 2) + varint(len(body)) + body


def read_varint(b, i):
    v = s = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7F) << s
        s += 7
        if not c & 0x80:
            return v, i


def parse(b):
    i, out = 0, []
    while i < len(b):
        key, i = read_varint(b, i)
        f, w = key >> 3, key & 7
        if w == 0:
            v, i = read_varint(b, i)
            out.append((f, v))
        elif w == 2:
            ln, i = read_varint(b, i)
            out.append((f, b[i:i + ln]))
            i += ln
        else:
            raise ValueError(f"unsupported wire type {w}")
    return out


# ---- the cluster Service entry ---------------------------------------------

INSETS = ("top", "bottom", "left", "right")


def insets(prefix, p):
    return b"".join(field(n + 1, p[f"{prefix}_{k}"]) for n, k in enumerate(INSETS) if p[f"{prefix}_{k}"])


def build(p, pads):
    """pads: set of optional zero fields to include for length."""
    vc = field(1, p["codec_res"]) + field(2, p["frame_rate"])
    if p["width_margin"] or "width_margin" in pads:
        vc += field(3, p["width_margin"])
    if p["height_margin"]:
        vc += field(4, p["height_margin"])
    vc += field(5, p["density"])
    if "decoder_depth" in pads:
        vc += field(6, 0)
    vc += field(7, p["viewing_distance"]) + field(8, p["pixel_aspect_ratio_e4"])
    vc += field(9, p["real_density"]) + field(10, p["video_codec_type"])
    ui = msg(1, insets("margin", p)) if insets("margin", p) or "margins" in pads else b""
    ci = insets("inset", p)
    if ci or "content_insets" in pads:
        ui += msg(2, ci)
    if "stable" in pads:
        ui += msg(3, b"")
    if "ui_theme" in pads:
        ui += field(4, 0)
    vc += msg(11, ui)
    # MediaSinkService as the DHU sends it for the cluster: video_configs,
    # display_id, display_type (no available_type: the phone validated the
    # entry against the DHU's shape, see dhu_sdresp_data.h)
    mss = msg(4, vc) + field(6, p["display_id"]) + field(7, p["display_type"])
    return msg(1, field(1, p["service_id"]) + msg(3, mss))


PADS = ("width_margin", "decoder_depth", "stable", "ui_theme", "margins", "content_insets")


def build_fitted(p):
    """Find the padding that makes the entry exactly TEMPLATE_LEN bytes.
    Each pad adds 2 bytes; viewing_distance 500->127 removes one, used only
    when the parity needs it."""
    import itertools
    for vd in (p["viewing_distance"], 127):
        q = dict(p, viewing_distance=vd)
        for n in range(len(PADS) + 1):
            for combo in itertools.combinations(PADS, n):
                b = build(q, set(combo))
                if len(b) == TEMPLATE_LEN:
                    if b[CODEC_BYTE] != p["codec_res"]:
                        raise SystemExit("error: codec_resolution is not at byte 9 (service id or lengths too large)")
                    return b, combo, vd
    base = len(build(p, set()))
    raise SystemExit(f"error: cannot fit the entry in {TEMPLATE_LEN} bytes (base {base}); "
                     f"change a value's size (values >= 128 take 2 varint bytes)")


# ---- ELF / files -------------------------------------------------------------

def elf_symbol(data, name):
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        return None
    shoff, = struct.unpack_from("<I", data, 0x20)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x2E)
    secs = [struct.unpack_from("<IIIIIIIIII", data, shoff + i * shentsize) for i in range(shnum)]
    for s in secs:
        if s[1] != 2:
            continue
        strtab = secs[s[6]]
        for pos in range(s[4], s[4] + s[5], 16):
            st_name, st_value, st_size, _, _, st_shndx = struct.unpack_from("<IIIBBH", data, pos)
            end = data.index(b"\0", strtab[4] + st_name)
            sym = data[strtab[4] + st_name:end].decode(errors="replace")
            # a file-local static gets a ".NNNN" suffix from the compiler
            if sym == name or sym.startswith(name + "."):
                sec = secs[st_shndx]
                return sec[4] + (st_value - sec[3]), st_size
    return None


def load_entry(path):
    """The cluster Service entry from a .so (by symbol), a raw template, or a
    service-discovery dump (the entry whose Service.id is the cluster id)."""
    data = open(path, "rb").read()
    sym = elf_symbol(data, SYMBOL)
    if sym:
        off, size = sym
        return data[off:off + size], f"{path} @ {SYMBOL} offset {off} ({size} bytes)"
    if len(data) == TEMPLATE_LEN and data[0] == 0x0A:
        return data, path
    # a ServiceDiscoveryResponse dump: find the services with a cluster display
    for f, v in parse(data):
        if f == 1 and isinstance(v, (bytes, bytearray)):
            for sf, sv in parse(v):
                if sf == 3 and any(mf == 7 and mv == 1 for mf, mv in parse(sv)):
                    return msg(1, v), f"{path}: service with display_type=CLUSTER"
    raise SystemExit(f"error: no cluster service entry found in {path}")


def describe(entry):
    names_vc = {1: "codec_resolution", 2: "frame_rate", 3: "width_margin", 4: "height_margin", 5: "density",
                6: "decoder_additional_depth", 7: "viewing_distance", 8: "pixel_aspect_ratio_e4",
                9: "real_density", 10: "video_codec_type"}
    (f, svc), = parse(entry)
    for sf, sv in parse(svc):
        if sf == 1:
            print(f"  service_id = {sv}")
        elif sf == 3:
            for mf, mv in parse(sv):
                if mf == 4:
                    print("  VideoConfiguration:")
                    for vf, vv in parse(mv):
                        if vf == 11:
                            for uf, uv in parse(vv):
                                label = {1: "margins", 2: "content_insets", 3: "stable_content_insets", 4: "ui_theme"}[uf]
                                if isinstance(uv, int):
                                    print(f"    ui_config.{label} = {uv}")
                                else:
                                    vals = {INSETS[k - 1]: v for k, v in parse(uv)}
                                    print(f"    ui_config.{label} = {vals if vals else '{}'}")
                        else:
                            print(f"    {names_vc.get(vf, 'f' + str(vf))} = {vv}")
                else:
                    label = {1: "available_type", 6: "display_id", 7: "display_type"}.get(mf, "f" + str(mf))
                    print(f"  {label} = {mv}")
    print(f"  ({len(entry)} bytes; byte {CODEC_BYTE} = codec_resolution placeholder {entry[CODEC_BYTE]})")


# ---- commands ----------------------------------------------------------------

def cmd_decode(path):
    entry, where = load_entry(path)
    print(where)
    describe(entry)


def cmd_build(out, kvs):
    p = dict(DEFAULTS)
    for kv in kvs:
        k, v = kv.split("=", 1)
        if k not in p:
            raise SystemExit(f"error: unknown key {k}; keys: {', '.join(sorted(p))}")
        p[k] = int(v)
    entry, pads, vd = build_fitted(p)
    open(out, "wb").write(entry)
    print(f"wrote {out} ({len(entry)} bytes; padding fields: {', '.join(pads) or 'none'}"
          f"{'; viewing_distance reduced to 127 for length' if vd != p['viewing_distance'] else ''})")
    describe(entry)


def cmd_patch(so_in, template, so_out):
    data = open(so_in, "rb").read()
    sym = elf_symbol(data, SYMBOL)
    if not sym:
        raise SystemExit(f"error: {SYMBOL} symbol not found in {so_in}")
    off, size = sym
    new = open(template, "rb").read()
    if len(new) != size:
        raise SystemExit(f"error: template is {len(new)} bytes, the slot is {size}")
    if new[CODEC_BYTE] != 1 and new[CODEC_BYTE] != data[off + CODEC_BYTE]:
        raise SystemExit("error: byte 9 must be the codec_resolution placeholder")
    patched = data[:off] + new + data[off + size:]
    assert len(patched) == len(data)
    open(so_out, "wb").write(patched)
    check, _ = load_entry(so_out)
    if check != new:
        raise SystemExit("error: verification failed")
    print(f"wrote {so_out}: {size} bytes replaced at offset {off}; nothing else changed; verified")
    describe(check)


def main(argv):
    if len(argv) == 3 and argv[1] == "decode":
        cmd_decode(argv[2])
    elif len(argv) >= 3 and argv[1] == "build":
        cmd_build(argv[2], argv[3:])
    elif len(argv) == 5 and argv[1] == "patch":
        cmd_patch(argv[2], argv[3], argv[4])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
