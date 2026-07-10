"""Interactive Ctrl-O user screen and the Tools > Console window."""


def test_ctrl_o_interactive_shell(dn):
    dn.send('\x0f')                       # Ctrl-O: user screen with a prompt
    dn.wait_text('Ctrl-O returns to DN')
    dn.send('echo MARKER123\r')
    dn.wait_for(lambda s: any(l.strip().endswith('MARKER123') and
                              'echo' not in l for l in s.display()),
                desc='command output on the user screen')
    dn.send('\x0f')                       # Ctrl-O returns to the panels
    dn.wait_text('Copy')                  # fkey bar back
    assert dn.alive()


def test_ctrl_o_esc_on_empty_line_returns(dn):
    dn.send('\x0f')
    dn.wait_text('Ctrl-O returns to DN')
    dn.key('ESC')
    dn.wait_text('Copy')
    assert dn.alive()


def test_console_window_runs_commands(dn):
    dn.click_on('Tools')
    dn.click_on('Console')
    dn.wait_text('Console')               # window title
    dn.send('echo KITTEN42')
    dn.wait_text('echo KITTEN42')         # input line echoes
    dn.key('ENTER')
    # the output line (no 'echo' on it) vs the echoed command line
    dn.wait_for(lambda s: any('KITTEN42' in l and 'echo' not in l
                              for l in s.display()),
                desc='captured output line')


def test_console_interactive_program_does_not_hang(dn):
    dn.click_on('Tools')
    dn.click_on('Console')
    dn.wait_text('Console')
    dn.send('cat')                        # would block forever on a tty;
    dn.key('ENTER')                       # with /dev/null stdin it just exits
    dn.send('echo AFTERCAT7')
    dn.key('ENTER')
    dn.wait_for(lambda s: any('AFTERCAT7' in l and 'echo' not in l
                              for l in s.display()),
                desc='console alive after a stdin-hungry command')
    # full-screen programs see TERM=dumb and refuse to start
    dn.send('echo T=$TERM')
    dn.key('ENTER')
    dn.wait_text('T=dumb')


def test_console_ctrl_c_kills_running_command(dn):
    dn.click_on('Tools')
    dn.click_on('Console')
    dn.wait_text('Console')
    dn.send('sleep 30')
    dn.key('ENTER')
    dn.pump(0.3)
    dn.send('\x03')                       # Ctrl-C
    dn.wait_text('[terminated]', timeout=8)
    dn.send('echo ALIVE9')
    dn.key('ENTER')
    dn.wait_for(lambda s: any('ALIVE9' in l and 'echo' not in l
                              for l in s.display()),
                desc='console alive after killing a command')


def test_console_guards_known_tui_app(dn):
    dn.click_on('Tools')
    dn.click_on('Console')
    dn.wait_text('Console')
    dn.send('htop')                       # never captured: TUI app
    dn.key('ENTER')
    dn.wait_text('needs a real terminal')
    dn.wait_text('Ctrl-O')                # pointed at the interactive shell
    # ...and the console keeps working afterwards
    dn.send('echo STILLHERE8')
    dn.key('ENTER')
    dn.wait_for(lambda s: any('STILLHERE8' in l and 'echo' not in l
                              for l in s.display()),
                desc='console alive after refusing a TUI app')


def test_console_guards_gui_app(dn):
    dn.click_on('Tools')
    dn.click_on('Console')
    dn.wait_text('Console')
    dn.send('open .')                     # macOS GUI launcher
    dn.key('ENTER')
    dn.wait_text('is a GUI program')
    assert dn.alive()


def test_console_points_unknown_tui_at_ctrl_o(dn):
    dn.click_on('Tools')
    dn.click_on('Console')
    dn.wait_text('Console')
    # a program the known-apps list misses, detected by its ioctl complaint
    dn.send('sh -c "echo Inappropriate ioctl for device >&2; exit 1"')
    dn.key('ENTER')
    dn.wait_text('[exit code 1]')
    dn.wait_text('press Ctrl-O for a shell')
    assert dn.alive()


def test_ctrl_o_reachable_from_focused_console(dn):
    dn.click_on('Tools')
    dn.click_on('Console')
    dn.wait_text('Console')
    dn.send('\x0f')                       # Ctrl-O works even over a window
    dn.wait_text('Ctrl-O returns to DN')
    dn.send('\x0f')                       # back; the console window survives
    dn.wait_text('Console')
    assert dn.alive()


def test_console_cd_builtin_and_history(dn):
    dn.click_on('Tools')
    dn.click_on('Console')
    dn.wait_text('Console')
    dn.send('cd /')
    dn.key('ENTER')
    dn.send('echo DIR=$PWD')
    dn.key('ENTER')
    dn.wait_for(lambda s: any('DIR=/' in l and 'echo' not in l
                              for l in s.display()),
                desc='command ran in the builtin-changed dir')
    dn.key('UP')                          # history recall
    dn.wait_text('/> echo DIR=$PWD')
    dn.key('ESC')                         # clears the recalled input
    dn.key('ESC')                         # empty input: closes the window
    dn.wait_gone('Console')
    assert dn.alive()
