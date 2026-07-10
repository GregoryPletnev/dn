# Embedded terminal — design & work plan

Status: **planned, not started.** This document is the spec for running a
live terminal (with full-screen TUI apps) inside a DN desktop window.

## Why

The current `Tools > Console` (`src/dnconsole.pas`) captures a command's
stdout/stderr through a pipe and streams the lines into a scrollback
window. That is deliberately not a terminal: stdin is `/dev/null` and
`TERM=dumb`, so full-screen apps (htop, mc, vim, less) can't drive the
screen. Today they are refused, not run:

- the console detects known full-screen/GUI programs up front, and an
  ioctl complaint after the fact (`IsInteractiveApp` /
  `LooksLikeTtyComplaint`), and points the user at Ctrl-O;
- Ctrl-O drops to an interactive shell on the real terminal (global, so
  it works even while a console window is focused).

(An earlier `!cmd` shortcut that suspended ncurses to run one command
full-screen was removed: `endwin`/`reset_prog_mode` over a desktop window
corrupts the panels underneath.)

The next step is a real embedded terminal: a PTY-backed window that
renders a child program *inside* the DN desktop, so htop/mc/vim run in a
panel without leaving the ncurses UI.

## Architecture

New unit `src/dnterm.pas`, a `TTermWin = class(TWin)`, opened from
`Tools > Terminal` (and, later, offered as the "Run" action when the
console refuses a full-screen app — rendering it in-window instead of
sending the user to Ctrl-O).

### 1. PTY + background child

- `forkpty` is available directly from libc on both targets (declared in
  FPC's `libc/src/ptyh.inc`; we can `external 'c'` it ourselves to avoid
  the heavy `libc` unit). `openpty` + manual `fpFork` is the fallback.
- Child: `setsid`, make the slave the controlling tty, `TERM=xterm-256color`,
  `chdir` to the window's directory, `exec $SHELL` (or the requested cmd).
- Parent keeps the master fd, sets it `O_NONBLOCK`, and reads it during
  the main loop's idle ticks — the same plumbing the console capture and
  the screen savers already use. The focused terminal window must be
  polled faster than the current 1 s tick (see §5).
- Window size is pushed to the pty with `ioctl(master, TIOCSWINSZ, …)`
  matching the inner content rect; re-sent on zoom/move/resize.

### 2. VT parser → cell grid  (the bulk of the work, ~700–1000 LOC)

A screen model: `grid[row][col]` of `(codepoint, fg, bg, attrs)`, a
cursor, a scroll region, and saved-cursor state. Feed master bytes through
a state machine covering the subset real apps use:

- **Printable text**: UTF-8 assembly, put at cursor, wrap/advance.
- **C0 controls**: BS, HT (8-col tabs), LF, CR, BEL (ignore), SI/SO
  (charset shift).
- **CSI**: CUU/CUD/CUF/CUB, CUP/HVP, ED (0/1/2), EL (0/1/2), IL/DL, ICH/DCH,
  ECH, DECSTBM (scroll region), SU/SD, SGR (see below), DECTCEM (cursor
  show/hide, `?25`), DECSET/DECRST for the modes below.
- **Alternate screen** (`?1049h/l`, also `?47`, `?1047`): mandatory —
  htop, vim, mc, less all use it. Keep two grids, switch and clear.
- **SGR**: reset, bold, dim, underline, blink, reverse, 8/16 colors,
  `38;5;n` / `48;5;n` 256-color, default fg/bg. (24-bit `38;2;r;g;b`
  can be quantized to 256 to start.)
- **DEC line drawing** (G0 `ESC(0`): mc, dialog, ncurses apps draw boxes
  with it — map to the same Unicode box glyphs `dnscreen` already uses.
- **OSC** (`ESC]0;title BEL`): capture the title into the window frame;
  otherwise swallow to the string terminator.
- Ignore/absorb everything else without desyncing (unknown CSI, DCS, etc.).

Recommended: build against a golden-output harness — feed byte streams,
assert the resulting grid — before wiring real apps. `tests/` already has
the pty+pyte machinery; pyte itself is a reference VT implementation we can
diff against.

### 3. Render grid → window

- Draw the grid into the window's inner rect each frame, clipped to the
  frame; place the hardware cursor at the child's cursor when focused.
- Colors need arbitrary (fg,bg) pairs, unlike our fixed palette. Add a
  small on-demand pair cache: `PairFor(fg,bg)` allocates the next free
  `init_pair` slot and memoizes it. This terminal reports hundreds of
  pairs (`COLOR_PAIRS`), plenty for a 256-color LRU cache; evict if it
  fills. Keep the cache above our fixed pairs (currently ≤ 37).
- Only repaint on change (dirty rows) to keep a busy htop cheap.

### 4. Keyboard → pty (reverse of the panel key loop)

`dn.pas` already decodes ESC-prefixed sequences *into* `KEY_*`; here we do
the inverse. Focused-window keys become the bytes the child expects:

- Arrows → `ESC[A..D` (or `ESC O A..D` in application cursor-key mode,
  `?1h`), Home/End/PgUp/PgDn/Ins/Del → their `ESC[` sequences, F1–F12 →
  `ESC O P…`/`ESC[…~`, plain keys and Ctrl-letters verbatim.
- Track DECCKM/keypad modes the app sets to pick the right encoding.
- A dedicated "detach" chord (e.g. Ctrl-\ or the window Close) leaves the
  child running or kills it — decide policy (mc wants clean exit).

### 5. Main-loop integration

- The focused window must be able to request a fast poll. Give `TWin` an
  optional "wants frequent ticks" flag; when a `TTermWin` is focused, the
  main loop uses a short `timeout` and pumps the pty every iteration
  (mirrors `dnconsole`'s captured-run loop, but persistent and non-modal).
- Reap the child with `SIGCHLD`/`waitpid(WNOHANG)`; on child exit show
  `[process exited]` and freeze the last frame until the window closes.
- Resize: on window zoom/move recompute rows×cols, `TIOCSWINSZ`, and let
  the app repaint.

## Scope / phasing

1. PTY + shell + parser MVP: text, CR/LF/BS/tab, CUP, ED/EL, SGR colors,
   alt-screen, cursor. Target: `bash`, `htop`, `less` render correctly.
2. DEC line drawing + insert/delete line/char + scroll region. Target:
   `mc`, `dialog`, `ncdu`.
3. Application cursor/keypad modes, mouse forwarding (SGR 1006 →
   child), title via OSC. Target: `vim`, `tmux` inside.
4. Polish: 24-bit color, dirty-row repaint, multiple terminal windows,
   copy from scrollback.

## Risks

- Correctness is validated by *real apps*, not unit tests alone — htop, mc
  and vim exercise different corners and debugging is iterative.
- ncurses is itself a curses app; nesting a VT renderer inside it means we
  reimplement cell output rather than delegate — expect edge cases with
  wide chars (needs `wcwidth`, already a pending item in ROADMAP) and with
  our own frame drawing overlapping the child's last column.
- Color-pair exhaustion on terminals that report few pairs — the LRU cache
  and graceful fallback to the nearest fixed pair handle it.

## Not doing (use the existing escape hatches instead)

- GUI apps (`open`, `code`, a browser) — they don't want a terminal at
  all; the console already refuses TUI/GUI names and points at Ctrl-O
  (GUI ones just say "run outside DN"). An embedded terminal doesn't
  change that.
