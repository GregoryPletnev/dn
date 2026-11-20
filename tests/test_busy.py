"""Slow external commands show a progress box (dnvfs.RunBusyHook): title,
file name, a moving bar, a counter, elapsed time, and Esc to cancel.
A slow `bsdtar` on PATH stands in for a large archive."""

import os
import shutil
import subprocess
import time

import pytest

from conftest import make_session

REAL_BSDTAR = shutil.which('bsdtar')


@pytest.fixture
def slow_sandbox(sandbox):
    left = sandbox / 'left'
    stage = sandbox / 'stage'
    stage.mkdir()
    for i in range(30):
        (stage / ('f%02d.txt' % i)).write_text('x\n')
    subprocess.run(['zip', '-qr', str(left / 'big.zip'), '.'], cwd=stage,
                   check=True)
    return sandbox


def slow_session(sandbox, delay):
    """dn whose bsdtar waits `delay` seconds, printing one listing line
    first, so the box has something to count."""
    fake = sandbox / 'fakebin'
    fake.mkdir(exist_ok=True)
    tool = fake / 'bsdtar'
    tool.write_text('#!/bin/sh\necho "first line"\nsleep %s\nexec %s "$@"\n'
                    % (delay, REAL_BSDTAR))
    tool.chmod(0o755)
    path = str(fake) + os.pathsep + os.environ.get('PATH', '')
    s = make_session(sandbox, env={'PATH': path})
    s.wait_text('big.zip')
    s.click_on('big.zip', panel='left')
    return s


needs_bsdtar = pytest.mark.skipif(REAL_BSDTAR is None, reason='no bsdtar')


@needs_bsdtar
def test_slow_archive_shows_progress_box(slow_sandbox):
    s = slow_session(slow_sandbox, 2)
    try:
        s.key('ENTER')
        s.wait_text('Reading archive')
        assert s.row_of('big.zip') is not None
        s.wait_text('entries')                  # the line counter
        assert s.row_of('Esc cancel') is not None
        assert any('█' in l for l in s.display()), 'no progress bar drawn'
        s.wait_text('f00.txt', timeout=10)      # the listing arrives
        s.wait_gone('Reading archive')
    finally:
        s.close()


@needs_bsdtar
def test_esc_cancels_a_slow_command(slow_sandbox):
    s = slow_session(slow_sandbox, 30)
    try:
        s.key('ENTER')
        s.wait_text('Reading archive')
        t0 = time.time()
        s.key('ESC')
        s.wait_text('cancelled', timeout=5)     # the error box says why
        assert time.time() - t0 < 5
        assert s.row_of('f00.txt') is None      # did not enter the archive
        # the whole command was stopped, not only the shell around it
        out = subprocess.run(['pgrep', '-f', 'sleep 30'],
                             capture_output=True, text=True).stdout
        assert out.strip() == '', 'the slow command kept running'
        assert s.alive()
    finally:
        s.close()


def test_quick_commands_show_no_box(sandbox):
    """the box waits 300 ms: a fast listing never flashes it"""
    left = sandbox / 'left'
    stage = sandbox / 'stage'
    stage.mkdir()
    (stage / 'a.txt').write_text('a\n')
    subprocess.run(['zip', '-qr', str(left / 'small.zip'), '.'], cwd=stage,
                   check=True)
    s = make_session(sandbox)
    try:
        s.wait_text('small.zip')
        s.click_on('small.zip', panel='left')
        start = len(s.raw)
        s.key('ENTER')
        s.wait_text('a.txt')
        assert b'Reading archive' not in s.raw[start:]
    finally:
        s.close()
