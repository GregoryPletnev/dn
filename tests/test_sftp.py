"""M3: RemoteFS over sftp (Navigator Link replacement). The transport is
a fake sftp client (fakesftp.py) driven через DN_SFTP_CMD, so the whole
stack — URL parsing, batch generation, listing parse, panel integration,
transfers — is exercised without a real sshd."""

import os
import sys

import pytest

from conftest import make_session

FAKE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fakesftp.py')


@pytest.fixture
def remote_root(sandbox):
    r = sandbox / 'remote'
    (r / 'docs').mkdir(parents=True)
    (r / 'hello.txt').write_text('remote hello\n')
    (r / 'docs' / 'deep.txt').write_text('deep file\n')
    return r


@pytest.fixture
def dns(sandbox, remote_root):
    s = make_session(sandbox, env={
        'DN_SFTP_CMD': '%s %s' % (sys.executable, FAKE),
        'FAKE_SFTP_ROOT': str(remote_root),
    })
    s.wait_text('a.txt')
    yield s
    s.close()


def connect(s):
    s.send('cd sftp://user@fakehost/')
    s.key('ENTER')
    s.wait_text('hello.txt')
    assert 'sftp://user@fakehost' in s.display()[1], s.dump()[:500]


def test_connect_and_browse(dns):
    connect(dns)
    dns.click_on('docs', panel='left')
    dns.key('ENTER')
    dns.wait_text('deep.txt')
    assert 'sftp://user@fakehost/docs' in dns.display()[1]
    dns.key('BACKSPACE')
    dns.wait_text('hello.txt')


def test_connect_failure_dialog(dns):
    dns.send('cd sftp://badhost/')
    dns.key('ENTER')
    dns.wait_text('Cannot connect')
    dns.key('ENTER')
    assert dns.alive()


def test_view_remote_file(dns):
    connect(dns)
    dns.click_on('hello.txt', panel='left')
    dns.key('F3')
    dns.wait_text('remote hello')
    dns.send('q')


def test_copy_from_remote(dns, sandbox):
    connect(dns)
    dns.click_on('hello.txt', panel='left')
    dns.key('F5')
    dns.wait_text('Copy "hello.txt"')
    dns.key('ENTER')
    dns.wait_for(lambda s: (sandbox / 'right' / 'hello.txt').exists(),
                 desc='downloaded to the right panel')
    assert (sandbox / 'right' / 'hello.txt').read_text() == 'remote hello\n'


def test_copy_dir_from_remote(dns, sandbox):
    connect(dns)
    dns.click_on('docs', panel='left')
    dns.key('F5')
    dns.wait_text('Copy "docs"')
    dns.key('ENTER')
    dns.wait_for(lambda s: (sandbox / 'right' / 'docs' / 'deep.txt').exists(),
                 desc='directory downloaded')


def test_copy_to_remote(dns, sandbox, remote_root):
    connect(dns)
    dns.key('TAB')
    dns.click_on('r.txt', panel='right')
    dns.key('F5')
    dns.wait_text('Copy "r.txt"')
    dns.key('ENTER')
    dns.wait_for(lambda s: (remote_root / 'r.txt').exists(),
                 desc='uploaded to the remote root')
    dns.key('TAB')
    dns.key('CTRL_R')
    dns.wait_text('r.txt')


def test_copy_dir_to_remote(dns, sandbox, remote_root):
    # left panel stays local, right panel connects to the fake host
    dns.key('TAB')
    dns.send('cd sftp://user@fakehost/')
    dns.key('ENTER')
    dns.wait_text('hello.txt')
    dns.key('TAB')                            # back to the local left panel
    dns.click_on('alpha', panel='left')
    dns.key('F5')
    dns.wait_text('Copy "alpha"')
    dns.key('ENTER')
    dns.wait_for(lambda s: (remote_root / 'alpha' / 'inner.txt').exists(),
                 desc='directory uploaded recursively')


def test_delete_remote_recursive(dns, remote_root):
    connect(dns)
    dns.click_on('docs', panel='left')
    dns.key('F8')
    dns.wait_text('Delete "docs"')
    dns.key('ENTER')
    dns.wait_for(lambda s: not (remote_root / 'docs').exists(),
                 desc='remote dir removed recursively')


def test_mkdir_remote(dns, remote_root):
    connect(dns)
    dns.key('F7')
    dns.wait_text('Directory name:')
    dns.send('newremote')
    dns.key('ENTER')
    dns.wait_for(lambda s: (remote_root / 'newremote').is_dir(),
                 desc='remote mkdir')


def test_move_from_remote_deletes_source(dns, sandbox, remote_root):
    connect(dns)
    dns.click_on('hello.txt', panel='left')
    dns.key('F6')
    dns.wait_text('Move "hello.txt"')
    dns.key('ENTER')
    dns.wait_for(lambda s: (sandbox / 'right' / 'hello.txt').exists() and
                 not (remote_root / 'hello.txt').exists(),
                 desc='moved: downloaded and removed remotely')
