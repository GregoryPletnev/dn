"""MicroEd — the built-in editor (F4), running in a desktop window."""


def open_editor(dn, name):
    dn.click_on(name, panel='left')
    dn.key('F4')
    dn.wait_text('1:1')                 # status line:col in the frame


def test_f4_opens_microed(dn):
    open_editor(dn, 'a.txt')
    assert dn.row_of('aaa') is not None, dn.dump()
    r = dn.row_of('[■]')
    assert r is not None, 'window frame with close icon'
    assert 'a.txt' in dn.display()[r], 'title in frame'
    assert 'Save' in dn.display()[23], 'fkey bar switches to window labels'
    assert 'Left' in dn.display()[0], 'menu bar still visible'


def test_type_and_save(dn, sandbox):
    open_editor(dn, 'a.txt')
    dn.send('XY')
    dn.wait_text('Modified')
    dn.key('F2')
    dn.wait_gone('Modified')
    dn.wait_text('Saved')               # save notification in the status
    assert (sandbox / 'left' / 'a.txt').read_text() == 'XYaaa\n'
    dn.wait_gone('Saved', timeout=6)    # ...and it fades out


def test_f3_closes_editor(dn):
    open_editor(dn, 'a.txt')
    dn.key('F3')                        # labeled Close in the fkey bar
    dn.wait_gone('[■]')
    dn.wait_text('Copy')                # panels focused again
    assert dn.alive()


def test_enter_splits_backspace_joins(dn, sandbox):
    open_editor(dn, 'b.txt')            # 'bbbbbb'
    dn.key('RIGHT', 3)
    dn.key('ENTER')
    dn.wait_text('2:1')
    dn.key('F2')
    dn.wait_for(lambda s: (sandbox / 'left' / 'b.txt').read_text() == 'bbb\nbbb\n',
                desc='split line saved')
    dn.key('BACKSPACE')
    dn.wait_text('1:4')
    dn.key('F2')
    dn.wait_for(lambda s: (sandbox / 'left' / 'b.txt').read_text() == 'bbbbbb\n',
                desc='joined line saved')


def test_close_discard_keeps_file(dn, sandbox):
    open_editor(dn, 'a.txt')
    dn.send('Z')
    dn.wait_text('Modified')
    dn.key('ESC')
    dn.wait_text('Save it?')
    dn.send('d')                        # Discard hotkey
    dn.wait_gone('Save it?')
    dn.wait_gone('[■]')
    assert (sandbox / 'left' / 'a.txt').read_text() == 'aaa\n'


def test_close_cancel_keeps_window(dn):
    open_editor(dn, 'a.txt')
    dn.send('Z')
    dn.key('ESC')
    dn.wait_text('Save it?')
    dn.send('c')                        # Cancel
    dn.wait_gone('Save it?')
    assert dn.row_of('[■]') is not None, 'window still open'
    assert dn.row_of('Modified') is not None


def test_find_and_find_next(dn, sandbox):
    big = sandbox / 'left' / 'big.txt'
    big.write_text(''.join('line %02d\n' % i for i in range(1, 31)))
    dn.key('CTRL_R')
    open_editor(dn, 'big.txt')
    dn.key('F7')
    dn.wait_text('Search for:')
    dn.send('line 2')
    dn.key('ENTER')
    dn.wait_text('20:1')                # first match: 'line 20' on line 20
    dn.key('CTRL_L')
    dn.wait_text('21:1')                # next: 'line 21'


def test_overwrite_mode_indicator(dn):
    open_editor(dn, 'a.txt')
    dn.key('INSERT')
    dn.wait_text('Ovr')
    dn.key('INSERT')
    dn.wait_gone('Ovr')


def test_ctrl_y_deletes_line(dn, sandbox):
    (sandbox / 'left' / 'two.txt').write_text('first\nsecond\n')
    dn.key('CTRL_R')
    open_editor(dn, 'two.txt')
    dn.key('CTRL_Y')
    dn.key('F2')
    dn.wait_for(lambda s: (sandbox / 'left' / 'two.txt').read_text() == 'second\n',
                desc='first line deleted and saved')
