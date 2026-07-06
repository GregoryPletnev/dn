"""M3: archives as directories (DN 3.9) — browse, view, copy in/out, delete."""

import subprocess

import pytest

from conftest import make_session


@pytest.fixture
def arc_sandbox(sandbox):
    """left/ gets data.zip (f1.txt, sub/f2.txt) and data.tgz (same)."""
    left = sandbox / 'left'
    stage = sandbox / 'stage'
    (stage / 'sub').mkdir(parents=True)
    (stage / 'f1.txt').write_text('zip file one\n')
    (stage / 'sub' / 'f2.txt').write_text('zip file two\n')
    subprocess.run(['zip', '-qr', str(left / 'data.zip'), '.'], cwd=stage, check=True)
    subprocess.run(['tar', 'czf', str(left / 'data.tgz'), '.'], cwd=stage, check=True)
    return sandbox


@pytest.fixture
def dna(arc_sandbox):
    s = make_session(arc_sandbox)
    s.wait_text('data.zip')
    yield s
    s.close()


def enter_archive(s, name):
    s.click_on(name, panel='left')
    s.key('ENTER')
    s.wait_text('f1.txt')
    assert '://' in s.display()[1], 'panel title shows the archive path'


def test_browse_zip_and_subdir(dna):
    enter_archive(dna, 'data.zip')
    # 'sub ' with the panel padding: the bare string would also match the
    # test's own tmpdir name shown in the panel title
    assert dna.row_of('sub ') is not None
    dna.click_on('sub ', panel='left')
    dna.key('ENTER')
    dna.wait_text('f2.txt')
    dna.key('BACKSPACE')                    # up to archive root
    dna.wait_text('f1.txt')
    dna.key('BACKSPACE')                    # out of the archive
    dna.wait_text('data.tgz')
    assert 'data.zip' in dna.cursor_bar_text(), 'cursor back on the archive'


def test_browse_tgz(dna):
    enter_archive(dna, 'data.tgz')
    dna.click_on('sub ', panel='left')
    dna.key('ENTER')
    dna.wait_text('f2.txt')


def test_view_file_inside_zip(dna):
    enter_archive(dna, 'data.zip')
    dna.click_on('f1.txt', panel='left')
    dna.key('F3')
    dna.wait_text('zip file one')
    dna.send('q')


def test_copy_out_of_zip(dna, arc_sandbox):
    enter_archive(dna, 'data.zip')
    dna.click_on('f1.txt', panel='left')
    dna.key('F5')
    dna.wait_text('Copy "f1.txt"')
    dna.key('ENTER')
    dna.wait_for(lambda s: (arc_sandbox / 'right' / 'f1.txt').exists(),
                 desc='file extracted to the right panel')
    assert (arc_sandbox / 'right' / 'f1.txt').read_text() == 'zip file one\n'


def test_copy_dir_out_of_zip(dna, arc_sandbox):
    enter_archive(dna, 'data.zip')
    dna.click_on('sub ', panel='left')
    dna.key('F5')
    dna.wait_text('Copy "sub"')
    dna.key('ENTER')
    dna.wait_for(lambda s: (arc_sandbox / 'right' / 'sub' / 'f2.txt').exists(),
                 desc='subtree extracted')


def test_copy_into_zip(dna, arc_sandbox):
    enter_archive(dna, 'data.zip')
    dna.key('TAB')                          # right panel (local)
    dna.click_on('r.txt', panel='right')
    dna.key('F5')
    dna.wait_text('Copy "r.txt"')
    dna.key('ENTER')
    dna.pump(0.5)
    out = subprocess.run(['bsdtar', '-tf', str(arc_sandbox / 'left' / 'data.zip')],
                         capture_output=True, text=True).stdout
    assert 'r.txt' in out, 'file added to the zip: %s' % out
    dna.key('TAB')                          # panel over the zip re-lists it
    dna.key('CTRL_R')
    dna.wait_text('r.txt')


def test_delete_inside_zip(dna, arc_sandbox):
    enter_archive(dna, 'data.zip')
    dna.click_on('f1.txt', panel='left')
    dna.key('F8')
    dna.wait_text('Delete "f1.txt"')
    dna.key('ENTER')
    dna.wait_for(lambda s: s.row_of('f1.txt') is None, desc='gone from panel')
    out = subprocess.run(['bsdtar', '-tf', str(arc_sandbox / 'left' / 'data.zip')],
                         capture_output=True, text=True).stdout
    assert 'f1.txt' not in out


def test_tgz_is_readonly(dna, arc_sandbox):
    enter_archive(dna, 'data.tgz')
    dna.click_on('f1.txt', panel='left')
    dna.key('F8')
    dna.wait_text('Delete "f1.txt"')
    dna.key('ENTER')
    dna.wait_text('only supported')         # error dialog
    dna.key('ENTER')
    assert dna.alive()


def test_edit_inside_zip_writes_back(dna, arc_sandbox):
    enter_archive(dna, 'data.zip')
    dna.click_on('f1.txt', panel='left')
    dna.key('F4')
    dna.wait_text('1:1')
    dna.send('EDITED ')
    dna.key('F2')
    dna.wait_text('Saved')
    dna.key('ESC')
    dna.pump(0.3)
    out = subprocess.run(
        ['bsdtar', '-xOf', str(arc_sandbox / 'left' / 'data.zip'), 'f1.txt'],
        capture_output=True, text=True).stdout
    assert out == 'EDITED zip file one\n', 'zip member updated: %r' % out
