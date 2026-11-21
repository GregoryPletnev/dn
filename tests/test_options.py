"""Options menu: panel setup, confirmations, colors; persistence."""

from conftest import make_session


def open_options_item(dn, item, dialog_text):
    dn.click_on('Options')
    dn.wait_text('Panel setup')
    dn.click_on(item)
    dn.wait_text(dialog_text)


def term_env(**kw):
    """A fixed terminal identity: variables leaked from the terminal that
    runs pytest must not change what DN detects (or let a test touch a
    real Terminal.app / iTerm2 profile)."""
    e = {k: '' for k in ('TMUX', 'STY', 'ZELLIJ', 'KITTY_WINDOW_ID',
                         'WEZTERM_PANE', 'ITERM_SESSION_ID', 'ITERM_PROFILE',
                         'ALACRITTY_WINDOW_ID', 'WT_SESSION',
                         'KONSOLE_VERSION', 'VTE_VERSION', 'XTERM_VERSION',
                         'TERM_PROGRAM', 'TERM_PROGRAM_VERSION')}
    e.update(kw)
    return e


def read_config(sandbox):
    f = sandbox / 'cfg' / 'options'
    return f.read_text() if f.exists() else ''


def test_hidden_files_shown_by_default(dn, sandbox):
    (sandbox / 'left' / '.secret').write_text('x')
    dn.key('CTRL_R')
    dn.wait_text('.secret')


def test_panel_setup_hides_dotfiles_and_persists(dn, sandbox):
    (sandbox / 'left' / '.secret').write_text('x')
    dn.key('CTRL_R')
    dn.wait_text('.secret')
    open_options_item(dn, 'Panel setup', 'Show hidden files')
    dn.send(' ')                        # toggle off (cursor on the only item)
    dn.key('ENTER')
    dn.wait_gone('.secret')
    assert 'show_hidden=0' in read_config(sandbox)

    dn.close()
    s = make_session(sandbox)           # restart: setting must survive
    try:
        s.wait_text('a.txt')
        s.pump(0.3)
        assert s.row_of('.secret') is None
    finally:
        s.close()


def test_panel_setup_cancel_changes_nothing(dn, sandbox):
    (sandbox / 'left' / '.secret').write_text('x')
    dn.key('CTRL_R')
    dn.wait_text('.secret')
    open_options_item(dn, 'Panel setup', 'Show hidden files')
    dn.send(' ')
    dn.key('ESC')                       # cancel: toggle is discarded
    dn.wait_gone('Show hidden files')
    dn.pump(0.2)
    assert dn.row_of('.secret') is not None


def test_confirm_delete_off(dn, sandbox):
    open_options_item(dn, 'Confirmations', 'Confirm delete')
    dn.send(' ')                        # cursor starts on 'Confirm delete'
    dn.key('ENTER')
    dn.wait_gone('Confirm delete')
    dn.click_on('a.txt', panel='left')
    dn.key('F8')                        # no dialog: deletes immediately
    dn.wait_for(lambda s: s.row_of('a.txt') is None, desc='a.txt deleted')
    assert not (sandbox / 'left' / 'a.txt').exists()
    assert 'confirm_delete=0' in read_config(sandbox)


def test_confirm_exit(dn, sandbox):
    open_options_item(dn, 'Confirmations', 'Confirm exit')
    dn.key('DOWN', 2)                   # delete -> overwrite -> exit
    dn.send(' ')
    dn.key('ENTER')
    dn.wait_gone('Confirm exit')
    dn.key('F10')
    dn.wait_text('Quit DN - DataNavigator')
    dn.send('n')                        # stay
    dn.wait_gone('Quit DN - DataNavigator')
    assert dn.alive()
    dn.key('F10')
    dn.wait_text('Quit DN - DataNavigator')
    dn.send('y')
    assert dn.wait_exit() == 0


def test_overwrite_confirmation(dn, sandbox):
    (sandbox / 'left' / 'r.txt').write_text('LLL\n')
    dn.key('CTRL_R')
    dn.wait_text('r.txt')
    dn.click_on('r.txt', panel='left')
    dn.key('F5')
    dn.wait_text('Copy "r.txt" to')
    dn.key('ENTER')                     # Yes
    dn.wait_text('Overwrite "r.txt"')
    dn.send('n')                        # skip
    dn.wait_gone('Overwrite "r.txt"')
    assert (sandbox / 'right' / 'r.txt').read_text() == 'rrr\n'

    dn.key('F5')
    dn.wait_text('Copy "r.txt" to')
    dn.key('ENTER')
    dn.wait_text('Overwrite "r.txt"')
    dn.key('ENTER')                     # Yes is focused
    dn.wait_gone('Overwrite "r.txt"')
    dn.wait_for(lambda s: (sandbox / 'right' / 'r.txt').read_text() == 'LLL\n',
                desc='r.txt overwritten')


def test_colors_dialog_saves_palette(dn, sandbox):
    dn.click_on('Options')
    dn.wait_text('Fonts/Colors')
    dn.click_on('Fonts/Colors...')
    dn.wait_text('Color scheme: DN default')
    dn.click_on('Color scheme: DN default')
    dn.wait_text('Norton Commander')     # the DN 1.51 palettes
    dn.wait_text('Monochrome')
    dn.click_on('Norton Commander')
    dn.wait_text('Color scheme: Norton Commander')  # back in Fonts/Colors
    assert 'colors=norton' in read_config(sandbox)
    r = dn.row_of('a.txt')
    c = dn.display()[r].index('a.txt')
    assert dn.cell(r, c).bg == 'blue', 'Norton panels are blue'
    dn.key('ESC')
    dn.wait_gone('Color scheme: Norton')


def test_default_palette_is_dn_gray(dn):
    r = dn.row_of('a.txt')
    c = dn.display()[r].index('a.txt')
    assert dn.cell(r, c).bg in ('brightblack', 'cyan'), dn.cell(r, c)
    assert dn.cell(0, 3).bg == 'white', 'menu bar: black on light gray'


def test_legacy_palette_setting_maps_to_dn_palette(sandbox):
    (sandbox / 'cfg').mkdir()
    (sandbox / 'cfg' / 'options').write_text('palette=0\n')
    s = make_session(sandbox)
    try:
        s.wait_text('a.txt')
        r = s.row_of('a.txt')
        c = s.display()[r].index('a.txt')
        assert s.cell(r, c).bg in ('blue', 'cyan'), 'old classic blue -> Norton'
    finally:
        s.close()


def test_space_selects_files(dn, sandbox):
    dn.click_on('a.txt', panel='left')
    dn.send(' ')                        # select a.txt, cursor moves down
    dn.send(' ')                        # select b.txt
    dn.key('F8')
    dn.wait_text('Delete 2 files')
    dn.send('n')
    dn.wait_gone('Delete 2 files')


def test_space_types_into_nonempty_cmdline(dn):
    dn.send('x')
    dn.send(' ')
    dn.send('y')
    dn.wait_text('>x y')                # went to the command line, no select
    dn.key('ESC')


def test_space_select_toggle_off(dn, sandbox):
    open_options_item(dn, 'Panel setup', 'Space selects files')
    dn.key('DOWN')
    dn.send(' ')                        # uncheck 'Space selects files'
    dn.key('ENTER')
    dn.wait_gone('Space selects files')
    assert 'space_select=0' in read_config(sandbox)
    dn.click_on('a.txt', panel='left')
    dn.send(' ')
    dn.key('F5')
    dn.wait_text('Copy "a.txt" to')     # a single file: space selected nothing
    dn.key('ESC')


def test_highlight_groups_color_files(dn, sandbox):
    (sandbox / 'left' / 'foo.zip').write_text('')
    (sandbox / 'left' / 'run.sh').write_text('')
    dn.key('CTRL_R')
    dn.wait_text('foo.zip')
    r = dn.row_of('foo.zip')
    c = dn.display()[r].index('foo.zip')
    assert dn.cell(r, c).fg in ('brown', 'yellow', 'brightbrown'), \
        'archives draw yellow, got %r' % (dn.cell(r, c),)
    r = dn.row_of('run.sh')
    c = dn.display()[r].index('run.sh')
    assert dn.cell(r, c).fg == 'green', \
        'executables draw green, got %r' % (dn.cell(r, c),)


def test_highlight_dialog_cycles_color_and_saves(dn, sandbox):
    dn.click_on('Options')
    dn.wait_text('Highlight groups')
    dn.click_on('Highlight groups...')
    dn.wait_text('Space = color')
    dn.send(' ')                        # group 1: Green -> Yellow
    dn.key('TAB')                       # focus [ OK ]
    dn.key('ENTER')
    dn.wait_gone('Space = color')
    assert 'hl1_color=3' in read_config(sandbox)


def test_highlight_dialog_edit_mask(dn, sandbox):
    (sandbox / 'left' / 'data.foo').write_text('')
    dn.key('CTRL_R')
    dn.wait_text('data.foo')
    dn.click_on('Options')
    dn.wait_text('Highlight groups')
    dn.click_on('Highlight groups...')
    dn.wait_text('Space = color')
    dn.key('DOWN', 3)                   # group 4 (custom, empty)
    dn.key('ENTER')
    dn.wait_text('File masks')
    dn.send('*.foo')
    dn.key('ENTER')
    dn.wait_text('Space = color')
    dn.key('TAB')
    dn.key('ENTER')                     # OK
    dn.wait_gone('Space = color')
    assert 'hl4_mask=*.foo' in read_config(sandbox)
    r = dn.row_of('data.foo')
    c = dn.display()[r].index('data.foo')
    dn.wait_for(lambda s: s.cell(r, c).fg == 'white',
                desc='custom group colors data.foo white')


def test_info_shows_detected_terminal(sandbox):
    s = make_session(sandbox, env=term_env(TERM_PROGRAM='iTerm.app',
                                           TERM_PROGRAM_VERSION='3.5.4'))
    try:
        s.wait_text('a.txt')
        s.click_on('Options')
        s.wait_text('Panel setup')
        s.click_on('Info')
        s.wait_text('iTerm2 3.5.4')
        s.wait_text('xterm-256color')
        s.wait_text('80x24')
        s.key('ENTER')
        s.wait_gone('Detected by')
    finally:
        s.close()


def open_fonts(s):
    s.click_on('Options')
    s.wait_text('Fonts/Colors')
    s.click_on('Fonts/Colors...')
    s.wait_text('Font: terminal default')


def test_font_list_shows_licenses_and_state(sandbox):
    s = make_session(sandbox, env=term_env(TERM_PROGRAM='vscode'))
    try:
        s.wait_text('a.txt')
        open_fonts(s)
        s.click_on('Font: terminal default')
        s.wait_text('Font (VS Code terminal)')
        s.wait_text('CC BY-SA 4.0')
        s.wait_text('SIL OFL 1.1')
        s.wait_text('bundled')
        s.wait_text('not for this terminal')         # the PSF console font
        s.key('ESC')
        s.wait_gone('Font (VS Code')
    finally:
        s.close()


def test_bundled_font_installs_and_persists(sandbox):
    fonts = sandbox / 'userfonts'
    s = make_session(sandbox, env=term_env(TERM_PROGRAM='vscode',
                                           DN_USER_FONT_DIR=str(fonts)))
    try:
        s.wait_text('a.txt')
        open_fonts(s)
        s.click_on('Font: terminal default')
        s.wait_text('IBM VGA 9x16')
        s.click_on('IBM VGA 9x16')
        s.wait_text('terminal.integrated.fontFamily')
        assert (fonts / 'PxPlus_IBM_VGA_9x16.ttf').stat().st_size == 71144
        s.key('ENTER')
        s.wait_text('Font: IBM VGA 9x16 (DOS)')     # back in Fonts/Colors
        cfg = read_config(sandbox)
        assert 'font=vga' in cfg and 'font_size=14' in cfg
    finally:
        s.close()


def test_font_size_error_returns_to_input(sandbox):
    s = make_session(sandbox, env=term_env(TERM_PROGRAM='vscode'))
    try:
        s.wait_text('a.txt')
        open_fonts(s)
        s.click_on('Font size: 14')
        s.wait_text('Size in points')
        s.key('BACKSPACE', 4)
        s.send('99')
        s.key('ENTER')
        s.wait_text('from 6 to 72')
        s.key('ENTER')                  # OK: the input again, value kept
        s.wait_gone('from 6 to 72')
        s.wait_text('Size in points')
        s.wait_text('99')
        s.key('BACKSPACE', 2)
        s.send('16')
        s.key('ENTER')
        s.wait_text('Font size: 16')    # back in Fonts/Colors
        assert 'font_size=16' in read_config(sandbox)
    finally:
        s.close()


def test_esc_goes_back_one_step(sandbox):
    s = make_session(sandbox, env=term_env(TERM_PROGRAM='vscode'))
    try:
        s.wait_text('a.txt')
        open_fonts(s)
        # size input -> Fonts/Colors
        s.click_on('Font size: 14')
        s.wait_text('Size in points')
        s.key('ESC')
        s.wait_gone('Size in points')
        s.wait_text('Font: terminal default')
        # colour scheme -> Fonts/Colors
        s.click_on('Color scheme: DN default')
        s.wait_text('Norton Commander')
        s.key('ESC')
        s.wait_gone('Norton Commander')
        s.wait_text('Color scheme: DN default')
        # font list -> Fonts/Colors
        s.click_on('Font: terminal default')
        s.wait_text('Font (VS Code terminal)')
        # download prompt -> font list
        s.click_on('Hack')
        s.wait_text('Download Hack')
        s.key('ESC')
        s.wait_gone('Download Hack')
        s.wait_text('Font (VS Code terminal)')
        # a font that does not fit -> its reason -> the font list
        s.click_on('Spleen')
        s.wait_text('only on the Linux console')
        s.key('ENTER')
        s.wait_text('Font (VS Code terminal)')
        s.key('ESC')
        s.wait_gone('Font (VS Code')
        s.wait_text('Font: terminal default')
        s.key('ESC')
        s.wait_gone('Font: terminal default')
        assert 'font=\n' in read_config(sandbox) + '\n' or \
            'font=' not in read_config(sandbox)
    finally:
        s.close()
