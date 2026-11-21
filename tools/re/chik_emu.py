#!/usr/bin/env python3
"""CHIK.SS ground-truth emulator: the reference for src/dnchiksav.pas.

Final semantics (every branch byte-verified with capstone; map in
tools/re/chik_analysis.md). One frame = one retrace iteration:

  state byte (bp-0x05): 0 = choose (0x02B1), != 0 = moving.

  bootstrap (0x01F3..0x0254): walk = PRD(20) first-move delay;
    col = PRD(cellsX)*w, row = PRD(rowsY)*h, winOff = (row*cols+col)*2
    (+page*8000). The first-pass wipe (0x0256..0x02A1, entered with
    state=0 from 0x02A3, NOT gated by the countdown) blanks one strip
    row per frame for rows div h = rowsY frames; bp-0x20 (the row-loop
    bound, 0x0248) = rows div h, the x bound (0x0288) = cellsX. So the
    boot wipe covers the box strip (cellsX wide box cells, i.e. the
    box columns at w apart — modeled as the w-wide box per row).

  choose (0x02A3..0x03C2): winOff/col/row are re-set every choose
    frame by the 0x03C4..0x03F2 slide block, which recomputes winOff
    from the box cell scaled by the lattice step:
    winOff = (2*(col div w) * (w*(cols div w)) + 2*(row div h)*
    (rows div h)*cols) + (quantized cell offset) — the port models
    this as winOff = 2*(row*cols + col) with col/row the slide-tracked
    box cell (the slide vectors are added to col/row at sweep end,
    the 0x0484 add 2*dx*stepW + 2*dy*rowsY*cols... see note). The
    0x02BA..0x02F8 retract is unreachable dead code.
    Direction reroll (0x02FB..0x04BB): dir = PRD(4)&3 rejected at the
    FAR wall with the original's off-by-one: dir=2 rejected when
    col == (cellsX-1)*w (last lattice column), dir=3 when row ==
    (rowsY-1)*h; LEFT/UP rejected at col==0/row==0. Jump table
    cs:[0x5DA]: right walk=cellsX, down walk=rowsY, left cellsX,
    up rowsY.

  moving frames (0x041C..0x0524): ONE lattice cell per frame.
    cell = winOff/2 + y*cols + x, x < cols div w (0x0466), y < rows
    div h (0x047C). Capture (live pass): snapshot then write 0 (the
    erased text never returns — the 0x04B2 restore loop is on the
    unreachable path). Sweep end (after rowsY*cellsX frames): dec
    walk; walk==0 -> choose; else winOff += 2*dx + 2*cols*dy (the
    0x0484 one-cell slide) and col += dx, row += dy.

  The walk moves the erase window ONE cell per sweep: cellsX sweeps
  horizontal (span cellsX cells), rowsY vertical. The window stays
  inside the screen because choose re-anchors winOff to the
  quantized box cell and the reroll rule rejects outward legs.

PRD(b) = int 21h/2Ch seconds mod b (helper 0x05E2); the clock is a
callable so tests pin the DOS second. Under a frozen clock the
original spins at 0x04BB; the emulator takes the first inward
direction after 8 tries (documented deviation).

The snapshot buffer (0xFD0, 125 words) is modeled only as bounds:
capture never restores, so its contents do not affect the grid.
"""

BOX = {(40, 25): (4, 5), (80, 25): (4, 5), (80, 50): (4, 5),
       (80, 43): (4, 6)}


class Chik:
    def __init__(self, cols, rows, clock, page=0):
        if (cols, rows) not in BOX:
            raise ValueError("unsupported geometry (original div by zero)")
        self.cols, self.rows = cols, rows
        self.w, self.h = BOX[(cols, rows)]
        self.clock = clock
        self.page = page
        self.cellsX = cols // self.w
        self.rowsY = rows // self.h
        self.g = [0] * (cols * rows)
        self.phase = "boot"
        self.walk = 0
        self.col = 0
        self.row = 0
        self.wo = 0
        self.dx = 0
        self.dy = 0
        self.x = 0
        self.y = 0
        self.first = None

    def prd(self, b):
        return 0 if b <= 0 else self.clock() % b

    def vget(self, w):
        w += self.page * 4000
        return self.g[w] if 0 <= w < len(self.g) else 0

    def vset(self, w, v):
        w += self.page * 4000
        if 0 <= w < len(self.g):
            self.g[w] = v

    def choose(self):
        d = 0
        for _ in range(8):
            d = self.prd(4) & 3
            if d == 0 and self.col <= 0:
                continue
            if d == 1 and self.row <= 0:
                continue
            if d == 2 and self.col >= (self.cellsX - 1) * self.w:
                continue
            if d == 3 and self.row >= (self.rowsY - 1) * self.h:
                continue
            break
        else:
            if self.col < (self.cellsX - 1) * self.w:
                d = 0
            elif self.row < (self.rowsY - 1) * self.h:
                d = 1
            elif self.col > 0:
                d = 2
            else:
                d = 3
        if d == 0:
            self.dx, self.dy, self.walk = 1, 0, self.cellsX
        elif d == 1:
            self.dx, self.dy, self.walk = 0, 1, self.rowsY
        elif d == 2:
            self.dx, self.dy, self.walk = -1, 0, self.cellsX
        else:
            self.dx, self.dy, self.walk = 0, -1, self.rowsY
        # 0x03C4..0x03F2 re-anchors winOff from the (slide-tracked)
        # box cell every choose frame; quantized to lattice columns.
        self.wo = 2 * (self.row * self.cols + self.col)

    def erase_row(self, yy):
        for xx in range(self.w):
            self.vset(self.wo // 2 + yy * self.cols + xx, 0)

    def cell(self):
        return self.wo // 2 + self.y * self.cols + self.x

    def in_box(self):
        return (self.wo // 2) % self.cols + self.w <= self.cols \
            and (self.wo // 2) // self.cols + self.h <= self.rows

    def frame(self):
        if self.phase == "boot":
            self.walk = self.prd(20)
            self.first = self.walk
            self.col = self.prd(self.cellsX) * self.w
            self.row = self.prd(self.rowsY) * self.h
            self.wo = 2 * (self.row * self.cols + self.col)
            self.phase = "wipe"
            self.x = 0
            self.y = 0
            # the original runs the wipe loop and the frame-top 0x0512
            # dec on the boot frame too (0x0256): erase wipe row 0 and
            # tick the first countdown now
            self.erase_row(self.y)
            self.y += 1
            self.walk -= 1
            if self.walk > 0:
                return
            self.walk = 0
            self.phase = "walk"
        if self.phase == "wipe":
            # boot wipe (0x0256): box row per frame, one per frame,
            # concurrent with the countdown (the frame-top 0x0512 dec);
            # at countdown zero the choose branch runs THIS frame
            if self.y < self.rowsY:
                self.erase_row(self.y)
                self.y += 1
            self.walk -= 1
            if self.walk > 0:
                return
            self.walk = 0
            self.phase = "walk"
        # choose frame (0x02B1 with the zero stored at 0x02A3): pick a
        # direction, re-anchor winOff, reset the strip, erase cell 0 now
        if self.walk == 0:
            self.choose()
            self.x = 0
            self.y = 0
        # moving frame: erase one lattice cell per frame; at strip end
        # one lattice step of walk consumed (the original decrements
        # the walk counter once per full screen-row pass, 0x0472)
        p = self.cell()
        self.vset(p, 0)
        self.x += 1
        if self.x >= self.cellsX:
            self.x = 0
            self.y += 1
            self.walk -= 1
            nxt = self.wo + 2 * self.dx + 2 * self.cols * self.dy
            if self.walk == 0 or not self.d_in(nxt):
                self.walk = 0
                self.phase = "walk"
            else:
                self.wo = nxt
                self.col += self.dx
                self.row += self.dy
            if self.y >= self.rowsY:
                self.y = 0

    def d_in(self, wo):
        bx = (wo // 2) % self.cols
        by = (wo // 2) // self.cols
        return 0 <= bx and bx + self.w <= self.cols \
            and 0 <= by and by + self.h <= self.rows

    def sum(self):
        return sum(self.g) & 0xFFFFFFFF


def f32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v >= 0x80000000 else v


def vectors():
    """Pinned vectors: fixed DOS second, filled grid, frames 1..12,
    plus a stress run per geometry checking bounded motion."""
    for (cols, rows), secs, gval in (
            ((80, 25), 5, 0x1F20),
            ((80, 25), 13, 0x1F20),
            ((80, 25), 5, 0x07C1),
            ((80, 43), 7, 0x1F20),
            ((40, 25), 9, 0x1F20)):
        clk = [secs]
        c = Chik(cols, rows, lambda: clk[0])
        c.g = [gval] * (cols * rows)
        print(f"-- {cols}x{rows} sec={secs} grid={gval:04X}")
        for f in range(1, 13):
            c.frame()
            print(f"f{f:02d} sum={f32(c.sum())//2:>9} pos={c.wo//2:<5} "
                  f"col={c.col:<3} row={c.row:<3} walk={c.walk:<3} "
                  f"x={c.x:<3} y={c.y:<3} d={c.dx:>2},{c.dy:>2} "
                  f"first={c.first}")
    ok = True
    for (cols, rows), s0, stepsec in (((80, 25), 5, 37), ((80, 25), 13, 53),
                                      ((80, 43), 5, 31), ((40, 25), 7, 41)):
        clk = [s0]
        c = Chik(cols, rows, lambda: clk[0])
        c.g = [0x1F20] * (cols * rows)
        minx = miny = 10 ** 9
        maxx = maxy = -1
        dirs = 0
        lastd = (0, 0)
        prev = None
        for f in range(1, 5001):
            if f % stepsec == 0:
                clk[0] += 1
            c.frame()
            k = (c.walk, c.wo, c.x, c.y)
            assert k != prev, f"stuck at {f}"
            prev = k
            bx = (c.wo // 2) % cols
            by = (c.wo // 2) // cols
            minx, maxx = min(minx, bx), max(maxx, bx)
            miny, maxy = min(miny, by), max(maxy, by)
            if (c.dx, c.dy) != lastd:
                dirs += 1
                lastd = (c.dx, c.dy)
        print(f"stress {cols}x{rows}: x {minx}..{maxx} y {miny}..{maxy} "
              f"dirs={dirs} sum={f32(c.sum())}")


if __name__ == "__main__":
    vectors()
