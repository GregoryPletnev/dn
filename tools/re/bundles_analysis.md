# BUNDLES.SS — reverse engineering notes

Source: `ssavers_raw/BUNDLES.SS`, 14336 bytes, unpacked RIT screen saver
from `ssavers.zip` (1995). 16-bit DOS `.COM`. Memory addresses below are
`file offset + 0x100`. Verified with `python3` + `capstone`
(`CS_ARCH_X86`, `CS_MODE_16`) — see `tools/re/disasm_bundles.py`.

## Verdict on prior RE claims

| Claim | Verdict | Evidence |
| --- | --- | --- |
| Entry jmps at 0x100 to 0x279E | **correct** | file `0x00`: `E9 9B 26` → `jmp 0x279E` |
| VESA check `ax=1C00 bx=28C3` = mode 0x1C (320x200x8bpp) | **wrong** | `0x28A2` block runs `AX=1C00h` = VESA *get palette* with `BX=0x28C3` buffer, `CX=7`, then checks `AL=1Ch` and `BX<70h`. The actual mode set is `MOV AX,0012h; INT 10h` at `0x27DF` = **VGA mode 12h, 640x480x4bpp** |
| Parameter block at file 0x0D, records (string offset, default, max) | **correct, one fix** | records are 8 bytes: `(word stringOfs, word default, word max, word pad0)`, string offsets relative to record base `0x15`; full parse below |
| Axis bounce 0x3704/0x3736 with limits 0x27F/0x1DF | **wrong address, correct limits** | real bounce routines: `0x3804` (X, limit `0x27F`) and `0x3836` (Y, limit `0x1DF`). `0x3704/0x3736` sit inside the tick dispatcher |
| RNG = 997-entry (0x3E6) word table at `0x2FC3+0x100` | **wrong base, correct size/wrap** | table lives at **file `0x2EC3`** = mem `0x2FC3`; `RngNext` (`0x38E0`) wraps at `CMP [0x1DC], 3E6h`, so 997 words `0x2EC3..0x36AD` (997 is prime). The `+0x100` in the claim double-counts the COM base |
| RNG index at 0x1DC | **correct** | written `0x35D9`, `0x373A`; incremented in `RngNext` `0x38E1` |
| Palette chase at 0x3326 writes DAC index 0 with value at 0x33EC cycling 1..15 every 3 calls | **wrong address, correct behavior** | routine is `0x3426`. `INC [0x33EE]`; at 3: reset, `INC [0x33EC]`, `AND 0Fh`, re-`INC` if zero → color walks 1..15 forever. Then `AH:AL = [0x33EC]:0`, `OUT 3CEh` (VGA GC set/reset, index 0). `0x3326` is middle-of-data: no code refs it. `OUT 0EBh` after each VGA write is the RIT unpacker's I/O delay filler |
| Bresenham at 0x3356, state 33DD..33E9, jump targets 3524/3564 | **wrong entry, rest correct** | entry is `0x3456`. State `0x33DD..0x33E9` is correct; `0x33E9` is a **self-modifying jump target** set to `0x3524` (X-major) at `0x34AF` or `0x3564` (Y-major) at `0x34B9`. Jump targets `0x3524/0x3564` confirmed (`JMP WORD PTR [0x33E9]` at `0x34E6`). `0x3356` is inside RNG data |
| Ray records 8 bytes x,y,dx,dy walked at 0x3768 | **half correct** | 8-byte records confirmed, but layout is `[x0,y0,x1,y1]` (two endpoints = a *segment trail*), not position+velocity. Velocity is a parallel array at `0x131C` (4 words per bundle). Walk driver is the frame loop `0x3765`; advance routine `0x3868`. `0x3768` is a few bytes into the frame loop |
| Ring buffer bounds 118A/118C | **correct** | `[BX+0x118A]` = ring start pointer, `[BX+0x118C]` = ring end; wrap at `0x3795` (draw) and `0x3871` (advance) |

## Header and config block

File header (`0x00..0x0C`):

```
0x00  jmp 0x279E     ; run (main)
0x03  jmp 0x3701     ; tick hook (called by host loop / self)
0x06  jmp 0x35D3     ; init
0x09  jmp 0x10C      ; (unused stub)
0x0D  dw 0x000D      ; pointer to parameter block (self-referential here)
```

Parameter block records, 8 bytes each, from file `0x15`; string offsets
relative to `0x15`; terminator `0,0,0,0`:

| String | Default | Max | Runtime value mem |
| --- | --- | --- | --- |
| NEW COLOR SIDES ONLY | 0 | 0x8C | `0x113` (default 0) |
| NEW COLOR TOP/BOTTOM | 5 | 0xFA | `0x119` (default 0) |
| NUMBER OF LINES | 0x9D (157) | 2 | `0x11D` (default 5) |
| NUMBER OF BUNDLES | 100 | 0xB0 (176) | `0x123` (default 2) |
| BOUNCES PER COLOR | 3 | 0x7F | `0x129` (default 3) |
| DURATION IN TICKS | 1 | 0x64 | `0x12F` (default 1) |

(Note: the table columns interleave because the default of one record is
the max of the previous record when misread as words — parsed correctly
as above by record. The values the code actually reads at `0x11D/0x123/
0x129/0x12F` are 5, 2, 3, 1.)

The saver code reads exactly these config words: `0x11D` (lines),
`0x123` (bundles), `0x129` (bounces per color, low byte; 0 → 3),
`0x12F` (ticks per drawn frame; 0 → 1), `0x119` (top/bottom gate input at
init). Sanity at init (`0x35E2`): if lines or bundles is 0, or
lines*bundles overflows / exceeds `0x1F4`, defaults `5 / 2` are forced.

## Memory map (data)

| Mem | Contents |
| --- | --- |
| `0x1DC` | RNG word index |
| `0x1E0` | last RNG value |
| `0x1E2` | trail record area, 8-byte records `[x0,y0,x1,y1]` |
| `0x118A+b*2` | per-bundle pointer to current *new* trail record |
| `0x1254+b*2` | per-bundle pointer to current *old* trail record (draw cursor) |
| `0x131C+b*8` | velocity: `vx0, vy0, vx1, vy1` (signed words) |
| `0x1644+b` | initial color of bundle (1..15) |
| `0x1646+b` | live draw color of bundle |
| `0x1710+b` | live 3-step counter of the palette chase |
| `0x17DA` | lines copy |
| `0x17DE` | bundles copy |
| `0x2798` | DURATION copy |
| `0x2EC3..0x36AD` | RNG table, 997 words → `bundles_rng.inc` |
| `0x33DD..0x33E9` | line state: X0,Y0,X1,Y1, dPos, dNeg, jump target |
| `0x33EB` | plane-mask flag (0 = set mode, 1 = XOR mode) |
| `0x33EC` | current DAC color value (0..15) |
| `0x33ED` | saved color for set-mode pass |
| `0x33EE` | chase step counter (0..2) |
| `0x3433` | bounces-per-color (3) |

Trail geometry is **double-resolution**: x `0..639`, y `0..479`; the VGA
plane at `A000:0` holds 640x300 bytes addressed `x shr 3 + y*80`
(`0x33C3`), with the 16-color palette of mode 12h.

## Run flow

`0x279E` main:
1. Save video mode from BIOS `0:[0x449]`; init text segment.
2. `call 0x35D3` — config + world init (seed `RngIdx := AX AND 1FF`,
   AX=0 → index 0).
3. VESA get palette (`AX=1C01`), `INT 10h AX=0012` (mode 12h), VESA
   get+verify palette (`AX=1C00`), program VGA: `SC[5]=0`, `SC[3]=3`,
   `GC[1]=FFh` (this is `0x33F3`, called again at every frame).
4. Tick init: `call 0x3701` with `AX=0` → seeds `RngIdx :=
   BIOS timer (0:46Ch) AND 3FEh`, draws frame 0.
5. Loop: `call 0x3701` with `AX=1` (tick), poll keyboard `INT 21h
   AH=0Bh`, wait for BIOS tick change, repeat; on key: restore mode,
   VESA palette set (`AX=1C02`), terminate.

Tick dispatcher `0x3701`: on `AX≠0` increments `[0x1DE]`; when it reaches
DURATION (`[0x2798]`, default 1) it resets the counter and runs one frame
under a `BTS/BTR` re-entrancy lock.

## RNG (`0x38E0`)

```
INC RngIdx; IF RngIdx ≥ 997 THEN RngIdx := 0
RngVal := RngTable[RngIdx]
```

Seeded from BIOS timer jiffies `AND 3FE` at tick init, from 0 at config
init. For the headless port the documented deterministic seed is index 0;
first `Next()` returns `table[1]`.

## World init (`0x35D3`, after config)

1. Build two pointer tables (`0x118A`, `0x1254`), `bundles` entries,
   stride `8*lines` bytes over the record area `0x1E2`: per bundle a ring
   of `lines` segment records.
2. Per bundle (ascending), 4 RNG draws build the initial segment:

```
x0 := (RNG_lo * 5) shr 1            ; 0..637
y0 := RNG_lo * 2; IF y0 ≥ 480 THEN y0 := y0 − 39    ; 0..479
x1 := (RNG_lo * 5) shr 1
y1 := RNG_lo * 2; IF y1 ≥ 480 THEN y1 := y1 − 40    ; 0..479
```

3. Per bundle (descending), 4 RNG draws give the velocity:
   `d := RNG_lo AND 0Fh; IF d=0 THEN d=1; IF RNG_hi bit0 THEN d := −d`
   for `vx0` (mask `$F`), `vy0` (`$7`), `vx1` (`$7`), `vy1` (`$F`).
4. Per bundle (descending), retry RNG until `RNG_lo AND 0Fh ≠ 0` → color.
5. Gate mapping from config `0x119`: value 0 clears side gate `0x33F2`,
   value 1 clears top/bottom gate `0x33F1`. Default 0: both chase gates
   active (init leaves both at 1).

## Frame (`0x3765`)

Re-disassembly correction (verified): the frame loop **advances first**, then
runs the line routine twice over the *new* head record. It is erase-then-draw
of the same segment, not draw-old then draw-new of two segments. The steady
picture is the OR of the L newest segments per bundle.

Per bundle `b` (index in `BX := b*2`):

1. Load `[0x1646+b]` → current color `[0x33EC]`, `[0x1710+b]` → chase
   counter `[0x33EE]`.
2. **Erase**: cursor `SI := [0x1254+b]`; next ring slot `SI+8`, wrapped to
   `[0x118A+b]` when `≥ [0x118C+b]`. Set mask flag `[0x33EB] := 1`, load the
   next record (the one advance will overwrite), `call 0x3456`.
3. **Advance**: `call 0x3868` — new record = old + velocity, each endpoint
   through the bounce routines; write to the next ring slot; `SI := next`.
4. **Draw**: set `[0x33EB] := 0`, load the new record, `call 0x3456`.
5. Store updated color/counter back to `0x1646+b` / `0x1710+b`.

### Plane model (corrected)

The plotter `0x3598`/`0x35B1` writes **VGA GC register 8** (bit set/reset),
not the 4-bit pixel. `DX := 0x3CE; AL := 8; OUT DX, AX` with `AH` as the
bitmask. The active plane is selected by the segment, not the plot: each
segment runs `0x3456` once with `GC[8]` index 0 set to the color (`0x3473`),
so color `c` (1..15) draws into plane `(c-1) AND 3`. Pixel `(x, y)` lives at
byte `(x shr 3) + (y shr 1)*80` in one plane, bit `x AND 7`.

* Draw (mode 0, `[0x33EB]=0`): `AH := color`; GC bit op = set/reset → `OR`
  the bit into the plane byte.
* Erase (mode 1, `[0x33EB]=1`): `AH := NOT mask` (the vertical branch at
  `0x3504` loads `[0x33EB]`); GC bit op with the XOR write mode clears the
  pixel. The frame tail restores the drawn color (`0x3585`-`0x3594`).

So the screen is **four monochrome 640x300 bit-planes** (80 bytes/row,
`0x9600` total), each holding one color's pixels. A pixel's visible color is
the owning plane; the frame keeps the L newest segments of every bundle
OR-combined, so trails persist and fade only where erase and draw coincide.


### Bounce (`0x3804` X, `0x3836` Y)

```
IF x < 0 THEN
  side-bounce-palette; v := ((RNG AND mask) SHL 1); IF v=0 THEN v:=5; x := 0
ELSE IF x > limit THEN
  side-bounce-palette; v := −((RNG AND mask) SHL 1); IF v=0 THEN v:=5; x := limit
```

X limit `0x27F`, Y limit `0x1DF` (verified at `0x381A/0x384C`).
Mask per endpoint: `vx0:$F, vy0:$7, vx1:$7, vy1:$F` (`CX` at `0x3884`,
`0x389B`, `0x38B3`, `0x38CB`). A bounce calls `0x3410` (sides gate) for X
and `0x341B` (top/bottom gate) for Y; if the gate is set, the shared
palette chase `0x3426` runs: per call step+1; every 3rd call
`color := ((color+1) AND $F) or (if 0 then 1)` — i.e. 1..15 cyclically —
and pushes it to DAC index 0 (the *background* palette register, so the
whole screen background pulses; in the port this only drives the shared
color value).

### Line draw (`0x3456`)

Bresenham with endpoint normalization: `dx<0` swaps both coordinates and
negates the y-step `SI := ±80`. State block `0x33DD..0x33E9`:

```
dPos := 2*minor ; dNeg := dPos − 2*major ; err := dPos − major
```

Vertical case (`dx=0`) at `0x34EA` fills straight down with mask.
X-major loop at `0x3524`: rotates the 16-bit bit mask `DX` per pixel and
uses `ror; ror; cmc; adc bx,0` carry chains to step `bx` (byte address)
across bit boundaries. Y-major loop at `0x3564` adds `SI` (=±80) to `bx`
per step, carrying into the mask with `ror dl/dh; cmc; adc`.
Plot (`0x3598`): bounds check `bx < 0x9600`, `GC[8] := AH`, plain byte write
at `ES:[BX]`; the hardware GC set/reset does the plane work. Addressing
`(x shr 3) + (y shr 1)*80` and the even-`y` plot make the canvas a 640x300
plane. The DN port keeps grid == plane space (640x300) and decimates to the
320x100 terminal rect only at paint time (display cell `dx,dy` shows grid
`px=2*dx, py=3*dy`).


## Port model (src/dnbundlessav.pas)

Pure logic, no VGA/terminal in the sim record. The state is the four 80x300
byte bit-planes plus the trail rings, velocities, per-bundle colors and chase
counters. The port reproduces the exact RNG stream (997-word table from
`0x2EC3`), bounce dynamics, endpoint masks, Bresenham walk, erase-then-draw
per frame, and the 1..15 chase — plane-for-plane with the hardware.

`BundlesPixel(px,py)` reads the composite (lowest color with a set plane bit);
`BundlesDisplayValue(dx,dy)` decimates to the 320x100 rect. The terminal
paint (`PaintBundlesRect`) maps colors 1..15 onto ncurses pairs 46..53.

## Verification (bit-exact)

`tools/re/bundles_oracle.py` is an independent Python emulator that replays
the same pipeline; `tools/re/bundlesselfcheck.pas` drives the FPC unit and
prints FNV-1a checksums over the 640x300 grid and the 320x100 display. The
two agree byte-for-byte on grid FNV, display FNV, the first lit cell, and the
per-bundle colors for frames 0..10, seeds 0..3 (seeds 0≡1 and 2≡3 because the
tick seed is `seed AND 3FE`). The same vectors are asserted in
`tests/unittests.pas` (`TestBundles`).

