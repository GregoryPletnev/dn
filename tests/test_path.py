"""The `dn` PATH hint and the `--install-path` command."""

import fcntl
import os
import pty
import struct
import subprocess
import termios
import time

from conftest import ROOT

DN = os.path.join(ROOT, 'bin', 'dn')
BASE_PATH = '/usr/bin:/bin'


def _launch(sandbox, argv0, path=BASE_PATH, cwd=None):
    """Run dn on a pty with argv[0] = argv0. Returns (proc, master_fd)."""
    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    env = os.environ.copy()
    env.pop('DN_NO_PATH_HINT', None)
    env.pop('XDG_BIN_HOME', None)
    env.update({'TERM': 'xterm-256color', 'LC_ALL': 'en_US.UTF-8',
                'DN_CONFIG_DIR': str(sandbox / 'cfg'),
                'HOME': str(sandbox / 'home'),
                'PATH': path})
    proc = subprocess.Popen([argv0, str(sandbox / 'left'),
                             str(sandbox / 'right')],
                            executable=DN, stdin=slave, stdout=slave,
                            stderr=slave, env=env, cwd=cwd or str(sandbox),
                            close_fds=True, start_new_session=True)
    os.close(slave)
    return proc, master


def _read_until_exit(proc, master, timeout=8.0):
    """Read pty output until the process exits; return the raw bytes."""
    fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)
    out = b''
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = os.read(master, 65536)
            if chunk:
                out += chunk
        except (BlockingIOError, OSError):
            pass
        if proc.poll() is not None:
            time.sleep(0.2)
            try:
                while True:
                    chunk = os.read(master, 65536)
                    if not chunk:
                        break
                    out += chunk
            except (BlockingIOError, OSError):
                pass
            break
        time.sleep(0.02)
    return out


def _run_and_quit(sandbox, argv0, **kw):
    proc, master = _launch(sandbox, argv0, **kw)
    try:
        time.sleep(2.0)
        os.write(master, b'\x1b[21~')      # F10: quit
        return _read_until_exit(proc, master)
    finally:
        if proc.poll() is None:
            proc.kill()
        os.close(master)


def _install(home, argv, path=BASE_PATH, cwd=None, extra_env=None):
    env = {'PATH': path}
    if home is not None:
        env['HOME'] = str(home)
    env.update(extra_env or {})
    return subprocess.run(argv, env=env, cwd=cwd, capture_output=True,
                          text=True, timeout=30)


def _link(home):
    return home / '.local' / 'bin' / 'dn'


def _points_at_dn(link):
    return link.is_symlink() and \
        os.path.realpath(link) == os.path.realpath(DN)


def test_install_path_creates_symlink(tmp_path):
    home = tmp_path / 'home'
    home.mkdir()
    r = _install(home, [DN, '--install-path'])
    assert r.returncode == 0, r.stderr
    assert _points_at_dn(_link(home)), r.stdout + r.stderr
    assert 'is not in PATH' in r.stdout


def test_install_path_is_idempotent(tmp_path):
    home = tmp_path / 'home'
    home.mkdir()
    for _ in range(2):
        r = _install(home, [DN, '--install-path'])
        assert r.returncode == 0, r.stderr
    assert _points_at_dn(_link(home))


def test_install_path_through_the_link_keeps_it(tmp_path):
    # Running the installed link itself must not make it point at itself.
    home = tmp_path / 'home'
    home.mkdir()
    assert _install(home, [DN, '--install-path']).returncode == 0
    link = _link(home)
    r = _install(home, [str(link), '--install-path'])
    assert r.returncode == 0, r.stderr
    assert _points_at_dn(link), os.readlink(link)


def test_install_path_by_bare_name(tmp_path):
    # `dn --install-path` found through PATH, run from an unrelated cwd.
    home = tmp_path / 'home'
    home.mkdir()
    path = os.path.dirname(DN) + ':' + BASE_PATH
    r = _install(home, ['dn', '--install-path'], path=path,
                 cwd=str(tmp_path))
    assert r.returncode == 0, r.stderr
    assert _points_at_dn(_link(home))


def test_install_path_replaces_dangling_link(tmp_path):
    home = tmp_path / 'home'
    link = _link(home)
    link.parent.mkdir(parents=True)
    link.symlink_to(tmp_path / 'moved' / 'dn')
    r = _install(home, [DN, '--install-path'])
    assert r.returncode == 0, r.stderr
    assert _points_at_dn(link)


def test_install_path_without_home(tmp_path):
    r = _install(None, [DN, '--install-path'])
    assert r.returncode == 1
    assert 'HOME is not set' in r.stderr


def test_path_hint_shown_once_on_exit(sandbox):
    # A path-qualified launch with no dn in PATH prints the hint after the
    # TUI exits and remembers it, so the next launch stays quiet.
    (sandbox / 'home').mkdir(exist_ok=True)
    out = _run_and_quit(sandbox, DN)
    assert b'not in PATH' in out, out
    assert DN.encode() + b' --install-path' in out, out
    assert 'path_hint_shown=1' in (sandbox / 'cfg' / 'options').read_text()

    out2 = _run_and_quit(sandbox, DN)
    assert b'not in PATH' not in out2


def test_path_hint_silent_for_bare_name_launch(sandbox):
    # The shell found `dn` through PATH, so there is nothing to suggest.
    (sandbox / 'home').mkdir(exist_ok=True)
    path = os.path.dirname(DN) + ':' + BASE_PATH
    out = _run_and_quit(sandbox, 'dn', path=path)
    assert b'not in PATH' not in out, out
