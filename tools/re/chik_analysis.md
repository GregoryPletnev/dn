# CHIK.SS — reverse engineering report

Source: `ssavers_raw/CHIK.SS`, 1307 bytes, 16-bit DOS `.COM`
(RIT ssavers.zip, dated 1995-12-05). Code `0x0100..0x061B`, one flat
segment, no overlay, no embedded graphics. All offsets are `.COM`
virtual offsets (file offset + 0x100). Method: capstone 16-bit linear
sweep plus raw-byte checks at every branch target (see
`tools/re/ssrev.py` for the batch runner).

## Verdict: what it animates

There is **no sprite art and no data table in the file**. The whole
file is code; `0x05DA..0x061B` is the direction jump table and two
helper routines, not printable CP437 art (verified hexdump, all
opcodes).

CHIK does not draw a cockerel. It **snapshots a box of the color
text screen, blanks the box, slides the blank box along straight
lines one cell per video frame, and repaints the saved words behind
it**. On a busy screen the visible object is a moving blank square
that eats text at its leading edge and drops it back at its trailing
edge. The sprite is the absence of characters.

Corrections to the prior RE notes:

| Prior claim | Actual |
|---|---|
| Jump table of 4 directions at `0x5DA` | Correct: `jmp word ptr cs:[bx+0x5da]` at `0x035F`, entries `0x0364` (dx=+1), `0x037B` (dy=+1), `0x0394` (dx=-1), `0x03AB` (dy=-1) |
| `bp-0x2E/-0x30` = dx/dy | Correct, signed words ±1 |
| Sprite dims at `bp-0x0C/-0x0E` | Correct: box size in cells, 4x5 (4x6 at 80x43) |
| Position at `bp-0x1A` | Correct: word offset of the box origin in B800:0000 |
| `0xFD0`-word snapshot buffer | `0xFD0` **bytes**: 125 usable words + slack; the snapshot holds the *current screen box*, captured one column per frame |
| Timer 46Ch for pacing | 46Ch is **never read**. PRNG = `int 21h/2Ch` (DOS time, seconds) mod bound, helper at `0x05E2`. Pacing = CGA status 3DAh bit 3, one frame per retrace wait |
| Exit via int 16h/60h | No 60h call. Plain `int 16h/0000h` at `0x05D2`, reached only after the 40:417h / keyboard-buffer checks say keys were pressed |
| Video mode 4..7 or 0xF runs | Branches: `<4` falls through to run, `==7` exits, so modes 0..3, 4..6 run; 7 and 0xE/0xF exit. Effectively the 40x25 and 80x25 text modes plus 320x200 graphics text cells |
| Bounce flips direction at edges | Half right. The pick at `0x02FB..0x0350` rerolls only when the box touches the **left/top** wall and the roll points further out; the right/bottom walls are never tested. Direction actually changes when the walk counter expires at the far wall |

## Stack frame (after `sub sp, 0FD0h` at `0x0103`)

| Offset | Name | Meaning |
|---|---|---|
| `bp-0FD0h` | `snap[125+]` | saved video words of the box (the 0xFD0 buffer) |
| `bp-02Ch` | shift flags | 40:0417h at startup |
| `bp-02Ah` | mouse_ok | -1 when `int 33h/0000h` returned FFFFh |
| `bp-028h/-026h` | mouse x0/y0 | mouse pixels at startup |
| `bp-024h` | buttons | mouse buttons at last poll |
| `bp-020h/-022h` | mouse x1/y1 | mouse pixels at last poll (shares slots with cells_x/rows scratch, never live together) |
| `bp-01Eh/-01Ch` | tick fptr | 0:046Ch BIOS timer tick pointer |
| `bp-01Ah` | win_off | box origin, byte offset in B800:0000 |
| `bp-018h/-016h` | fptr scratch | far-pointer staging (B800 segment) |
| `bp-014h` | row | inner loop row (`0x0415`) |
| `bp-012h` | seed | PRNG delay parameter, 20 |
| `bp-010h` | vp page | 40:044Eh active page |
| `bp-00Ah` | cols | 40:044Ah columns |
| `bp-00Ch` | box_w | box width in cells (4) |
| `bp-00Eh` | box_h | box height in cells (5, or 6 at 80x43) |
| `bp-007h/-006h` | row/col | box origin in cells |
| `bp-005h` | walk | direction step countdown |
| `bp-004h` | col_x | inner loop column |
| `bp-003h` | rows | 40:0484h rows + 1 |
| `bp-002h` | font8 | 40:0462h font height (unused after load) |
| `bp-001h` | vmode | 40:0449h video mode |

## Algorithms

`PRD(bound)` at `0x05E2`: `int 21h/2Ch` gives `DL` = seconds; `DL mod
bound` by subtraction loop; returns `DL`. Identical rolls within one
DOS second.

`MkFP(seg, ofs)` at `0x05FD`: stacks a far pointer, returns `ES:BX`
(used for every `les`). `0x05FB` is a dead duplicate.

Geometry (`0x019F..0x01F3`): `box = 4x5` at 80x25 and 80x50; `4x6` and
`rows-1` at 80x43; `0x0` otherwise, where the first `div` at `0x0205`
crashes (the original only survives supported text geometries).
`cells_x = cols div box_w`; loop bounds use `rows div box_h` rows and
`cells_x` columns, i.e. the lattice step is one box per screen cell
group, one cell per frame.

### Bootstrap (`0x01F3..0x0254`)

1. `walk = PRD(20)`: the delay of the first move, in frames (0..19).
2. Lattice start: `tile = PRD(cells_x)`, `col = tile*box_w`,
   `row = PRD(rows div box_h)*box_h`,
   `win_off = ((row*cols)+col)*2 + page*8000`.
3. The first erase pass (`0x0256..0x02A1`) blanks `rows div box_h`
   rows x `cells_x` columns of the *box region* at the new position;
   in the port this is the pre-roll (the box waits blank).

### Choose direction (`0x02A3..0x03C2`, when walk counter = 0)

1. `win_off += (-dx)*2*cells_x*(cols div box_w)` and
   `(-dy)*2*(rows div box_h)*cols` (`imul 0FFFFh` is negation):
   retract the origin to the walk start so the wipe covers the cell
   the box just left.
2. `col -= dx`, `row -= dy` (same retraction, in cells).
3. Reroll loop: `dir = PRD(4) and 3`; reroll when the box touches the
   home wall in that direction: `dir=0 & col=0`, `dir=1 & row=0`,
   `dir=2 & col=box_w-1`, `dir=3 & row=box_h-1`. The wall tests use
   the box size, not the screen — an original bug; harmless because
   the ported lattice never starts there.
4. Jump table `cs:[0x5DA]`: right `walk = cells_x`, down
   `walk = rows div box_h`, left `cells_x`, up `rows div box_h`. The
   walk counter equals the number of box positions across the whole
   screen in that axis.

### Frame work (one iteration per retrace, 3DAh bit 3)

Final byte-level read (capstone-verified; supersedes the earlier
wipe/restore narrative):

* state byte `bp-05h` (the walk counter): 0 → choose branch (`0x02B1`),
  non-zero → moving frames. There is no live restore pass — the
  `0x04B2..0x0510` loop is only entered through the dead `0x02F5`
  path, so erased text never comes back: the sprite is a walking hole.
* boot (`0x01F3..0x0254`): `walk = PRD(20)` (first-move countdown,
  same byte as the walk counter), `col = PRD(cells_x)*box_w`,
  `row = PRD(rowsY)*box_h`, `win_off = ((row*cols)+col)*2`. The
  first-pass wipe (`0x0256..0x02A1`) erases one box row per frame for
  `rows div box_h` frames, concurrent with the countdown (the `0x0512`
  dec runs from the frame top).
* choose (`0x02A3..0x03C2`): reroll loop at `0x02FB` rejects `dir=0`
  at `col=0`, `dir=1` at `row=0`, `dir=2` at `col=(cells_x-1)*box_w`,
  `dir=3` at `row=(rowsY-1)*box_h` — far wall off-by-one, an original
  quirk. Jump table `cs:[05DAh]`: right/down `walk = cells_x`/`rowsY`,
  left/up the same. `win_off` re-anchors from `col/row` every choose
  frame (the `0x03C4` block); the `0x02BA..0x02F8` retract is
  unreachable (`0x02B1` only sees the zero stored at `0x02A3`).
* moving frames (`0x041C..0x0510`): ONE cell per frame,
  cell = `win_off/2 + y*cols + x`, `x < cells_x` (`0x0466`),
  `y < rowsY` (`0x047C`); write `0000h` (space, black-on-black).
  At row end (`x` wrapped): `dec walk` (the original's counter is per
  screen row), slide `win_off += 2*dx + 2*cols*dy` (`0x0484`),
  `col += dx`, `row += dy`. `walk = 0` → choose. The port clamps the
  slide so the box can never leave the screen (documented deviation);
  the original walks out and resets at the wall.

Net visible motion: a 4x5 (4x6 at 80x43) blank box crawls straight
lines one cell per sweep, ~`cells_x` sweeps horizontal (80/4 = 20)
and `rows div box_h` vertical (25/5 = 5), erasing text as it goes,
new direction when the walk counter runs out or the wall stops it.
Frames per cell: one (the sweep covers `cells_x*rowsY` cells at one
per frame, the walk counter ticks per row).

### Exit checks (`0x054A..0x05D2`, every frame)

`int 28h`; poll mouse; exit when mouse present and (pixels != startup
or buttons != 0). Else compare word 40:417h against the startup copy:
on change, read 40:41Ah (keyboard buffer head); head != tail →
`int 16h/0000h` consumes the key and exits. The 40:41Ah word is also
compared to a startup snapshot: mismatch means another program
touched the keyboard buffer while the saver ran → repaint the snapshot
(`0x05C2`) and exit, leaving no half-blanked text.

## Frame count / colors / timing summary

* One column of the strip per video frame; CGA retrace ≈ 8.9 ms per
  wait pair, ~113 waits/s in the capture loop.
* First move after `PRD(20)` frames (0..19), i.e. up to ~0.17 s.
* Horizontal walk: 20 box positions; vertical: 5 at 25 rows.
* Direction re-roll at every walk expiry; no animation frames, no
  palette changes, single attribute `0000h`.

## Port (`src/dnchiksav.pas`)

Pure logic, no curses, styled like `dnsaver`/`dntetris`:

* `TChikSaver.Create(cols, rows)` + `Init(roll, delay)`: lattice
  geometry (4x5, 4x6 at 80x43), PRNG hook (original `mod` semantics,
  injected; nil uses a model clock).
* `Step` = one original frame: pre-roll wait, direction pick with the
  reroll rule, wipe one strip cell, restore one cell, slide one cell.
* `DelayTicks(ticks)` runs whole frames between BIOS tick counts
  (`ChikFramesPerTick` ≈ 113/18.2).
* `Cell/Dirty` give the repaint map (blanked cells),
  `WindowWord` exposes the snapshot buffer; `BoxX/BoxY/DirX/DirY/
  Phase/WalksLeft` expose the walk state.
* Clamped lattice (the box can never leave the screen) replaces the
  original's silent overflow paths; all other rules follow the
  listing.

Compile: `fpc -MObjFPC -Sh -Fusrc -FUbuild -FEbin src/dnchiksav.pas`
— verified clean (FPC 3.2.2), no unit dependencies.
