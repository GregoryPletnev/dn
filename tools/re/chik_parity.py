#!/usr/bin/env python3
"""Bit-exact parity: chik_emu vs the Pascal probe dump.

Harness (both sides identical): frozen second; Init primes the roll;
the boot frame runs on the blank default grid; the caller paints the
filled grid right after the boot frame; frames 1..12 printed and
compared. Probe sums grid BYTES (126 per 0x1F20 cell, 193 per 0x07C1
cell, 0 erased); the reference dump carries erased-cell counts.

Usage: python3 tools/re/chik_parity.py <probe_dump.txt>
"""
import re
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from chik_probe_emu import CFGS

BPW = {0x1F20: 63, 0x07C1: 200}  # byte sum per cell: hi + lo bytes
CELL_WORD = {0x1F20: 0x1F20, 0x07C1: 0x07C1}

REF = re.compile(
    r'f(\d+) sum=(\d+) erased=(\d+) pos=(\d+) col=(\d+) row=(\d+) '
    r'walk=(\d+) x=(\d+) y=(\d+) d=(-?\d+),(-?\d+) first=(\d+)')
PROBE = re.compile(
    r'f(\d+) sum=(\d+) erased=(\d+) pos=(\d+) col=(\d+) row=(\d+) '
    r'walk=(\d+) x=(\d+) y=(\d+) d=(-?\d+),(-?\d+) first=(\d+)')


def parse(path, rx):
    blocks = {}
    cur = None
    for line in open(path):
        m = re.match(r'-- (\d+)x(\d+) sec=(\d+) grid=(\w+)', line)
        if m:
            cur = (int(m.group(1)), int(m.group(2)),
                   int(m.group(3)), int(m.group(4), 16))
            blocks[cur] = []
            continue
        m = rx.match(line.strip())
        if m and cur:
            blocks[cur].append(tuple(int(g) for g in m.groups()))
    return blocks


def main():
    ref = parse('tools/re/chik_probe_emu.out', REF)
    pas = parse(sys.argv[1], PROBE)
    assert set(ref) == set(pas), (set(ref) ^ set(pas))
    bad = 0
    checked = 0
    for (cols, rows), _s, gval in CFGS:
        k = (cols, rows, _s, gval)
        cells = cols * rows
        bps = BPW[gval]
        p = {row[0]: row for row in pas[k]}
        for r in ref[k]:
            fp = p.get(r[0])
            if fp is None:
                continue
            checked += 1
            state_ok = r[3:] == fp[3:]
            cells_left, rem = divmod(r[1], CELL_WORD[gval])
            expect = cells_left * bps if rem == 0 else None
            if not (state_ok and expect == fp[1]):
                bad += 1
                print("MISMATCH", k, "f", r[0], "\n ref", r, "\n pas", fp,
                      "\n expect_bytes", expect)
    print("frames:", checked, "mismatches:", bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
