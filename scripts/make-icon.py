#!/usr/bin/env python3
"""Regenerate assets/dn.icns from the original DN.ICO pixel art.

Takes the compass and the letter 'D' straight from original/DN.ICO,
adds a matching pixel 'N', and puts everything on a macOS-style
squircle gradient. Requires ImageMagick (magick) and iconutil.

Usage: python3 scripts/make-icon.py   (from the repo root)
"""
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICO = os.path.join(ROOT, 'original', 'DN.ICO')
ASSETS = os.path.join(ROOT, 'assets')


def run(*cmd):
    subprocess.run(cmd, check=True)


def main():
    tmp = tempfile.mkdtemp()
    png = os.path.join(tmp, 'ico.png')
    run('magick', ICO, png)

    # --- read the 32x32 original into a character grid ---------------------
    out = subprocess.run(['magick', png, 'txt:'],
                         capture_output=True, text=True, check=True).stdout
    grid = [['.'] * 32 for _ in range(32)]
    for line in out.splitlines()[1:]:
        pos, rest = line.split(':', 1)
        x, y = map(int, pos.split(','))
        c = rest.split('#')[1][:6]
        grid[y][x] = {'000000': '#', '00FFFF': 'C', '0000FF': 'B',
                      'FF0000': 'R'}.get(c, '.')

    compass = [''.join(grid[y][8:30]) for y in range(11, 30)]   # 22x19
    D = [''.join(grid[y][3:8]) for y in range(2, 10)]           # 5x8
    N = ['#...#', '##..#', '##..#', '#.#.#',                    # matching style
         '#.#.#', '#..##', '#..##', '#...#']

    # --- compose the 30x30 working grid ------------------------------------
    W = H = 30
    art = [['.'] * W for _ in range(H)]

    def blit(rows, x0, y0, remap=None):
        for dy, row in enumerate(rows):
            for dx, ch in enumerate(row):
                if ch != '.':
                    art[y0 + dy][x0 + dx] = remap.get(ch, ch) if remap else ch

    blit(D, 9, 1, remap={'#': 'W'})     # 'DN' in white, centered
    blit(N, 16, 1, remap={'#': 'W'})
    blit(compass, 4, 10)

    colors = {'.': (0, 0, 0, 0),
              'W': (255, 255, 255, 255),
              '#': (10, 16, 40, 255),   # outlines: near-black navy
              'C': (0, 229, 255, 255),  # compass body: cyan
              'B': (41, 98, 255, 255),  # needle south: blue
              'R': (255, 61, 61, 255)}  # needle north: red
    art_txt = os.path.join(tmp, 'art.txt')
    with open(art_txt, 'w') as f:
        f.write('# ImageMagick pixel enumeration: %d,%d,255,srgba\n' % (W, H))
        for y in range(H):
            for x in range(W):
                r, g, b, a = colors[art[y][x]]
                f.write('%d,%d: (%d,%d,%d,%d)\n' % (x, y, r, g, b, a))

    # --- squircle + gradient + pixel art -> 1024 master ---------------------
    art_big = os.path.join(tmp, 'art_big.png')
    squircle = os.path.join(tmp, 'squircle.png')
    master = os.path.join(ASSETS, 'dn-icon-1024.png')
    run('magick', art_txt, '-sample', '720x720', art_big)
    run('magick', '-size', '824x824', 'gradient:#3552DE-#111C5C',
        '(', '-size', '824x824', 'xc:black', '-fill', 'white',
        '-draw', 'roundrectangle 0,0 823,823 186,186', ')',
        '-alpha', 'off', '-compose', 'CopyOpacity', '-composite', squircle)
    os.makedirs(ASSETS, exist_ok=True)
    run('magick', '-size', '1024x1024', 'xc:none',
        squircle, '-gravity', 'center', '-composite',
        art_big, '-gravity', 'center', '-composite', master)

    # --- iconset -> icns -----------------------------------------------------
    iconset = os.path.join(tmp, 'dn.iconset')
    os.makedirs(iconset)
    for s in (16, 32, 128, 256, 512):
        run('sips', '-z', str(s), str(s), master,
            '--out', os.path.join(iconset, 'icon_%dx%d.png' % (s, s)))
        run('sips', '-z', str(s * 2), str(s * 2), master,
            '--out', os.path.join(iconset, 'icon_%dx%d@2x.png' % (s, s)))
    run('iconutil', '-c', 'icns', iconset,
        '-o', os.path.join(ASSETS, 'dn.icns'))
    print('wrote', os.path.join(ASSETS, 'dn.icns'))


if __name__ == '__main__':
    main()
