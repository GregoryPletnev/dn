#!/usr/bin/env python3
"""Bit-exact CPU model of AZ_WATER.ASM / AZ_FIRE.ASM wave loops.

Tracks eax/ebx/ecx/edx as true 32-bit registers and models 8-bit sub-op
carries (add dl,dh / adc ch,dl / ...) exactly as the 386 does, including
the stale ah/upper bytes that the original relies on.

Usage: python3 wave_emu.py {water|fire} [frames]
"""
import sys

W, H = 320, 100
N = W * H
M8, M16, M32 = 0xFF, 0xFFFF, 0xFFFFFFFF


class R:
    def __init__(self, v=0):
        self.v = v & M32

    @property
    def al(self): return self.v & M8
    @al.setter
    def al(self, x): self.v = (self.v & ~M8) | (x & M8)
    @property
    def ah(self): return (self.v >> 8) & M8
    @ah.setter
    def ah(self, x): self.v = (self.v & ~0xFF00) | ((x & M8) << 8)

    @property
    def bl(self): return self.v & M8
    @bl.setter
    def bl(self, x): self.v = (self.v & ~M8) | (x & M8)
    @property
    def bh(self): return (self.v >> 8) & M8
    @bh.setter
    def bh(self, x): self.v = (self.v & ~0xFF00) | ((x & M8) << 8)
    @property
    def bx(self): return self.v & M16
    @bx.setter
    def bx(self, x): self.v = (self.v & ~M16) | (x & M16)

    @property
    def cl(self): return self.v & M8
    @cl.setter
    def cl(self, x): self.v = (self.v & ~M8) | (x & M8)
    @property
    def ch(self): return (self.v >> 8) & M8
    @ch.setter
    def ch(self, x): self.v = (self.v & ~0xFF00) | ((x & M8) << 8)
    @property
    def cx(self): return self.v & M16
    @cx.setter
    def cx(self, x): self.v = (self.v & ~M16) | (x & M16)

    @property
    def dl(self): return self.v & M8
    @dl.setter
    def dl(self, x): self.v = (self.v & ~M8) | (x & M8)
    @property
    def dh(self): return (self.v >> 8) & M8
    @dh.setter
    def dh(self, x): self.v = (self.v & ~0xFF00) | ((x & M8) << 8)
    @property
    def dx(self): return self.v & M16
    @dx.setter
    def dx(self, x): self.v = (self.v & ~M16) | (x & M16)


def ld(buf, off):
    return buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)


class Saver:
    def __init__(self, kind, memsize=65536, comlen=0x1000):
        # tiny .COM image + zeroed tail (DOS gives a fresh PSP-filled 64K;
        # uninitialized vars are RAM garbage in the field, zero for RE)
        self.mem = [0] * comlen
        self.kind = kind
        # offsets: after the code (~0x160 for fire/water COMs) come
        # Wave1/Wave2 words, then WaveImage1, WaveImage2.
        self.o_w1 = 0x150
        self.o_img1 = 0x158
        self.o_img2 = self.o_img1 + N
        self.rand_off = 0x14E
        # rep stosd fill
        if kind == 'water':
            for i in range(N):
                self.mem[self.o_img1 + i] = 8
            self.seed_water()
        # eax/ebx/ecx/edx/bx survive between frames on real hardware;
        # zero init models a freshly-loaded COM.
        self.eax, self.ebx, self.ecx, self.edx = R(), R(), R(), R()
        self.cf = 0

    def seed_water(self):
        dx, cx = 0xDEAD, 0xFACE
        for _ in range(2000):
            dx = ((dx << 3) | (dx >> 13)) & M16
            dl, dh = dx & M8, (dx >> 8) & M8
            s = dl + dh                                  # add dl,dh
            dx = (dx & 0xFF00) | (s & M8)
            cf = s >> 8
            dl = dx & M8
            ch = (cx >> 8) & M8
            s = ch + dl + cf                             # adc ch,dl
            ch = s & M8
            cf = s >> 8
            cl = (cx & M8) ^ dh                          # xor cl,dh (CF=0)
            t = (cx & 0xFF00) | cl
            t -= dx                                      # sub cx,dx
            cf = 1 if t < 0 else 0
            t &= M16
            s = ch + dl + cf                             # adc ch,dl
            ch = s & M8
            cx = (t & M8) | (ch << 8)
            rem = cx % (W * (H - 2))
            self.mem[self.o_img1 + rem + W] = ch & 3     # al:=ch; and al,3
        self.mem[self.o_w1] = self.o_img1 & M16
        self.mem[self.o_w1 + 2] = self.o_img2 & M16

    def add8(self, getv, setv, src):
        s = getv() + src
        self.cf = s >> 8
        setv(s & M8)

    def adc8(self, getv, setv, src):
        s = getv() + src + self.cf
        self.cf = s >> 8
        setv(s & M8)

    def frame(self):
        mem = self.mem
        eax, ebx, ecx, edx = self.eax, self.ebx, self.ecx, self.edx
        w1 = mem[self.o_w1]
        w2 = mem[self.o_w1 + 2]
        si = w1 + W - 1
        di = w2 + (1 if self.kind == 'fire' else W)
        ebx.v = ld(mem, si - W)
        ecx.v = ld(mem, si)
        edx.v = ld(mem, si + W)
        ebx.bl = 0
        si += 4
        bp = W * (H - 2)
        while bp:
            eax.al = mem[si]                             # mov al,[si]
            ecx.v = ((ecx.v >> 8) | (eax.v << 24)) & M32 # shrd ecx,eax,8
            eax.al = mem[si + W]                         # mov al,[si+WaveW]
            edx.v = ((edx.v >> 8) | (eax.v << 24)) & M32 # shrd edx,eax,8
            si += 1
            if self.kind == 'water':
                s = (ebx.bl + ecx.cl + edx.dl) & M8
                s = (s + ebx.bl + edx.dl + ebx.bh + ecx.ch + edx.dh) & M8
                if (eax.al & 2) == 0:
                    s = (s + 1) & M8        # shr ah,3; add ah,al(al<=1)
                # NOTE: shr ah,3 discards the dither add? no: the asm is
                # shr ah,3 BEFORE add ah,al. Re-check below.
                mem[di] = s
            else:
                # shld eax,ecx,16
                eax.v = ((eax.v << 16) | (ecx.v >> 16)) & M32
                self.add8(lambda: eax.al, lambda v: setattr(eax, 'al', v), ecx.cl)
                eax.ah = 1 if self.cf else 0             # setc ah
                self.add8(lambda: eax.al, lambda v: setattr(eax, 'al', v), ecx.ch)
                self.adc8(lambda: eax.ah, lambda v: setattr(eax, 'ah', v), 0)
                self.add8(lambda: eax.al, lambda v: setattr(eax, 'al', v), edx.dh)
                self.adc8(lambda: eax.ah, lambda v: setattr(eax, 'ah', v), 0)
                ax = ((eax.v >> 2) | (eax.v << 14)) & M16
                eax.v = (eax.v & ~M16) | ax              # ror ax,2
                if eax.al != 0:
                    eax.ah = 1 if (ecx.cl & 1) else 0
                    eax.al = (eax.al - eax.ah) & M8
                mem[di] = eax.al
            di += 1
            bp -= 1
        # --- water: no MakeSeed; fire: MakeSeed into the same buffer ---
        if self.kind == 'fire':
            dx = R(mem[self.rand_off] | (mem[self.rand_off + 1] << 8))
            di2 = (H - 1) * W + w2
            for _ in range(W):
                ebx.bx = (ebx.bx + 0x5EDA) & M16
                ebx.bx ^= dx.dx
                dx.dx = (dx.dx + 0xE34A) & M16
                ebx.bl = 0
                ebx.bh = 0
                ebx.v = (ebx.v & ~M8) | ((ebx.v >> 8) & M8) << 0  # noop
                # mov dl,bh
                dx.v = (dx.v & ~M8) | ebx.bh
                self.add8(lambda: dx.dh, lambda v: setattr(dx, 'dh', v), ebx.bl)
                self.adc8(lambda: dx.dl, lambda v: setattr(dx, 'dl', v), eax.al)
                ebx.bx = (ebx.bx + dx.dx) & M16
                ebx.bx = ((ebx.bx << 3) | (ebx.bx >> 13)) & M16
                eax.al = ebx.bl & 0x7F
                mem[di2] = eax.al
                di2 += 1
            mem[self.rand_off] = dx.v & M8
            mem[self.rand_off + 1] = (dx.v >> 8) & M8
        # refresh blit (pure copies, registers untouched) + swap
        mem[self.o_w1], mem[self.o_w1 + 2] = w2, w1
        self.eax, self.ebx, self.ecx, self.edx = eax, ebx, ecx, edx

    # corrected water step per exact asm order:
    # ah=sum; shr ah,3; (test al,2 / setz al); add ah,al
    def frame_water_fixed(self):
        mem = self.mem
        eax, ebx, ecx, edx = self.eax, self.ebx, self.ecx, self.edx
        w1 = mem[self.o_w1]
        w2 = mem[self.o_w1 + 2]
        si = w1 + W - 1
        di = w2 + W
        ebx.v = ld(mem, si - W)
        ecx.v = ld(mem, si)
        edx.v = ld(mem, si + W)
        ebx.bl = 0
        si += 4
        bp = W * (H - 2)
        while bp:
            eax.al = mem[si]
            ecx.v = ((ecx.v >> 8) | (eax.v << 24)) & M32
            eax.al = mem[si + W]
            edx.v = ((edx.v >> 8) | (eax.v << 24)) & M32
            si += 1
            s = (ebx.bl + ecx.cl + edx.dl) & M8
            s = (s + ebx.bl + edx.dl + ebx.bh + ecx.ch + edx.dh) & M8
            s >>= 3                                       # shr ah,3
            if (eax.al & 2) == 0:
                s = (s + 1) & M8                          # setz al; add ah,al
            else:
                s = s & M8
            mem[di] = s
            di += 1
            bp -= 1
        mem[self.o_w1], mem[self.o_w1 + 2] = w2, w1
        self.eax, self.ebx, self.ecx, self.edx = eax, ebx, ecx, edx

    def cur(self):
        w1 = mem16 = self.mem[self.o_w1] | (self.mem[self.o_w1 + 1] << 8)
        base = w1
        return self.mem[base:base + N]


def stats(b):
    return (min(b), max(b), sum(b) // len(b), sum(1 for v in b if v > 8),
            sum(1 for v in b if v == 0))


if __name__ == '__main__':
    kind = sys.argv[1]
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 100
    s = Saver(kind)
    step = s.frame_water_fixed if kind == 'water' else s.frame
    for f in range(1, frames + 1):
        step()
        if f in (1, 10, 50, 100):
            c = s.cur()
            print('frame %3d  min %3d  max %3d  mean %3d  >8: %5d  zero: %5d'
                  % ((f,) + stats(c)))
    c = s.cur()
    if kind == 'fire':
        print('row 5 mean ', sum(c[5*W:6*W]) // W)
        print('row 50 mean', sum(c[50*W:51*W]) // W)
        print('row 95 mean', sum(c[95*W:96*W]) // W)
