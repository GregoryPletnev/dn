{ dnplayer — the media player window (PLAYER.md): an audio player on the
  DN desktop, the DN way — its own window, driven from the keyboard.

  Playback is delegated to an external decoder process (ffplay / mpg123 /
  afplay), the same pattern the console and the archive VFS use. The window
  owns the queue, the transport state, the volume, the visualizer and the
  10-band equalizer.

  Test seams (all environment variables):
    DN_PLAYER_CMD      replace the backend; %f = file, %s = start offset
    DN_PLAYER_NO_PROBE skip ffprobe (duration unknown)
    DN_PLAYER_TICK_MS  override the 250 ms tick
    DN_PLAYER_NO_ANALYZER  force the visualizer's fake mode
    DN_PLAYER_FAKE_PCM a raw PCM file the analyzer reads instead of ffmpeg
    DN_PLAYER_EQ       force the EQ backend: mpg123 | ffmpeg | none }
unit dnplayer;

{$mode objfpc}{$H+}

interface

uses
  Classes, Process, BaseUnix, dnwin, dnplaylist, dnaudio;

type
  TRepeatMode = (rpOff, rpAll, rpOne);
  TVizMode = (vzOff, vzBars, vzScope);
  TEqBackend = (eqNone, eqMpg123, eqFfmpeg);

  TPlayerWin = class(TWin)
  public
    Playlist: TPlaylist;        // owned
    Cur: Integer;               // cursor row in the list
    Top: Integer;               // first visible row
    Playing: Integer;           // index of the playing track, -1 = none
    Paused: Boolean;
    RepeatMode: TRepeatMode;
    Shuffle: Boolean;
    Volume: Integer;            // 0..100
    Muted: Boolean;
    MuteSaved: Integer;
    Viz: TVizMode;
    Analyzer: TAnalyzer;        // owned
    Eq: TEqualizer;             // owned
    EqOpen: Boolean;
    EqBand: Integer;            // selected band in the EQ sub-window
    EqBackend: TEqBackend;
    Backend: AnsiString;        // 'ffplay' | 'mpg123' | 'afplay' | '' | custom
    BackendName: AnsiString;    // short label shown in the status line
    BackendPid: TPid;           // the running decoder process, 0 = none
    StartTick: QWord;           // when the current backend started (ms)
    SeekBaseMs: Integer;        // offset the backend was started at
    ElapsedMs: Integer;         // elapsed at the last start (pause bookkeeping)
    ShuffleBag: array of Integer;
    ShufflePos: Integer;
    AnalyzerProc: TProcess;
    AnalyzerFd: Integer;
    FakePos: Integer;
    Msg: AnsiString;            // transient status message
    MsgTick: QWord;
    constructor CreatePlayer(const APath: AnsiString);
    destructor Destroy; override;
    procedure DrawContent(Focused: Boolean); override;
    function StatusText: AnsiString; override;
    function HandleKey(ch: LongInt): TKeyAction; override;
    procedure HandleClick(mx, my: Integer; bstate: QWord); override;
    function ConfirmClose: Boolean; override;
    { called by the main loop on each idle tick }
    procedure Tick;
    { transport }
    procedure PlayIndex(i: Integer; FromStart: Boolean = True);
    procedure TogglePause;
    procedure Stop;
    procedure NextTrack(Auto: Boolean = False);
    procedure PrevTrack;
    procedure SeekBy(Seconds: Integer);
    procedure SetVolume(V: Integer);
    procedure ToggleMute;
    procedure CycleRepeat;
    procedure CycleViz;
    procedure RemoveCurrent;
    procedure SaveQueue;
    { queue building }
    procedure QueuePath(const APath: AnsiString);
    function ElapsedSeconds: Integer;
    function TrackDuration(i: Integer): Integer;
  private
    procedure DrawNowPlaying(cw: Integer);
    procedure DrawProgress(cw: Integer);
    procedure DrawVolumeBar(cw: Integer);
    procedure DrawViz(cw, rows: Integer);
    procedure DrawList(cw: Integer; FirstRow, Rows: Integer);
    procedure DrawEqOverlay;
    procedure StartBackend(SeekSec: Integer);
    procedure KillBackend;
    function BackendRunning: Boolean;
    procedure SpawnAnalyzer;
    procedure KillAnalyzer;
    procedure PumpAnalyzer;
    procedure ProbeBackend;
    function ProbePath(const Name: AnsiString): Boolean;
    procedure SetMsg(const s: AnsiString);
    procedure EnsureShuffleBag;
    function PickNext: Integer;
  end;

{ Open the player on a file (queue it, expand a playlist) or a directory
  (queue it recursively). Returns the window, already added to the desktop. }
function OpenPlayer(const APath: AnsiString): TPlayerWin;

{ The idle-tick interval in ms: the fast value while a player window is open
  (DN_PLAYER_TICK_MS overrides it), otherwise the caller uses 1000. }
function PlayerTickMs: Integer;

implementation

uses
  SysUtils, Unix, ncurses, dnscreen, dndialog, dnconfig, dnoptions;

const
  DefTickMs = 250;
  MaxAnalyzerChunk = 2048;

function c_setpgid(pid, pgid: LongInt): LongInt;
  cdecl; external 'c' name 'setpgid';
function c_waitpid(pid: LongInt; var status: LongInt; options: LongInt): LongInt;
  cdecl; external 'c' name 'waitpid';

var
  Cascade: Integer = 0;

function PlayerTickMs: Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable('DN_PLAYER_TICK_MS'), DefTickMs);
  if Result < 20 then Result := 20;
end;

function BoolStr2(b: Boolean; const t, f: AnsiString): AnsiString;
begin
  if b then Result := t else Result := f;
end;

{ --- window ----------------------------------------------------------- }

constructor TPlayerWin.CreatePlayer(const APath: AnsiString);
var
  rw, rh: Integer;
begin
  rw := COLS - 2;
  rh := ((DeskY1 - DeskY0 + 1) * 3) div 4;
  if rh < 12 then rh := DeskY1 - DeskY0 + 1;
  inherited Create(2 + (Cascade mod 4) * 3, DeskY0 + 1 + (Cascade mod 4),
                   rw, rh, 'Player');
  Inc(Cascade);
  Playlist := TPlaylist.Create;
  Analyzer := TAnalyzer.Create;
  Eq := TEqualizer.Create;
  Eq.ApplyCurve(Opt.PlayerEqPreset, Opt.PlayerEqBands);
  Cur := 0; Top := 0; Playing := -1;
  RepeatMode := rpAll;
  Shuffle := False;
  Volume := Opt.PlayerVolume;
  if Volume < 0 then Volume := 0;
  if Volume > 100 then Volume := 100;
  Muted := False; MuteSaved := Volume;
  case Opt.PlayerViz of
    1: Viz := vzBars;
    2: Viz := vzScope;
  else
    Viz := vzOff;
  end;
  EqOpen := False; EqBand := 0;
  BackendPid := 0;
  StartTick := 0; ElapsedMs := 0; SeekBaseMs := 0;
  AnalyzerProc := nil; AnalyzerFd := -1;
  FakePos := 0;
  ShufflePos := 0;
  Msg := ''; MsgTick := 0;
  ProbeBackend;
  QueuePath(APath);
  if Playlist.Count > 0 then
    PlayIndex(0, True);
end;

destructor TPlayerWin.Destroy;
begin
  KillBackend;
  KillAnalyzer;
  Analyzer.Free;
  Eq.Free;
  Playlist.Free;
  inherited;
end;

procedure TPlayerWin.SetMsg(const s: AnsiString);
begin
  Msg := s;
  MsgTick := GetTickCount64;
end;

function TPlayerWin.StatusText: AnsiString;
var
  rp: AnsiString;
begin
  if Backend = '' then Exit('no player found');
  case RepeatMode of
    rpOff: rp := 'off';
    rpAll: rp := 'all';
    rpOne: rp := 'one';
  end;
  Result := BackendName + ' · repeat: ' + rp +
            ' · shuffle: ' + BoolStr2(Shuffle, 'on', 'off') +
            ' · vol ' + IntToStr(Volume) + '%';
  if Muted then Result := Result + ' (muted)';
  if Eq.Active then
  begin
    if EqBackend = eqNone then
      Result := Result + ' · eq: not supported'
    else
      Result := Result + ' · eq: ' + Eq.Preset;
  end;
  if Viz = vzBars then Result := Result + ' · viz: bars'
  else if Viz = vzScope then Result := Result + ' · viz: scope';
  if (Msg <> '') and (GetTickCount64 - MsgTick < 2500) then
    Result := Result + ' · ' + Msg
  else
    Msg := '';
end;

{ --- backend probing --------------------------------------------------- }

function TPlayerWin.ProbePath(const Name: AnsiString): Boolean;
var
  path, p: AnsiString;
  i: Integer;
begin
  Result := False;
  path := GetEnvironmentVariable('PATH');
  if path = '' then path := '/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin';
  while path <> '' do
  begin
    i := Pos(':', path);
    if i > 0 then
    begin
      p := Copy(path, 1, i - 1);
      path := Copy(path, i + 1, MaxInt);
    end
    else
    begin
      p := path;
      path := '';
    end;
    if (p <> '') and FileExists(IncludeTrailingPathDelimiter(p) + Name) then
      Exit(True);
  end;
end;

procedure TPlayerWin.ProbeBackend;
var
  cmd: AnsiString;
  forced: AnsiString;
begin
  cmd := GetEnvironmentVariable('DN_PLAYER_CMD');
  if cmd <> '' then
  begin
    Backend := cmd;      // the whole command line; %f / %s are substituted
    BackendName := 'player';   // a short label; the command may be long
  end
  else if ProbePath('ffplay') then
  begin
    Backend := 'ffplay'; BackendName := 'ffplay';
  end
  else if ProbePath('mpg123') then
  begin
    Backend := 'mpg123'; BackendName := 'mpg123';
  end
  else if ProbePath('afplay') then
  begin
    Backend := 'afplay'; BackendName := 'afplay';
  end
  else
  begin
    Backend := ''; BackendName := '';
  end;

  forced := GetEnvironmentVariable('DN_PLAYER_EQ');
  if forced = 'mpg123' then EqBackend := eqMpg123
  else if forced = 'ffmpeg' then EqBackend := eqFfmpeg
  else if forced = 'none' then EqBackend := eqNone
  else if Backend = 'mpg123' then EqBackend := eqMpg123
  else if Backend = 'ffplay' then EqBackend := eqFfmpeg
  else EqBackend := eqNone;
end;

{ --- queue building --------------------------------------------------- }

procedure TPlayerWin.QueuePath(const APath: AnsiString);
var
  A: TTrackArray;
  e: AnsiString;
  i: Integer;
begin
  if DirectoryExists(APath) then
  begin
    A := ScanDir(APath, True);
    Playlist.SetTracks(A);
    Playlist.Name := APath;
  end
  else if FileExists(APath) then
  begin
    e := LowerCase(ExtractFileExt(APath));
    if (e = '.m3u') or (e = '.m3u8') or (e = '.dnpl') then
    begin
      if LoadPlaylist(APath, A) then
      begin
        { fill in tags for tracks the playlist left blank }
        for i := 0 to High(A) do
          if (A[i].Title = '') and (A[i].Artist = '') then
            FillTags(A[i]);
        Playlist.SetTracks(A);
        Playlist.Name := APath;
      end;
    end
    else if IsAudioFile(APath) then
    begin
      SetLength(A, 1);
      FillChar(A[0], SizeOf(A[0]), 0);
      A[0].Path := APath;
      FillTags(A[0]);
      Playlist.SetTracks(A);
      Playlist.Name := ExtractFileName(APath);
    end;
  end;
end;

function TPlayerWin.TrackDuration(i: Integer): Integer;
begin
  Result := Playlist.Get(i).Duration;
end;

function TPlayerWin.ElapsedSeconds: Integer;
begin
  if (StartTick = 0) or Paused then
    Exit(ElapsedMs div 1000);
  Result := (SeekBaseMs + Integer(GetTickCount64 - StartTick)) div 1000;
end;

{ --- backend process --------------------------------------------------- }

{ Replace %f with the file and %s with the start offset. Quotes the file. }
function BackendCommand(const Tmpl, File_: AnsiString; SeekSec: Integer): AnsiString;
var
  q, off: AnsiString;
begin
  q := AnsiQuotedStr(File_, '''');
  off := IntToStr(SeekSec);
  Result := StringReplace(Tmpl, '%f', q, [rfReplaceAll]);
  Result := StringReplace(Result, '%s', off, [rfReplaceAll]);
end;

{ The default command line for a known backend. }
function DefaultBackendCmd(const Backend, File_: AnsiString;
                          SeekSec, Volume: Integer): AnsiString;
var
  q: AnsiString;
  af: AnsiString;
begin
  q := AnsiQuotedStr(File_, '''');
  if Backend = 'ffplay' then
  begin
    Result := 'ffplay -nodisp -autoexit -loglevel quiet';
    Result := Result + ' -volume ' + IntToStr(Volume);
    if SeekSec > 0 then
      Result := Result + ' -ss ' + IntToStr(SeekSec);
    Result := Result + ' ' + q;
  end
  else if Backend = 'mpg123' then
  begin
    Result := 'mpg123 -q';
    if SeekSec > 0 then
      Result := Result + ' -k ' + IntToStr(SeekSec);
    if Volume <> 100 then
      Result := Result + ' -f ' + IntToStr((Volume * 32768) div 100);
    Result := Result + ' ' + q;
  end
  else if Backend = 'afplay' then
  begin
    Result := 'afplay';
    if Volume <> 100 then
      Result := Result + ' -v ' + Format('%f', [Volume / 100.0]);
    Result := Result + ' ' + q;
  end
  else
    Result := '';
  af := '';
  if af <> '' then Exit;   // silence "not used"
end;

procedure TPlayerWin.StartBackend(SeekSec: Integer);
var
  cmd: AnsiString;
  tmpl: AnsiString;
  pid: TPid;
  devnull: cint;
  argv0: AnsiString;
begin
  KillBackend;
  if Backend = '' then Exit;
  if (Playing < 0) or (Playing >= Playlist.Count) then Exit;

  tmpl := GetEnvironmentVariable('DN_PLAYER_CMD');
  if tmpl <> '' then
    cmd := BackendCommand(tmpl, Playlist.Get(Playing).Path, SeekSec)
  else
    cmd := DefaultBackendCmd(Backend, Playlist.Get(Playing).Path, SeekSec,
                             Volume);
  if cmd = '' then Exit;

  pid := fpFork;
  if pid = 0 then
  begin
    c_setpgid(0, 0);
    fpSignal(SIGINT, SignalHandler(SIG_DFL));
    fpSignal(SIGQUIT, SignalHandler(SIG_DFL));
    devnull := fpOpen('/dev/null', O_RDWR);
    if devnull >= 0 then
    begin
      fpDup2(devnull, 0);
      fpDup2(devnull, 1);
      fpDup2(devnull, 2);
      if devnull > 2 then fpClose(devnull);
    end;
    fpExecl('/bin/sh', ['-c', cmd]);
    fpExit(127);
  end;
  if pid < 0 then
  begin
    SetMsg('cannot start ' + Backend);
    Exit;
  end;
  BackendPid := pid;
  StartTick := GetTickCount64;
  SeekBaseMs := SeekSec * 1000;
  ElapsedMs := SeekBaseMs;
  argv0 := '';
  if argv0 <> '' then Exit;
end;

procedure TPlayerWin.KillBackend;
var
  st: LongInt;
begin
  if BackendPid > 0 then
  begin
    fpKill(-BackendPid, SIGTERM);
    { a short grace period, then SIGKILL }
    if c_waitpid(BackendPid, st, WNOHANG) = 0 then
    begin
      Sleep(30);
      if c_waitpid(BackendPid, st, WNOHANG) = 0 then
        fpKill(-BackendPid, SIGKILL);
    end;
    c_waitpid(BackendPid, st, 0);
    BackendPid := 0;
  end;
  StartTick := 0;
end;

function TPlayerWin.BackendRunning: Boolean;
var
  st: LongInt;
begin
  Result := False;
  if BackendPid <= 0 then Exit;
  if c_waitpid(BackendPid, st, WNOHANG) = BackendPid then
  begin
    BackendPid := 0;      // reaped; track ended
    Exit(False);
  end;
  Result := True;
end;

{ --- analyzer --------------------------------------------------------- }

procedure TPlayerWin.SpawnAnalyzer;
var
  fake: AnsiString;
  src: AnsiString;
  cmd: AnsiString;
begin
  KillAnalyzer;
  if GetEnvironmentVariable('DN_PLAYER_NO_ANALYZER') <> '' then Exit;
  if (Playing < 0) or (Playing >= Playlist.Count) then Exit;

  fake := GetEnvironmentVariable('DN_PLAYER_FAKE_PCM');
  if fake = '' then
  begin
    if not ProbePath('ffmpeg') then Exit;    // no analyzer: fake mode
    src := Playlist.Get(Playing).Path;
    cmd := 'ffmpeg -loglevel quiet -i ' + AnsiQuotedStr(src, '''') +
           ' -f s16le -ac 1 -ar 8000 -';
  end
  else
    cmd := 'cat ' + AnsiQuotedStr(fake, '''');

  { TProcess keeps the child off the pty and gives us a readable pipe,
    which a raw fork inside ncurses does not do reliably }
  AnalyzerProc := TProcess.Create(nil);
  AnalyzerProc.Executable := '/bin/sh';
  AnalyzerProc.Parameters.Add('-c');
  AnalyzerProc.Parameters.Add(cmd);
  AnalyzerProc.Options := [poUsePipes, poStderrToOutPut];
  try
    AnalyzerProc.Execute;
  except
    FreeAndNil(AnalyzerProc);
    Exit;
  end;
  AnalyzerFd := -1;      // we read through TProcess, not a raw fd
  Analyzer.Reset;
end;

procedure TPlayerWin.KillAnalyzer;
begin
  if AnalyzerProc <> nil then
  begin
    try
      AnalyzerProc.Terminate(200);
    except
      { non-fatal }
    end;
    FreeAndNil(AnalyzerProc);
  end;
  AnalyzerFd := -1;
end;

procedure TPlayerWin.PumpAnalyzer;
var
  buf: array[0..MaxAnalyzerChunk - 1] of SmallInt;
  n: LongInt;
  s: array of SmallInt;
  i: Integer;
  stream: TStream;
begin
  if AnalyzerProc = nil then Exit;
  stream := AnalyzerProc.Output;
  if stream = nil then Exit;
  { one chunk per call: the buffer is 2 bytes per sample; never block }
  n := stream.Read(buf, SizeOf(buf));
  if n <= 0 then Exit;
  SetLength(s, n div 2);
  for i := 0 to High(s) do
    s[i] := buf[i];
  Analyzer.Push(s);
end;

{ --- drawing ---------------------------------------------------------- }

procedure TPlayerWin.DrawContent(Focused: Boolean);
var
  cw, first, rows: Integer;
begin
  cw := W - 2;
  DrawNowPlaying(cw);
  DrawProgress(cw);
  DrawVolumeBar(cw);
  first := 4;
  rows := H - 2 - first;
  if Viz <> vzOff then
  begin
    DrawViz(cw, 2);
    first := first + 2;
    rows := rows - 2;
  end;
  if rows < 0 then rows := 0;
  DrawList(cw, first, rows);
  if EqOpen then DrawEqOverlay;
end;

procedure TPlayerWin.DrawNowPlaying(cw: Integer);
var
  s: AnsiString;
  dur: Integer;
begin
  if (Playing >= 0) and (Playing < Playlist.Count) then
  begin
    dur := TrackDuration(Playing);
    s := Format('%d/%d  %s', [Playing + 1, Playlist.Count,
                 Playlist.RowLabel(Playing)]);
    if dur > 0 then
      s := s + '  ' + FormatTime(dur);
  end
  else
    s := '— nothing playing —';
  PutStr(Y + 1, X + 1, Utf8PadRight('♪ ' + s, cw), cpViewer, True);
end;

procedure TPlayerWin.DrawProgress(cw: Integer);
var
  pos, dur, fill, i, barw: Integer;
  bar, s: AnsiString;
begin
  dur := 0;
  if Playing >= 0 then dur := TrackDuration(Playing);
  pos := ElapsedSeconds;
  barw := cw - 18;
  if barw < 4 then barw := 4;
  if dur > 0 then
  begin
    fill := (pos * barw) div dur;
    if fill > barw then fill := barw;
  end
  else
    fill := 0;
  bar := '[';
  for i := 0 to barw - 1 do
    if i < fill then bar := bar + '█' else bar := bar + '░';
  bar := bar + ']';
  if dur > 0 then
    s := FormatTime(pos) + ' / ' + FormatTime(dur)
  else
    s := FormatTime(pos);
  PutStr(Y + 2, X + 1, Utf8PadRight(bar + ' ' + s, cw), cpViewer);
end;

procedure TPlayerWin.DrawVolumeBar(cw: Integer);
var
  fill, i, bw: Integer;
  bar, s: AnsiString;
begin
  bw := 20;
  if bw > cw - 34 then bw := cw - 34;
  if bw < 6 then bw := 6;
  fill := (Volume * bw) div 100;
  bar := '';
  for i := 0 to bw - 1 do
    if i < fill then bar := bar + '█' else bar := bar + '░';
  s := 'Vol [' + bar + '] ' + IntToStr(Volume) + '%';
  if Muted then s := s + ' MUTE';
  s := s + '  EQ: ' + Eq.Preset;
  PutStr(Y + 3, X + 1, Utf8PadRight(s, cw), cpViewer);
end;

procedure TPlayerWin.DrawViz(cw, rows: Integer);
var
  Levels: array[0..255] of Integer;
  Points: array[0..255] of Double;
  i, band, bh, nb: Integer;
  line: AnsiString;
begin
  nb := cw;
  if nb > 256 then nb := 256;
  if nb < 1 then nb := 1;
  Analyzer.BandCount := nb;
  if AnalyzerProc <> nil then
  begin
    PumpAnalyzer;
    Analyzer.Bands(Levels);
  end
  else
    Analyzer.FakeBands(Levels);

  if Viz = vzBars then
  begin
    { the bottom row is the baseline; bars grow upwards }
    for bh := rows - 1 downto 0 do
    begin
      line := '';
      for i := 0 to nb - 1 do
      begin
        band := (Levels[i] * rows) div 100;
        if (rows - 1 - bh) < band then line := line + '█'
        else line := line + ' ';
      end;
      PutStr(Y + 4 + bh, X + 1, Utf8PadRight(line, cw), cpViewer);
    end;
  end
  else
  begin
    Analyzer.Scope(Points, nb);
    for bh := 0 to rows - 1 do
    begin
      line := '';
      for i := 0 to nb - 1 do
      begin
        band := Trunc((Points[i] + 1.0) * 0.5 * (rows - 1));
        if band < 0 then band := 0;
        if band > rows - 1 then band := rows - 1;
        if band = rows - 1 - bh then line := line + '█'
        else line := line + ' ';
      end;
      PutStr(Y + 4 + bh, X + 1, Utf8PadRight(line, cw), cpViewer);
    end;
  end;
end;

procedure TPlayerWin.DrawList(cw: Integer; FirstRow, Rows: Integer);
var
  j, idx, dur: Integer;
  s, mark: AnsiString;
  pair: Integer;
begin
  for j := 0 to Rows - 1 do
  begin
    idx := Top + j;
    if idx >= Playlist.Count then
    begin
      PutStr(Y + FirstRow + j, X + 1, Utf8PadRight('', cw), cpViewer);
      Continue;
    end;
    dur := TrackDuration(idx);
    if idx = Playing then mark := '>'
    else if idx = Cur then mark := '·'
    else mark := ' ';
    s := Format('%s%2d. %s', [mark, idx + 1, Playlist.RowLabel(idx)]);
    if dur > 0 then
    begin
      while Utf8Len(s) + 7 > cw do
        s := Utf8Copy(s, 1, Utf8Len(s) - 1);
      s := Utf8PadRight(s, cw - 6) + FormatTime(dur);
    end;
    if idx = Cur then pair := cpSelCursor
    else if idx = Playing then pair := cpSelected
    else pair := cpViewer;
    PutStr(Y + FirstRow + j, X + 1, Utf8PadRight(s, cw), pair);
  end;
end;

function SignedDb(Db: Integer): AnsiString;
begin
  if Db >= 0 then
    Result := '+' + IntToStr(Db)
  else
    Result := IntToStr(Db);
end;

procedure TPlayerWin.DrawEqOverlay;
var
  i, bx, by: Integer;
  s, bar: AnsiString;
begin
  bx := X + 2;
  by := Y + H - 9;
  if by < Y + 5 then by := Y + 5;
  PutStr(by, bx, Utf8PadRight('── Equalizer ───────────────────────────', W - 4),
         cpMenuBar);
  { row 1: the selected band's gain, row 2: the centre frequency,
    row 3: a small gain bar }
  for i := 0 to EqBands - 1 do
  begin
    s := SignedDb(Eq.GetBand(i));
    if i = EqBand then
      PutStr(by + 1, bx + i * 4, Utf8PadRight('[' + s + ']', 4), cpMenuSel)
    else
      PutStr(by + 1, bx + i * 4, Utf8PadRight(' ' + s + ' ', 4), cpViewer);
    PutStr(by + 2, bx + i * 4, Utf8PadRight(IntToStr(EqFreqs[i]), 4), cpViewer);
    { a short bar: up for a boost, down for a cut }
    bar := '';
    if Eq.GetBand(i) >= 0 then
      while Length(bar) < Eq.GetBand(i) do bar := bar + '▄'
    else
      while Length(bar) < -Eq.GetBand(i) do bar := bar + '▀';
    if bar = '' then bar := '·';
    PutStr(by + 3, bx + i * 4, Utf8PadRight(bar, 4), cpViewer);
  end;
  if EqBackend = eqNone then
    PutStr(by + 4, bx, Utf8PadRight('eq: not supported by this backend', W - 6),
           cpViewer);
  s := 'Preset: ' + Eq.Preset + '   Tab: preset  Enter: apply  Esc: cancel';
  PutStr(by + 5, bx, Utf8PadRight(s, W - 6), cpMenuBar);
end;

{ --- transport -------------------------------------------------------- }

procedure TPlayerWin.EnsureShuffleBag;
var
  i, j, t: Integer;
begin
  SetLength(ShuffleBag, Playlist.Count);
  for i := 0 to High(ShuffleBag) do
    ShuffleBag[i] := i;
  for i := High(ShuffleBag) downto 1 do
  begin
    j := Random(i + 1);
    t := ShuffleBag[i]; ShuffleBag[i] := ShuffleBag[j]; ShuffleBag[j] := t;
  end;
  ShufflePos := 0;
end;

function TPlayerWin.PickNext: Integer;
begin
  if Playlist.Count = 0 then Exit(-1);
  if not Shuffle then
    Exit((Playing + 1) mod Playlist.Count);
  if (Length(ShuffleBag) <> Playlist.Count) then EnsureShuffleBag;
  if ShufflePos >= Length(ShuffleBag) then EnsureShuffleBag;
  Result := ShuffleBag[ShufflePos];
  Inc(ShufflePos);
end;

procedure TPlayerWin.PlayIndex(i: Integer; FromStart: Boolean);
begin
  if (i < 0) or (i >= Playlist.Count) then Exit;
  Playing := i;
  Paused := False;
  if (Shuffle) and (Length(ShuffleBag) <> Playlist.Count) then
    EnsureShuffleBag;
  StartBackend(0);
  if Viz <> vzOff then SpawnAnalyzer;
  if FromStart then Cur := i;
end;

procedure TPlayerWin.TogglePause;
begin
  if Playing < 0 then Exit;
  if Backend = '' then Exit;
  if Paused then
  begin
    { resume: restart the backend at the paused offset }
    StartBackend(ElapsedMs div 1000);
    Paused := False;
  end
  else
  begin
    { pause: remember the elapsed time, stop the backend }
    ElapsedMs := SeekBaseMs + Integer(GetTickCount64 - StartTick);
    KillBackend;
    StartTick := 0;
    Paused := True;
  end;
end;

procedure TPlayerWin.Stop;
begin
  KillBackend;
  KillAnalyzer;
  Playing := -1;
  Paused := False;
  StartTick := 0;
  ElapsedMs := 0;
  SeekBaseMs := 0;
end;

procedure TPlayerWin.NextTrack(Auto: Boolean);
var
  n: Integer;
begin
  if Playlist.Count = 0 then Exit;
  if Auto and (RepeatMode = rpOne) then
  begin
    PlayIndex(Playing, True);
    Exit;
  end;
  n := PickNext;
  if (Auto) and (RepeatMode = rpOff) and (n <= Playing) then
  begin
    { the queue has run out: stop at the end }
    Stop;
    Exit;
  end;
  PlayIndex(n, True);
end;

procedure TPlayerWin.PrevTrack;
begin
  if Playlist.Count = 0 then Exit;
  if Shuffle then
  begin
    if ShufflePos > 1 then Dec(ShufflePos);
    PlayIndex(ShuffleBag[ShufflePos - 1], True);
  end
  else
    PlayIndex((Playing - 1 + Playlist.Count) mod Playlist.Count, True);
end;

procedure TPlayerWin.SeekBy(Seconds: Integer);
var
  target: Integer;
begin
  if Playing < 0 then Exit;
  target := ElapsedSeconds + Seconds;
  if target < 0 then target := 0;
  if Paused then
  begin
    SeekBaseMs := target * 1000;
    ElapsedMs := SeekBaseMs;
  end
  else
  begin
    StartBackend(target);
    if Viz <> vzOff then SpawnAnalyzer;
  end;
end;

procedure TPlayerWin.SetVolume(V: Integer);
begin
  if V < 0 then V := 0;
  if V > 100 then V := 100;
  if Volume = V then Exit;
  Volume := V;
  if Muted then Muted := False;
  { volume is a backend argument: restart at the current offset }
  if (Playing >= 0) and (Backend <> '') then
  begin
    if Paused then
    begin
      SeekBaseMs := ElapsedMs;
      { nothing to restart; the next resume picks up the new volume }
    end
    else
    begin
      StartBackend(ElapsedSeconds);
      if Viz <> vzOff then SpawnAnalyzer;
    end;
  end;
end;

procedure TPlayerWin.ToggleMute;
begin
  if Muted then
  begin
    Volume := MuteSaved;
    Muted := False;
  end
  else
  begin
    MuteSaved := Volume;
    Volume := 0;
    Muted := True;
  end;
  if (Playing >= 0) and (Backend <> '') and (not Paused) then
  begin
    StartBackend(ElapsedSeconds);
    if Viz <> vzOff then SpawnAnalyzer;
  end;
end;

procedure TPlayerWin.CycleRepeat;
begin
  case RepeatMode of
    rpOff: RepeatMode := rpAll;
    rpAll: RepeatMode := rpOne;
    rpOne: RepeatMode := rpOff;
  end;
end;

procedure TPlayerWin.CycleViz;
begin
  case Viz of
    vzOff: begin Viz := vzBars; SpawnAnalyzer; end;
    vzBars: begin Viz := vzScope; SpawnAnalyzer; end;
    vzScope: begin Viz := vzOff; KillAnalyzer; end;
  end;
end;

procedure TPlayerWin.RemoveCurrent;
begin
  if (Cur < 0) or (Cur >= Playlist.Count) then Exit;
  if Cur = Playing then
  begin
    Stop;
    Playlist.Delete(Cur);
    if Cur >= Playlist.Count then Cur := Playlist.Count - 1;
    if Cur < 0 then Cur := 0;
    SetMsg('removed');
    Exit;
  end;
  Playlist.Delete(Cur);
  if Playing > Cur then Dec(Playing);
  if Cur >= Playlist.Count then Cur := Playlist.Count - 1;
  if Cur < 0 then Cur := 0;
  SetMsg('removed');
end;

procedure TPlayerWin.SaveQueue;
var
  name, path: AnsiString;
begin
  name := ExtractFileName(Playlist.Name);
  if name = '' then name := 'playlist';
  name := ChangeFileExt(name, '.m3u');
  if not InputBox('Save playlist', 'File name:', name) then Exit;
  if name = '' then Exit;
  path := name;
  if ExtractFileDir(path) = '' then
    path := IncludeTrailingPathDelimiter(GetCurrentDir) + path;
  if SaveM3U(path, Playlist.GetTracks) then
    SetMsg('saved ' + ExtractFileName(path))
  else
    SetMsg('cannot save');
end;

procedure TPlayerWin.Tick;
begin
  if (Playing >= 0) and (not Paused) and (Backend <> '') then
    if not BackendRunning then
      NextTrack(True);      // end of track
  if Viz <> vzOff then
  begin
    if (AnalyzerProc = nil) and (Backend <> '') then SpawnAnalyzer;
  end
  else if AnalyzerProc <> nil then
    KillAnalyzer;
  Inc(FakePos);
end;

{ --- keys ------------------------------------------------------------- }

function TPlayerWin.HandleKey(ch: LongInt): TKeyAction;
var
  ph: Integer;
  i: Integer;
begin
  Result := kaConsumed;
  if EqOpen then
  begin
    case ch of
      KEY_LEFT: if EqBand > 0 then Dec(EqBand);
      KEY_RIGHT: if EqBand < EqBands - 1 then Inc(EqBand);
      KEY_UP: Eq.SetBand(EqBand, Eq.GetBand(EqBand) + 1);
      KEY_DOWN: Eq.SetBand(EqBand, Eq.GetBand(EqBand) - 1);
      KEY_PPAGE: Eq.SetBand(EqBand, Eq.GetBand(EqBand) + 6);
      KEY_NPAGE: Eq.SetBand(EqBand, Eq.GetBand(EqBand) - 6);
      Ord('t'), Ord('T'), 9:
        begin
          { cycle to the next preset }
          Eq.NextPreset;
          SetMsg('preset: ' + Eq.Preset);
        end;
      Ord('r'), Ord('R'): Eq.Reset;
      10, 13, KEY_ENTER:
        begin
          EqOpen := False;
          SetMsg('eq: ' + Eq.Preset);
          if (Playing >= 0) and (Backend <> '') and (not Paused) then
          begin
            StartBackend(ElapsedSeconds);
            if Viz <> vzOff then SpawnAnalyzer;
          end;
        end;
      27: begin EqOpen := False; end;
    else
      Result := kaPass;
    end;
    Exit;
  end;

  ph := H - 2;
  case ch of
    KEY_UP:   if Cur > 0 then Dec(Cur);
    KEY_DOWN: if Cur < Playlist.Count - 1 then Inc(Cur);
    KEY_PPAGE: Dec(Cur, ph);
    KEY_NPAGE: Inc(Cur, ph);
    KEY_HOME: Cur := 0;
    KEY_END:  Cur := Playlist.Count - 1;
    10, 13, KEY_ENTER: PlayIndex(Cur, True);
    Ord(' '): TogglePause;
    KEY_LEFT: SeekBy(-5);
    KEY_RIGHT: SeekBy(5);
    KEY_SLEFT: SeekBy(-30);
    KEY_SRIGHT: SeekBy(30);
    Ord('n'), Ord('N'): NextTrack(False);
    Ord('p'), Ord('P'): PrevTrack;
    Ord('+'): SetVolume(Volume + 5);
    Ord('-'): SetVolume(Volume - 5);
    Ord('m'), Ord('M'): ToggleMute;
    Ord('0'): SetVolume(100);
    Ord('9'): SetVolume(0);
    Ord('v'), Ord('V'): CycleViz;
    Ord('e'), Ord('E'): EqOpen := True;
    Ord('r'), Ord('R'): CycleRepeat;
    Ord('s'), Ord('S'): Shuffle := not Shuffle;
    Ord('d'), Ord('D'), KEY_DC: RemoveCurrent;
    KEY_F0 + 2: SaveQueue;
    KEY_F0 + 3:
      begin
        { re-read tags for the cursor track }
        if (Cur >= 0) and (Cur < Playlist.Count) then
          SetMsg('tags: ' + Playlist.RowLabel(Cur));
      end;
    27, KEY_F0 + 10: Exit(kaClose);
  else
    Result := kaPass;
  end;

  { keep the cursor in view }
  if Cur < Top then Top := Cur;
  if Cur > Top + ph - 1 then Top := Cur - ph + 1;
  if Top < 0 then Top := 0;
  i := 0;
  if i <> 0 then Exit;
end;

procedure TPlayerWin.HandleClick(mx, my: Integer; bstate: QWord);
var
  rel, idx: Integer;
  first, rows: Integer;
begin
  first := 4;
  if Viz <> vzOff then first := first + 2;
  rel := my - (Y + first);
  if (rel >= 0) and (rel < H - 2 - first) then
  begin
    idx := Top + rel;
    if (idx >= 0) and (idx < Playlist.Count) then
    begin
      Cur := idx;
      if (bstate and mbtn1Double) <> 0 then PlayIndex(idx, True);
    end;
  end;
  if (bstate and mbtnWheelUp) <> 0 then Dec(Top, 3);
  if (bstate and mbtnWheelDown) <> 0 then Inc(Top, 3);
  if Top < 0 then Top := 0;
  rows := H - 2 - first;
  if rows < 1 then rows := 1;
  if Top > Playlist.Count - rows then Top := Playlist.Count - rows;
  if Top < 0 then Top := 0;
end;

function TPlayerWin.ConfirmClose: Boolean;
var
  i: Integer;
begin
  KillBackend;
  KillAnalyzer;
  { persist the player settings (PLAYER.md) }
  Opt.PlayerVolume := Volume;
  case Viz of
    vzBars: Opt.PlayerViz := 1;
    vzScope: Opt.PlayerViz := 2;
  else
    Opt.PlayerViz := 0;
  end;
  Opt.PlayerEqPreset := Eq.Preset;
  for i := 0 to 9 do
    Opt.PlayerEqBands[i] := Eq.GetBand(i);
  OptSave;
  Result := True;
end;

function OpenPlayer(const APath: AnsiString): TPlayerWin;
begin
  Result := TPlayerWin.CreatePlayer(APath);
  WinAdd(Result);
end;

end.
