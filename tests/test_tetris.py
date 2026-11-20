"""Tetris (Tools menu / Ctrl+T). DN_TETRIS_SEQ makes piece order
deterministic. The game is a desktop window: at 80x24 the desktop is rows
1..21, so the field is 19 rows tall with its top-left cell at (2, 24)."""

import time

from conftest import make_session

FY, FX = 2, 24          # field top-left screen cell at 80x24
FH, FWCH = 19, 20       # field height in rows, width in screen chars


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
        blank_rows = [3, 7] + list(range(13, FH))  # rows with no label
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


def top_cyan_row(s):
    rows = field_rows_with_bg(s, 'cyan')
    return min(rows) if rows else None


def test_pause_stops_gravity(sandbox):
    s = make_session(sandbox, env={'DN_TETRIS_SEQ': 'I'})
    try:
        open_tetris(s)
        s.send('p')
        s.wait_text('PAUSED')
        s.pump(0.2)
        r0 = top_cyan_row(s)
        time.sleep(1.3)
        s.pump(0.2)
        assert top_cyan_row(s) == r0, 'piece fell while paused'
        s.send('p')
        s.wait_gone('PAUSED')
        s.wait_for(lambda x: top_cyan_row(x) > r0, timeout=3,
                   desc='gravity resumed after P')
    finally:
        s.close()


def test_losing_focus_pauses(sandbox):
    s = make_session(sandbox, env={'DN_TETRIS_SEQ': 'I'})
    try:
        open_tetris(s)
        s.mouse(3, 10)                  # click the left panel
        s.wait_text('PAUSED')
        s.key('CTRL_T')                 # back to the same game, still paused
        s.pump(0.3)
        assert sum(l.count('TETRIS') for l in s.display()) == 1, s.dump()
        assert s.row_of('PAUSED') is not None
        s.key('LEFT')                   # a game key resumes
        s.wait_gone('PAUSED')
    finally:
        s.close()


def test_drag_title_moves_game(sandbox):
    s = make_session(sandbox, env={'DN_TETRIS_SEQ': 'I'})
    try:
        open_tetris(s)
        s.send('p')                     # keep the piece still while dragging
        s.wait_text('PAUSED')
        tx = s.display()[1].find('TETRIS')
        assert tx > 0, s.dump()
        s.drag(tx, 1, tx - 10, 1)
        s.wait_for(lambda x: x.display()[1].find('TETRIS') == tx - 10,
                   desc='title followed the drag')
        # the field moved with the frame: its left edge is now 10 cols over
        s.wait_for(lambda x: x.cell(FY, FX - 10).bg in ('black', 'cyan'),
                   desc='field moved with the window')
        assert s.cell(FY + FH - 1, FX + FWCH - 1).bg not in ('black',), \
            'old field area still painted'
    finally:
        s.close()


def test_new_game_after_game_over(sandbox):
    s = make_session(sandbox, env={'DN_TETRIS_SEQ': 'O'})
    try:
        open_tetris(s)
        for _ in range(12):
            s.send(' ')
            time.sleep(0.1)
        s.wait_text('GAME  OVER')
        s.send('n')
        s.wait_gone('GAME  OVER')
        s.wait_text('Score: 0')
    finally:
        s.close()
