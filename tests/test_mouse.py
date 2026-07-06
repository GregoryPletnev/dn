"""Mouse support tests — covers the operations from features.txt that are
implementable with the current widget set (panels, status line, scrollbar)."""

import pytest

from conftest import make_session


@pytest.fixture
def dn_many(sandbox):
    many = sandbox / 'left' / 'many'
    many.mkdir()
    for i in range(60):
        (many / ('f%02d.txt' % i)).write_text('x')
    s = make_session(sandbox, left=many)
    s.wait_text('f00.txt')
    yield s
    s.close()


def test_mouse_reporting_enabled(dn):
    """The app must ask the terminal to send mouse events at all."""
    dn.pump(0.1)
    assert b'[?1000' in dn.raw or b'[?1006' in dn.raw, \
        'app never enabled xterm mouse reporting'


def test_click_moves_cursor(dn):
    dn.click_on('b.txt', panel='left')
    dn.wait_for(lambda s: 'b.txt' in (s.cursor_bar_text() or ''),
                desc='cursor on clicked file')


def test_click_activates_other_panel(dn, sandbox):
    dn.click_on('r.txt', panel='right')
    dn.wait_for(lambda s: s.cmdline_shows(sandbox / 'right'),
                desc='right panel activated by click')
    assert 'r.txt' in dn.cursor_bar_text()


def test_double_click_enters_directory(dn, sandbox):
    dn.click_on('alpha', panel='left', clicks=2)
    dn.wait_text('inner.txt')
    assert dn.cmdline_shows(sandbox / 'left' / 'alpha'), dn.dump()


def test_single_click_does_not_enter(dn):
    dn.click_on('alpha', panel='left')
    dn.wait_for(lambda s: 'alpha' in (s.cursor_bar_text() or ''),
                desc='cursor on alpha')
    assert dn.row_of('inner.txt') is None, 'single click must not enter'


def test_right_click_inverts_selection(dn):
    r = dn.click_on('a.txt', button='right', panel='left')
    c = dn.display()[r].index('a.txt')
    dn.wait_for(lambda s: s.cell(r, c).fg in ('brown', 'yellow'),
                desc='right-clicked file becomes selected (yellow)')
    # cursor stays on the file, does not jump down (unlike Insert)
    assert 'a.txt' in dn.cursor_bar_text()
    dn.mouse(c, r, button='right')
    dn.wait_for(lambda s: s.cell(r, c).fg not in ('brown', 'yellow'),
                desc='second right click deselects')


def test_right_click_does_not_select_updir(dn):
    r = dn.click_on('>UP--DIR<', button='right', panel='left')
    cell = dn.cell(r, 1)
    assert cell.fg not in ('brown', 'yellow'), '.. must not be selectable'
    assert dn.alive()


def test_wheel_scrolls_panel(dn_many):
    s = dn_many
    assert '..' in s.cursor_bar_text()
    s.mouse(10, 8, button='wheeldown')
    s.wait_for(lambda x: 'f02.txt' in (x.cursor_bar_text() or ''),
               desc='wheel down moves cursor 3 lines')
    s.mouse(10, 8, button='wheelup')
    s.wait_for(lambda x: '..' in (x.cursor_bar_text() or ''),
               desc='wheel up moves back')


def test_scrollbar_drawn_when_list_long(dn_many):
    s = dn_many
    # left panel right border is col 39; arrows at top/bottom of file area
    assert s.cell(3, 39).data == '▲', s.dump()
    assert s.cell(18, 39).data == '▼', s.dump()
    assert s.cell(4, 39).data == '■', 'thumb at top when cursor at top: %s' % s.dump()


def test_no_scrollbar_on_short_list(dn):
    assert dn.cell(3, 39).data == '║', dn.dump()


def test_scrollbar_arrows_and_paging(dn_many):
    s = dn_many
    s.mouse(39, 18)                     # down arrow: one line down
    s.wait_for(lambda x: 'f00.txt' in (x.cursor_bar_text() or ''),
               desc='down arrow moves cursor one line')
    s.mouse(39, 17)                     # track below thumb: page down
    s.wait_for(lambda x: 'f16.txt' in (x.cursor_bar_text() or ''),
               desc='click below thumb pages down')
    s.mouse(39, 3)                      # up arrow: one line up
    s.wait_for(lambda x: 'f15.txt' in (x.cursor_bar_text() or ''),
               desc='up arrow moves cursor one line up')
    s.mouse(39, 4)                      # track above thumb: page up
    s.wait_for(lambda x: '..' in (x.cursor_bar_text() or ''),
               desc='click above thumb pages up')
    # thumb follows the cursor
    s.key('END')
    s.wait_for(lambda x: x.cell(17, 39).data == '■',
               desc='thumb at bottom of track when cursor at end')


def test_fkey_bar_click_runs_operation(dn):
    """DN: <C> on wanted operation on status line. Slot 10 is Exit."""
    dn.mouse(74, 23)
    assert dn.wait_exit() == 0


def test_fkey_bar_click_opens_help(dn):
    dn.mouse(2, 23)                     # slot 1 = Help
    dn.wait_text('DN - DataNavigator')
    dn.send('q')
    dn.wait_text('Name')                # panels back
    assert dn.alive()
