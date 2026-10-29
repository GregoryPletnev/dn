"""Media player window (PLAYER.md): queue, transport, volume, visualizer,
equalizer. The backend is replaced by DN_PLAYER_CMD, so no audio device and no
media toolchain is needed. Arrow-key navigation is avoided: it is unreliable in
this test environment, so rows are picked with the mouse instead."""

import os
import stat

import pytest

from conftest import make_session

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DN = os.path.join(ROOT, 'bin', 'dn')


@pytest.fixture
def music(tmp_path):
    """A small music tree with a nested subdirectory."""
    m = tmp_path / 'music'
    (m / 'sub').mkdir(parents=True)
    for n in ('a.mp3', 'b.mp3'):
        (m / n).write_bytes(b'\x00' * 64)
    (m / 'sub' / 'c.flac').write_bytes(b'\x00' * 64)
    (m / 'notes.txt').write_text('not audio\n')
    return m


@pytest.fixture
def pl(music, tmp_path):
    """A session with the fake backend and the analyzer in fake mode."""
    env = {'DN_PLAYER_CMD': _fake_backend(tmp_path) + ' %f %s',
           'DN_PLAYER_NO_ANALYZER': '1'}
    s = make_session(tmp_path, env=env, left=music, right=tmp_path)
    s.wait_text('a.mp3')
    yield s
    s.close()


def _fake_backend(tmp_path):
    """A backend that prints PLAYING <args> and sleeps: no audio at all."""
    sh = tmp_path / 'fakeplay.sh'
    sh.write_text('#!/bin/sh\necho PLAYING "$@"\nsleep 30\n')
    sh.chmod(sh.stat().st_mode | stat.S_IEXEC)
    return str(sh)


def open_player(s):
    """Open the player from the Tools menu (arrows are unreliable here)."""
    s.click_on('Tools')
    s.click_on('Player')
    s.wait_text('Player')


def screen(s):
    """The whole visible screen as one string."""
    return '\n'.join(s.display())


def test_open_player_queues_directory(pl):
    """Tools > Player queues the panel directory recursively: a.mp3, b.mp3 and
    the nested sub/c.flac, but not notes.txt."""
    open_player(pl)
    pl.wait_text('♪ 1/3')
    screen = '\n'.join(pl.display())
    assert 'a.mp3' in screen
    assert 'b.mp3' in screen
    assert 'c.flac' in screen, screen
    assert 'notes.txt' not in screen, screen


def test_player_status_line(pl):
    open_player(pl)
    pl.wait_for(lambda s: 'repeat:' in screen(s), desc='player status line')
    assert 'repeat: all' in screen(pl)
    assert 'shuffle: off' in screen(pl)
    assert 'vol 80%' in screen(pl)


def test_volume_up_and_down(pl):
    open_player(pl)
    pl.wait_text('Vol [')
    pl.send('+')
    pl.wait_text('85%')
    pl.send('-')
    pl.wait_text('80%')


def test_volume_mute(pl):
    open_player(pl)
    pl.wait_text('Vol [')
    pl.send('m')
    pl.wait_text('MUTE')
    pl.send('m')
    pl.wait_gone('MUTE')


def test_visualizer_cycles(pl):
    open_player(pl)
    pl.wait_text('Vol [')
    pl.send('v')                       # bars
    pl.wait_for(lambda s: 'viz: bars' in screen(s),
                desc='visualizer bars in the status line')
    pl.send('v')                       # scope
    pl.wait_for(lambda s: 'viz: scope' in screen(s),
                desc='visualizer scope in the status line')
    pl.send('v')                       # off
    pl.wait_for(lambda s: 'viz:' not in screen(s),
                desc='visualizer off')


def test_equalizer_overlay_and_preset(pl):
    open_player(pl)
    pl.wait_text('Vol [')
    pl.send('e')
    pl.wait_text('Equalizer')
    assert 'Preset: Flat' in '\n'.join(pl.display())
    pl.send('\t')                      # next preset
    pl.wait_text('Preset: Rock')
    pl.send('\t')
    pl.wait_text('Preset: Pop')
    pl.key('ESC')
    pl.wait_gone('Equalizer')


def test_repeat_and_shuffle_toggle(pl):
    open_player(pl)
    pl.wait_text('repeat: all')
    pl.send('r')
    pl.wait_text('repeat: one')
    pl.send('r')
    pl.wait_text('repeat: off')
    pl.send('s')
    pl.wait_for(lambda s: 'shuffle: on' in screen(s), desc='shuffle on')


def test_save_queue_asks_for_a_name(pl):
    open_player(pl)
    pl.wait_text('Vol [')
    pl.key('F2')
    pl.wait_text('Save playlist')


def test_alt_f8_stops_playback(pl):
    open_player(pl)
    pl.wait_text('Vol [')
    # the fake backend is running; Alt-F8 stops the decoder process
    pl.send('\x1b' + '8')              # Alt-F8
    pl.wait_for(lambda s: s.alive(), desc='app alive after Alt-F8')


def test_player_closes_on_esc(pl):
    open_player(pl)
    pl.wait_text('Vol [')
    pl.key('ESC')
    pl.wait_gone('Vol [')
    assert pl.alive()


def test_f3_on_folder_opens_player(pl):
    """F3 on a directory queues it recursively (PLAYER.md entry point)."""
    pl.click_on('sub')                # cursor the nested directory
    pl.key('F3')
    pl.wait_text('Vol [')
    assert 'c.flac' in screen(pl)


def test_enter_on_audio_file_opens_player(pl):
    """Enter on an audio file opens the player on that one track."""
    pl.click_on('a.mp3')
    pl.key('ENTER')
    pl.wait_text('Vol [')
    assert '1/1' in screen(pl)
