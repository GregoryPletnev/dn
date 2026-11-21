#!/usr/bin/env python3
"""Independent ground-truth emulator for src/dnbundlessav.pas.

Models the verified BUNDLES.SS bit-plane pipeline (see bundles_analysis.md
and tools/re/disasm_bundles.py) by replaying the original frame loop, not by
reconstructing a model:

  * Four color planes. Plane P is a bit-plane of 80 bytes/row x 300 rows
    (0x9600 bytes). Plane pixel (px, py) lives at byte (px>>3) + py*80,
    bit (px&7); py = y>>1 because the plotter only acts on even y.
  * Color c (1..15) draws into plane (c-1) mod 4 (VGA GC set/reset op,
    routine 0x3598). Draw mode ORs the bit in; the frame loop erases the
    new head segment first (GC XOR with NOT mask, clears the pixel) then
    OR-draws it (0x3765 loop, modes 1 then 0).
  * Bresenham walk, bounce walls 0x27F/0x1DF, and the 997-word RNG table are
    taken from the disassembly, identical to the FPC unit.

The composite grid maps the plane directly: grid column = px (0..639), grid
row = py (0..299), one palette-8 value per cell. The owning color is the
lowest color with a set bit in any plane, matching the original draw order.

Usage:
  python3 tools/re/bundles_oracle.py [RngSeed]
  python3 tools/re/bundles_oracle.py [RngSeed] --vectors
"""
import os
import struct
import sys

BIN = next(p for p in ('ssavers_raw/BUNDLES.SS',
                       '../../ssavers_raw/BUNDLES.SS',
                       '/Users/admin/Projects/dn/ssavers_raw/BUNDLES.SS')
           if os.path.exists(p))
ARGV = [a for a in sys.argv[1:] if a != '--vectors']
VECTORS = '--vectors' in sys.argv
SEED = int(ARGV[0]) if ARGV else 1

# RNG table straight from the binary (mem 0x2FC3 = file 0x2EC3)
RNG = struct.unpack_from('<997H', open(BIN, 'rb').read(), 0x2EC3)
B, L = 2, 5                       # NumBundles, NumLines (shipped defaults)
WALLX, WALLY = 0x27F, 0x1DF       # bounce limits (0x381A / 0x384C)
GRIDW, GRIDH = 640, 300           # composite grid = the plane dimensions
ROWB = 80                         # bytes per plane row
PLANEBYTES = ROWB * GRIDH         # 0x9600

idx = SEED & 0x3FE                # orig tick init 0x372E: jiffies AND 3FE
val = RNG[idx]


def nxt():
    global idx, val
    idx = (idx + 1) % 997
    val = RNG[idx]
    return val


# world init: segments (0x3651), velocities (0x369D), colors (0x36BF)
pos, vel, col = [], [[0] * 4 for _ in range(B)], [0] * B
for b in range(B):
    r = nxt(); x0 = ((r & 0xFF) * 5) >> 1
    r = nxt(); y = (r & 0xFF) * 2; y0 = y - 39 if y >= 480 else y
    r = nxt(); x1 = ((r & 0xFF) * 5) >> 1
    r = nxt(); y = (r & 0xFF) * 2; y1 = y - 40 if y >= 480 else y
    pos.append([x0, y0, x1, y1])
masks = (0xF, 7, 7, 0xF)
for b in range(B - 1, -1, -1):
    for j in range(4):
        r = nxt()
        d = (r & masks[j]) or 1
        vel[b][j] = -d if (r >> 8) & 1 else d
for b in range(B - 1, -1, -1):
    while True:
        r = nxt()
        if r & 0xF:
            break
    col[b] = r & 0xF

trail = [[((pos[b][0], pos[b][1]), (pos[b][2], pos[b][3]))
          for _ in range(L)] for b in range(B)]
head, color, chasestep = [0] * B, col[:], [0] * B
chase, chasecolor = [0] * B, [0] * B


def chase_tick(b):
    chase[b] += 1
    if chase[b] >= 3:
        chase[b] = 0
        c = (chasecolor[b] + 1) & 0xF
        chasecolor[b] = c or 1


def bounce(p, v, mask, mx, b):
    if p < 0:
        chase_tick(b)
        v = (val & mask) << 1 or 5
        p = 0
    elif p > mx:
        chase_tick(b)
        nv = (val & mask) << 1
        v = -(nv or 5)
        p = mx
    return p, v


# four bit-planes, each 80 bytes x 300 rows
planes = [bytearray(PLANEBYTES) for _ in range(4)]


def plot(x, y, c, erase):
    # orig bounds 0x3598: bx = (x>>3) + (y>>1)*80 must be < 0x9600
    if not (0 <= x < 640) or (y & 1) or not (0 <= y < 480):
        return
    off = (x >> 3) + (y >> 1) * ROWB
    if off >= PLANEBYTES:
        return
    bit = 1 << (x & 7)
    p = planes[(c - 1) & 3]
    if erase:
        p[off] ^= bit            # GC XOR op with NOT mask clears the pixel
    else:
        p[off] |= bit            # GC set op ORs the pixel in


def line(x0, y0, x1, y1, c, erase):
    # orig 0x3456: normalize endpoints, forward Bresenham, fill verticals
    if x0 > x1:
        x0, x1, y0, y1 = x1, x0, y1, y0
    dx, dy = x1 - x0, y1 - y0
    if dx == 0:
        if dy < 0:
            dy, y0, y1 = -dy, y1, y0
        while y0 <= y1:
            plot(x0, y0, c, erase)
            y0 += 1
        return
    ys = 1
    if dy < 0:
        dy, ys = -dy, -1
    if dy <= dx:
        e = 2 * dy - dx
        while True:
            plot(x0, y0, c, erase)
            if x0 == x1:
                break
            if e < 0:
                e += 2 * dy
            else:
                e += 2 * (dy - dx)
                y0 += ys
            x0 += 1
    else:
        e = 2 * dx - dy
        while True:
            plot(x0, y0, c, erase)
            if y0 == y1:
                break
            if e < 0:
                e += 2 * dx
            else:
                e += 2 * (dx - dy)
                x0 += 1
            y0 += ys


def compose():
    # one palette-8 value per grid cell; owner = lowest color with a set bit
    g = [[0] * GRIDW for _ in range(GRIDH)]
    for py in range(GRIDH):
        row = g[py]
        base = py * ROWB
        for px in range(GRIDW):
            by = (px >> 3) + base
            bit = 1 << (px & 7)
            for c in range(1, 16):
                if planes[(c - 1) & 3][by] & bit:
                    row[px] = c
                    break
    return g


def fnv(g):
    h = 0x811C9DC5
    for row in g:
        for v in row:
            h ^= v
            h = (h * 0x01000193) & 0xFFFFFFFF
    return h


def pixels(g):
    return sum(1 for row in g for v in row if v)


def first_px(g):
    for yy in range(GRIDH):
        row = g[yy]
        for xx in range(GRIDW):
            if row[xx]:
                return (yy, xx, row[xx])
    return None


def decimate(g):
    # the terminal rect maps the 640x300 grid down to 320x100: a display
    # cell is lit by its top-left source pixel, color and all
    return [[g[py * 3][px * 2] for px in range(320)] for py in range(100)]


def step_all():
    # literal frame loop 0x3765: advance head, erase new head, draw new head
    for b in range(B):
        chasecolor[b] = color[b] & 0xF or 1
        chase[b] = chasestep[b]
        n = (head[b] + 1) % L
        (ax, ay), (bx, by) = trail[b][head[b]]
        ax += vel[b][0]
        ax, vel[b][0] = bounce(ax, vel[b][0], 0xF, WALLX, b)
        ay += vel[b][1]
        ay, vel[b][1] = bounce(ay, vel[b][1], 7, WALLY, b)
        bx += vel[b][2]
        bx, vel[b][2] = bounce(bx, vel[b][2], 7, WALLX, b)
        by += vel[b][3]
        by, vel[b][3] = bounce(by, vel[b][3], 0xF, WALLY, b)
        c = chasecolor[b]
        line(ax, ay, bx, by, c, erase=True)     # 0x37C6 mode 1 erase new head
        line(ax, ay, bx, by, c, erase=False)    # 0x37E2 mode 0 draw new head
        trail[b][n] = ((ax, ay), (bx, by))
        head[b] = n
        color[b] = chasecolor[b]
        chasestep[b] = chase[b]


# bootstrap: the init path (0x3745) draws each bundle's single segment once
for b in range(B):
    (ax, ay), (bx, by) = trail[b][0]
    line(ax, ay, bx, by, color[b], erase=False)


def report(tag, g):
    d = decimate(g)
    return (f"seed {SEED} {tag} fnv {format(fnv(g), '08x')} px {pixels(g)} "
            f"first {first_px(g)} d_fnv {format(fnv(d), '08x')} "
            f"d_px {pixels(d)}")


if VECTORS:
    g = compose()
    print(report("frame 0", g), "color", list(color))
    for k in range(1, 11):
        step_all()
        g = compose()
        print(report(f"frame {k}", g), "color", list(color))
    raise SystemExit(0)


print("init pos", pos)
print("init vel", vel)
print("init col", col)
g = compose()
print("init first", first_px(g), "fnv", format(fnv(g), '08x'))
for k in range(3):
    step_all()
    g = compose()
    print("step", k, "color", color, "first", first_px(g),
          "fnv", format(fnv(g), '08x'))
