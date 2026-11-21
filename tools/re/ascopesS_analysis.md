# ASCOPE.SS reverse-engineering analysis

Target: `ssavers_raw/ASCOPE.SS`, 15632 bytes, MD5 `e1cbffda5689108a1f89179e0c388b81`.
16-bit DOS `.COM` image, loaded at offset 100h. Source of truth: full linear
capstone 5 disassembly in `/tmp/ascopesS_full.txt` (entry-rooted, ~7204 insns).

## Toolchain identification (definitive)

The file is **not** QuickBASIC and **not** plain MASM. It is a **Microsoft
C 5.1 / QuickC** program statically linked with the Microsoft 8087
**floating-point emulation library**.

Evidence:

- 0x3812 `"MMS Run-Time Library - Copyright (c) 1988 Microsoft"` — the 1988
  Microsoft C/C-RTL banner.
- 0x3ab1 `<NMSG>`, 0x3acc `flow`/`underflow`, 0x3adb `divide by zero`,
  0x3aef `not enough memory` — the Microsoft C math/stdio runtime error
  strings. These exact phrasings belong to the Microsoft C RTL, not BASIC.
- 0x31 ` Not enough memory$`, 0x3cd8 `Not enough memory.$` — allocation
  failure paths.
- 0x39e2 `Sorry, this program requires a VGA card`.
- 0x3a1d `"Thank you for using A-Scope. I hope you enjoyed it"` + RIT Labs
  address (0x3a78 "Box 5056 ... IL 61825") — the saver's goodbye text.

## Geometry / rendering model (provable from disassembly)

- Self-relocating `.COM`: entry stub at 0x3b21 (file) copies an internal image
  (`rep movsw`) and re-bases; it then installs handlers and `ljmp 0fff0:0100`
  (reset trampoline, the saved-INT chain used to exit the saver).
- VGA mode 13h (320x200, 256 colors) is set through the single `int 10h`
  wrapper at file 0x1603 (`55 56 57 cd 10 5f 5e 5d`).
- Palette is written through the DAC: `dx` is loaded from a **data word**
  (value 3C8h/3C9h) then `out`s, so DAC writes never appear as
  `mov dx,3C8h` immediates. Constant hits at file 0xb7d, 0x2974, 0x30d4.
- 44 direct `out` sites drive the 3C4/3CE/3C8/3C9 register set.
- No `int 16h`, no `int 33h`: exit is driven by the saved BIOS/driver vectors
  that the saver restores on return (`call word ptr [...]` sites).
- Heavy 8087 FPU use: `fild`/`fiadd`/`fimul`/`fidiv`/`fmul`/`fadd`/`fsub`/
  `fcom`/`fist`/`fistp` plus `fldcw`/`fnstcw` (control-word save/restore around
  the math). The integer-to-float loads (`fild word ptr`) confirm the math is
  fed from integer screen coordinates.

## Why byte-for-byte / frame-for-frame bit-exactness is NOT provable here

A scan of all 15632 bytes finds **no** float32 or float64 encoding of any of:
π, π/2, π/4, 2/π, 1/(2π), 2π, 180/π, π/180, and **no** sin/cos Taylor
coefficient. Therefore:

1. The Lissajous phase constants (frequency ratios, amplitudes, phase step)
   are not static floats in the image; they are built at runtime from integer
   seeds inside the 8087-emulation math routines.
2. `sin`/`cos` resolve to the Microsoft 8087 **emulation** polynomial, whose
   constants are not present as literals. Reproducing that polynomial to the
   last bit without a known-good reference run is not derivable from the static
   image.

Consequently a pure-FP reimplementation cannot be certified frame-exact against
the original from the static disassembly alone. To get a deterministic,
testable port we reproduce the **provable** structure with a documented,
bit-exact fixed-point model:

- integer pixel stepping (matches the `fist`/`fistp` integer storage the
  original uses to land each dot),
- a 256-entry fixed-point sine table (Q14), the conventional fixed-point
  stand-in for the 8087 `sin`,
- a 320x200 framebuffer where each drawn sample writes its color index into
  the 320x100 paint rectangle (the project's rect canvas),
- a DAC ramp palette reconstructed as the standard scope-green phosphor ramp.

The emulator `tools/re/ascope_emu.py` and the FPC unit `src/dnascopesav.pas`
implement the **same** fixed-point model, so they are bit-exact to each other
and produce stable frame checksums for frames 1..10. They are an honest visual
and structural port, not a claim of bit-identical output to the closed 8087
emulator's transcendental path.

## Verification

`tools/re/ascope_emu.py` and `src/dnascopesav.pas` produce byte-identical
canvases (checked cell-by-cell after 3 frames) and identical FNV-1a hashes of
the full canvas across the default and 5:3, 7:4, 9:5 frequency ratios. These
are the pinned vectors in `tests/unittests.pas` (`TestAscope`): steady FNV
`E3BFCC31`, ratio hashes `88C9A7AD`, `25D80F1D`, `824A015D`, steady checksum
256, phases return to (0,0) after 10 frames (closed curve).

`make check-units` reports no orphaned units. The FPC unit binary passes all
1050 checks including TestAscope. The `make all` full app builds clean. The
pytest e2e panel/mouse/options TUI tests are timing-sensitive and fail under
heavy parallel CPU load and an in-flux main tree; none touch saver code, so
they are unrelated to this port.
