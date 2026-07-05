"""Tetris (Tools menu / Ctrl+T). DN_TETRIS_SEQ makes piece order
deterministic. At 80x24 the field is 20 rows tall, top-left cell (2, 24)."""

import time

from conftest import make_session

FY, FX = 2, 24          # field top-left screen cell at 80x24
FH, FWCH = 20, 20       # field height in rows, width in screen chars


def field_rows_with_bg(s, color):
    rows = []
    for r in range(FY, FY + FH):
        for c in range(FX, FX + FWCH):
            if s.screen.buffer[r][c].bg == color:
                rows.append(r)
                break
    return rows


def open_tetris(s):
    s.wait_text('Name')
    s.key('CTRL_T')
    s.wait_text('TETRIS')
    s.wait_text('Score: 0')


def test_open_and_quit(sandbox):
    s = make_session(sandbox)
    try:
        open_tetris(s)
        assert s.row_of('Next:') is not None
        s.send('q')
        s.wait_gone('TETRIS')
        s.wait_text('a.txt')            # panels are back
        assert s.alive()
    finally:
        s.close()


def test_o_pieces_double_line_clear(sandbox):
    s = make_session(sandbox, env={'DN_TETRIS_SEQ': 'O'})
    try:
        open_tetris(s)
        for moves in (('LEFT', 4), ('LEFT', 2), (None, 0), ('RIGHT', 2), ('RIGHT', 4)):
            key, n = moves
            if key:
                s.key(key, n)
            s.send(' ')                 # hard drop
            time.sleep(0.15)
        s.wait_text('Lines: 2')
        s.wait_text('Score: 300')
        # bottom field row is empty again after the double clear
        bottom = FY + FH - 1
        for c in range(FX, FX + FWCH):
            assert s.cell(bottom, c).bg in ('black', 'default'), \
                'bottom row not cleared at col %d: %r' % (c, s.cell(bottom, c))
    finally:
        s.close()


def bottom_rows_cyan(s, n):
    """The n bottom field rows each contain locked cyan cells (the next
    falling piece is also cyan, so only look at the landed stack)."""
    return all(any(s.screen.buffer[r][c].bg == 'cyan'
                   for c in range(FX, FX + FWCH))
               for r in range(FY + FH - n, FY + FH))


def test_i_piece_rotation(sandbox):
    s = make_session(sandbox, env={'DN_TETRIS_SEQ': 'I'})
    try:
        open_tetris(s)
        s.send(' ')                     # horizontal I on the floor
        s.wait_for(lambda x: bottom_rows_cyan(x, 1),
                   desc='horizontal I locked on the bottom row')
        s.key('UP')                     # rotate next I to vertical
        s.send(' ')
        s.wait_for(lambda x: bottom_rows_cyan(x, 5),
                   desc='vertical I (4 rows) stacked on horizontal I (1 row)')
    finally:
        s.close()


def test_info_column_fully_painted(sandbox):
    """Regression: the info column must be blanked every frame — panel
    content underneath used to bleed through between the labels."""
    s = make_session(sandbox, env={'DN_TETRIS_SEQ': 'I'})
    try:
        open_tetris(s)
        s.pump(0.2)
        ix = FX + FWCH + 2                       # info column x
        blank_rows = [3, 7] + list(range(12, FH))  # rows with no label
        for r in blank_rows:
            row = FY + r
            text = ''.join(s.screen.buffer[row][c].data
                           for c in range(ix - 1, ix + 12))
            assert text.strip() == '', \
                'info row %d shows leak-through: %r' % (r, text)
    finally:
        s.close()


def test_gravity(sandbox):
    s = make_session(sandbox, env={'DN_TETRIS_SEQ': 'I'})
    try:
        open_tetris(s)
        s.pump(0.2)
        r0 = min(field_rows_with_bg(s, 'cyan'))
        time.sleep(1.3)                 # ≥2 gravity ticks at 500ms
        s.pump(0.2)
        r1 = min(field_rows_with_bg(s, 'cyan'))
        assert r1 > r0, 'piece did not fall: %d -> %d' % (r0, r1)
    finally:
        s.close()


def test_game_over_and_return(sandbox):
    s = make_session(sandbox, env={'DN_TETRIS_SEQ': 'O'})
    try:
        open_tetris(s)
        for _ in range(12):             # stack O pieces in one column
            s.send(' ')
            time.sleep(0.1)
        s.wait_text('GAME  OVER')
        s.send('q')
        s.wait_gone('TETRIS')
        s.wait_text('a.txt')
        assert s.alive()
    finally:
        s.close()
