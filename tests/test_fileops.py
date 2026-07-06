"""F-key operations: dialogs, file ops, viewer, help."""


def test_f7_mkdir(dn, sandbox):
    dn.key('F7')
    dn.wait_text('Make directory')
    dn.send('newdir')
    dn.key('ENTER')
    dn.wait_text('newdir')
    assert (sandbox / 'left' / 'newdir').is_dir()
    assert 'newdir' in dn.cursor_bar_text(), 'cursor moves to the new dir'


def test_f7_mkdir_cancel(dn, sandbox):
    dn.key('F7')
    dn.wait_text('Directory name:')
    dn.send('nope')
    dn.key('ESC')
    dn.wait_gone('Directory name:')
    assert not (sandbox / 'left' / 'nope').exists()


def test_f8_delete_file(dn, sandbox):
    dn.click_on('a.txt', panel='left')
    dn.key('F8')
    dn.wait_text('Delete "a.txt"')
    dn.key('ENTER')                     # Yes is focused
    dn.wait_for(lambda s: s.row_of('a.txt') is None, desc='a.txt gone from panel')
    assert not (sandbox / 'left' / 'a.txt').exists()


def test_f8_delete_cancel(dn, sandbox):
    dn.click_on('b.txt', panel='left')
    dn.key('F8')
    dn.wait_text('Delete "b.txt"')
    dn.send('n')                        # hotkey for [ No ]
    dn.wait_gone('Delete "b.txt"')
    assert (sandbox / 'left' / 'b.txt').exists()


def test_f8_delete_directory_recursive(dn, sandbox):
    dn.click_on('alpha', panel='left')
    dn.key('F8')
    dn.wait_text('Delete "alpha"')
    dn.key('ENTER')
    dn.wait_for(lambda s: s.row_of('alpha') is None, desc='alpha gone')
    assert not (sandbox / 'left' / 'alpha').exists()


def test_f5_copy_file(dn, sandbox):
    dn.click_on('a.txt', panel='left')
    dn.key('F5')
    dn.wait_text('Copy "a.txt" to')
    dn.key('ENTER')
    dn.wait_for(lambda s: s.row_of('a.txt') is not None and
                'a.txt' in s.display()[s.row_of('a.txt')][40:] or
                any('a.txt' in l[40:] for l in s.display()),
                desc='a.txt appears in right panel')
    assert (sandbox / 'right' / 'a.txt').read_text() == 'aaa\n'
    assert (sandbox / 'left' / 'a.txt').exists(), 'copy keeps the source'


def test_f5_copy_directory_recursive(dn, sandbox):
    dn.click_on('alpha', panel='left')
    dn.key('F5')
    dn.wait_text('Copy "alpha" to')
    dn.key('ENTER')
    dn.wait_for(lambda s: any('alpha' in l[40:] for l in s.display()),
                desc='alpha in right panel')
    assert (sandbox / 'right' / 'alpha' / 'inner.txt').read_text() == 'hello\n'


def test_f5_copy_selected_files(dn, sandbox):
    dn.click_on('a.txt', button='right', panel='left')
    dn.click_on('b.txt', button='right', panel='left')
    dn.key('F5')
    dn.wait_text('Copy 2 files to')
    dn.key('ENTER')
    dn.wait_for(lambda s: any('b.txt' in l[40:] for l in s.display()),
                desc='files in right panel')
    assert (sandbox / 'right' / 'a.txt').exists()
    assert (sandbox / 'right' / 'b.txt').exists()


def test_f6_move_file(dn, sandbox):
    dn.click_on('b.txt', panel='left')
    dn.key('F6')
    dn.wait_text('Move "b.txt" to')
    dn.key('ENTER')
    dn.wait_for(lambda s: not any('b.txt' in l[:40] for l in s.display()),
                desc='b.txt gone from left panel')
    assert not (sandbox / 'left' / 'b.txt').exists()
    assert (sandbox / 'right' / 'b.txt').read_text() == 'bbbbbb\n'


def test_f3_viewer(dn):
    dn.click_on('a.txt', panel='left')
    dn.key('F3')
    dn.wait_text('lines')               # viewer status bar
    assert dn.row_of('aaa') is not None, dn.dump()
    dn.send('q')
    dn.wait_text('Name')                # panels back
    assert dn.alive()


def test_f1_help(dn):
    dn.key('F1')
    dn.wait_text('DN - DataNavigator')
    dn.key('END')                       # scroll to the bottom of the help
    dn.wait_text('Gregory Pletnev')
    dn.send('q')
    dn.wait_gone('DN - DataNavigator')
    assert dn.alive()


def test_f2_no_menu_offers_template(dn):
    dn.key('F2')
    dn.wait_text('No user menu entries')
    dn.send('n')
    dn.wait_gone('No user menu entries')
    assert dn.alive()
