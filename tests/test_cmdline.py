"""M1: command line, shell execution, history, launching (DN 2.1/2.2/4.1/4.2)."""

import os
import stat
import time

from conftest import make_session


def test_typing_goes_to_cmdline(dn):
    dn.send('echo hi')
    dn.wait_for(lambda s: 'echo hi' in s.display()[22], desc='typed text on cmdline')
    dn.key('ESC')
    dn.wait_for(lambda s: 'echo hi' not in s.display()[22], desc='Esc clears')


def test_backspace_edits_cmdline_not_panel(dn, sandbox):
    dn.send('abc')
    dn.wait_for(lambda s: 'abc' in s.display()[22], desc='typed')
    dn.key('BACKSPACE')
    dn.wait_for(lambda s: '>ab' in s.display()[22] and 'abc' not in s.display()[22],
                desc='backspace deleted one char')
    # panel did not go up: title still shows /left
    assert '/left ' in dn.display()[1]
    dn.key('ESC')


def test_enter_executes_command(dn, sandbox):
    dn.send('touch created_by_cmd.txt')
    dn.key('ENTER')
    dn.wait_text('created_by_cmd.txt')     # panels reloaded after the command
    assert (sandbox / 'left' / 'created_by_cmd.txt').exists()


def test_cd_changes_panel_dir(dn, sandbox):
    dn.send('cd alpha')
    dn.key('ENTER')
    dn.wait_text('inner.txt')
    assert dn.cmdline_shows(sandbox / 'left' / 'alpha')
    dn.send('cd ..')
    dn.key('ENTER')
    dn.wait_for(lambda s: s.cmdline_shows(sandbox / 'left'), desc='back in left')


def test_cd_nonexistent_shows_error(dn):
    dn.send('cd nosuchdir')
    dn.key('ENTER')
    dn.wait_text('No such directory')
    dn.key('ENTER')                         # dismiss
    dn.wait_gone('No such directory')


def test_history_recall_and_persistence(dn, sandbox):
    dn.send('echo one')
    dn.key('ENTER')
    dn.send('echo two')
    dn.key('ENTER')
    dn.pump(0.3)
    dn.key('CTRL_E')
    dn.wait_for(lambda s: 'echo two' in s.display()[22], desc='Ctrl-E last command')
    dn.key('CTRL_E')
    dn.wait_for(lambda s: 'echo one' in s.display()[22], desc='Ctrl-E older command')
    dn.key('CTRL_X')
    dn.wait_for(lambda s: 'echo two' in s.display()[22], desc='Ctrl-X forward')
    dn.key('ESC')
    dn.key('F10')
    assert dn.wait_exit() == 0
    assert 'echo two' in (sandbox / 'cfg' / 'history').read_text()

    s = make_session(sandbox)               # same DN_CONFIG_DIR
    try:
        s.wait_text('a.txt')
        s.key('CTRL_E')
        s.wait_for(lambda x: 'echo two' in x.display()[22],
                   desc='history persisted across sessions')
    finally:
        s.close()


def test_ctrl_f_inserts_filename(dn):
    dn.click_on('a.txt', panel='left')
    dn.send('cat ')
    dn.key('CTRL_F')
    dn.wait_for(lambda s: 'cat a.txt' in s.display()[22], desc='filename inserted')
    dn.key('ESC')


def test_enter_runs_executable(dn, sandbox):
    exe = sandbox / 'left' / 'runme.sh'
    exe.write_text('#!/bin/sh\ntouch "$(dirname "$0")/ran.txt"\n')
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
    dn.key('CTRL_R')
    dn.click_on('runme.sh', panel='left')
    dn.key('ENTER')
    dn.wait_text('ran.txt')
    assert (sandbox / 'left' / 'ran.txt').exists()


def test_enter_on_plain_file_does_nothing(dn, sandbox):
    dn.click_on('a.txt', panel='left')
    dn.key('ENTER')
    dn.pump(0.3)
    assert dn.alive()
    assert dn.row_of('[■]') is None, 'no window opened without dn.ext mapping'


def test_dn_ext_view_and_shell(sandbox):
    cfg = sandbox / 'cfg'
    cfg.mkdir()
    (cfg / 'dn.ext').write_text('txt=@view\nmrk=touch %f.done\n')
    (sandbox / 'left' / 'x.mrk').write_text('m')
    s = make_session(sandbox)
    try:
        s.wait_text('a.txt')
        s.click_on('a.txt', panel='left')
        s.key('ENTER')
        s.wait_text('lines')                # viewer window opened via @view
        s.send('q')
        s.wait_gone('lines')
        s.click_on('x.mrk', panel='left')
        s.key('ENTER')
        s.wait_text('x.mrk.done')           # shell mapping ran
        assert (sandbox / 'left' / 'x.mrk.done').exists()
    finally:
        s.close()


def test_ctrl_o_user_screen(dn):
    dn.send('echo marker_on_user_screen')
    dn.key('ENTER')
    dn.pump(0.3)
    dn.key('CTRL_O')
    dn.wait_text('Ctrl-O returns to DN')
    dn.send('x')                            # typing lands on the prompt line
    dn.wait_text('> x')
    dn.key('CTRL_O')                        # toggles back to the panels
    dn.wait_gone('Ctrl-O returns to DN')
    assert dn.alive()


def test_exit_command_quits(dn):
    dn.send('exit')
    dn.key('ENTER')
    assert dn.wait_exit() == 0
