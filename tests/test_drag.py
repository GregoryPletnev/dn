"""Mouse drag: move/resize windows, drag the panel divider; Alt-[/]/= split."""

from test_windows import open_editor, frame_col


def test_drag_title_moves_window(dn):
    open_editor(dn, 'a.txt')
    r, c = frame_col(dn, 'a.txt')
    tx = dn.display()[r].find('a.txt')
    dn.drag(tx, r, tx + 6, r + 4)
    dn.wait_for(lambda s: frame_col(s, 'a.txt') == (r + 4, c + 6),
                desc='window followed the title drag')


def test_drag_corner_resizes_window(dn):
    open_editor(dn, 'a.txt')
    r, c = frame_col(dn, 'a.txt')
    line = dn.display()[r]
    right = line.rindex('╗')
    bottom = None
    for rr in range(r + 1, dn.rows):
        if dn.cell(rr, right).data == '╝':
            bottom = rr
            break
    assert bottom is not None, dn.dump()
    dn.drag(right, bottom, right - 8, bottom - 3)
    dn.wait_for(lambda s: s.cell(bottom - 3, right - 8).data == '╝',
                desc='corner drag shrank the window')
    assert dn.cell(bottom, right).data != '╝'


def test_drag_panel_divider(dn):
    assert dn.cell(1, 40).data == '╔'
    dn.drag(40, 5, 30, 5)
    dn.wait_for(lambda s: s.cell(1, 30).data == '╔',
                desc='right panel starts at the new split')
    assert dn.cell(1, 40).data != '╔'
    # drag state is released: ordinary clicks still work
    dn.click_on('a.txt', panel='left')
    assert 'a.txt' in dn.cursor_bar_text()


def test_alt_brackets_change_split(dn):
    dn.send('\x1b]')                    # Alt+]: split moves right
    dn.wait_for(lambda s: s.cell(1, 42).data == '╔', desc='split at 42')
    dn.send('\x1b[')                    # Alt+[: back left
    dn.wait_for(lambda s: s.cell(1, 40).data == '╔', desc='split at 40')
    dn.send('\x1b]')
    dn.wait_for(lambda s: s.cell(1, 42).data == '╔', desc='split at 42 again')
    dn.send('\x1b=')                    # Alt+=: reset to the middle
    dn.wait_for(lambda s: s.cell(1, 40).data == '╔', desc='split reset')


def test_split_clamps_to_minimum(dn):
    dn.drag(40, 5, 2, 5)                # far beyond the minimum
    dn.wait_for(lambda s: s.cell(1, 20).data == '╔',
                desc='split clamped at the minimal panel width')
