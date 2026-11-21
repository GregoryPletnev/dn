# Dos Navigator 1.51 color palettes

Unmodified copies of `COLORS/*.PAL` from the Dos Navigator 1.51
distribution, https://www.ritlabs.com/download/dn/dn151.zip
(downloaded 2026-11-20, SHA-256
f6dee3904945a2f390f8576a5d18d83446f4554e43d6f0a3c75f8aa5b570d7d9).

Dos Navigator 1.51, Copyright (c) 1991-99 RIT Research Labs.
Based on Dos Navigator by RIT Research Labs.

`scripts/gen-palettes.py` turns them into `src/dnpalettes.inc`; DN shows
them in Options > Fonts/Colors > Color scheme. Each file holds the 228
attributes of the Turbo Vision application palette (the `CColor` layout of
DN 1.51's DNAPP.PAS) and the VGA DAC the palette was designed with; DN maps
re-programmed DAC colors to the nearest xterm-256 color.

| File | Shown as |
|---|---|
| DEFAULT.PAL | DN default |
| NORTON.PAL | Norton Commander |
| _BLUE.PAL | DN blue (VGA) |
| DARK.PAL | Dark |
| _SPRING.PAL | Spring (VGA) |
| DOSSHELL.PAL | MS-DOS Shell |
| PCTOOLS.PAL | PC Tools / Norton Utilities |
| VAX.PAL | Green terminal (VAX) |
| BW.PAL | Black & white |
| _BW.PAL | Black & white (VGA mono) |
| MONO.PAL | Monochrome |
