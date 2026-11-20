Software is a meme these days. 

I'm proud to say: Fable  is the first model capable of passing a test of reimplementing DN to modern product.

Was it worth it? I bet so.

Star, share, join my tg channel: https://t.me/My_CTO_Notes

Best!
Gregory Pletnev

# DN - DataNavigator (OSX / Linux)

**DN - DataNavigator** is a recreation of the classic
[Dos Navigator](original/) look and feel using modern tools: Free Pascal +
ncurses, for a fast, keyboard-driven file management experience in the
terminal.

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
make install  # links bin/dn into ~/.local/bin/dn
```

`bin/dn [left-dir [right-dir]]` — optional arguments set the starting
directory of each panel.

`make install` (or `PREFIX=/opt make install`) puts a `dn` symlink on
`PATH`. When you launch dn by a path (`./bin/dn`) and no `dn` is on
`PATH`, dn prints a one-time hint after the first exit;
`bin/dn --install-path` creates the `~/.local/bin/dn` symlink
(`$XDG_BIN_HOME/dn` when that is set) on the spot. `DN_NO_PATH_HINT=1`
silences the hint.

## Distribution (macOS, Apple Silicon)

```sh
make dmg                                  # dist/DN-DataNavigator-<version>-arm64.dmg
VERSION=1.2.0 scripts/build-dmg.sh        # override the version
```

Builds `DN - DataNavigator.app` (double-clicking it opens `dn` in Terminal),
bundles the Homebrew ncurses dylib inside the app so it runs on machines
without Homebrew, signs it and packs everything into a compressed DMG with
an `/Applications` symlink. By default the signature is ad-hoc, so users
need right-click > Open on first launch; for Gatekeeper-clean distribution
pass a Developer ID via `CODESIGN_IDENTITY=...` and notarize the DMG.

The app icon (`assets/dn.icns`) is a new project-local DN mark inspired by
the classic dual-panel visual language; regenerate it with
`python3 scripts/make-icon.py` (needs ImageMagick).

## Distribution (Debian/Ubuntu)

```sh
make deb                                  # dist/dn-datanavigator_<version>_<arch>.deb
VERSION=1.2.0 scripts/build-deb.sh        # override the version
```

Runs on a Debian/Ubuntu machine (needs `fpc`, `libncursesw5-dev` and
`dpkg-deb`): builds the binary and packs `/usr/bin/dn` with a desktop
entry, the icon and doc files. Depends on `libncursesw6`; `bsdtar`
(libarchive-tools) and `openssh-client` are recommended for the archive
and SFTP panels.

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
| Insert / Space | Select/deselect file (Space is MC-style, off in Options → Panel setup) |
| Ctrl+R | Reread both panels |
| Ctrl+T | Tetris (also Tools → Tetris) |
| F1 | Help |
| F2 | User menu (`dn.mnu`, see below) |
| F3 | View file (in a window); on a folder, open the media player |
| F4 | Edit file in MicroEd, the built-in DN editor (in a window) |
| F5 / F6 | Copy / move selection (or current file) to the other panel |
| F7 | Make directory |
| F8 | Delete (recursive, with confirmation) |
| F9 | Pull-down menu (arrows, Enter, Esc; fully mouse-driven too) |
| F10 | Exit (asks about unsaved editors) |
| Alt+S | Sort panel: name / ext / size / date / unsorted |
| Alt+[ / Alt+] | Move the panel split left / right (Alt+= resets) |
| Alt+letter | Quick jump to the next file starting with that letter |
| + / - / * | Select / deselect by mask, invert selection |
| Ctrl+U | Swap panels |
| Ctrl+G | Count directory size (shown in the Size column) |
| Left/Right → Columns… | Pick panel columns: Size / Date / Time (saved as default) |
| Options → Panel setup | Hidden files, Space select, exact sizes (1,234,567) |
| Ctrl+C | Compare directories: select files that differ |
| Ctrl+O | Shell screen toggle, MC-style (Ctrl+O / Esc returns) |
| Ctrl+E / Ctrl+X | Command history: previous / next |
| Ctrl+F | Insert current filename into the command line |
| Ctrl+S | SSH session manager |
| Ctrl+W | Read a file list into the panel (virtual listing) |
| Ctrl+F7 / Ctrl+F8 | UU-encode / UU-decode the current file |
| Alt-F8 | Stop and close every media player window |

## User menu (F2)

Entries live in `dn.mnu`: a local one in the panel directory overrides
the global `<config>/dn.mnu` (DN's Local/Global menu definition — both
editable from the Options menu; a template is created on first use).
Format:

```
# comment
Show file type
	file %p
Pack selection
	tar czvf selection.tar.gz %s
```

Titles start at column 1, the indented lines below are the shell
commands. Placeholders: `%f` file name, `%p` full path, `%d` panel dir,
`%D` other panel dir, `%s` selected files (each quoted), `%%` literal
percent. Output is shown on the shell screen with a "press any key"
pause.

## Virtual file systems

Panels browse more than the local disk (ROADMAP M3):

- **Archives as directories** (DN 3.9): press Enter on a `.zip`, `.tar`,
  `.tgz`, `.7z`, `.iso`, … to browse it like a folder. View files inside,
  copy in/out (extract/pack), and — for `.zip` — delete members and edit
  a file in place (MicroEd writes it back). Backend: `bsdtar` (+ `zip`).
- **Remote over SFTP** — the Navigator Link reborn as an MC-style shell
  link. `cd sftp://user@host[:port]/path`, or use the Disk menu. Copy,
  move, delete and mkdir work across any two file systems (local ⇄ remote
  ⇄ archive). Uses the OpenSSH client with a shared ControlMaster.
- **SSH session manager** (Ctrl+S or Disk → SSH sessions): a folder tree
  of saved sessions stored in `~/.config/dnfpc/sessions` (ordinary
  ssh_config, valid for `ssh -G`). Enter connects a remote panel, Ctrl+T
  opens a terminal login, Ctrl+K runs `ssh-copy-id`; Insert/F4/Del add,
  edit and remove sessions. Per-session HostName/User/Port/IdentityFile,
  port forwards and a remote start directory.
- **File list panel** (Ctrl+W, DN 2.12): read a text file of paths into a
  virtual listing.

## Find file

Alt-F7 (Commands → Find file…) is DN's Find File dialog, as DN 1.51 and
DN OSP / Necromancer's DN had it: file mask (`*.txt;*.md`), text to find,
hex string (`53 51 4c`), options (advanced search, recursive, case
sensitive, whole words, hidden files) and scope (current directory,
selected, home, entire disk). dn adds **File type (content)**: a type
told by the file's signature — SQLite, PDF, PNG, ZIP, ELF, Mach-O, … — or
a whole group (Images, Archives, Executables, Audio & video, Documents,
Databases), whatever the file is called. Advanced search adds date
after/before, size greater/less (`10K`, `2M`), read-only, executable.

As in DN, the results fill the panel: each hit by its path from where the
search started. View, edit, copy, move and delete act on the real files;
Enter goes to a hit in its own directory; `..` returns. Esc during the
search asks whether to stop and keeps what was found.

## Databases

Disk → Databases… (Ctrl-Q) manages connections to PostgreSQL, ClickHouse
and SQLite. dn runs their own clients — `psql` (12+), `clickhouse client`
(or `clickhouse-client`), `sqlite3` — so TLS, every auth method and
`~/.pgpass` work as usual.

- **Manager:** Enter opens the database in the active panel, F2 opens an
  SQL window, F5 tests the connection, Ins/F4/F8 add, edit, delete.
  Connections live in `~/.config/dnfpc/databases` (INI, no passwords).
- **Panel:** `db://name/` lists schemas (PostgreSQL) or databases
  (ClickHouse) as directories, tables and views as files; the size column
  is the row estimate. F3/Enter show the first 1000 rows in a grid, F4
  opens an SQL window with a SELECT, F5 to a local panel exports the table
  as CSV. The panel is read-only: changes go through SQL.
- **SQLite files:** F3, F4 or Enter on an SQLite database file opens it
  as a database in the panel, the way an archive opens as a directory (no
  registry entry needed); `..` leads back to the file. dn tells the file
  by its header, not its name: `app.db`, `data.sqlite3` and a browser's
  `History` all open; a `.db` that is not SQLite opens as an ordinary file.
- **SQL window:** an editor on `~/.config/dnfpc/sql/<name>.sql`, kept
  between sessions. Ctrl-R runs the block under the cursor (the lines
  between blank lines); the rows (up to 10000) appear in a grid below.
  In a grid, arrows move the cell, Enter shows the whole value.
- **Passwords:** when a login fails dn asks for the password and offers to
  save it in `~/.config/dnfpc/vault.db` — an SQLite file (mode 0600) whose
  entries are encrypted with a master password (PBKDF2-HMAC-SHA256,
  ChaCha20 + HMAC-SHA256). The master password is asked once per dn run.
  An unsaved password lives in memory until dn exits. Passwords reach the
  clients through their environment (`PGPASSWORD`) or a 0600 temporary
  config file (ClickHouse), never the command line.

## Slow operations

Opening an archive, mounting a disk image, SFTP, (un)mounting and
ejecting disks run external tools (bsdtar, zip, hdiutil, diskutil,
udisksctl, sftp, curl). One that takes longer than 300 ms shows a box
with the operation, the file, a progress bar (a real percentage when the
tool reports one, e.g. hdiutil; a moving block otherwise), a counter
where it means something (archive entries) and the elapsed time. Esc
stops the tool and everything it started.

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

## Media player

An audio player in its own desktop window (Tools → Player, or F3 on a
folder). It queues every audio file under a folder recursively and plays
MP3, M4A, AAC, FLAC, OGG, Opus, WAV, AIFF and WMA. Full spec in
`PLAYER.md`.

The window holds a track list with a cursor, a now-playing line, a progress
bar, a volume bar, a text-mode spectrum analyzer, and a 10-band equalizer.
Tags come from ID3v2, ID3v1 and Vorbis comments.

Playback uses an external decoder, the same pattern as archives and SFTP.
DN probes the `PATH` for `ffplay`, then `mpg123`, then `afplay`; override
the command with `DN_PLAYER_CMD` (`%f` = file, `%s` = start offset).
When no decoder is installed, the window still opens and the status line
says `no player found`.

| Key | Action |
|-----|--------|
| Enter | Play the row under the cursor |
| Space | Play / pause |
| Left / Right | Seek −5 s / +5 s |
| Shift-Left / Shift-Right | Seek −30 s / +30 s |
| Up / Down, PgUp / PgDn, Home / End | Move the cursor in the list |
| + / − | Volume up / down |
| M | Mute |
| V | Visualizer: off → bars → scope |
| E | Equalizer overlay |
| T / Tab | Next equalizer preset |
| R | Repeat: off → all → one |
| S | Shuffle on / off |
| Del | Remove the row from the queue |
| F2 | Save the queue as `.m3u` |
| F3 | Play a folder (queue it recursively) |
| Alt-F8 | Stop and close every player window |
| Esc, F10 | Close the player window |

Playlists load from `.m3u` / `.m3u8` (`#EXTM3U` / `#EXTINF`) and from DN's
own `.dnpl` format. Enter on an audio file opens the player through the
`dn.ext` entry `mp3=@play`, or through the built-in audio-extension check.

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
| Drag: window by title bar, resize by bottom-right corner | ✔ (xterm 1002 motion tracking) |
| Drag: panel divider — change the split (also Alt+[ / Alt+] / Alt+= ) | ✔ |
| Drag: copy files by drag, scrollbar thumb drag | ✖ planned |
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
built in: Tools → Tetris or Ctrl+T. The game is a window: drag it by the
title, leave it in the background (it pauses itself). Arrows move/rotate,
Space drops, P pauses, N starts over after game over, Q/Esc closes it.
`DN_TETRIS_SEQ=IOTSZJL...` fixes the piece sequence (used by the tests).

## LocalSend

DN exchanges files with [LocalSend](https://localsend.org) devices
(protocol v2).

- **Send:** select files in a local panel (or put the cursor on one),
  Tools → LocalSend. The list shows the devices nearby (UDP multicast
  `224.0.0.167:53317`) and fills in as they answer; the first row takes a
  `host:port` by hand. The other device asks its user to accept. Devices
  with Encryption on (HTTPS, the LocalSend default) are reached through
  `curl`; the certificate must hash to the fingerprint the device
  announced, as LocalSend itself checks it.
- **Diagnostics:** `dn --localsend-scan [seconds]` announces, prints every
  discovery packet and HTTP answer, and lists the devices found.
- **Receive:** set `localsend_port=53317` (and optionally
  `localsend_name=...`) in `~/.config/dnfpc/options` and restart DN. DN
  then shows up in other devices' "Nearby devices"; incoming files are
  accepted and saved under their own names in the home directory. When
  the LocalSend app runs on the same machine it owns port 53317: pick
  another port for DN.

## Status

Working: dual panels (classic DN look), full mouse support, pull-down
menus (including Disk and Options), command line execution, the user
menu (F2), the multi-window desktop (viewer and editor windows),
MicroEd, file operations F5/F6/F7/F8 with dialogs, virtual file systems
(archives, disk images, SFTP), configurable colors and confirmations,
window drag/resize by mouse, panel split (mouse or Alt+[ / Alt+]),
help (F1), Tetris, the media player (playlists, volume, visualizer,
equalizer). Not yet: copying files by mouse drag, scrollbar thumb drag.

Known limitations:

- UTF-8 is supported end to end (display, editing, input, dialogs), with
  display width counted in codepoints — double-width CJK characters will
  still misalign a row.
