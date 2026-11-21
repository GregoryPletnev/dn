#!/usr/bin/env python3
"""One-run RE pass over ssavers_raw .SS/.EXE savers, round 2.

Fixes from round 1: single capstone engine (CsError(7) came from a second
engine created with detail=False), robust linear sweep that skips undecodable
bytes, correct entry-target parsing, DN '.SET' parameter-block parsing at the
'CSt' magic (0x0C in BUNDLES/DACTYL), full-file disassemblies for the small
.COM savers. Writes tools/re/report.txt. Run once per invocation; iterate
files inside python.
"""
import glob
import os
import re
import struct
import sys

from capstone import Cs, CS_ARCH_X86, CS_MODE_16

BASE = "/Users/admin/Projects/dn/ssavers_raw"
OUT = "/Users/admin/Projects/dn/tools/re/report.txt"

out = open(OUT, "w")
MD = Cs(CS_ARCH_X86, CS_MODE_16)
MD.detail = False


def P(*args):
    s = " ".join(str(a) for a in args)
    print(s)
    out.write(s + "\n")


def load(name):
    return open(os.path.join(BASE, name), "rb").read()


def hexdump(data, base, start, n, per=16):
    lines = []
    for off in range(start, min(start + n, len(data)), per):
        row = data[off:off + per]
        hx = " ".join(f"{b:02x}" for b in row)
        asc = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
        lines.append(f"  {base + off:05x}: {hx:<{per * 3}} {asc}")
    return "\n".join(lines)


def strings(data, minlen=5):
    return [(m.start(), m.group().decode("latin1"))
            for m in re.finditer(rb"[\x20-\x7e]{%d,}" % minlen, data)]


def int_sites(data):
    return [(m.start(), data[m.start() + 1])
            for m in re.finditer(rb"\xcd[\x10\x16\x21\x28\x33\x60]", data)]


def disasm_at(data, base_off, vbase=None):
    """Robust linear sweep: yield (fileoff, bytes, text), skipping bad bytes."""
    addr = (0x100 + base_off) if vbase is None else vbase
    buf = data[base_off:]
    i = 0
    while i < len(buf):
        chunk = buf[i:]
        ins = next(MD.disasm(chunk, addr + i), None)
        if ins is None:
            yield (base_off + i, buf[i:i + 1], f"db {buf[i]:02X}h")
            i += 1
            continue
        yield (base_off + i, ins.bytes, f"{ins.mnemonic} {ins.op_str}".strip())
        i += len(ins.bytes)


def dis_block(data, base_off, count=400, stop_va=None):
    lines = []
    n = 0
    for foff, raw, txt in disasm_at(data, base_off):
        va = 0x100 + foff
        lines.append(f"  {foff:05x} ({va:05x}) {raw.hex():<8} {txt}")
        n += 1
        if n >= count:
            break
        if stop_va is not None and va >= stop_va:
            break
    return "\n".join(lines)


def entry_target(data):
    b = data[0]
    if b == 0xE9:
        return struct.unpack_from("<h", data, 1)[0] + 3
    if b == 0xEB:
        return 2 + struct.unpack_from("<b", data, 1)[0]
    return 0


def ports_used(data):
    res = {}
    for m in re.finditer(rb"\xba(..)", data):
        v = struct.unpack_from("<H", data, m.start() + 1)[0]
        if 0x3B0 <= v <= 0x3DF or v in (0x20, 0x21):
            res.setdefault(v, []).append(m.start())
    return res


def movax_int(data, want=None):
    res = []
    for m in re.finditer(rb"\xb8(..)\xcd\x10", data):
        v = struct.unpack_from("<H", data, m.start() + 1)[0]
        if want is None or v in want:
            res.append((m.start(), v))
    return res


# ------------------------------------------------ DN ".CSt" .SET param block
def cst_block(data, off):
    """Parse the DN parameter block that starts with magic 'CSt' (0x0C).
    Layout (little-endian, all 16-bit):
      0x00: 'CSt' magic, word count, ...
      word @+0x0A: number of params
      then param descriptor records; strings at word offsets given in recs.
    Exact record size TBD: dump raw words and candidate string-offset triples."""
    n = struct.unpack_from("<H", data, off + 0x0A)[0]
    P(f"  CSt block at {off:05x}: count@+0x0A = {n}")
    raw = data[off + 8:off + 8 + 0x60]
    P("  raw words from +8:")
    for i in range(0, len(raw), 2):
        w = struct.unpack_from("<H", raw, i)[0]
        s = ""
        so = struct.unpack_from("<H", raw, i)[0]
        if 0x10 <= so < len(data):
            j = so
            while j < len(data) and 32 <= data[j] < 127:
                j += 1
            if data[so:so + 1].isalpha() and j - so >= 4:
                s = f"  -> {data[so:j].decode('latin1')!r}"
        P(f"    +{0x08 + i:02x}: {w:04X}{s}")


# ---------------------------------------------------------------- ASCOPE
def ascupe():
    d = load("ASCOPE.SS")
    P("=" * 78)
    P("ASCOPE.SS size", len(d), "entry off", hex(entry_target(d)))
    P("int sites:", [(hex(o), hex(i)) for o, i in int_sites(d)])
    P("key strings:")
    for o, s in strings(d, 8):
        P(f"  {o:05x}: {s!r}")
    P("ports:", {hex(k): [hex(x) for x in v] for k, v in ports_used(d).items()})
    P("int10 ax:", [(hex(o), hex(v)) for o, v in movax_int(d)])
    P("disasm entry (0x3dc1), 500 insns:")
    P(dis_block(d, 0x3dc1, 500))
    P("disasm 0x0..0x60:")
    P(dis_block(d, 0, 40))
    # the hook body is 0xC4 words = 0x188 bytes rep-movsw'd; find rep movsw
    for m in re.finditer(rb"\xf3\xa5", d):
        P(f"  rep movsw at {m.start():05x}")


# ---------------------------------------------------------------- BUNDLES
def bundles():
    d = load("BUNDLES.SS")
    P("=" * 78)
    P("BUNDLES.SS size", len(d), "entry off", hex(entry_target(d)))
    P("head dump 0..0x100:")
    P(hexdump(d, 0, 0, 0x100))
    cst_block(d, 0x0C)
    P("int10 ax:", [(hex(o), hex(v)) for o, v in movax_int(d)])
    P("mov ax,const (mode-ish):")
    for m in re.finditer(rb"\xb8(..)", d):
        v = struct.unpack_from("<H", d, m.start() + 1)[0]
        if v in (0x1C00, 0x4F02, 0x4F01, 0x0013, 0x0012, 0x0010, 0x001C):
            P(f"  mov ax,{v:04X}h at {m.start():05x}")
    P("ports:", {hex(k): [hex(x) for x in v] for k, v in ports_used(d).items()})
    for name, off, cnt in (("entry@279e", 0x279E, 400), ("3326 pal", 0x3326, 60),
                           ("3356 line", 0x3356, 140), ("3704 bounce", 0x3704, 90),
                           ("3768 walk", 0x3768, 160)):
        P(f"disasm {name}:")
        P(dis_block(d, off, cnt))
    P("RNG table head (0x2FC3):")
    P(hexdump(d, 0, 0x2FC3, 48))
    P("Bresenham params 0x33DD:")
    P(hexdump(d, 0, 0x33DD, 16))
    P("jump tables:")
    P(hexdump(d, 0, 0x3524, 0x40))
    P(hexdump(d, 0, 0x3564, 0x40))
    P("records/ring 0x1180:")
    P(hexdump(d, 0, 0x1180, 0x40))


# ---------------------------------------------------------------- CHIK
def chik():
    d = load("CHIK.SS")
    P("=" * 78)
    P("CHIK.SS size", len(d), "entry off", hex(entry_target(d)))
    P("full disasm:")
    P(dis_block(d, 0, len(d)))
    P("full hexdump:")
    P(hexdump(d, 0, 0, len(d)))


# ---------------------------------------------------------------- COLINES
def colines():
    d = load("COLINES.SS")
    P("=" * 78)
    P("COLINES.SS size", len(d), "entry off", hex(entry_target(d)))
    P("full disasm:")
    P(dis_block(d, 0, len(d)))
    P("hexdump 0x100..end:")
    P(hexdump(d, 0, 0x100, len(d) - 0x100))


# ---------------------------------------------------------------- DACTYL
def dactyl():
    d = load("DACTYL.SS")
    P("=" * 78)
    P("DACTYL.SS size", len(d), "entry off", hex(entry_target(d)))
    cst_block(d, 0x0C)
    P("int10 ax:", [(hex(o), hex(v)) for o, v in movax_int(d)])
    P("ports:", {hex(k): [hex(x) for x in v] for k, v in ports_used(d).items()})
    P("disasm 0x140..0x200 (mode set, DAC, blitter):")
    P(dis_block(d, 0x140, 120))
    P("disasm 0x12E0.. (mode 13h?):")
    P(dis_block(d, 0x12E0, 60))
    P("disasm entry region (jmp stub targets 0x158c?):")
    for cand in (entry_target(d), 0x158C, 0x1AD, 0x1AB, 0x192):
        P(f"  --- from {cand:05x}:")
        P(dis_block(d, cand & 0xFFFF, 60))
    # frame stream: scan for plausible 32-byte-row RLE frames
    P("candidate frame-stream region: hexdump 0x200..0x280, 0x1500..0x15A0")
    P(hexdump(d, 0, 0x200, 0x80))
    P(hexdump(d, 0, 0x1500, 0x80))
    # find the 16 frame pointers: the known 16-word table (from user) is at
    # 0x1D8? search for the exact byte pattern d817 271d a723...
    sig = bytes.fromhex("d817271da7238a29432e9f33c8394140 0f48b550f1585d5f daf8cb0bc074".replace(" ", ""))
    i = d.find(sig)
    P("frame-pointer table sig at", hex(i) if i >= 0 else "NOT FOUND")
    if i >= 0:
        for k in range(16):
            P(f"   frame[{k}] off={struct.unpack_from('<H', d, i + 2 * k)[0]:04X}")


# ---------------------------------------------------------------- DAZZLE2
def dazzle2():
    d = load("DAZZLE2.SS")
    P("=" * 78)
    P("DAZZLE2.SS size", len(d), "entry off", hex(entry_target(d)))
    P("int10 ax:", [(hex(o), hex(v)) for o, v in movax_int(d)])
    P("ports:", {hex(k): [hex(x) for x in v] for k, v in ports_used(d).items()})
    P("int sites hist:")
    h = {}
    for o, i in int_sites(d):
        h[i] = h.get(i, 0) + 1
    P(" ", {hex(k): v for k, v in sorted(h.items())})
    P("strings >=6:")
    for o, s in strings(d, 6):
        P(f"  {o:05x}: {s!r}")
    P("head disasm:")
    P(dis_block(d, 0, 40))


# ---------------------------------------------------------------- EXPLOSIV
def explosiv():
    d = load("EXPLOSIV.SS")
    P("=" * 78)
    P("EXPLOSIV.SS size", len(d), "entry off", hex(entry_target(d)))
    P("int10 ax:", [(hex(o), hex(v)) for o, v in movax_int(d)])
    P("ports:", {hex(k): [hex(x) for x in v] for k, v in ports_used(d).items()})
    P("strings >=5:")
    for o, s in strings(d, 5):
        P(f"  {o:05x}: {s!r}")
    P("head disasm:")
    P(dis_block(d, 0, 80))


# ---------------------------------------------------------------- VGARAIN
def vgarain():
    d = load("VGARAIN.SS")
    P("=" * 78)
    P("VGARAIN.SS size", len(d), "entry off", hex(entry_target(d)))
    P("int10 ax:", [(hex(o), hex(v)) for o, v in movax_int(d)])
    P("ports:", {hex(k): [hex(x) for x in v] for k, v in ports_used(d).items()})
    P("strings >=5:")
    for o, s in strings(d, 5):
        P(f"  {o:05x}: {s!r}")
    P("head disasm:")
    P(dis_block(d, 0, 80))


# ---------------------------------------------------------------- MZ files
def mz_summary():
    for name in ("ISRAEL.SS", "TESTSS.EXE", "NEON.SS", "STARS.SS", "MAZESOLV.SS"):
        d = load(name)
        P("=" * 78)
        P(name, "size", len(d))
        if d[:2] != b"MZ":
            P("  not MZ")
            continue
        clen = struct.unpack_from("<H", d, 0x08)[0]
        reloc_off, reloc_n = struct.unpack_from("<HH", d, 0x18)
        ip, cs = struct.unpack_from("<HH", d, 0x14)
        P(f"  hdrparas={clen}(load 0x{clen << 4:x}) reloc@{reloc_off:#x} x{reloc_n} "
          f"CS:IP={cs:04X}:{ip:04X}")
        P("  image head:")
        P(hexdump(d, 0, clen << 4, 32))
        for sig in (b"LZEXE", b"PKL", b"PKLite", b"MsDos Exe", b"TPU"):
            idx = d.find(sig)
            if idx >= 0:
                P(f"  sig {sig!r} at {idx:05x}")


def main():
    only = sys.argv[1:]
    fns = {
        "ASCOPE.SS": ascupe, "BUNDLES.SS": bundles, "CHIK.SS": chik,
        "COLINES.SS": colines, "DACTYL.SS": dactyl, "DAZZLE2.SS": dazzle2,
        "EXPLOSIV.SS": explosiv, "VGARAIN.SS": vgarain,
    }
    names = only if only else list(fns)
    for b in names:
        if b in fns:
            try:
                fns[b]()
            except Exception as e:
                import traceback
                P(f"!! {b}: {e!r}")
                P(traceback.format_exc())
    if not only:
        mz_summary()
    out.close()
    print("report ->", OUT)


if __name__ == "__main__":
    main()
