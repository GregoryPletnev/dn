#!/usr/bin/env python3
"""Regenerate the DN app icon from new project-local pixel art.

The mark is a new geometric DN monogram with a dual-panel/compass motif,
drawn directly in this script. Requires ImageMagick (magick) and iconutil.

Usage: python3 scripts/make-icon.py   (from the repo root)
"""
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, 'assets')


def run(*cmd):
    subprocess.run(cmd, check=True)


def main():
    tmp = tempfile.mkdtemp()

    # --- compose the 30x30 working grid ------------------------------------
    W = H = 30
    art = [['.'] * W for _ in range(H)]

    def blit(rows, x0, y0, remap=None):
        for dy, row in enumerate(rows):
            for dx, ch in enumerate(row):
                if ch != '.':
                    art[y0 + dy][x0 + dx] = remap.get(ch, ch) if remap else ch

    D = [
        '#####.',
        '##..##',
        '##...#',
        '##...#',
        '##...#',
        '##...#',
        '##..##',
        '#####.',
    ]
    N = [
        '##...##',
        '###..##',
        '####.##',
        '##.####',
        '##..###',
        '##...##',
        '##...##',
        '##...##',
    ]
    left_panel = [
        '##########',
        '#........#',
        '#.######.#',
        '#........#',
        '#.####...#',
        '#........#',
        '##########',
    ]
    right_panel = [
        '##########',
        '#........#',
        '#...####.#',
        '#........#',
        '#.######.#',
        '#........#',
        '##########',
    ]
    needle_north = [
        '..R..',
        '.RRR.',
        'RRRRR',
        '..R..',
        '..R..',
    ]
    needle_south = [
        '..B..',
        '..B..',
        'BBBBB',
        '.BBB.',
        '..B..',
    ]

    blit(D, 5, 3, remap={'#': 'W'})
    blit(N, 16, 3, remap={'#': 'W'})
    blit(left_panel, 3, 16, remap={'#': 'C'})
    blit(right_panel, 17, 16, remap={'#': 'C'})
    blit(needle_north, 12, 14)
    blit(needle_south, 13, 20)
    art[18][14] = 'W'
    art[18][15] = 'W'
    art[19][14] = 'W'
    art[19][15] = 'W'

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
        art_big, '-gravity', 'center', '-composite',
        '-depth', '8', 'PNG32:' + master)

    # --- iconset -> icns -----------------------------------------------------
    iconset = os.path.join(tmp, 'dn.iconset')
    os.makedirs(iconset)
    for s in (16, 32, 128, 256, 512):
        run('magick', master, '-resize', '%dx%d' % (s, s), '-depth', '8',
            'PNG32:' + os.path.join(iconset, 'icon_%dx%d.png' % (s, s)))
        run('magick', master, '-resize', '%dx%d' % (s * 2, s * 2), '-depth', '8',
            'PNG32:' + os.path.join(iconset, 'icon_%dx%d@2x.png' % (s, s)))
    run('iconutil', '-c', 'icns', iconset,
        '-o', os.path.join(ASSETS, 'dn.icns'))
    print('wrote', os.path.join(ASSETS, 'dn.icns'))


if __name__ == '__main__':
    main()
