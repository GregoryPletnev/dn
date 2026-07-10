from conftest import make_session


def test_startup_layout(dn, sandbox):
    dn.wait_text('Exit')
    lines = dn.display()
    assert 'Left' in lines[0] and 'Commands' in lines[0], 'menu bar'
    assert '/left ' in lines[1], 'left panel title (tail after truncation)'
    assert '/right ' in lines[1], 'right panel title (tail after truncation)'
    assert '>UP--DIR<' in lines[3], '.. entry'
    assert '>SUB-DIR<' in ''.join(lines), 'directory size marker'
    assert 'Help' in lines[23] and 'Exit' in lines[23], 'fkey bar'
    assert dn.cmdline_shows(sandbox / 'left'), 'command line'
    # cursor bar starts on '..'
    assert '..' in dn.cursor_bar_text()


def test_startup_forces_utf8_locale_for_box_drawing(sandbox):
    s = make_session(sandbox, env={'LC_ALL': 'C', 'LC_CTYPE': 'C', 'LANG': 'C'})
    try:
        s.wait_text('a.txt')
        s.wait_for(lambda x: x.cell(1, 0).data == '╔' and x.cell(1, 39).data == '╗',
                   desc='box drawing rendered as UTF-8')
    finally:
        s.close()


def test_enter_and_leave_directory(dn, sandbox):
    # cursor: .. alpha beta a.txt b.txt
    dn.key('DOWN')                      # alpha
    dn.key('ENTER')
    dn.wait_text('inner.txt')
    assert dn.cmdline_shows(sandbox / 'left' / 'alpha'), dn.dump()
    # go back up via '..' (Enter on it), cursor must land on 'alpha'
    dn.key('ENTER')
    dn.wait_text('beta')
    assert 'alpha' in dn.cursor_bar_text(), dn.dump()


def test_backspace_goes_up(dn, sandbox):
    dn.key('DOWN')
    dn.key('ENTER')
    dn.wait_text('inner.txt')
    dn.key('BACKSPACE')
    dn.wait_text('b.txt')
    assert 'alpha' in dn.cursor_bar_text(), dn.dump()


def test_tab_switches_panel(dn, sandbox):
    dn.key('TAB')
    dn.wait_for(lambda s: s.cmdline_shows(sandbox / 'right'),
                desc='command line shows right panel path')
    # cursor bar must now be in the right half of the screen
    assert dn.cursor_bar_row() is not None
    dn.key('TAB')
    dn.wait_for(lambda s: s.cmdline_shows(sandbox / 'left'),
                desc='command line shows left panel path')


def test_insert_selects_file(dn):
    dn.key('DOWN', 3)                   # a.txt
    assert 'a.txt' in dn.cursor_bar_text()
    dn.key('INSERT')
    # cursor moved down to b.txt, a.txt is drawn selected (yellow on blue)
    dn.wait_for(lambda s: 'b.txt' in (s.cursor_bar_text() or ''),
                desc='cursor moved to b.txt')
    r = dn.row_of('a.txt')
    c = dn.display()[r].index('a.txt')
    cell = dn.cell(r, c)
    assert cell.fg in ('brown', 'yellow'), 'selected file should be yellow, got %r' % (cell,)
    # deselect again
    dn.key('UP')
    dn.key('INSERT')
    cell = dn.cell(r, c)
    assert cell.fg not in ('brown', 'yellow'), 'file should be deselected, got %r' % (cell,)


def test_selection_skips_updir(dn):
    assert '..' in dn.cursor_bar_text()
    dn.key('INSERT')
    r = dn.row_of('>UP--DIR<')
    cell = dn.cell(r, 1)
    assert cell.fg not in ('brown', 'yellow'), '.. must not be selectable'


def test_paging_and_home_end(sandbox):
    many = sandbox / 'left' / 'many'
    many.mkdir()
    for i in range(60):
        (many / ('f%02d.txt' % i)).write_text('x')
    s = make_session(sandbox, left=many)
    try:
        s.wait_text('f00.txt')
        s.key('END')
        s.wait_for(lambda x: 'f59.txt' in (x.cursor_bar_text() or ''),
                   desc='End puts cursor on last file')
        s.key('HOME')
        s.wait_for(lambda x: '..' in (x.cursor_bar_text() or ''),
                   desc='Home puts cursor on first entry')
        s.key('PGDN')
        s.wait_for(lambda x: 'f15.txt' in (x.cursor_bar_text() or ''),
                   desc='PgDn moves cursor one page down (16 rows)')
        s.key('PGUP')
        s.wait_for(lambda x: '..' in (x.cursor_bar_text() or ''),
                   desc='PgUp moves back to top')
    finally:
        s.close()


def test_ctrl_r_rereads(dn, sandbox):
    (sandbox / 'left' / 'zz_new.txt').write_text('fresh\n')
    dn.key('CTRL_R')
    dn.wait_text('zz_new.txt')


def test_resize(dn, sandbox):
    dn.resize(20, 60)
    dn.wait_for(lambda s: s.alive() and s.display()[1].rstrip().endswith('╗')
                and len(s.display()[1].rstrip()) == 60
                and 'Exit' in s.display()[19],
                desc='layout redrawn at 60x20')
    # left panel border must end at column 29, right panel start at 30
    assert dn.cell(1, 29).data == '╗', dn.dump()
    assert dn.cell(1, 30).data == '╔', dn.dump()
    dn.resize(24, 80)
    dn.wait_for(lambda s: s.alive() and len(s.display()[1].rstrip()) == 80,
                desc='layout redrawn back at 80x24')
    assert dn.cell(1, 39).data == '╗', dn.dump()


def test_empty_directory(sandbox):
    empty = sandbox / 'left' / 'hollow'
    empty.mkdir()
    s = make_session(sandbox, left=empty)
    try:
        s.wait_text('>UP--DIR<')
        assert '..' in s.cursor_bar_text()
        # keys must not crash on a lone '..'
        s.key('END'); s.key('HOME'); s.key('PGDN'); s.key('PGUP')
        assert s.alive()
    finally:
        s.close()


def test_f10_exits_cleanly(dn):
    dn.key('F10')
    assert dn.wait_exit() == 0
