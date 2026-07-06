"""M3: SSH connection manager (à la redial) — sessions file, tree UI,
connect via the fake sftp transport, add/edit/delete."""

import os
import sys

import pytest

from conftest import make_session

FAKE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fakesftp.py')


def write_sessions(sandbox, text):
    cfg = sandbox / 'cfg'
    cfg.mkdir(exist_ok=True)
    (cfg / 'sessions').write_text(text)


@pytest.fixture
def remote_root(sandbox):
    r = sandbox / 'remote'
    r.mkdir()
    (r / 'server_file.txt').write_text('on the server\n')
    return r


@pytest.fixture
def dnm(sandbox, remote_root):
    write_sessions(sandbox, (
        "#folder: work\n"
        "Host db1\n"
        "    HostName fakehost\n"
        "    User admin\n"
        "    #dn-dir /\n"
        "\n"
        "#folder: \n"
        "Host home\n"
        "    HostName fakehost\n"
    ))
    s = make_session(sandbox, env={
        'DN_SFTP_CMD': '%s %s' % (sys.executable, FAKE),
        'FAKE_SFTP_ROOT': str(remote_root),
    })
    s.wait_text('a.txt')
    yield s
    s.close()


def open_mgr(s):
    s.send('\x13')                          # Ctrl-S
    s.wait_text('SSH Sessions')


def test_open_manager_shows_tree(dnm):
    open_mgr(dnm)
    assert dnm.row_of('[+] work') is not None or dnm.row_of('[-] work') is not None
    assert dnm.row_of('home') is not None    # top-level session
    dnm.key('ESC')
    dnm.wait_gone('SSH Sessions')


def test_expand_folder_reveals_session(dnm):
    open_mgr(dnm)
    # 'work' is collapsed initially; db1 hidden
    assert dnm.row_of('db1') is None
    dnm.click_on('work')                     # select the folder row
    dnm.key('ENTER')                         # expand
    dnm.wait_text('db1')
    assert dnm.row_of('[-] work') is not None


def test_connect_from_manager(dnm):
    open_mgr(dnm)
    dnm.click_on('home')
    dnm.key('ENTER')                         # connect
    dnm.wait_gone('SSH Sessions')
    dnm.wait_text('server_file.txt')         # remote panel populated
    assert 'sftp://home' in dnm.display()[1]


def test_connect_nested_session_uses_start_dir(dnm):
    open_mgr(dnm)
    dnm.click_on('work')
    dnm.key('ENTER')                         # expand
    dnm.wait_text('db1')
    dnm.click_on('db1')
    dnm.key('ENTER')                         # connect
    dnm.wait_gone('SSH Sessions')
    dnm.wait_text('server_file.txt')
    assert 'sftp://db1' in dnm.display()[1]


def test_add_session_persists(dnm, sandbox):
    open_mgr(dnm)
    dnm.key('INSERT')
    dnm.wait_text('Alias (Host):')
    dnm.send('newbox')
    dnm.key('ENTER')                         # Alias
    dnm.wait_text('HostName:')
    dnm.send('fakehost')
    dnm.key('ENTER')                         # HostName
    for _ in range(5):                       # User, Port, Identity, Folder, Dir
        dnm.wait_text(':')
        dnm.key('ENTER')
    dnm.wait_text('newbox')
    text = (sandbox / 'cfg' / 'sessions').read_text()
    assert 'Host newbox' in text
    assert 'HostName fakehost' in text
    dnm.key('ESC')


def test_delete_session(dnm, sandbox):
    open_mgr(dnm)
    dnm.click_on('home')
    dnm.key('DELETE')
    dnm.wait_text('Delete session')
    dnm.key('ENTER')                         # Yes
    dnm.wait_gone('Delete session')
    assert dnm.row_of('home') is None
    assert 'Host home' not in (sandbox / 'cfg' / 'sessions').read_text()
    dnm.key('ESC')


def test_empty_state_hint(sandbox):
    # no sessions file at all
    s = make_session(sandbox)
    try:
        s.wait_text('a.txt')
        s.send('\x13')                       # Ctrl-S
        s.wait_text('SSH Sessions')
        assert s.row_of('No saved sessions') is not None
        assert s.row_of('Add') is not None    # footer button
        s.key('ESC')
        s.wait_gone('SSH Sessions')
    finally:
        s.close()


def test_f1_help_in_manager(dnm):
    open_mgr(dnm)
    dnm.key('F1')
    dnm.wait_text('ssh-copy-id')              # help text body
    dnm.key('ENTER')                          # close help
    dnm.wait_gone('ssh-copy-id')
    dnm.wait_text('SSH Sessions')             # back to the manager
    dnm.key('ESC')


def test_footer_button_add_clickable(dnm, sandbox):
    open_mgr(dnm)
    dnm.click_on('Add')                       # footer button, not a hotkey
    dnm.wait_text('Alias (Host):')
    dnm.send('clickadd')
    dnm.key('ENTER')
    dnm.wait_text('HostName:')
    for _ in range(6):
        dnm.wait_text(':')
        dnm.key('ENTER')
    dnm.wait_text('clickadd')
    assert 'Host clickadd' in (sandbox / 'cfg' / 'sessions').read_text()
    dnm.key('ESC')


def test_footer_button_connect_clickable(dnm):
    open_mgr(dnm)
    dnm.click_on('home')                      # select the session row
    dnm.click_on('Connect')                   # footer button
    dnm.wait_gone('SSH Sessions')
    dnm.wait_text('server_file.txt')


def test_footer_esc_button_closes(dnm):
    open_mgr(dnm)
    dnm.click_on('Esc')                       # footer close button
    dnm.wait_gone('SSH Sessions')
    assert dnm.alive()


def test_sessions_file_is_valid_ssh_config(dnm, sandbox):
    """ssh -G must accept our generated file (add a session, then parse)."""
    open_mgr(dnm)
    dnm.key('INSERT')
    dnm.wait_text('Alias (Host):')
    dnm.send('cfgcheck')
    dnm.key('ENTER')
    dnm.wait_text('HostName:')
    dnm.send('example.com')
    dnm.key('ENTER')
    for _ in range(5):
        dnm.wait_text(':')
        dnm.key('ENTER')
    dnm.wait_text('cfgcheck')
    dnm.key('ESC')

    import subprocess
    r = subprocess.run(
        ['ssh', '-F', str(sandbox / 'cfg' / 'sessions'), '-G', 'cfgcheck'],
        capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert 'hostname example.com' in r.stdout.lower()
