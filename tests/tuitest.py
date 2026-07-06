"""TUI test harness: runs a curses app in a real pty and emulates the
terminal with pyte, so tests can assert on screen text, colors and layout."""

import collections
import fcntl
import os
import pty
import signal
import struct
import subprocess
import termios
import threading
import time

import pyte


class DNScreen(pyte.Screen):
    """pyte.Screen + SU/SD (CSI S / CSI T). ncurses uses scroll-region
    scrolling for optimized repaints; stock pyte silently drops those
    sequences, leaving ghost rows a real terminal would never show."""

    def dn_scroll_up(self, count=None):
        count = count or 1
        top, bottom = self.margins or (0, self.lines - 1)
        rows = {y: self.buffer[y] for y in range(top, bottom + 1)}
        for y in range(top, bottom + 1):
            if y + count <= bottom:
                self.buffer[y] = rows[y + count]
            else:
                self.buffer.pop(y, None)      # becomes a blank row
        self.dirty.update(range(top, bottom + 1))

    ALT_MODES = (47, 1047, 1049)

    def set_mode(self, *modes, **kwargs):
        """Alternate-screen support (smcup/rmcup): stock pyte ignores mode
        1049, blending the curses screen with normal-screen shell output."""
        if kwargs.get('private') and any(m in self.ALT_MODES for m in modes):
            self._alt_saved = ({y: dict(row) for y, row in self.buffer.items()},
                               self.cursor.x, self.cursor.y)
            self.buffer.clear()
            self.dirty.update(range(self.lines))
            modes = tuple(m for m in modes if m not in self.ALT_MODES)
        if modes or not kwargs.get('private'):
            super().set_mode(*modes, **kwargs)

    def reset_mode(self, *modes, **kwargs):
        if kwargs.get('private') and any(m in self.ALT_MODES for m in modes):
            saved = getattr(self, '_alt_saved', None)
            if saved is not None:
                self.buffer.clear()
                for y, row in saved[0].items():
                    self.buffer[y].update(row)
                self.cursor.x, self.cursor.y = saved[1], saved[2]
            self.dirty.update(range(self.lines))
            modes = tuple(m for m in modes if m not in self.ALT_MODES)
        if modes or not kwargs.get('private'):
            super().reset_mode(*modes, **kwargs)

    def dn_scroll_down(self, count=None):
        count = count or 1
        top, bottom = self.margins or (0, self.lines - 1)
        rows = {y: self.buffer[y] for y in range(top, bottom + 1)}
        for y in range(top, bottom + 1):
            if y - count >= top:
                self.buffer[y] = rows[y - count]
            else:
                self.buffer.pop(y, None)
        self.dirty.update(range(top, bottom + 1))


class DNStream(pyte.ByteStream):
    csi = dict(pyte.ByteStream.csi, S='dn_scroll_up', T='dn_scroll_down')
    events = pyte.ByteStream.events | frozenset(
        ['dn_scroll_up', 'dn_scroll_down'])


KEYS = {
    # application cursor-key mode (smkx): ncurses only recognizes SS3 arrows
    'UP': '\x1bOA',
    'DOWN': '\x1bOB',
    'RIGHT': '\x1bOC',
    'LEFT': '\x1bOD',
    'PGUP': '\x1b[5~',
    'PGDN': '\x1b[6~',
    'HOME': '\x1bOH',
    'END': '\x1bOF',
    'INSERT': '\x1b[2~',
    'DELETE': '\x1b[3~',
    'ENTER': '\r',
    'TAB': '\t',
    'BACKSPACE': '\x7f',
    'CTRL_R': '\x12',
    'F1': '\x1bOP',
    'F2': '\x1bOQ',
    'F3': '\x1bOR',
    'F4': '\x1bOS',
    'F5': '\x1b[15~',
    'F6': '\x1b[17~',
    'F7': '\x1b[18~',
    'F8': '\x1b[19~',
    'F9': '\x1b[20~',
    'F10': '\x1b[21~',
    'ESC': '\x1b',
    'CTRL_T': '\x14',
    'CTRL_E': '\x05',
    'CTRL_F': '\x06',
    'CTRL_L': '\x0c',
    'CTRL_O': '\x0f',
    'CTRL_X': '\x18',
    'CTRL_Y': '\x19',
    'CTRL_F5': '\x1b[15;5~',
    'SHIFT_LEFT': '\x1b[1;2D',
    'SHIFT_RIGHT': '\x1b[1;2C',
}


class TuiSession:
    def __init__(self, argv, rows=24, cols=80, cwd=None, env=None):
        self.rows, self.cols = rows, cols
        self.screen = DNScreen(cols, rows)
        self.stream = DNStream(self.screen)
        self.raw = b''          # everything the app ever wrote (for protocol checks)
        self.master, slave = pty.openpty()
        fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                    struct.pack('HHHH', rows, cols, 0, 0))
        env = dict(os.environ, TERM='xterm-256color', LC_ALL='en_US.UTF-8',
                   **(env or {}))
        self.proc = subprocess.Popen(
            argv, stdin=slave, stdout=slave, stderr=slave,
            env=env, cwd=cwd, close_fds=True, start_new_session=True)
        os.close(slave)
        # A real terminal never stops reading its pty. If we only read
        # inside pump(), the buffer can fill up and the app deadlocks in
        # tcsetattr/endwin waiting for output to drain — so read always.
        self._chunks = collections.deque()
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self):
        while True:
            try:
                data = os.read(self.master, 65536)
            except OSError:             # EIO/EBADF after child exit or close
                return
            if not data:
                return
            self._chunks.append(data)

    # --- output pumping -------------------------------------------------
    def pump(self, timeout=0.05):
        """Feed everything the reader thread has collected into pyte,
        waiting up to `timeout` for more to arrive."""
        deadline = time.time() + timeout
        while True:
            fed = False
            while self._chunks:
                data = self._chunks.popleft()
                self.raw += data
                self.stream.feed(data)
                fed = True
            if fed:
                deadline = time.time() + 0.03   # keep draining bursts
            if time.time() >= deadline:
                return
            time.sleep(0.01)

    def display(self):
        self.pump(0)
        return list(self.screen.display)

    def dump(self):
        return '\n'.join('%2d|%s' % (i, l.rstrip())
                         for i, l in enumerate(self.display()))

    def cell(self, row, col):
        self.pump(0)
        return self.screen.buffer[row][col]

    # --- waiting --------------------------------------------------------
    def wait_for(self, pred, timeout=5.0, desc='condition'):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(0.05)
            if pred(self):
                return
        raise AssertionError('timed out waiting for %s\nscreen:\n%s'
                             % (desc, self.dump()))

    def wait_text(self, text, timeout=5.0):
        self.wait_for(lambda s: any(text in l for l in s.display()),
                      timeout, 'text %r' % text)

    def wait_gone(self, text, timeout=5.0):
        self.wait_for(lambda s: all(text not in l for l in s.display()),
                      timeout, 'disappearance of %r' % text)

    def wait_exit(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(0.02)
            if self.proc.poll() is not None:
                return self.proc.returncode
        raise AssertionError('process did not exit\nscreen:\n%s' % self.dump())

    # --- input ----------------------------------------------------------
    def send(self, data):
        os.write(self.master, data.encode())

    def key(self, name, n=1):
        for _ in range(n):
            self.send(KEYS[name])
            time.sleep(0.03)

    # --- mouse ------------------------------------------------------------
    MOUSE_BTN = {'left': 0, 'middle': 1, 'right': 2,
                 'wheelup': 64, 'wheeldown': 65}

    def _mouse_event(self, code, x, y, press):
        """Encode one mouse event in whichever protocol the app enabled:
        SGR (1006) if it was requested, legacy X10 otherwise."""
        self.pump(0)
        if b'[?1006' in self.raw:
            return '\x1b[<%d;%d;%d%s' % (code, x + 1, y + 1, 'M' if press else 'm')
        if press:
            return '\x1b[M' + chr(32 + code) + chr(32 + x + 1) + chr(32 + y + 1)
        return '\x1b[M' + chr(32 + 3) + chr(32 + x + 1) + chr(32 + y + 1)

    def mouse(self, x, y, button='left', clicks=1):
        """Send press+release pairs at cell (x, y), 0-based coordinates.

        Waits out ncurses' click-merge interval first: consecutive clicks
        within ~166ms merge into double/triple clicks regardless of their
        coordinates, which would turn two separate test clicks into one."""
        time.sleep(0.2)
        code = self.MOUSE_BTN[button]
        if button in ('wheelup', 'wheeldown'):
            self.send(self._mouse_event(code, x, y, True))
            time.sleep(0.05)
            return
        seq = ''
        for _ in range(clicks):
            seq += self._mouse_event(code, x, y, True)
            seq += self._mouse_event(code, x, y, False)
        self.send(seq)
        time.sleep(0.05)

    def drag(self, x0, y0, x1, y1, steps=4):
        """Button-1 drag: press at (x0, y0), motion events along the way,
        release at (x1, y1). Requires the app to enable xterm 1002.
        Events go out separately with gaps: batched into one read, ncurses
        swallows the press and the drag never starts."""
        time.sleep(0.2)
        self.send(self._mouse_event(0, x0, y0, True))
        for i in range(1, steps + 1):
            xi = x0 + (x1 - x0) * i // steps
            yi = y0 + (y1 - y0) * i // steps
            time.sleep(0.08)
            self.send(self._mouse_event(32, xi, yi, True))  # motion, held
        time.sleep(0.08)
        self.send(self._mouse_event(0, x1, y1, False))
        time.sleep(0.05)

    def click_on(self, text, button='left', clicks=1, panel=None):
        """Click on the first row containing `text`. `panel` = 'left'/'right'
        restricts the search to that half of the screen."""
        self.pump(0)
        half = self.cols // 2
        for r, line in enumerate(self.display()):
            seg = line if panel is None else (
                line[:half] if panel == 'left' else line[half:])
            pos = seg.find(text)
            if pos >= 0:
                x = pos + (0 if panel != 'right' else half)
                self.mouse(x, r, button, clicks)
                return r
        raise AssertionError('no row with %r to click on\nscreen:\n%s'
                             % (text, self.dump()))

    def resize(self, rows, cols):
        self.rows, self.cols = rows, cols
        fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                    struct.pack('HHHH', rows, cols, 0, 0))
        self.screen.resize(rows, cols)
        os.kill(self.proc.pid, signal.SIGWINCH)

    # --- app-specific helpers --------------------------------------------
    def cursor_bar_row(self):
        """Find the file-panel cursor bar: a cyan-background cell in the
        file area (menu bar row 0 and header rows excluded)."""
        self.pump(0)
        for r in range(3, self.rows - 3):
            for c in range(1, self.cols - 1):
                ch = self.screen.buffer[r][c]
                if ch.bg == 'cyan' and ch.data not in ('║', '│'):
                    return r
        return None

    def cursor_bar_text(self):
        r = self.cursor_bar_row()
        if r is None:
            return None
        return self.screen.display[r]

    def cmdline_shows(self, path):
        """The command line shows `path>`, possibly truncated on the left
        when the path is longer than the screen."""
        line = self.display()[self.rows - 2].rstrip()
        want = str(path) + '>'
        want = want[-min(len(want), self.cols - 2):]
        return line.endswith(want)

    def row_of(self, text):
        for i, l in enumerate(self.display()):
            if text in l:
                return i
        return None

    def alive(self):
        return self.proc.poll() is None

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        try:
            os.close(self.master)
        except OSError:
            pass
