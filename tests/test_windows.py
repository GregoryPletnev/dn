"""The DN multi-window desktop: cycling, zoom, move, icons, quit guard."""


def open_editor(dn, name):
    dn.click_on(name, panel='left')
    dn.key('F4')
    dn.wait_text('1:1')


def frame_col(dn, title):
    """x of the top-left frame corner of the window titled `title`."""
    r = dn.row_of(' ' + title + ' ')
    assert r is not None, dn.dump()
    line = dn.display()[r]
    for ch in ('╔', '┌'):
        p = line.find(ch)
        if p >= 0:
            return r, p
    raise AssertionError('no frame corner on row %d\n%s' % (r, dn.dump()))


def test_two_windows_and_f6_cycle(dn, sandbox):
    open_editor(dn, 'a.txt')
    dn.key('F6')                        # window -> panels
    dn.wait_text('Copy')                # fkey bar back to panel labels
    dn.key('END')                       # b.txt is the last panel entry
    dn.wait_for(lambda s: 'b.txt' in s.display()[20],
                desc='panel cursor on b.txt (mini-status)')
    dn.key('F4')
    dn.wait_text('1:1')
    assert dn.row_of(' a.txt ') is not None, 'first window still on screen'
    assert dn.row_of(' b.txt ') is not None, 'second window on screen'
    # typing goes to the focused (b.txt) window
    dn.send('Q')
    dn.wait_text('Modified')
    dn.key('F2')
    dn.wait_for(lambda s: (sandbox / 'left' / 'b.txt').read_text() == 'Qbbbbbb\n',
                desc='keystroke went to b.txt window')
    # cycle: b.txt -> a.txt -> panels. The a.txt window is under b.txt in
    # z-order (its status line is covered), so verify focus by saving.
    dn.key('F6')
    dn.send('W')                        # now a.txt is focused
    dn.key('F2')
    dn.wait_for(lambda s: (sandbox / 'left' / 'a.txt').read_text() == 'Waaa\n',
                desc='keystroke went to a.txt window after F6')
    dn.key('F6')
    dn.wait_text('Copy')                # panels again


def test_zoom_and_unzoom(dn):
    open_editor(dn, 'a.txt')
    assert dn.cell(1, 40).data == '╔', 'right panel corner visible before zoom'
    dn.key('F5')
    dn.wait_for(lambda s: s.cell(1, 40).data != '╔',
                desc='zoomed window covers the panel row')
    dn.key('F5')
    dn.wait_for(lambda s: s.cell(1, 40).data == '╔',
                desc='unzoom restores geometry')


def test_zoom_icon_click(dn):
    open_editor(dn, 'a.txt')
    r, c = frame_col(dn, 'a.txt')
    line = dn.display()[r]
    zx = line.index('[↕]')
    dn.mouse(zx + 1, r)
    dn.wait_for(lambda s: s.cell(1, 40).data != '╔', desc='zoom via icon')


def test_move_mode(dn):
    open_editor(dn, 'a.txt')
    r0, c0 = frame_col(dn, 'a.txt')
    dn.key('CTRL_F5')
    dn.key('LEFT', 2)
    dn.key('DOWN')
    dn.key('ENTER')
    dn.pump(0.3)
    r1, c1 = frame_col(dn, 'a.txt')
    assert (r1, c1) == (r0 + 1, c0 - 2), 'window moved: %r -> %r' % ((r0, c0), (r1, c1))
    # resize wider by 2 via Shift-Right
    dn.key('CTRL_F5')
    dn.key('SHIFT_RIGHT', 2)
    dn.key('ENTER')
    dn.pump(0.3)
    r2, p2 = frame_col(dn, 'a.txt')
    line = dn.display()[r2]
    # frame width = distance to the closing corner
    right = max(line.rfind('╗'), line.rfind('┐'))
    assert right - p2 == 59 + 2, 'width grew by 2 (was 60)'


def test_close_icon_click(dn):
    dn.click_on('a.txt', panel='left')
    dn.key('F3')                        # viewer window
    dn.wait_text('lines')
    r = dn.row_of('[■]')
    c = dn.display()[r].index('[■]')
    dn.mouse(c + 1, r)
    dn.wait_gone('[■]')
    dn.wait_text('Copy')                # panels focused again


def test_wheel_scrolls_viewer_window(dn, sandbox):
    big = sandbox / 'left' / 'wide.txt'
    big.write_text(''.join('row %02d\n' % i for i in range(1, 41)))
    dn.key('CTRL_R')
    dn.click_on('wide.txt', panel='left')
    dn.key('F3')
    dn.wait_text('row 01')
    r = dn.row_of('row 01')
    dn.mouse(20, r + 2, button='wheeldown')
    dn.wait_gone('row 01')


def test_click_on_panel_refocuses_panels(dn, sandbox):
    open_editor(dn, 'a.txt')
    assert 'Save' in dn.display()[23]
    dn.mouse(75, 3)                     # right panel area, outside the window
    dn.wait_text('Copy')                # panel fkey labels back
    dn.wait_for(lambda s: s.cmdline_shows(sandbox / 'right'),
                desc='right panel activated by the click')


def test_quit_asks_about_modified_editor(dn, sandbox):
    open_editor(dn, 'a.txt')
    dn.send('Z')
    dn.wait_text('Modified')
    dn.key('F6')                        # panels
    dn.wait_text('Copy')
    dn.key('F10')                       # quit -> must ask about a.txt
    dn.wait_text('Save it?')
    dn.send('c')                        # Cancel: stay alive
    dn.wait_gone('Save it?')
    assert dn.alive()
    dn.key('F6')                        # editor -> panels
    dn.wait_text('Copy')
    dn.key('F10')
    dn.wait_text('Save it?')
    dn.send('d')                        # Discard: quit proceeds
    assert dn.wait_exit() == 0
    assert (sandbox / 'left' / 'a.txt').read_text() == 'aaa\n'


def test_viewer_clips_binary_lines(dn, sandbox):
    # tabs and control bytes used to render wider than counted (^X pairs,
    # tab stops) and spill over the right frame border
    with open(sandbox / 'left' / 'bin.dat', 'wb') as f:
        f.write(b'plain\n')
        f.write(b'A\tB\tC\tD\tE\tF\tG\tH\tI\tJ\tK\tL\tM\n')
        f.write(bytes(range(1, 32)) * 8 + b'\n')
    dn.key('CTRL_R')
    dn.wait_text('bin.dat')
    dn.click_on('bin.dat', panel='left')
    dn.key('F3')
    dn.wait_text('plain')
    r = dn.row_of('plain')
    line = dn.display()[r]
    b = line.find('║', line.find('plain'))
    assert b > 0, dn.dump()
    assert dn.cell(r + 1, b).data == '║', 'tab line spilled: ' + dn.dump()
    assert dn.cell(r + 2, b).data == '║', 'control line spilled: ' + dn.dump()
