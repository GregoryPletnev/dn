"""Pull-down menu: F9/keyboard navigation and mouse."""


def test_f9_opens_and_esc_closes(dn):
    dn.key('F9')
    dn.wait_text('Re-read')             # Left menu dropdown
    dn.key('ESC')
    dn.wait_gone('Re-read')
    assert dn.alive()


def test_keyboard_navigation_exit_item(dn):
    dn.key('F9')
    dn.wait_text('Re-read')
    dn.key('RIGHT')                     # Files menu
    dn.wait_text('Make directory')
    dn.key('UP')                        # wraps to last item: Exit
    dn.key('ENTER')
    assert dn.wait_exit() == 0


def test_mouse_opens_tools_and_starts_tetris(dn):
    dn.click_on('Tools')
    dn.wait_text('Tetris')
    dn.click_on('Tetris')
    dn.wait_text('TETRIS')              # game window title
    dn.send('q')
    dn.wait_gone('TETRIS')
    assert dn.alive()


def test_mouse_click_outside_closes_menu(dn):
    dn.click_on('Files')
    dn.wait_text('Make directory')
    dn.mouse(80 - 6, 15)                # far away from the dropdown
    dn.wait_gone('Make directory')
    assert dn.alive()


def test_fkey_bar_pulldn_click_opens_menu(dn):
    dn.mouse(66, 23)                    # "9 PullDn" slot
    dn.wait_text('Re-read')
    dn.key('ESC')
    dn.wait_gone('Re-read')


def test_disabled_item_not_executable(dn):
    dn.click_on('Disk')
    dn.wait_text('(not implemented)')
    dn.key('ENTER')                     # nothing selectable — must not close/crash
    dn.pump(0.2)
    assert dn.row_of('(not implemented)') is not None
    dn.key('ESC')
    dn.wait_gone('(not implemented)')
    assert dn.alive()


def test_menu_left_reread(dn, sandbox):
    (sandbox / 'left' / 'zz_menu.txt').write_text('x')
    dn.key('F9')
    dn.wait_text('Re-read')
    dn.click_on('Re-read')
    dn.wait_text('zz_menu.txt')
