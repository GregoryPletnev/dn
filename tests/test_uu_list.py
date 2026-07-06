"""M3: UU-encode/decode via the Commands menu, and the Ctrl-W list panel."""

import subprocess

from conftest import make_session


def test_uu_encode_then_decode_roundtrip(dn, sandbox):
    (sandbox / 'left' / 'payload.bin').write_bytes(bytes(range(256)))
    dn.key('CTRL_R')
    dn.click_on('payload.bin', panel='left')
    # Commands menu -> UU-encode
    dn.click_on('Commands')
    dn.wait_text('UU-encode')
    dn.click_on('UU-encode')
    dn.wait_text('payload.bin.uue')
    assert (sandbox / 'left' / 'payload.bin.uue').exists()
    # decode it back
    dn.click_on('payload.bin.uue', panel='left')
    dn.click_on('Commands')
    dn.wait_text('UU-decode')
    dn.click_on('UU-decode')
    dn.wait_text('payload.bin.decoded')
    assert (sandbox / 'left' / 'payload.bin.decoded').read_bytes() == bytes(range(256))


def test_uu_output_matches_system_uudecode(dn, sandbox):
    (sandbox / 'left' / 'msg.txt').write_text('interop check\nsecond line\n')
    dn.key('CTRL_R')
    dn.click_on('msg.txt', panel='left')
    dn.click_on('Commands')
    dn.wait_text('UU-encode')
    dn.click_on('UU-encode')
    dn.wait_text('msg.txt.uue')
    uue = sandbox / 'left' / 'msg.txt.uue'
    out = sandbox / 'sysout'
    r = subprocess.run(['uudecode', '-o', str(out), str(uue)],
                       capture_output=True, text=True)
    if r.returncode != 0:                    # uudecode not present -> skip
        import pytest
        pytest.skip('system uudecode unavailable')
    assert out.read_text() == 'interop check\nsecond line\n'


def test_ctrl_w_list_panel(dn, sandbox):
    left = sandbox / 'left'
    (left / 'one.txt').write_text('1')
    (left / 'two.txt').write_text('2')
    (left / 'mylist').write_text('one.txt\ntwo.txt\nalpha/inner.txt\n')
    dn.key('CTRL_R')
    dn.send('\x17')                          # Ctrl-W
    dn.wait_text('List file')
    dn.send('mylist')
    dn.key('ENTER')
    dn.wait_text('list:mylist')              # panel title switched to the VFS
    assert dn.row_of('one.txt') is not None
    assert dn.row_of('inner.txt') is not None, 'listed a file from a subdir'
    # copy a listed file out to the right panel
    dn.click_on('inner.txt', panel='left')
    dn.key('F5')
    dn.wait_text('Copy "inner.txt"')
    dn.key('ENTER')
    dn.wait_for(lambda s: (sandbox / 'right' / 'inner.txt').exists(),
                desc='listed file copied out')
    # leave the list panel
    dn.send('cd ' + str(left))
    dn.key('ENTER')
    dn.wait_text('mylist')
