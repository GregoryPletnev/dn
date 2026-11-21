#!/usr/bin/env python3
"""ASCOPE.SS ground-truth emulator (fixed-point model).

ASCOPE.SS is a Microsoft C program (8087 FP-emulation library) that draws an
oscilloscope Lissajous figure into VGA mode 13h and ramps the DAC palette.
The exact transcendental path is the closed Microsoft 8087 emulator and its
constants are not present as floats in the image (see ascopesS_analysis.md), so
we cannot certify frame-exact output against it from the static binary.

This emulator reproduces the *provable* structure as a deterministic, pure
integer model. src/dnascopesav.pas implements the identical model, so the two
agree bit-for-bit and produce stable checksums for frames 1..10. See the
analysis file for the fidelity caveats.

Model (all integer, Q14 fixed point):
  - canvas W=320, H=100 (the project's paint rect)
  - two integer oscillators advance by fixed phase steps each sample
  - x,y from a 256-entry Q14 sine table, mapped to canvas pixels
  - each sample writes a color index into the H*W byte buffer
  - a frame advances a fixed number of samples and the palette phase
"""
import struct

W = 320
H = 100
Q = 14               # sine table Q format

# 256-entry sine table in Q14, quarter-wave symmetry. The first-quadrant
# values come from the standard Bhaskara I approximation (integer-only, so the
# Python emulator and the FPC unit produce byte-identical tables with no
# floating-point rounding differences). Max amplitude 16000 (< 2^14).
def sine_table():
    tab = [0] * 256
    for i in range(1, 64):
        # x is the angle in degrees (0..90). Bhaskara I:
        #   sin(x) ~= 16*x*(180-x) / (5*180^2 - 4*x*(180-x))
        num = 16 * i * (180 - i)
        den = 5 * 180 * 180 - 4 * i * (180 - i)
        s = (num * 10000) // den          # 0..10000 (1e-4 units)
        tab[i] = s * 8 // 5               # scale to ~0..16000
    tab[64] = 16000                       # sin(90 deg) peak
    for i in range(65, 128):
        tab[i] = tab[128 - i]
    for i in range(128, 256):
        tab[i] = -tab[i - 128]
    return tab

SINE = sine_table()

class Ascope:
    def __init__(self):
        self.buf = bytearray(W * H)
        # Lissajous frequency ratio 3:2 (classic scope figure), phase step.
        self.px = 0        # phase of X oscillator, 0..255 (one turn = 256)
        self.py = 0        # phase of Y oscillator
        self.dpx = 3       # X phase step per sample (fixed, integer)
        self.dpy = 2       # Y phase step per sample
        self.pal = 0       # palette ramp phase
        self.frame = 0
        self.SAMPLES = 256  # samples drawn per frame (covers the figure)
        self.GAIN = 1       # per-sample phosphor gain
        self.DECAY = 6      # per-frame phosphor decay (scope persistence)

    def _plot(self, cx, cy, color):
        if 0 <= cx < W and 0 <= cy < H:
            idx = cy * W + cx
            v = self.buf[idx] + color     # additive phosphor glow, saturate
            self.buf[idx] = 255 if v > 255 else v

    def step(self):
        """Advance one frame; returns (frame_number, checksum)."""
        self.frame += 1
        # phosphor decay: every cell loses DECAY intensity steps
        d = self.DECAY
        for i in range(W * H):
            b = self.buf[i]
            if b:
                self.buf[i] = 0 if b <= d else b - d
        cx = W // 2
        cy = H // 2
        amp_x = cx - 1
        amp_y = cy - 1
        for _ in range(self.SAMPLES):
            sx = SINE[self.px & 0xFF]      # -16000..16000
            sy = SINE[self.py & 0xFF]
            # amplitude scale: sine peak 16000 -> half-extent, via >>6 (÷64)
            px_pix = cx + ((sx * amp_x) >> 14)
            py_pix = cy + ((sy * amp_y) >> 14)
            color = self.GAIN
            self._plot(px_pix, py_pix, color)
            self.px = (self.px + self.dpx) & 0xFF
            self.py = (self.py + self.dpy) & 0xFF
        self.pal = (self.pal + 1) & 0xFF
        return self.frame, self.checksum()

    def checksum(self):
        return sum(self.buf)

    def fnv(self):
        h = 0x811C9DC5
        for v in self.buf:
            h ^= v
            h = (h * 0x01000193) & 0xFFFFFFFF
        return h


def main():
    a = Ascope()
    for _ in range(10):
        f, c = a.step()
        print(f"frame {f}: checksum {c} fnv {a.fnv() & 0xFFFFFFFF:#010x} "
              f"px {a.px} py {a.py}")


if __name__ == "__main__":
    main()
