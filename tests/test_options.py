"""Options menu: panel setup, confirmations, colors; persistence."""

from conftest import make_session


def open_options_item(dn, item, dialog_text):
    dn.click_on('Options')
    dn.wait_text('Panel setup')
    dn.click_on(item)
    dn.wait_text(dialog_text)


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
    dn.wait_text('Colors')
    dn.click_on('Colors...')
    dn.wait_text('Color scheme:')
    dn.send('d')                        # [ Dark ]
    dn.wait_gone('Color scheme:')
    assert dn.alive()
    assert 'palette=1' in read_config(sandbox)


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
    assert dn.cell(r, c).fg in ('brown', 'yellow'), \
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
