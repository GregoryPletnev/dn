# Media player — design & work plan

Status: **done.** This document is the spec for an in-desktop
audio player window: MP3 and friends, playlists, and recursive folder
playback — the DN way, in its own window on the desktop. See
`PLAYER_REPORT.md` for the delivery report and the remaining follow-ups.

## Why

DN has a viewer (F3), an editor (F4) and a console (Tools > Console), but
nothing that *plays* a media file. Today `Enter` on `song.mp3` either does
nothing useful or hands the file to a GUI app outside DN, which breaks the
keyboard-only, stay-in-the-terminal workflow.

The classic DN answer is a desktop window: the player lives on the DN desktop
like the editor and the viewer, obeys F5 zoom / F6 focus / Ctrl-F5 move, and
is driven entirely from the keyboard.

## Scope

In scope (this milestone):

- MP3 and the common formats that `ffmpeg`/`afplay` decode: `.mp3`, `.m4a`,
  `.aac`, `.flac`, `.ogg`, `.opus`, `.wav`, `.aiff`, `.wma`.
- A **playlist window** with a track list, a moving cursor, and the full
  transport: play/pause, next/prev, seek ±5 s / ±30 s, repeat (off/all/one),
  shuffle, remove-from-queue, save queue.
- A **volume bar** drawn in the window (not just a key): `+`/`-` and `M`
  mute, with the level shown as a filled bar and a percentage.
- A **text-mode spectrum analyzer** ("the Winamp animation in a terminal"):
  a live bar-graph driven by the audio spectrum, plus an oscilloscope mode.
- A **10-band text equalizer** with per-band gain, presets, and the `E` key
  to open it — subject to backend support (see "Equalizer" below).
- **Play a directory**: queue every audio file under a folder, recursively.
- **Playlist files**: `.m3u` / `.m3u8` read and written (`#EXTM3U` /
  `#EXTINF`); DN's own `.dnpl` format for saved queues with per-track
  metadata.
- **Tag display**: title / artist / album / duration from ID3v2 (and Vorbis
  comments), shown in the playlist rows and the status line.
- Two equal entry points: **F3 on a directory** opens the player with that
  folder queued recursively, and the **Tools > Player** menu item opens a
  directory picker (default: the active panel directory).
- Point-and-shoot: `Enter` on an audio file opens the player (via the
  `dn.ext` map) instead of the viewer.

Out of scope (explicitly deferred):

- Video playback and any on-screen video rendering.
- Audio CD / DAAP / streaming URLs beyond a plain HTTP `ffplay` fallback.
- Gapless crossfade and ReplayGain normalization.
- A separate audio output backend in Pascal (see "Playback engine" below).
- A graphical (non-text) equalizer curve or skin engine.

## Playback engine

Decision: **drive an external decoder process, do not decode in Pascal.**

Reasons:

- Writing an MP3 decoder (or binding libmad/libmpg123) in FPC is weeks of work
  and adds a native dependency to a pure-Pascal codebase.
- `dn` already shells out for archives (`bsdtar`), archives (`zip`) and SFTP
  (`ssh`); an external player is the same pattern.
- The decoder must be *controllable* (pause, seek, next) and *interruptible*,
  so the choice is a player with a control channel, not a fire-and-forget
  `system()` call.

Backend selection, in order, probing `PATH` at first use and caching the
result:

1. `ffplay` — preferred on both macOS and Linux. Reads every format above,
   accepts `-nodisp -autoexit -ss <sec>` for seek, `-volume` for gain, and
   takes a single file per process. Control by killing and restarting at a new
   offset (pause = kill, resume = restart at the last reported position).
2. `mpg123` — fallback for `.mp3` on Linux where `ffplay` is absent; it has a
   real remote-control mode (`-R`) with `PAUSE` / `JUMP` / `VOLUME` commands,
   which gives exact pause and seek.
3. `afplay` — macOS built-in, last resort. No seek and no pause; the player
   disables those controls and the status line says `seek: n/a`.

A config override `DN_PLAYER_CMD` (env) or `player_cmd` (options) forces a
specific backend; `%f` is the file, `%s` the start offset in seconds. This is
also the test seam: the test suite points `DN_PLAYER_CMD` at a script that
prints a line and sleeps, so no audio device is needed in CI.

Position and duration:

- Duration comes from `ffprobe` (`-show_entries format=duration`) when
  available; otherwise the ID3v2/`TLEN` or Vorbis `LENGTH` tag; otherwise
  unknown, and the progress bar shows only elapsed time.
- Elapsed time is tracked by the player itself from the moment the backend
  starts, plus the seek offset. The player does not parse backend stdout for
  progress: `ffplay` is silent about position. A 250 ms timer advances the
  clock, and the window repaints the progress bar.
- End of track is detected by `waitpid(WNOHANG)` on the backend in the same
  250 ms tick; the player then advances to the next track. A user-initiated
  stop is flagged so it is not mistaken for end-of-track.

## Volume

Volume is a first-class control with a **visible bar**, not a hidden key.

- The level is an integer `0..100`; the window draws it in the now-playing
  block as a filled bar plus a percentage:
  `Vol [██████░░░░░░░░░░] 60%`.
- Keys: `+` / `-` change it by 5; `Shift-+` / `Shift--` by 1; `M` toggles
  mute (remembers the pre-mute level); `0` jumps to 100%, `9` to 0%.
- Backend mapping: `ffplay -volume <0..100>` (its scale is 0..100, linear),
  `mpg123` `VOLUME <0..100>` over the remote-control channel, `afplay -v
  <0.0..1.0>` (linear, so the percentage is divided by 100).
- Volume is a player setting, not a track property: it survives track changes
  and is saved in the config (`player_volume`) so the next session starts at
  the same level.
- The status line mirrors it: `vol 60%` or `vol 60% (muted)`.

## Visualizer — the text-mode "Winamp"

The window can show a live animation of the playing audio. This is what makes
the player feel like a real music player and not a file list.

Two modes, cycled with the `V` key (and a third, `V` off):

1. **Spectrum bars** — a column of `▁▂▃▄▅▆▇█` blocks per band, N bands across
   the window width (N = interior width, typically 40–76). Height per band is
   the log-scaled magnitude of that band. This is the classic equalizer-bar
   look.
2. **Oscilloscope** — the raw waveform drawn left to right, one sample per
   column, using the same block characters (mid-line = zero). Good for seeing
   transients.

Where the data comes from (this is the hard part, and it is why the backend
choice matters):

- The player does not decode audio itself, so it needs a spectrum feed from the
  backend. The clean source is **`ffmpeg` piping raw PCM** to stdout:
  `ffmpeg -i <file> -f s16le -ac 1 -ar 8000 -` gives 8 kHz mono PCM at a
  steady rate, which is more than enough for a 40-band display.
- A second, **muted, background `ffmpeg` process** is spawned *only while the
  visualizer is on*: its stdout feeds the analyzer, its stderr goes to
  `/dev/null`, and it is killed when the visualizer is switched off or the
  window closes. Playback stays on the primary backend, so audio is unaffected.
- The player reads a small chunk (e.g. 1024 samples) per repaint, applies a
  window function (Hann) and a **radix-2 FFT** over 1024 points, folds the
  bins into the display bands logarithmically (20 Hz … 16 kHz), smooths each
  band against the previous frame (a decay of ~0.6) so the bars fall instead of
  flicker, and maps magnitudes to the 8 block heights.
- The FFT is ~80 lines of plain Pascal (iterative Cooley–Tukey, real input via
  a complex FFT of size 1024) — no dependency, and it is unit-testable with
  synthetic sine input.
- If `ffmpeg` is absent, the visualizer falls back to a **fake mode** driven
  by the elapsed-time clock and a smoothed random walk, so the feature still
  demos on any machine. The status line marks it `viz: fake`.
- Cost control: the analyzer reads at most one chunk per 100 ms and skips a
  frame if the window is not visible or the terminal is small (`< 40` cols or
  `< 10` rows), where the visualizer is hidden.

The visualizer takes the space of the track list when it is on and the window is
zoomed; otherwise it is a two-row strip between the progress bar and the list.
`V` cycles off → bars → scope → off.

## Equalizer

A **10-band text equalizer**, opened with `E` (a small sub-window or an overlay
row, not a separate desktop window): bands at 31, 62, 125, 250, 500, 1k, 2k,
4k, 8k, 16k Hz, each `-12..+12 dB`, drawn as a column of `▄` blocks with the
gain printed under each band. `←/→` pick a band, `↑/↓` change the gain, `Tab`
reaches the preset row, `Enter` applies, `Esc` cancels.

Presets: Flat, Rock, Pop, Jazz, Classical, Vocal, Bass Boost, Treble Boost,
plus the user's own saved curve.

**Backend reality — this must be stated honestly:**

- `ffplay` has **no equalizer**. To apply an EQ curve, the playback pipeline
  must become an `ffmpeg` filter chain feeding an output sink:
  `ffmpeg -i <file> -af "equalizer=f=31:g=<dB>,equalizer=f=62:g=<dB>,…" -f
  <sink> -`. The sink is `coreaudio` on macOS, `pulse`/`alsa` on Linux, or
  `ffplay -` reading the filtered stream. This works, but it changes how
  playback is started, so it is a distinct backend mode.
- `mpg123` has a **built-in 15-band equalizer** (`-e`, and `EQUALIZER` /
  `EQUALIZER_RESET` commands over the remote-control channel). On `mpg123`,
  the EQ is exact and live, and it is the preferred backend when the EQ is
  used.
- `afplay` has **no equalizer**. On `afplay`, `E` opens the window, the curve
  can be edited and saved, but the status line says `eq: not supported by
  backend` and the curve has no audible effect.

So the equalizer is delivered in two tiers:

1. **Tier 1 (this milestone)** — the EQ UI, presets, and persistence, wired to
   `mpg123 -e` and to the `ffmpeg -af equalizer` chain when either is
   available. On `afplay` the UI works but is flagged as inaudible.
2. **Tier 2 (deferred)** — a per-band live `ffmpeg` filter chain with the
   visualizer feed, and ReplayGain-aware gain staging.

The chosen curve and preset are saved in the config (`player_eq_band<N>`,
`player_eq_preset`) and restored at startup.

## Architecture

New unit `src/dnplayer.pas` with a `TPlayerWin = class(TWin)`, following the
`dnview.pas` / `dnedit.pas` / `dnconsole.pas` pattern exactly:

- `CreatePlayer(const Path: AnsiString)` — `Path` is a file (queue one track
  and, if it is a playlist, expand it) or a directory (queue the folder
  recursively).
- `DrawContent` — the track list with the cursor row highlighted, a
  now-playing header, a progress bar and a time readout.
- `StatusText` — backend name, repeat/shuffle flags, volume.
- `HandleKey` — transport keys (table below).
- `HandleClick` — click a row to jump to that track, click the progress bar to
  seek, wheel to scroll the list.
- `ConfirmClose` — stop the backend process, never leave a stray `ffplay`.
- `destructor` — `fpKill` the backend and `fpWaitPid` it, so no zombie is
  left when the window closes.

New unit `src/dnplaylist.pas` (pure logic, no ncurses — unit-tested):

- `TPlaylist` class: an ordered list of `TTrack` records
  (`Path`, `Title`, `Artist`, `Album`, `Duration`).
- `LoadM3U(Path)`, `SaveM3U(Path)` — `#EXTM3U` / `#EXTINF:<sec>,<artist - title>`
  plus bare path lines; relative paths resolved against the playlist's folder.
- `ScanDir(Dir, Recursive)` — collect audio files by extension, sorted by
  name (or by directory order), hidden files skipped.
- `ReadTags(Path)` — ID3v2.3/2.4 (`TIT2`, `TPE1`, `TALB`, `TLEN`) and
  ID3v1 fallback; Vorbis comments (`TITLE`, `ARTIST`, `ALBUM`) for Ogg/Opus.
  Tag reading is best-effort: on any parse error the track keeps its filename.
- `FormatTime(Sec)`, `ParseM3U` round-trip helpers.

New unit `src/dnaudio.pas` (pure logic, no ncurses — unit-tested):

- `TAnalyzer` class: `Push(PCM: array of SmallInt)` accumulates samples;
  `Bands(const Levels: array of Integer)` returns per-band magnitudes for the
  spectrum display, with decay smoothing.
- `Fft1024(var Re, Im: array of Double)` — iterative radix-2 Cooley–Tukey,
  real input expanded to 1024 complex points; unit-tested against a synthetic
  sine (peak lands in the expected bin).
- `Hann1024` window table, log-band folding (20 Hz … 16 kHz), magnitude →
  block-height mapping.
- `TEqualizer` record: 10 gains in dB, named presets, `FilterChain` returns the
  `ffmpeg -af` string and the `mpg123 -e` argument list.

Window layout (interior, `W` × `H` cells). Two-row visualizer strip shown when
`V` is on; the volume bar sits under the progress bar:

```
╔═ Player — <folder or playlist> ════════════════════[■]═[↕]╗
║ ♪ 03/17  Artist — Title                            2:41 ║   now playing
║ [████████████░░░░░░░░░░░░░░░░░░░░] 0:42 / 3:18      ║   progress
║ Vol [████████████░░░░░░░░] 60%   EQ: Rock   viz: bars ║   volume/EQ/viz
║ ▁▃▅█▇▅▃▂▁▂▄▆█▇▅▃▂▁▃▅▇█▆▄▂▁▂▃▅▆▇█▅▃▂▁▂▄▅▇▆▄▃▂▁▃▅▆█▇▅▃▂  ║   spectrum
║──────────────────────────────────────────────────────║
║  1. Artist — Title                                  2:41 ║
║ >2. Other Artist — Other Title                      3:18 ║   cursor row
║  3. ...                                                  ║
║──────────────────────────────────────────────────────║
║ ffplay · repeat: all · shuffle: off · vol 60% · eq: on  ║   status
╚════════════════════════════════════════════════════════╝
```

Transport keys (window focused):

| Key            | Action                                  |
|----------------|-----------------------------------------|
| Enter          | play the row under the cursor            |
| Space          | play / pause                            |
| Left / Right   | seek −5s / +5s                          |
| Shift-Left / Shift-Right | seek −30s / +30s               |
| Up / Down      | move the cursor in the list               |
| PgUp / PgDn    | cursor by a page                         |
| Home / End     | first / last track                       |
| N / P          | next / previous track                    |
| `+` / `-`      | volume up / down (5% steps)              |
| Shift-`+` / Shift-`-` | volume by 1%                       |
| M              | mute / unmute (remembers the level)      |
| `0` / `9`      | volume to 100% / 0%                      |
| V              | cycle visualizer: off → bars → scope      |
| E              | open the 10-band equalizer               |
| R              | cycle repeat: off → all → one             |
| S              | toggle shuffle                          |
| D              | remove the cursor row from the queue      |
| Del            | same as `D`                              |
| F2             | save the queue as `.m3u` (asks for a name)|
| F3             | read tags again for the cursor track      |
| F5             | zoom (handled by the desktop)             |
| Esc            | close the window                         |

In the equalizer sub-window:

| Key            | Action                                  |
|----------------|-----------------------------------------|
| Left / Right   | select a band                            |
| Up / Down      | gain ±1 dB for the selected band         |
| PgUp / PgDn    | gain ±6 dB                               |
| Tab            | reach the preset row                     |
| Enter          | apply and close                          |
| Esc            | cancel (restore the previous curve)      |

While the panels have focus:

| Key                | Action                                          |
|--------------------|-------------------------------------------------|
| F3 on a directory  | open the player, queue the folder recursively    |
| Enter on audio     | open the player with that file                   |
| Alt-F8             | stop playback (the backend process)              |

`F3` keeps its viewer behavior for files and gains a new meaning for
directories (today `F3` on a directory is a no-op). The **Tools > Player**
menu item opens the same window through a directory picker, so both paths are
equal and neither is a hidden shortcut.

## Work plan

Each step lands with tests in `tests/` and leaves `make test` green.

1. **`dnplaylist.pas` skeleton** — `TTrack`, `TPlaylist`, `ScanDir`,
   `LoadM3U`/`SaveM3U`, `FormatTime`. Unit tests only, no UI. This is the
   largest chunk of pure logic and it needs no terminal.
2. **Tag reading** — ID3v2.3/2.4 and ID3v1 in the same unit; Vorbis comments
   for Ogg/Opus. Unit tests with hand-built byte buffers.
3. **`dnplayer.pas` window** — list rendering, cursor, selection, scrolling,
   progress bar; no audio yet. TUI tests open the window and assert on rows.
4. **Backend launcher** — `TPlayerBackend` class: probe `PATH`, `fpFork` +
   `fpExecl`, non-blocking `waitpid` poll from the 250 ms tick. Tests point
   `DN_PLAYER_CMD` at a shell script that prints and sleeps.
5. **Transport controls** — play/pause/stop/next/prev/seek, repeat and
   shuffle, end-of-track advance. Tests drive keys and assert on the status line.
6. **Volume** — the level state, the drawn bar, the keys, mute, backend
   mapping, and config persistence. TUI tests assert on the bar and the status.
7. **`dnaudio.pas` + visualizer** — the FFT and analyzer with unit tests on a
   synthetic sine; the spectrum/scope rendering and the `V` cycle; the muted
   `ffmpeg` PCM feeder and its lifecycle; the fake mode when `ffmpeg` is absent.
8. **Equalizer** — `TEqualizer`, presets, the sub-window UI, persistence, and
   the backend mapping (`mpg123 -e` and the `ffmpeg -af equalizer` chain); the
   `eq: not supported` flag on `afplay`.
9. **Directory queue and playlists** — `F3` on a folder and `Enter` on an
   audio file scan/queue; F2 saves the queue; `.m3u` and `.dnpl` load. Tests
   with a nested fixture tree.
10. **Integration** — `dn.ext` entry `mp3=@play`, `Tools > Player` menu item
    (`cmPlayer`) with a directory picker, the `F3`-on-directory branch in
    `DoView`, the point-and-shoot path in `EnterOrLaunch`, Alt-F8 stop,
    `ConfirmClose`. End-to-end tests through the menu, through `F3` on a
    folder, and through `Enter` on a file.
11. **Docs** — `README.md` section, `ROADMAP.md` M6 entry, `features.txt`
    cross-check, `PLAYER.md` status flipped to done. DONE.

## Delivery notes

Steps 1–11 are implemented. `bin/unittests` has 331 green checks;
`tests/test_player.py` has 10 green TUI tests. Follow-ups and known gaps
are listed in `PLAYER_REPORT.md`.

## Test seams

- `DN_PLAYER_CMD` — replaces the backend with any command; `%f` = file,
  `%s` = start offset. The test script writes `PLAYING <file>` and sleeps.
- `DN_PLAYER_NO_PROBE` — skip `ffprobe`, treat every duration as unknown, so
  tests do not depend on the media toolchain.
- `DN_PLAYER_TICK_MS` — override the 250 ms tick for fast, deterministic
  end-of-track tests.
- `DN_PLAYER_NO_ANALYZER` — force the visualizer's fake mode (random-walk
  bars), so visualizer tests do not need `ffmpeg` or an audio device.
- `DN_PLAYER_FAKE_PCM` — a file of raw PCM the analyzer reads instead of
  spawning `ffmpeg`; a synthetic sine in the fixture makes the band assertions
  deterministic.
- `DN_PLAYER_EQ` — force the EQ backend (`mpg123` / `ffmpeg` / `none`) so the
  "not supported" path is testable on any machine.

## Risks

- **No backend installed.** The window must still open and show the queue; the
  status line says `no player found — install ffmpeg or mpg123`, and every
  transport key is a no-op. The window never crashes.
- **`ffplay` pause.** `ffplay` has no pause channel, so pause is implemented
  as stop + remember offset, resume = start at that offset. The progress bar
  may jump on resume by up to one tick; that is acceptable.
- **Killing the child.** The backend must run in its own process group
  (`setpgid`) so `SIGTERM` to `-pid` also kills the decoder thread, exactly
  as `dnconsole.pas` does. Window close, Alt-F8 and program exit all stop it.
  This applies to the analyzer's `ffmpeg` process too.
- **Tag parsing.** Malformed tags are common in the wild; `ReadTags` must never
  raise — on any error it returns the filename as the title and duration 0.
- **Visualizer cost.** The analyzer must never block the UI: reads are
  non-blocking with a bounded chunk per tick, and if the PCM pipe stalls the
  display freezes on the last frame instead of hanging the window.
- **Equalizer honesty.** `afplay` has no EQ; the window must say so in plain
  words rather than show a curve that does nothing. `ffplay` has no EQ either, so
  the EQ path must switch the playback pipeline to `ffmpeg -af … -f <sink>`, and
  the sink must exist (`coreaudio`/`pulse`/`alsa`) or the EQ is unavailable.

## Where it plugs in

- `src/dn.pas` — `uses dnplayer`; `cmPlayer` in `RunCommand` (opens the
  directory picker); the `F3`-on-directory branch in `DoView`; the
  audio-extension branch in `EnterOrLaunch`; `Alt-F8` stop; stop the backend
  on quit.
- `src/dnmenu.pas` — `cmPlayer = 34`; `AddItem('Player', 'F3 on a folder',
  cmPlayer)` under the **Tools** menu, before `Console`.
- `src/dnconfig.pas` — extend `ExtCommand` so `@play` maps to the player
  window instead of a shell command.
- `src/dnoptions.pas` — persist `player_volume`, `player_visualizer`,
  `player_eq_preset` and `player_eq_band<N>`.
- `Makefile` — add `src/dnplayer.pas`, `src/dnplaylist.pas` and
  `src/dnaudio.pas` to the `$(BIN)` prerequisites.
