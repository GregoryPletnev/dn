"""M2a: sorting, masks, quick jump, swap, dir size, compare (DN 1.3/1.5/2.3/…)."""

import pytest

from conftest import make_session


@pytest.fixture
def dnp(sandbox):
    """Sandbox with distinct sizes/extensions for sort tests."""
    left = sandbox / 'left'
    (left / 'zz.log').write_text('x' * 500)
    (left / 'mm.md').write_text('x' * 90)
    s = make_session(sandbox)
    s.wait_text('a.txt')
    yield s
    s.close()


def names_in_left(s):
    out = []
    for r in range(3, 19):
        line = s.display()[r][:40]
        if line.startswith('║') and line[1] != ' ':
            out.append(line[1:20].split('│')[0].strip())
    return [n for n in out if n]


def test_sort_by_size(dnp):
    dnp.send('\x1bs')                   # Alt-S
    dnp.wait_text('Sort panel by')
    dnp.send('s')                       # Size button hotkey
    dnp.wait_gone('Sort panel by')
    ns = names_in_left(dnp)
    files = [n for n in ns if n not in ('..', 'alpha', 'beta')]
    assert files[0] == 'zz.log', 'largest first: %r' % files
    assert files[1] == 'mm.md', files


def test_sort_by_ext(dnp):
    dnp.send('\x1bs')
    dnp.wait_text('Sort panel by')
    dnp.send('e')                       # Ext
    dnp.wait_gone('Sort panel by')
    ns = names_in_left(dnp)
    files = [n for n in ns if n not in ('..', 'alpha', 'beta')]
    assert files == ['zz.log', 'mm.md', 'a.txt', 'b.txt'], files


def test_filter_via_menu(dnp, sandbox):
    dnp.click_on('Left')
    dnp.wait_text('Filter...')
    dnp.click_on('Filter...')
    dnp.wait_text('File mask')
    dnp.send('*.txt')
    dnp.key('ENTER')
    dnp.wait_gone('mm.md')
    ns = names_in_left(dnp)
    assert 'a.txt' in ns and 'zz.log' not in ns
    assert 'alpha' in ns, 'directories always shown'
    # clear the filter
    dnp.click_on('Left')
    dnp.wait_text('Filter...')
    dnp.click_on('Filter...')
    dnp.wait_text('File mask')
    for _ in range(5):
        dnp.key('BACKSPACE')
    dnp.key('ENTER')
    dnp.wait_text('mm.md')


def test_select_by_mask(dnp):
    dnp.send('+')
    dnp.wait_text('Mask:')
    dnp.send('.txt')                    # default '*' -> '*.txt'
    dnp.key('ENTER')
    r = dnp.row_of('a.txt')
    c = dnp.display()[r].index('a.txt')
    dnp.wait_for(lambda s: s.cell(r, c).fg in ('brown', 'yellow'),
                 desc='a.txt selected by mask')
    rl = dnp.row_of('zz.log')
    assert dnp.cell(rl, 1).fg not in ('brown', 'yellow'), 'log not selected'
    # '-' deselects
    dnp.send('-')
    dnp.wait_text('Mask:')
    dnp.key('ENTER')                    # same mask kept
    dnp.wait_for(lambda s: s.cell(r, c).fg not in ('brown', 'yellow'),
                 desc='deselected by mask')


def test_invert_all(dnp):
    dnp.send('*')
    r = dnp.row_of('zz.log')
    dnp.wait_for(lambda s: s.cell(r, 1).fg in ('brown', 'yellow'),
                 desc='* inverted: files selected')
    ra = dnp.row_of('alpha')
    assert dnp.cell(ra, 1).fg not in ('brown', 'yellow'), 'dirs untouched'


def test_quick_jump_alt_letter(dnp):
    assert '..' in dnp.cursor_bar_text()
    dnp.send('\x1bb')                   # Alt-B
    dnp.wait_for(lambda s: 'beta' in (s.cursor_bar_text() or ''),
                 desc='jump to beta')
    dnp.send('\x1bb')
    dnp.wait_for(lambda s: 'b.txt' in (s.cursor_bar_text() or ''),
                 desc='next b-file')


def test_ctrl_u_swaps_panels(dnp, sandbox):
    dnp.send('\x15')                    # Ctrl-U
    dnp.wait_for(lambda s: '/right ' in s.display()[1][:40],
                 desc='left half now shows the right dir')
    assert '/left ' in dnp.display()[1][40:]


def test_ctrl_g_dir_size(dnp, sandbox):
    dnp.click_on('alpha', panel='left')
    dnp.send('\x07')                    # Ctrl-G
    r = dnp.row_of('alpha')
    dnp.wait_for(lambda s: '>SUB-DIR<' not in s.display()[r][:40] and
                 '6' in s.display()[r][:40],
                 desc='alpha shows its size (6 bytes of inner.txt)')


def test_ctrl_c_compare_dirs(dnp, sandbox):
    (sandbox / 'right' / 'a.txt').write_text('aaa\n')   # same as left
    dnp.key('CTRL_R')
    dnp.send('\x03')                    # Ctrl-C compare
    r = dnp.row_of('b.txt')
    dnp.wait_for(lambda s: s.cell(r, 1).fg in ('brown', 'yellow'),
                 desc='b.txt differs -> selected')
    ra = dnp.row_of('a.txt')
    assert dnp.cell(ra, 1).fg not in ('brown', 'yellow'), \
        'a.txt equal on both sides -> not selected'
    # right panel: r.txt differs
    rr = None
    for i, l in enumerate(dnp.display()):
        if 'r.txt' in l[40:]:
            rr = i
            break
    assert rr and dnp.cell(rr, 41).fg in ('brown', 'yellow'), dnp.dump()
