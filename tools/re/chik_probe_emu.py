#!/usr/bin/env python3
"""Harness-aligned ground-truth dump of chik_emu.

Mirrors the Pascal probe exactly: frozen second; the boot frame runs
on the blank default grid (erases land there, lost); the caller paints
the filled grid right after the boot frame; probe frame N is emulator
frame N+1 for N >= 1 (probe frame 1 prints the state the paint left,
matching the Pascal probe which prints after boot Step + paint).
"""
import sys

sys.path.insert(0, 'tools/re')
from chik_emu import Chik

CFGS = (((80, 25), 5, 0x1F20), ((80, 25), 13, 0x1F20), ((80, 25), 5, 0x07C1),
        ((80, 43), 7, 0x1F20), ((40, 25), 9, 0x1F20))


def show(c, cols, rows, f):
    nz = sum(1 for v in c.g if v)
    print(f"f{f} sum={sum(c.g)} erased={cols * rows - nz} pos={c.wo // 2} "
          f"col={(c.wo // 2) % cols} row={(c.wo // 2) // cols} "
          f"walk={c.walk} x={c.x} y={c.y} d={c.dx},{c.dy} first={c.first}")


def main():
    for (cols, rows), secs, gval in CFGS:
        clk = [secs]
        c = Chik(cols, rows, lambda: clk[0])
        c.frame()                     # boot frame on the blank grid
        c.g = [gval] * (cols * rows)  # caller paints the screen
        print(f"-- {cols}x{rows} sec={secs} grid={gval:04X}")
        for f in range(1, 13):
            if f >= 2:
                c.frame()
            show(c, cols, rows, f)


if __name__ == '__main__':
    main()
