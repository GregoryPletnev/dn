"""Disk-image auto-mount (hdiutil): Enter on a .dmg opens it as a directory."""

import shutil
import subprocess

import pytest

hdiutil = shutil.which('hdiutil')


@pytest.mark.skipif(not hdiutil, reason='hdiutil not available (macOS only)')
def test_enter_dmg_mounts_and_up_returns(dn, sandbox):
    vol = sandbox / 'volsrc'
    vol.mkdir()
    (vol / 'inside_dmg.txt').write_text('payload\n')
    dmg = sandbox / 'left' / 'test.dmg'
    subprocess.run(['hdiutil', 'create', '-srcfolder', str(vol),
                    '-volname', 'DNTEST', '-quiet', str(dmg)], check=True)
    dn.key('CTRL_R')
    dn.wait_text('test.dmg')
    dn.click_on('test.dmg', panel='left')
    dn.key('ENTER')
    dn.wait_text('inside_dmg.txt', timeout=20)

    dn.key('HOME')                      # cursor to '..'
    dn.key('ENTER')                     # leave the image root
    dn.wait_for(lambda s: 'test.dmg' in s.cursor_bar_text(), timeout=20,
                desc='back in the local dir, cursor on the image')


@pytest.mark.skipif(not hdiutil, reason='hdiutil not available (macOS only)')
def test_copy_out_of_dmg(dn, sandbox):
    vol = sandbox / 'volsrc2'
    vol.mkdir()
    (vol / 'take_me.txt').write_text('cargo\n')
    dmg = sandbox / 'left' / 'data.dmg'
    subprocess.run(['hdiutil', 'create', '-srcfolder', str(vol),
                    '-volname', 'DNDATA', '-quiet', str(dmg)], check=True)
    dn.key('CTRL_R')
    dn.wait_text('data.dmg')
    dn.click_on('data.dmg', panel='left')
    dn.key('ENTER')
    dn.wait_text('take_me.txt', timeout=20)
    dn.click_on('take_me.txt', panel='left')
    dn.key('F5')
    dn.wait_text('Copy "take_me.txt" to')
    dn.key('ENTER')
    dn.wait_for(lambda s: (sandbox / 'right' / 'take_me.txt').exists(),
                timeout=20, desc='file copied out of the image')
    assert (sandbox / 'right' / 'take_me.txt').read_text() == 'cargo\n'
