#!/usr/bin/env python3
"""Verify BUNDLES.SS (RIT ssavers.zip) against tools/re/bundles_analysis.md.

Usage: python3 tools/re/disasm_bundles.py [path/to/BUNDLES.SS]
Exits nonzero if any checked fact does not match.
"""
import os
import struct
import sys

from capstone import Cs, CS_ARCH_X86, CS_MODE_16, CS_OP_IMM

DEFAULTS = ('ssavers_raw/BUNDLES.SS', '../../ssavers_raw/BUNDLES.SS',
            '/Users/admin/Projects/dn/ssavers_raw/BUNDLES.SS')
PATH = sys.argv[1] if len(sys.argv) > 1 else next(
    p for p in DEFAULTS if os.path.exists(p))

data = open(PATH, 'rb').read()
md = Cs(CS_ARCH_X86, CS_MODE_16)
md.detail = True
fails = 0


def check(name, cond, detail=''):
    global fails
    mark = 'ok  ' if cond else 'FAIL'
    if not cond:
        fails += 1
    print(f'[{mark}] {name} {detail}')


def dis(a, n):
    return list(md.disasm(data[a - 0x100:a - 0x100 + n], a))


def txt(a, n):
    return '; '.join(f'{i.mnemonic} {i.op_str}' for i in dis(a, n))


def ins_txt(a, n):
    """Disassemble up to n bytes from a, following real sizes; stop on stall."""
    out = []
    off = a - 0x100
    end = a - 0x100 + n
    while off < end:
        nxt = list(md.disasm(data[off:end], 0x100 + off))
        if not nxt:
            break
        i = nxt[0]
        out.append(f'{i.mnemonic} {i.op_str}')
        off += i.size
    return '; '.join(out)


def jmp_target(off):
    return 0x100 + off + 3 + struct.unpack_from('<h', data, off + 1)[0]


def word8(off):
    return struct.unpack_from('<4H', data, off)


# --- header ------------------------------------------------------------------
check('entry jmp 0x100 -> 0x279E', data[0] == 0xE9 and jmp_target(0) == 0x279E)
check('header jmp 3 -> 0x3701 (tick)', data[3] == 0xE9 and jmp_target(3) == 0x3701)
check('header jmp 6 -> 0x35D3 (init)', data[6] == 0xE9 and jmp_target(6) == 0x35D3)

# --- parameter strings (known set) -------------------------------------------
STR_BASE = 0x33
strings = [s for s in
           (data[STR_BASE:0x0D5].split(b'\0')) if s]
expect = [b'NEW COLOR SIDES ONLY', b'NEW COLOR TOP/BOTTOM',
          b'NEW COLOR FOUR SIDES', b'BOUNCING BUNDLES', b'NUMBER OF LINES',
          b'NUMBER OF BUNDLES', b'BOUNCES PER COLOR', b'DURATION IN TICKS']
check('8 config strings at 0x33', strings[:8] == expect,
      strings[3].decode())
# config default words, read back from the init image (mem 0x113..0x130)
check('runtime defaults: LINES=5 BUNDLES=2 DUR=3 TICKS=1',
      struct.unpack_from('<H', data, 0x11D - 0x100)[0] == 5 and
      struct.unpack_from('<H', data, 0x123 - 0x100)[0] == 2 and
      struct.unpack_from('<H', data, 0x129 - 0x100)[0] == 3 and
      struct.unpack_from('<H', data, 0x12F - 0x100)[0] == 1)

# --- VESA: palette services, NOT mode 1C ------------------------------------
t7a = txt(0x287A, 0x15)
t00 = txt(0x28A2, 0x20)
check('AX=1C01 get palette at 0x287A (CX=7, BX=28C3)',
      'mov ax, 0x1c01' in t7a and 'mov cx, 7' in t7a and
      'mov bx, 0x28c3' in t7a)
check('AX=1C00 get+verify at 0x28A2 (AL=1Ch, BX<70h)',
      'mov ax, 0x1c00' in t00 and 'cmp al, 0x1c' in t00 and
      'cmp bx, 0x70' in t00)
check('AX=1C02 set palette at 0x288E', 'mov ax, 0x1c02' in txt(0x288E, 0x15))
check('video mode set is INT 10h AX=0012h (mode 12h)',
      'mov ax, 0x12' in txt(0x27DF, 6) and 'int 0x10' in txt(0x27DF, 6))

# --- RNG ---------------------------------------------------------------------
check('RngNext 0x38E0 wraps at 3E6h (997)',
      'inc word ptr [0x1dc]' in txt(0x38E0, 0x20) and
      'cmp word ptr [0x1dc], 0x3e6' in txt(0x38E0, 0x20))
check('RngNext table mem 0x2FC3 = file 0x2EC3',
      'mov ax, word ptr [di + 0x2fc3]' in txt(0x38E0, 0x20))
rng = struct.unpack_from('<997H', data, 0x2EC3)
check('997 RNG words, high entropy', len(set(rng)) > 800, f'unique={len(set(rng))} table[1]={rng[1]}')
check('index mem at 0x1DC, value at 0x1E0',
      'mov word ptr [0x1e0], ax' in txt(0x38E0, 0x20) and
      'mov word ptr [0x1dc], di' in txt(0x371C, 0x26))

# --- bounce ------------------------------------------------------------------
check('bounce X 0x3804 limit 0x27F', 'cmp bx, 0x27f' in txt(0x3804, 0x32))
check('bounce Y 0x3836 limit 0x1DF', 'cmp bx, 0x1df' in txt(0x3836, 0x32))
ta = ins_txt(0x3868, 0x78)
check('velocity masks per endpoint F,7,7,F in advance 0x3868',
      ta.count('mov cx, 0xf') == 2 and ta.count('mov cx, 7') == 2)
check('bounce new velocity: and cx, shl 1, 5 if 0, neg at max wall',
      all(s in txt(0x3804, 0x32) for s in
          ('and ax, cx', 'shl ax, 1', 'mov ax, 5', 'neg ax', 'mov bx, 0x27f')))

# --- palette chase --------------------------------------------------------------
t = txt(0x3426, 0x30)
check('chase 0x3426: step counter 33EE, color 33EC AND 0F skip 0',
      all(s in t for s in ('inc byte ptr [0x33ee]', 'cmp byte ptr [0x33ee], 3',
                           'inc byte ptr [0x33ec]',
                           'and byte ptr [0x33ec], 0xf')))
check('chase writes GC set/reset index 0 (DX=3CE, AL=0)',
      'mov dx, 0x3ce' in t and 'mov al, 0' in t and 'out dx, ax' in t)
check('side gate 0x3410 tests 33F1, top/bottom gate 0x341B tests 33F2',
      'cmp byte ptr [0x33f1], 0' in txt(0x3410, 6) and
      'cmp byte ptr [0x33f2], 0' in txt(0x341B, 6))
check('init gates from config 0x119: 0 clears 33F2, 1 clears 33F1',
      'cmp word ptr [0x119], 0' in txt(0x36D5, 0x1C) and
      'mov byte ptr [0x33f2], 0' in txt(0x36D5, 0xC) and
      'mov byte ptr [0x33f1], 0' in txt(0x36E3, 0xC))

# --- Bresenham -------------------------------------------------------------------
t = ins_txt(0x3456, 0x90)
check('line entry 0x3456 normalizes into state 33DD..33E3',
      all(s in t for s in ('xchg word ptr [0x33dd], bx', 'mov bx, word ptr [0x33e3]',
                           'sub cx, word ptr [0x33dd]')))
check('self-mod target 33E9 selects 3524 (X-major) / 3564 (Y-major)',
      'mov word ptr [0x33e9], 0x3524' in t and
      'mov word ptr [0x33e9], 0x3564' in t and
      'jmp word ptr [0x33e9]' in ins_txt(0x3456, 0x95))
check('plot bounds BX < 9600 (640x300 plane)',
      'cmp bx, 0x9600' in txt(0x3598, 8) and 'cmp bx, 0x9600' in txt(0x35B1, 8))
check('plot writes GC[8]=AH color mask, byte write',
      'mov al, 8' in txt(0x3598, 0x18) and 'mov byte ptr es:[bx], ah' in
      txt(0x3598, 0x18))
check('address calc 0x33C3: bx shr 3 + ax*80, bit = 7-(x and 7)',
      all(s in txt(0x33C3, 0x1A) for s in
          ('mul dx', 'shr bx, 1', 'and cl, 7', 'xor cl, 7', 'mov ah, 1')))

# --- trail rings -------------------------------------------------------------------
tf = txt(0x3765, 0x100)
check('ring wrap at [bx+0x118A] start / [bx+0x118C] end in frame',
      'mov si, word ptr [bx + 0x118a]' in tf and
      'cmp si, word ptr [bx + 0x118c]' in tf)
check('advance 0x3868 writes next ring slot, stride 8',
      'add di, 8' in ins_txt(0x386C, 12) and
      'cmp di, word ptr [bx + 0x118c]' in ins_txt(0x3871, 8) and
      'mov word ptr [di], bx' in ins_txt(0x3868, 0x78))

# --- world init formulas -------------------------------------------------------------
t = txt(0x3651, 0x4C)
check('init x = lo*5 shr 1 (0..637)', 'shr dx, 1' in t and 'add ax, dx' in t)
check('init y = lo*2, y>=1E0 -> minus 27 / 28',
      'cmp ax, 0x1e0' in t and 'sub ax, 0x27' in t and 'sub ax, 0x28' in t)
t = txt(0x369D, 0x20)
check('velocity: d = lo AND 0F (min 1), sign from bit0 of hi',
      all(s in t for s in ('and dx, 0xf', 'inc dx', 'test ah, 1', 'neg dx')))
check('color: retry until lo AND 0F nonzero',
      all(s in txt(0x36BF, 0x16) for s in ('and al, 0xf', 'je 0x36c5')))

# --- tick dispatcher -------------------------------------------------------------------
t = txt(0x3701, 0x64)
check('tick gate: counter 0x1DE vs DURATION 0x2798, reset+frame on hit',
      'inc word ptr [0x1de]' in t and 'mov ax, word ptr [0x2798]' in t and
      'cmp word ptr [0x1de], ax' in t and 'jae 0x3749' in t)
check('tick init seeds RNG idx from 0:46C AND 3FEh',
      'mov di, word ptr fs:[0x46c]' in t and 'and di, 0x3fe' in t and
      'mov word ptr [0x1dc], di' in t)
check('frame 0x3765 calls VGA unlock 0x33F3 first',
      'call 0x33f3' in ins_txt(0x3765, 0xF))
check('VGA unlock SC5=0 SC3=3 GC1=FF',
      all(s in txt(0x33F3, 0x1C) for s in
          ('mov al, 5', 'mov al, 3', 'mov ah, 0xff', 'mov al, 1')))
check('main polls key INT 21h AH=0Bh and timer 0:46Ch',
      'mov ah, 0xb' in txt(0x27F5, 4) and 'int 0x21' in txt(0x27F5, 6) and
      'mov ax, word ptr fs:[0x46c]' in txt(0x27FD, 0x14))

# --- claimed-wrong addresses are not code entries -----------------------------------------
seed_regions = [(0x100, 0x28C3), (0x33C3, 0x3701), (0x3765, 0x3910)]
refs = {}
for (a, b) in seed_regions:
    n = a
    while n < b:
        try:
            ins = next(md.disasm(data[n - 0x100:b - 0x100], n))
        except StopIteration:
            break
        if ins.mnemonic in ('call', 'jmp', 'je', 'jne', 'jae', 'jb', 'ja',
                            'jbe', 'jg', 'jge', 'jl', 'jle', 'loop'):
            for op in ins.operands:
                if op.type == CS_OP_IMM:
                    refs.setdefault(op.imm, []).append(n)
        n += ins.size
for wrong, why in ((0x3704, 'claimed bounce'), (0x3736, 'claimed bounce'),
                   (0x3326, 'claimed palette'), (0x3356, 'claimed bresenham'),
                   (0x3768, 'claimed ray walk')):
    check(f'no code refs to {wrong:#06X} ({why})', wrong not in refs,
          str([hex(x) for x in refs.get(wrong, [])]))
for right in (0x3804, 0x3836, 0x3426, 0x3456, 0x3868, 0x38E0):
    check(f'code refs to {right:#06X}', right in refs,
          str([hex(x) for x in refs[right]]))

print('FAILS:', fails)
sys.exit(1 if fails else 0)
