"""Find File (Alt-F7): the DN dialog, results in the panel as DN's find
drive, going to a hit, and the type-by-content filter."""

import subprocess

import pytest

from conftest import make_session

# field order in the dialog
F_MASK, F_TEXT, F_HEX, F_TYPE = 0, 1, 2, 3


@pytest.fixture
def tree(sandbox):
    left = sandbox / 'left'
    (left / 'notes.txt').write_text('find the needle here\n')
    (left / 'sub').mkdir()
    (left / 'sub' / 'deep.md').write_text('another needle\n')
    (left / 'sub' / 'plain.txt').write_text('nothing to see\n')
    (left / '.secret').write_text('needle\n')
    subprocess.run(['sqlite3', str(left / 'sub' / 'archive.bin'),
                    'create table t(a);'], check=True)
    (left / 'fake.db').write_text('not a database\n')
    return sandbox


def open_find(s):
    s.wait_text('notes.txt')
    s.key('ALT_F7')
    s.wait_text('Find File')
    s.wait_text('Text to find')


def goto_field(s, n):
    for _ in range(n):
        s.key('DOWN')


def test_text_search_lists_hits_in_the_panel(tree):
    s = make_session(tree)
    try:
        open_find(s)
        goto_field(s, F_TEXT)
        s.send('needle')
        s.key('ENTER')
        s.wait_text('find: * "needle" in left')     # the panel title
        s.wait_text('sub/deep.md')
        assert s.row_of('notes.txt') is not None
        assert s.row_of('plain.txt') is None
        assert s.row_of('.secret') is None          # hidden files are off
        s.click_on('sub/deep.md', panel='left')
        s.key('F3')                                 # view works on the hit
        s.wait_text('another needle')
        s.key('ESC')
        s.wait_gone('another needle')
        s.click_on('sub/deep.md', panel='left')
        s.key('ENTER')                              # go to the file
        s.wait_for(lambda x: (tree / 'left' / 'sub').name in x.display()[1]
                   and 'deep.md' in x.cursor_bar_text(),
                   desc='the panel is in sub/ with the cursor on deep.md')
        assert s.row_of('plain.txt') is not None    # a real directory now
    finally:
        s.close()


def test_dotdot_leaves_the_results(tree):
    s = make_session(tree)
    try:
        open_find(s)
        goto_field(s, F_TEXT)
        s.send('needle')
        s.key('ENTER')
        s.wait_text('find: ')
        s.click_on('..', panel='left')
        s.key('ENTER')
        s.wait_gone('find: ')
        s.wait_text('fake.db')                      # back in left/
    finally:
        s.close()


def test_type_by_content_finds_a_renamed_database(tree):
    s = make_session(tree)
    try:
        open_find(s)
        goto_field(s, F_TYPE)
        s.key('ENTER')                              # the drop-down tree opens
        s.wait_text('▸ Images (all)')
        assert s.row_of('PNG') is None              # groups start folded
        s.send('D')                                 # Documents,
        s.send('D')                                 # then Databases
        s.key('RIGHT')                              # unfold it
        s.wait_text('▾ Databases (all)')
        s.key('DOWN')
        s.key('ENTER')                              # SQLite
        s.wait_gone('▾ Databases (all)')
        assert any(l.find('SQLite') > 0 and '▾' in l for l in s.display())
        s.key('UP')
        s.key('ENTER')                              # Enter on another field: run
        s.wait_text('[SQLite]')
        s.wait_text('sub/archive.bin')
        assert s.row_of('fake.db') is None          # the name says db, the bytes do not
    finally:
        s.close()


def test_hex_string(tree):
    s = make_session(tree)
    try:
        open_find(s)
        goto_field(s, F_HEX)
        s.send('53 51 4c 69 74 65')                 # 'SQLite'
        s.key('ENTER')
        s.wait_text('sub/archive.bin')
    finally:
        s.close()


def test_nothing_found(tree):
    s = make_session(tree)
    try:
        open_find(s)
        s.key('CTRL_U')
        s.send('*.nothing')
        s.key('ENTER')
        s.wait_text('No files found')
    finally:
        s.close()


def test_delete_from_the_results(tree):
    s = make_session(tree)
    try:
        open_find(s)
        s.key('CTRL_U')
        s.send('plain.txt')
        s.key('ENTER')
        s.wait_text('sub/plain.txt')
        s.click_on('sub/plain.txt', panel='left')
        s.key('F8')                                 # the real file goes
        s.wait_text('Delete')
        s.key('ENTER')
        s.wait_gone('sub/plain.txt')
        assert not (tree / 'left' / 'sub' / 'plain.txt').exists()
    finally:
        s.close()


def test_a_whole_group_from_the_tree(tree):
    (tree / 'left' / 'shot.dat').write_bytes(b'\x89PNG\r\n\x1a\n' + b'\0' * 16)
    s = make_session(tree)
    try:
        open_find(s)
        goto_field(s, F_TYPE)
        s.key('ENTER')
        s.wait_text('Images (all)')
        s.send('I')                                 # Images (all) itself
        s.key('ENTER')
        s.key('UP')
        s.key('ENTER')
        s.wait_text('[Images]')
        s.wait_text('shot.dat')
    finally:
        s.close()
