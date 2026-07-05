"""UTF-8: panel alignment, Cyrillic input in editor/cmdline/dialogs."""

from conftest import make_session


def test_panel_alignment_with_cyrillic_names(sandbox):
    (sandbox / 'left' / 'файл.txt').write_text('data\n')
    s = make_session(sandbox)
    try:
        s.wait_text('файл.txt')
        ra = s.row_of('a.txt')
        rf = s.row_of('файл.txt')
        la, lf = s.display()[ra][:40], s.display()[rf][:40]
        assert la.index('│') == lf.index('│'), \
            'size column separator misaligned:\n%s\n%s' % (la, lf)
        # cursor bar and mini-status handle the name too
        s.click_on('файл.txt', panel='left')
        s.wait_for(lambda x: 'файл.txt' in (x.cursor_bar_text() or ''),
                   desc='cursor on cyrillic file')
        assert 'файл.txt' in s.display()[20]
    finally:
        s.close()


def test_editor_cyrillic_navigation_and_editing(sandbox):
    (sandbox / 'left' / 'ru.txt').write_text('привет мир\n')
    s = make_session(sandbox)
    try:
        s.wait_text('ru.txt')
        s.click_on('ru.txt', panel='left')
        s.key('F4')
        s.wait_text('1:1')
        s.key('END')
        s.wait_text('1:11')             # 10 codepoints + 1, not 19 bytes + 1
        s.send('!')
        s.key('F2')
        s.wait_for(lambda x: (sandbox / 'left' / 'ru.txt').read_text() ==
                   'привет мир!\n', desc='append after cyrillic text')
        # backspace deletes one whole character, not one byte
        s.key('BACKSPACE')              # '!'
        s.key('BACKSPACE')              # 'р' (2 bytes)
        s.key('F2')
        s.wait_for(lambda x: (sandbox / 'left' / 'ru.txt').read_text() ==
                   'привет ми\n', desc='backspace removes whole cyrillic char')
    finally:
        s.close()


def test_editor_cyrillic_typing(sandbox):
    s = make_session(sandbox)
    try:
        s.wait_text('a.txt')
        s.click_on('a.txt', panel='left')
        s.key('F4')
        s.wait_text('1:1')
        s.send('ы')
        s.wait_text('1:2')              # cursor moved one codepoint
        s.key('F2')
        s.wait_for(lambda x: (sandbox / 'left' / 'a.txt').read_text() ==
                   'ыaaa\n', desc='cyrillic char inserted and saved')
    finally:
        s.close()


def test_cmdline_cyrillic(dn, sandbox):
    dn.send('echo привет > из_команды.txt')
    dn.wait_for(lambda s: 'привет' in s.display()[22], desc='cyrillic typed')
    dn.key('ENTER')
    dn.wait_text('из_команды.txt')
    assert (sandbox / 'left' / 'из_команды.txt').read_text().strip() == 'привет'


def test_mkdir_cyrillic(dn, sandbox):
    dn.key('F7')
    dn.wait_text('Directory name:')
    dn.send('папка')
    dn.wait_text('папка')
    dn.key('ENTER')
    dn.wait_for(lambda s: (sandbox / 'left' / 'папка').is_dir(),
                desc='cyrillic directory created')
    dn.wait_text('>SUB-DIR<')


def test_viewer_cyrillic(sandbox):
    (sandbox / 'left' / 'ru2.txt').write_text('строка один\nстрока два\n')
    s = make_session(sandbox)
    try:
        s.wait_text('ru2.txt')
        s.click_on('ru2.txt', panel='left')
        s.key('F3')
        s.wait_text('строка один')
        s.send('q')
    finally:
        s.close()
