#!/usr/bin/env python3
"""Emulate the exact AZ_WATER.ASM seeding loop and wave step to derive
ground-truth for the FPC port."""
W, H = 320, 100
M8 = 0xFF
M16 = 0xFFFF

def seed():
    img = [8] * (W * H)
    dx, cx = 0xDEAD, 0xFACE
    cf = 0
    for _ in range(2000):
        # rol dx,3
        dx = ((dx << 3) | (dx >> 13)) & M16
        # add dl,dh  (8-bit add, carry out -> CF)
        dl, dh = dx & M8, (dx >> 8) & M8
        s = dl + dh
        dx = (dx & 0xFF00) | (s & M8)
        cf = s >> 8
        # adc ch,dl
        s = dh + (dx & M8) + cf
        ch = s & M8
        cf = s >> 8
        cx = (cx & 0x00FF) | (ch << 8)
        # xor cl,dh
        cl = (cx & M8) ^ dh
        cf = 0  # xor clears CF
        cx = (cx & 0xFF00) | cl
        # sub cx,dx
        t = cx - dx
        cf = 1 if t < 0 else 0
        cx &= M16
        # adc ch,dl
        s = ch + (dx & M8) + cf
        ch = s & M8
        cx = (cx & 0x00FF) | (ch << 8)
        # mov ax,cx; xor dx,dx; div W*(H-2) -> bx = remainder
        bx = cx % (W * (H - 2))
        # al := ch and 3 -> WaveImage1[bx+W] := al
        img[bx + W] = ch & 3
    return img, dx, cx

img, dx1, cx1 = seed()
nz = sum(1 for v in img if v != 8)
print('non-8 cells after seeding:', nz)
print('first non-8 positions:', [i for i, v in enumerate(img) if v != 8][:12])
print('sample vals:', [img[i] for i, v in enumerate(img) if v != 8][:24])
print('dx,cx end:', hex(dx1), hex(cx1))
