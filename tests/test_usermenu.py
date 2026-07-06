"""User menu (F2): dn.mnu entries, placeholders, local override."""


def write_global_menu(sandbox, text):
    cfg = sandbox / 'cfg'
    cfg.mkdir(exist_ok=True)
    (cfg / 'dn.mnu').write_text(text)


def test_f2_runs_selected_command(dn, sandbox):
    write_global_menu(sandbox, 'Make marker\n\ttouch marker.done\n')
    dn.key('F2')
    dn.wait_text('Make marker')
    dn.key('ENTER')
    dn.wait_text('Press any key')       # user-menu commands pause
    dn.send(' ')
    dn.wait_for(lambda s: (sandbox / 'left' / 'marker.done').exists(),
                desc='command ran in the panel dir')
    assert dn.alive()


def test_f2_placeholder_current_file(dn, sandbox):
    write_global_menu(sandbox, 'Copy name\n\tcp %f %f.bak\n')
    dn.click_on('a.txt', panel='left')
    dn.key('F2')
    dn.wait_text('Copy name')
    dn.key('ENTER')
    dn.wait_text('Press any key')
    dn.send(' ')
    dn.wait_for(lambda s: (sandbox / 'left' / 'a.txt.bak').exists(),
                desc='%f expanded to the current file')
    assert (sandbox / 'left' / 'a.txt.bak').read_text() == 'aaa\n'


def test_f2_placeholder_selection(dn, sandbox):
    write_global_menu(sandbox, 'List selection\n\techo %s > sel.txt\n')
    dn.click_on('a.txt', panel='left')
    dn.send(' ')                        # select a.txt (space-select)
    dn.send(' ')                        # select b.txt
    dn.key('F2')
    dn.wait_text('List selection')
    dn.key('ENTER')
    dn.wait_text('Press any key')
    dn.send(' ')
    dn.wait_for(lambda s: (sandbox / 'left' / 'sel.txt').exists(),
                desc='selection listed')
    assert (sandbox / 'left' / 'sel.txt').read_text().split() == ['a.txt', 'b.txt']


def test_f2_local_menu_overrides_global(dn, sandbox):
    write_global_menu(sandbox, 'Global entry\n\ttrue\n')
    (sandbox / 'left' / 'dn.mnu').write_text('Local entry\n\ttrue\n')
    dn.key('CTRL_R')
    dn.key('F2')
    dn.wait_text('Local entry')
    assert dn.row_of('Global entry') is None
    dn.key('ESC')
    dn.wait_gone('Local entry')


def test_f2_esc_runs_nothing(dn, sandbox):
    write_global_menu(sandbox, 'Danger\n\ttouch nope.txt\n')
    dn.key('F2')
    dn.wait_text('Danger')
    dn.key('ESC')
    dn.wait_gone('Danger')
    dn.pump(0.3)
    assert not (sandbox / 'left' / 'nope.txt').exists()


def test_options_global_menu_definition_opens_editor(dn, sandbox):
    dn.click_on('Options')
    dn.wait_text('Global menu definition')
    dn.click_on('Global menu definition...')
    dn.wait_text('user menu (F2)')      # template opened in MicroEd
    assert (sandbox / 'cfg' / 'dn.mnu').exists()
    dn.key('F10')                       # close the editor
    dn.wait_gone('user menu (F2)')
    assert dn.alive()


def test_sigint_does_not_kill_dn(dn):
    import os, signal
    os.kill(dn.proc.pid, signal.SIGINT)
    dn.pump(0.4)
    assert dn.alive()


def test_ctrl_c_aborts_command_not_dn(dn, sandbox):
    import os, signal, time
    write_global_menu(sandbox, 'Slow\n\tsleep 30\n')
    dn.key('F2')
    dn.wait_text('Slow')
    dn.key('ENTER')
    time.sleep(0.6)
    # ^C in a real terminal: SIGINT to the whole foreground process group
    os.killpg(os.getpgid(dn.proc.pid), signal.SIGINT)
    dn.wait_text('Press any key')       # sleep died, dn reached the pause
    dn.send('\x03')                     # ^C also dismisses the pause
    dn.wait_gone('Press any key')
    assert dn.alive()


def test_no_target_blocks_placeholder_command(dn, sandbox):
    # cursor starts on '..': "du -sh %s" must not run on the whole dir
    write_global_menu(sandbox, 'Disk usage of selection\n\tdu -sh %s\n')
    dn.key('HOME')                      # cursor to '..'
    dn.key('F2')
    dn.wait_text('Disk usage of selection')
    dn.key('ENTER')
    dn.wait_text('No file is selected')
    dn.key('ENTER')
    dn.wait_gone('No file is selected')
    assert dn.alive()
