# Roadmap

Gap analysis against `original/docs/DN.DOC` (sections in parentheses).
Every milestone lands with end-to-end tests in `tests/` (pty + pyte harness).

Cross-cutting groundwork, addressed as it blocks milestones:

- [x] **Alt keys in the terminal** — done: ESC-prefix reader with
  ungetch push-back for non-printable follow-ups.
- **Config file** (`~/.config/dnfpc/dn.ini`) — persistent options, colors,
  histories, user menu; DN's "Save setup" (5.1).
- [x] **UTF-8 column math** — done: codepoint-based helpers in `dnscreen`,
  used by panels, MicroEd, viewer, dialogs; multi-byte input assembled in
  the key loop. (CJK double-width still pending — needs wcwidth.)
- **Progress dialogs** — long copy/delete/pack need a cancellable gauge
  (DN 3.1); prerequisite for archives and remote FS.

## M1 — Command line & launching (DN 2.1, 2.2, 4.1, 4.2, 17)

- [x] Typed characters go to the command line; Enter executes via
      `$SHELL -c` (curses suspend/resume, like the old F4-editor path)
- [x] Ctrl-O "user screen": show output of the last command(s)
- [x] Command history (Ctrl-E recall, persisted in config)
- [x] Enter on executable file runs it (4.1)
- [x] Point-and-shoot by extension (4.2): `dn.ext`-style config,
      `Enter` on `*.txt` opens MicroEd, etc.
- [x] Ctrl-Enter / Ctrl-A: put current filename into the command line

Size: M. Unlocks the single biggest daily-use gap.

## M2 — Panel power features (DN 1.3–1.5, 2.3–2.11, 3.10, 3.13, 3.14, 3.6)

- [x] Sort modes: name/extension/size/date/unsorted (Alt-S menu + hotkeys)
- [x] File mask filter per panel (Alt-Del / menu)
- [x] Select/deselect/invert by mask: `+`, `-`, `*` (2.3)
- [x] Quick jump: Alt+letter moves to the next file starting with it
- [x] Swap panels (Ctrl-U); ~~hide/show panels~~ pending; re-read via menu
- [ ] Info panel (Ctrl-L) and Quick View (Ctrl-Q) as panel modes
- [ ] Brief/Wide/Full list modes + column setup (1.1, 1.4)
- [x] Compare directories (3.10), directory sizes (Ctrl-G, 3.13)
- [ ] File attributes / chmod dialog (3.14)
- [ ] Make file list from selection (Alt-W, 3.6)

Size: L (many small independent items — good filler between big rocks).

## M3 — VFS layer (architecture)

Refactor `TPanel` from direct `FindFirst` onto a `TVFS` interface
(list / stat / open-read / open-write / mkdir / delete / rename).
Backends:

- [x] **LocalFS** — current behavior extracted behind `TVFS`; all 93
      prior tests still pass unchanged.
- [x] **ArchiveFS** (DN 3.9): Enter on zip/tar/tgz/7z/… browses it as a
      directory; view, copy out (extract), copy in and delete (`.zip` via
      `zip`), edit-in-place writes back. Backend: `bsdtar` + `zip`.
- [~] Pack / extract: copy in/out of an archive panel covers it; explicit
      Shift-F1/F2 dialogs still pending.
- [x] **RemoteFS — the Navigator Link replacement**: SFTP over the OpenSSH
      client (batch mode, ControlMaster reuse). `cd sftp://user@host/path`
      or the Disk menu; copy/move/delete/mkdir across any two VFSes go
      through the stream helpers. FTP/WebDAV (libcurl) still to come.
- [x] **SSH connection manager** (à la redial): folder tree of saved
      sessions in ssh_config format (`~/.config/dnfpc/sessions`, valid for
      real `ssh -G`); connect opens a RemoteFS panel, Ctrl-T a terminal
      login, Ctrl-K ssh-copy-id; add/edit/delete; per-session forwards and
      start dir. UI from the Disk menu / Ctrl-S. (Live port-forward toggles
      pending.)
- [x] List panel: read a file list (Ctrl-W, 2.12) as a virtual `TListVFS`.
- [x] UU encode/decode (Ctrl-F7/F8 or Commands menu, 3.17–3.18): pure
      Pascal, round-trips and interoperates with system `uudecode`.

Size: XL — done bar FTP/WebDAV, pack dialogs, live forward toggles.
Tested with bsdtar (archives), a fake sftp transport driven by
`DN_SFTP_CMD` (remote + sessions), and `ssh -G` config validation.

## M4 — MicroEd & viewer completion (DN 7, 8)

- [ ] Blocks: Shift-arrows + WordStar Ctrl-K family; cut/copy/paste with
      an internal clipboard shared between editor windows (7.3)
- [ ] Undo/redo (multilevel, 7.5)
- [ ] Search & replace with options (7.1)
- [ ] Word wrap / paragraph reformat (7.6)
- [ ] Syntax highlighting: parse the original `DN.HGL` format from
      `original/docs/DN.HGL` (7.7)
- [ ] Go to line, bracket match, dup line — the small Ctrl-Q/Ctrl-K verbs
- [ ] Viewer: hex mode, search (F7), wrap toggle, xlat/codepage tables
      (8.1 — CP866/CP1251 → UTF-8 for viewing old files)
- [ ] Editor macros (7.8) — last, optional

Size: L.

## M5 — Tree & navigation (DN 2.6, 2.14, 2.11, 3.11)

- [ ] Directory tree panel/dialog — **returns Ctrl-T to the tree as in
      DN; Tetris moves to Tools-menu only**
- [ ] Branch mode: flatten a subtree into the panel (Ctrl-H)
- [ ] File find by mask + content (Alt-F7) with results as a list panel
- [ ] Change-directory dialog with history (3.11)

Size: M.

## M6 — Desktop accessories (DN 5.2, 9, 13, 16, 23.4, 10)

- [ ] User menu F2 (`dn.mnu`-compatible format, 5.2) + Quick Run (5.3)
- [ ] Calculator (9) — port `CCALC.PAS` behavior into a window
- [ ] ASCII table (23.4) — with mouse send-to-input as per features.txt
- [ ] SmartPad notepad (16) — MicroEd window over a fixed file
- [ ] System information (13) — Unix flavor: uname/mem/disks
- [ ] Spreadsheet (10) — flagship curiosity; own milestone if ever, last

Size: M (without the spreadsheet).

## M7 — Options, look & feel (DN 5.1, 22.1, 22.3, 23.1, 23.2, 6.2)

- [ ] Options menu backed by the config file; Save setup
- [ ] Color scheme editor (22.3) + a couple of shipped palettes
- [ ] Mouse drag: enable motion tracking (1002) — window move/resize by
      mouse, panel splitter drag, scrollbar drag (features.txt leftovers)
- [ ] Disk menu for Unix: mounted volumes list (/Volumes), df info,
      volume label where applicable (6.2)
- [ ] Keyboard macros (23.2)
- [ ] Screen savers (23.1) — pure fun, keep the DN ones' spirit
- [ ] Multilanguage UI (22.1) — string table, RU + EN
- [ ] Context help (21.1): help topics per dialog, F1 everywhere

Size: L, but every item independent.

## Suggested order

M1 → M2 (can interleave) → M3 → M4 → M5 → M6 → M7.
M3 is the point of no return architecturally — do not start M5's list
panels or M6 before the VFS interface exists, they all build on it.
да)
