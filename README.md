# Dos Navigator FPC (OSX / Linux)

A recreation of the classic [Dos Navigator](original/) look and feel using
modern tools: Free Pascal + ncurses, for a fast, keyboard-driven file
management experience in the terminal.

The original Turbo Pascal sources live under `original/` and serve as the
reference for behavior and appearance; the new code under `src/` is written
from scratch for Unix terminals.

This product is based on the ideas and code analysis of the original Dos
Navigator by **RIT Labs**. Dos Navigator is Copyright © RIT Labs; all
credit for the original design belongs to them.

## Building

Requirements:

- Free Pascal (FPC) 3.2+ — `brew install fpc` on macOS
- ncurses with wide-character support — `brew install ncurses` on macOS
  (the Makefile finds it via `brew --prefix`); on Linux, `libncursesw5-dev`
  or your distro's equivalent

```sh
make        # builds bin/dn
make run    # builds and runs
make test   # builds and runs the TUI test suite
```

`bin/dn [left-dir [right-dir]]` — optional arguments set the starting
directory of each panel.

## Testing

Two layers, both run by `make test`:

- `tests/unittests.pas` — FPC-native unit tests for pure logic (UTF-8
  helpers, mask matching, tree sizes); builds to `bin/unittests`.
- `tests/*.py` — end-to-end TUI tests: `tuitest.py` runs the binary in a
  real pty, feeds it keystrokes and emulates the terminal with
  [pyte](https://github.com/selectel/pyte) (extended with scroll-region
  and alternate-screen support), so tests assert on actual screen content,
  colors and layout, including resize via SIGWINCH and mouse input.
  Bootstraps a virtualenv in `tests/.venv`.

## Keys

| Key | Action |
|-----|--------|
| Tab | Switch active panel |
| ↑ ↓ PgUp PgDn Home End | Move cursor |
| Enter | Enter directory |
| Backspace | Go to parent directory |
| Insert | Select/deselect file |
| Ctrl+R | Reread both panels |
| Ctrl+T | Tetris (also Tools → Tetris) |
| F1 | Help |
| F3 | View file (in a window) |
| F4 | Edit file in MicroEd, the built-in DN editor (in a window) |
| F5 / F6 | Copy / move selection (or current file) to the other panel |
| F7 | Make directory |
| F8 | Delete (recursive, with confirmation) |
| F9 | Pull-down menu (arrows, Enter, Esc; fully mouse-driven too) |
| F10 | Exit (asks about unsaved editors) |
| Alt+S | Sort panel: name / ext / size / date / unsorted |
| Alt+letter | Quick jump to the next file starting with that letter |
| + / - / * | Select / deselect by mask, invert selection |
| Ctrl+U | Swap panels |
| Ctrl+G | Count directory size (shown in the Size column) |
| Ctrl+C | Compare directories: select files that differ |
| Ctrl+O | User screen (output of executed commands) |
| Ctrl+E / Ctrl+X | Command history: previous / next |
| Ctrl+F | Insert current filename into the command line |

F2 (user menu) is a placeholder. Menus with no working items yet
(Disk, Options) show a disabled entry.

## Command line

Any printable key types into the command line at the bottom; Enter runs
it via `$SHELL` in the active panel's directory (`cd` changes the panel,
`exit` quits). History persists in the config dir: `DN_CONFIG_DIR` or
`~/.config/dnfpc`. `dn.ext` there maps extensions to actions for Enter on
a file: `txt=@edit`, `log=@view`, `mrk=touch %f.done` (`%f` = quoted full
path); executables run directly. Filters per panel and sort modes live
in the Left/Right menus.

## Windows

Like the original DN, the viewer and the editor open in overlapping
windows above the panels — several files at once, cascaded placement,
double-line frame on the focused window, `[■]` close and `[↕]` zoom icons
(the original's `[*]` and `[|]`).

| Key | Action |
|-----|--------|
| F5 | Zoom / unzoom focused window |
| F6 | Cycle focus: top window → ... → bottom window → panels |
| Ctrl-F5 | Move/resize mode: arrows move, Shift-arrows resize, Enter/Esc done |
| Esc, F10 | Close window (asks to save if modified) |

Clicking a window focuses and raises it; clicking the panels focuses them.
F10 from the panels quits, asking about every unsaved editor first.

## MicroEd

F4 opens the built-in editor (a port of the spirit of
`original/Dos-Navigator/MICROED.PAS`): F2 save, F7 find, Ctrl-L find
next, Ins insert/overwrite, Ctrl-Y delete line, Tab = 4 spaces, status
shows `line:col`, `Ovr`, `Modified`. Closing a modified file asks
Save/Discard/Cancel. The terminal runs in raw mode so ^Y, ^S, ^Q reach
the editor instead of the tty driver (on macOS ^Y would otherwise
suspend the process).

Not ported yet from MicroEd: block selection, clipboard, undo, syntax
highlighting (DN.HGL), search & replace.

## Mouse

Mouse support follows the original DN mouse reference (`features.txt`).
Implemented (works in Terminal.app / iTerm2 via xterm mouse reporting):

| features.txt operation | Status |
|---|---|
| Click on file — put cursor there, activate panel | ✔ |
| Double-click on directory — enter it | ✔ |
| Right-click on file — invert selection | ✔ |
| Click on operation on status line (fkey bar) | ✔ |
| Click on menu bar — pull-down menus | ✔ |
| Mouse in dialogs (buttons, input line) | ✔ |
| Scrollbar: click arrows — line up/down | ✔ |
| Scrollbar: click track above/below thumb — page up/down | ✔ (simplified DN semantics) |
| Mouse wheel — scroll panel under pointer | ✔ (modern extension) |
| Drag operations (panel resize, copy by drag, scrollbar drag) | ✖ needs motion tracking, planned |
| Window ops: click to focus/raise, [■] close, [↕] zoom, click in editor sets cursor, wheel scrolls | ✔ |
| Tree panel, ASCII table | ✖ blocked on those widgets existing |

Mouse handling runs on raw press/release events (`mouseinterval(0)`) with
our own double-click detection — ncurses' click synthesis is timing-based
and can swallow events (a fast second click may arrive as a lone
`RELEASED`). Set `DN_MOUSE_LOG=<file>` to log decoded mouse events.

Implementation note: the FPC `ncurses` unit ships `BUTTON*` constants in the
NCURSES_MOUSE_VERSION 1 layout (6 bits per button), while libncurses 6 uses
version 2 (5 bits per button) — so the binding's constants for buttons ≥ 2
are wrong. `dnscreen.pas` defines correct v2 masks; don't use the binding's.

## Tetris

Like the original DN (`original/Dos-Navigator/TETRIS.PAS`), a Tetris is
built in: Tools → Tetris or Ctrl+T. Arrows move/rotate, Space drops,
Q/Esc quits back to the panels. `DN_TETRIS_SEQ=IOTSZJL...` fixes the piece
sequence (used by the tests).

## Status

Working: dual panels (classic DN look), full mouse support, pull-down
menus, the multi-window desktop (viewer and editor windows), MicroEd,
file operations F5/F6/F7/F8 with dialogs, help (F1), Tetris. Not yet:
command line execution, Disk and Options menus, user menu (F2), drag
operations (window drag/resize by mouse, panel width).

Known limitations:

- UTF-8 is supported end to end (display, editing, input, dialogs), with
  display width counted in codepoints — double-width CJK characters will
  still misalign a row.
