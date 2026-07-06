"""Panel columns (Left/Right > Columns...) and exact size display."""

from conftest import make_session


def open_columns(dn, menu):
    dn.click_on(menu)
    dn.wait_text('Columns...')
    dn.click_on('Columns...')
    dn.wait_text('[X] Size')


def test_time_column_toggle_and_persists(dn, sandbox):
    assert dn.row_of('Time') is None
    open_columns(dn, 'Left')
    dn.key('DOWN', 2)
    dn.send(' ')                        # check Time
    dn.key('ENTER')
    dn.wait_text('Time')
    assert 'col_time=1' in (sandbox / 'cfg' / 'options').read_text()

    dn.close()
    s = make_session(sandbox)           # the choice is the new default
    try:
        s.wait_text('a.txt')
        assert s.row_of('Time') is not None
    finally:
        s.close()


def test_size_column_off_left_only(dn):
    open_columns(dn, 'Left')
    dn.send(' ')                        # uncheck Size (cursor on first row)
    dn.key('ENTER')
    dn.wait_for(lambda s: 'Size' not in s.display()[2][:40],
                desc='left header without Size')
    assert 'Size' in dn.display()[2][40:], 'right panel keeps its columns'
    assert dn.row_of('>SUB-DIR<') is None or \
        all('>SUB-DIR<' not in l[:40] for l in dn.display()), \
        'no size cells on the left'


def test_columns_dialog_cancel(dn, sandbox):
    open_columns(dn, 'Left')
    dn.send(' ')
    dn.key('ESC')                       # cancel: nothing changes
    dn.wait_gone('[X] Date')
    dn.pump(0.2)
    assert 'Size' in dn.display()[2][:40]


def test_exact_sizes_display(dn, sandbox):
    (sandbox / 'left' / 'big.bin').write_bytes(b'x' * 1234567)
    dn.key('CTRL_R')
    dn.wait_text('big.bin')
    dn.click_on('Options')
    dn.wait_text('Panel setup')
    dn.click_on('Panel setup')
    dn.wait_text('Exact sizes in bytes')
    dn.key('DOWN', 2)
    dn.send(' ')
    dn.key('ENTER')
    dn.wait_text('1,234,567')
    assert 'exact_sizes=1' in (sandbox / 'cfg' / 'options').read_text()
