"""Syntax highlighting (dnhighlite) and idle screen savers (dnsaver)."""

from conftest import make_session


def test_editor_syntax_highlight(sandbox):
    (sandbox / 'left' / 'code.pas').write_text('begin zz // note\n')
    s = make_session(sandbox)
    try:
        s.wait_text('code.pas')
        s.click_on('code.pas', panel='left')
        s.key('F4')
        s.wait_text('1:1')
        s.wait_text('begin zz')
        row = s.row_of('begin zz')
        line = s.display()[row]
        # column 0 holds the editor cursor (inverse video): sample the 'e'
        kw = s.cell(row, line.index('begin') + 1)
        com = s.cell(row, line.index('//'))
        plain = s.cell(row, line.index('zz'))
        assert kw.bold, 'keyword is bold'
        assert com.bold and com.fg == 'black', 'comment is dark gray'
        assert not plain.bold, 'plain text is not bold'
    finally:
        s.close()


def test_editor_multiline_comment(sandbox):
    (sandbox / 'left' / 'ml.pas').write_text('{ first\nmiddle\nlast }\nbegin\n')
    s = make_session(sandbox)
    try:
        s.wait_text('ml.pas')
        s.click_on('ml.pas', panel='left')
        s.key('F4')
        s.wait_text('1:1')
        s.wait_text('middle')
        row = s.row_of('middle')
        line = s.display()[row]
        mid = s.cell(row, line.index('middle') + 1)
        assert mid.fg == 'black' and mid.bold, \
            'line inside a multi-line comment is highlighted as comment'
        krow = s.row_of('begin')
        kline = s.display()[krow]
        assert s.cell(krow, kline.index('begin') + 1).bold, \
            'code after the comment is highlighted again'
    finally:
        s.close()


def test_viewer_syntax_highlight(sandbox):
    (sandbox / 'left' / 'prog.c').write_text('int x; /* c */\n')
    s = make_session(sandbox)
    try:
        s.wait_text('prog.c')
        s.click_on('prog.c', panel='left')
        s.key('F3')
        s.wait_text('lines')            # viewer status bar
        s.wait_text('int x;')
        row = s.row_of('int x;')
        line = s.display()[row]
        assert s.cell(row, line.index('int')).bold, 'c keyword is bold'
        assert s.cell(row, line.index('/*')).fg == 'black', 'comment colored'
    finally:
        s.close()


def test_syntax_checkbox_toggles_in_menu(dn):
    dn.click_on('Options')
    dn.wait_text('[x] Syntax highlight')
    row = dn.row_of('[x] Syntax highlight')
    col = dn.display()[row].index('[x]')
    dn.mouse(col + 1, row)              # unticks, menu stays open
    dn.wait_text('[ ] Syntax highlight')
    dn.mouse(col + 1, row)              # ...and back
    dn.wait_text('[x] Syntax highlight')
    dn.key('ESC')
    dn.wait_gone('[x] Syntax highlight')


def test_syntax_toggle_affects_editor(sandbox):
    (sandbox / 'left' / 'off.pas').write_text('begin zz\n')
    s = make_session(sandbox)
    try:
        s.wait_text('off.pas')
        s.click_on('off.pas', panel='left')
        s.key('F4')
        s.wait_text('begin zz')
        row = s.row_of('begin zz')
        col = s.display()[row].index('begin') + 1
        s.wait_for(lambda x: x.cell(row, col).bold, desc='keyword bold with hl on')
        s.click_on('Options')
        s.click_on('[x] Syntax highlight')
        s.key('ESC')
        s.wait_for(lambda x: not x.cell(row, col).bold,
                   desc='keyword plain with hl off')
    finally:
        s.close()


def test_markdown_highlight_in_viewer(sandbox):
    (sandbox / 'left' / 'doc.md').write_text('# Head\ntext\n')
    s = make_session(sandbox)
    try:
        s.wait_text('doc.md')
        s.click_on('doc.md', panel='left')
        s.key('F3')
        s.wait_text('# Head')
        row = s.row_of('# Head')
        line = s.display()[row]
        assert s.cell(row, line.index('Head')).bold, 'md header is bold'
        trow = s.row_of('text')
        assert not s.cell(trow, s.display()[trow].index('text')).bold, \
            'md prose is plain'
    finally:
        s.close()


def test_screensaver_starts_and_wake_key_is_consumed(sandbox):
    s = make_session(sandbox, env={'DN_SAVER_SECONDS': '2'})
    try:
        s.wait_text('a.txt')
        # ~2 idle seconds later the saver blanks the whole UI
        s.wait_gone('Left', timeout=10)
        assert all('a.txt' not in l for l in s.display()), s.dump()
        # any key wakes it up and is swallowed, not typed into the cmdline
        s.send('Z')
        s.wait_text('Left', timeout=5)
        s.wait_text('a.txt')
        assert all('Z' not in l for l in s.display()), s.dump()
    finally:
        s.close()
