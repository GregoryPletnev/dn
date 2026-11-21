#!/usr/bin/env python3
"""One-off RE probe: int10 sites, RNG loops, data tables in .SS savers."""
import re, struct, sys

BASE = "ssavers_raw"

def chik():
    d = open(f"{BASE}/CHIK.SS", "rb").read()
    for m in re.finditer(rb"\xb8", d):
        s = m.start()
        ax = int.from_bytes(d[s + 1:s + 3], "little")
        if d[s + 3:s + 5] == b"\xcd\x10":
            print("int10 ax=%04X at" % ax, hex(s))
    print("all int10:", [hex(m.start()) for m in re.finditer(rb"\xcd\x10", d)])
    print("all int33:", [hex(m.start()) for m in re.finditer(rb"\xcd\x33", d)])

def bxadd(path):
    """Find BX=0; ADD BX,[mem16]; MUL DX sites: 31 DB, 03 1E xx xx, F7 E2
    (32-bit forms 66 03 1E / 66 F7 E2). Prints the 16-byte window."""
    d = open(path, "rb").read()
    for m in re.finditer(rb"\x31\xdb", d):
        s = m.start()
        win = d[s:s + 16]
        if re.search(rb"\x03\x1e|\x66\x03\x1e", win) and re.search(rb"\xf7\xe2|\x66\xf7\xe2", win):
            print(path, hex(s), win.hex())


def rngloop(path):
    """Find tight 16-bit xor/add/rol RNG loops: patterns seen in SS savers
    (D1 Cx/Dx rol, 01 Dx/Ex add, 31 Dx/Ex xor, 33 Cx/Dx xor, 88/8A mov,
    0F C1/C8/C0 shl/shrd) within a window ending in E2 xx (loop back).
    Counts the RNG-ish opcodes in each 24-byte window."""
    d = open(path, "rb").read()
    ops = (b"\xd1\xc2", b"\xd1\xc3", b"\xd3\xc2", b"\xd3\xc3",  # rol dx,cx / bx,cx
           b"\x01\xd3", b"\x01\xd7", b"\x01\xde", b"\x01\xdf",  # add bx/bx/bx/bx
           b"\x31\xc9", b"\x31\xd3", b"\x31\xd7", b"\x31\xde",  # xor cx/bx/bx/bx
           b"\x33\xc1", b"\x33\xdb", b"\x33\xd1", b"\x33\xd9",  # xor ax/bx/dx/bx
           b"\x88\xf2", b"\x8a\xf3", b"\x0f\xc1", b"\x0f\xc8",
           b"\x10\xf6")
    for m in re.finditer(rb"[\xd1\xd3]\xc[0-7]", d):
        s = m.start()
        win = d[s:s + 24]
        n = sum(win.count(o) for o in ops)
        if n >= 3 and b"\xe2" in win:
            print(path, hex(s), win.hex())


if __name__ == "__main__":
    import glob
    if len(sys.argv) > 1:
        for p in sys.argv[1:]:
            bxadd(p)
            rngloop(p)
    else:
        chik()
