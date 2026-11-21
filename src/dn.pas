{ dn — DN - DataNavigator: a Dos Navigator look-and-feel file manager
  for the modern terminal. FPC + ncurses, macOS / Linux. }
program dn;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads, clocale, Unix, BaseUnix, termio,{$endif}
  SysUtils, Classes, ncurses,
  dnscreen, dnpanel, dnmenu, dndialog, dnfileops, dntetris,
  dnwin, dnview, dnedit, dnconfig, dnoptions, dntermid, dnfonts, dnvfs, dnarcvfs, dnmount,
  dnsftp, dnsession, dnsessui, dnuu, dnusermenu, dnsaver, dnconsole, dngpm,
  dnplaylist, dnplayer, dnlsproto, dnls, dnlsdisc, dnlsident, dnpath,
  dndb, dndbvfs, dngrid, dndbui, dnvault, dnfind,
  dndisks, dndisksui,
  dnhttp, dnhtml, dncss, dnlayout, dnjs, dnbrowser;

{$ifdef darwin}
function setenv(name, value: PChar; overwrite: LongInt): LongInt;
  cdecl; external 'c';

{ The app bundle ships Homebrew's libncursesw, which only searches
  Homebrew's terminfo path — absent on machines without Homebrew
  ("Error opening terminal"). Point it at the terminfo copy bundled in
  Resources plus the system database. }
procedure SetupTerminfo;
var
  dirs, res: AnsiString;
begin
  if GetEnvironmentVariable('TERMINFO') <> '' then Exit;
  if GetEnvironmentVariable('TERMINFO_DIRS') <> '' then Exit;
  res := ExpandFileName(ExtractFileDir(ExpandFileName(ParamStr(0))) +
                        '/../Resources/terminfo');
  dirs := '/usr/share/terminfo';
  if DirectoryExists(res) then
    dirs := res + ':' + dirs;
  setenv('TERMINFO_DIRS', PChar(dirs), 1);
end;
{$endif}

const
  DNVersion = '1.1';
  FKeyLabels: array[1..10] of AnsiString =
    ('Help', 'UserMn', 'View', 'Edit', 'Copy', 'RenMov', 'MkDir', 'Delete', 'PullDn', 'Exit');
  FKeyLabelsWin: array[1..10] of AnsiString =
    ('Help', 'Save', 'Close', '', 'Zoom', 'Next', 'Find', '', 'PullDn', 'Close');

var
  LeftP, RightP: TPanel;
  ActiveP: TPanel;
  Quit: Boolean = False;
  FocusWin: TWin = nil;         // nil = panels have the focus
  MoveMode: Boolean = False;    // Ctrl-F5 window move/resize mode
  CmdLine: AnsiString = '';
  MaskBuf: AnsiString = '*';
  CmdHist: TStringList;
  HistPos: Integer = -1;
  { our own double-click detection (ncurses click synthesis is disabled) }
  LastClickPanel: TPanel = nil;
  LastClickIdx: Integer = -1;
  LastClickTick: QWord = 0;
  { panel split column, 0 = middle of the screen (Alt-[/], divider drag) }
  PanelSplit: Integer = 0;
  { a URL given on the command line: opens the browser once the desktop runs }
  StartUrl: AnsiString = '';

procedure DoBrowser; forward;
procedure OpenBrowserWin(const AUrl: AnsiString); forward;
procedure MaybeOpenStartUrl; forward;

type
  TDragMode = (dmNone, dmMoveWin, dmResizeWin, dmSplit);

var
  { mouse drag in progress (button-motion events, xterm 1002) }
  Drag: TDragMode = dmNone;
  DragWin: TWin = nil;
  DragOffX, DragOffY: Integer;

{ True when any player window is open: the main loop then uses a fast
  timeout so the visualizer animates. }
function PlayerActive: Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to WinCount - 1 do
    if Wins[i] is TPlayerWin then Exit(True);
end;

{ Advance every open player window by one tick. }
procedure TickPlayers;
var
  i: Integer;
begin
  for i := 0 to WinCount - 1 do
    if Wins[i] is TPlayerWin then TPlayerWin(Wins[i]).Tick;
end;

{ True when a Tetris game is running (not paused, not over): the main
  loop then wakes every TetrisTickMs for gravity. }
function GameActive: Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to WinCount - 1 do
    if (Wins[i] is TTetrisWin) and TTetrisWin(Wins[i]).Running then
      Exit(True);
end;

{ Gravity for every game window; one without the focus pauses itself. }
procedure TickGames;
var
  i: Integer;
begin
  for i := 0 to WinCount - 1 do
    if Wins[i] is TTetrisWin then
      TTetrisWin(Wins[i]).Tick(Wins[i] = FocusWin);
end;

{ Tools > Tetris / Ctrl-T: open the game window, or focus the open one. }
procedure DoTetris;
var
  w: TTetrisWin;
begin
  w := OpenTetris;
  if w <> nil then FocusWin := w;
end;

{ Stop and close every player window (Alt-F8, or on quit). }
procedure StopPlayers;
var
  i: Integer;
begin
  for i := WinCount - 1 downto 0 do
    if Wins[i] is TPlayerWin then
      TPlayerWin(Wins[i]).Stop;
end;

procedure DrawMenuBar;
begin
  DrawBar(-1);
  PutStr(0, COLS - 9, FormatDateTime('hh:nn:ss', Now), cpClock);
end;

procedure DrawCmdLine;
var
  s, prompt: AnsiString;
  pl: Integer;
begin
  FillRow(LINES - 2, 0, COLS, cpCmdLine);
  prompt := ActiveP.DisplayPath + '>';
  s := prompt + CmdLine;
  pl := Length(prompt);
  if Length(s) > COLS - 2 then
  begin
    pl := pl - (Length(s) - (COLS - 2));
    s := Copy(s, Length(s) - (COLS - 3), COLS - 2);
  end;
  PutStr(LINES - 2, 0, s, cpCmdLine);
  { DN draws the directory brighter than the typed command }
  if pl > 0 then PutStr(LINES - 2, 0, Copy(s, 1, pl), cpCmdPrompt);
  PutStr(LINES - 2, Length(s), ' ', cpCursor);   // block cursor
end;

procedure DrawFKeyBar;
var
  i, slot, x: Integer;
  lbl: AnsiString;
begin
  FillRow(LINES - 1, 0, COLS, cpFKeyNum);
  slot := COLS div 10;
  for i := 1 to 10 do
  begin
    x := (i - 1) * slot;
    if FocusWin <> nil then lbl := FKeyLabelsWin[i] else lbl := FKeyLabels[i];
    PutStr(LINES - 1, x, PadLeft(IntToStr(i), 2), cpFKeyNum);
    PutStr(LINES - 1, x + 2, PadRight(lbl, slot - 2), cpMenuBar);
  end;
end;

const
  MinPanelW = 20;

procedure Layout;
var
  pw: Integer;
begin
  pw := PanelSplit;
  if pw <= 0 then pw := COLS div 2;
  if pw > COLS - MinPanelW then pw := COLS - MinPanelW;
  if pw < MinPanelW then pw := MinPanelW;
  if (pw < MinPanelW) or (pw > COLS - MinPanelW) then
    pw := COLS div 2;   // terminal too narrow for a custom split
  LeftP.X0 := 0;   LeftP.W := pw;         LeftP.H := LINES - 4;
  RightP.X0 := pw; RightP.W := COLS - pw; RightP.H := LINES - 4;
end;

procedure SetSplit(col: Integer);
begin
  if col < MinPanelW then col := MinPanelW;
  if col > COLS - MinPanelW then col := COLS - MinPanelW;
  PanelSplit := col;
end;

procedure DrawBase;
begin
  erase;
  Layout;
  DeskY0 := 1;
  DeskY1 := LINES - 3;
  DrawMenuBar;
  LeftP.Draw;
  RightP.Draw;
  DrawCmdLine;
  DrawFKeyBar;
  WinDrawAll(FocusWin);
end;

procedure DrawAll;
begin
  DrawBase;
  refresh;
end;

procedure SwitchPanel;
begin
  LeftP.Active := not LeftP.Active;
  RightP.Active := not RightP.Active;
  if LeftP.Active then ActiveP := LeftP else ActiveP := RightP;
end;

procedure SetActive(p: TPanel);
begin
  ActiveP := p;
  LeftP.Active := p = LeftP;
  RightP.Active := p = RightP;
end;

function OtherPanel: TPanel;
begin
  if ActiveP = LeftP then Result := RightP else Result := LeftP;
end;

procedure ReloadPanels;
begin
  LeftP.Load;
  RightP.Load;
end;

{ --- file operations --------------------------------------------------- }

{ Selected file names, or the file under the cursor ('..' never included). }
procedure GetTargets(L: TStringList);
var
  i: Integer;
begin
  L.Clear;
  for i := 0 to High(ActiveP.Files) do
    if ActiveP.Files[i].Sel then
      L.Add(ActiveP.Files[i].Name);
  if (L.Count = 0) and (ActiveP.CurFile.Name <> '') and
     (ActiveP.CurFile.Name <> '..') then
    L.Add(ActiveP.CurFile.Name);
end;

function TargetIsDir(const Name: AnsiString): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(ActiveP.Files) do
    if ActiveP.Files[i].Name = Name then
      Exit(ActiveP.Files[i].IsDir);
end;

function TmpName: AnsiString;
begin
  Result := GetTempDir + 'dncp-' + IntToStr(GetProcessID) + '-' +
            IntToStr(Random(1000000));
end;

function TargetLabel(L: TStringList): AnsiString;
begin
  if L.Count = 1 then
    Result := '"' + L[0] + '"'
  else
    Result := IntToStr(L.Count) + ' files';
end;

procedure DoCopyOrMove(IsMove: Boolean);
var
  L: TStringList;
  i: Integer;
  err, verb, src, dst, tmp, tmp2: AnsiString;
  ok, isdir: Boolean;
begin
  L := TStringList.Create;
  try
    GetTargets(L);
    if L.Count = 0 then Exit;
    if IsMove then verb := 'Move' else verb := 'Copy';
    if MsgBox(verb, verb + ' ' + TargetLabel(L) + ' to' + #10 +
              OtherPanel.DisplayPath + ' ?', ['Yes', 'No']) <> 0 then
      Exit;
    for i := 0 to L.Count - 1 do
    begin
      src := VfsJoin(ActiveP.Path, L[i]);
      dst := VfsJoin(OtherPanel.Path, L[i]);
      isdir := TargetIsDir(L[i]);
      { overwrite check is local-target only: remote VFSes have no cheap
        existence test }
      if Opt.ConfirmOverwrite and not isdir and
         OtherPanel.Vfs.IsLocal and FileExists(dst) then
        case MsgBox('Overwrite',
                    'Overwrite "' + L[i] + '" ?', ['Yes', 'No', 'Cancel']) of
          0: ;
          1: Continue;
        else
          Break;
        end;
      if ActiveP.Vfs.IsLocal and OtherPanel.Vfs.IsLocal then
      begin
        { fast local path (rename on move) }
        if IsMove then ok := MoveTree(src, dst, err)
        else ok := CopyTree(src, dst, err);
      end
      else
      begin
        if OtherPanel.Vfs.IsLocal then
        begin
          if isdir then ok := ActiveP.Vfs.GetTree(src, dst, err)
          else ok := ActiveP.Vfs.GetFile(src, dst, err);
        end
        else if ActiveP.Vfs.IsLocal then
        begin
          if isdir then ok := OtherPanel.Vfs.PutTree(src, dst, err)
          else ok := OtherPanel.Vfs.PutFile(src, dst, err);
        end
        else
        begin
          tmp := TmpName;
          if isdir then
            ok := ActiveP.Vfs.GetTree(src, tmp, err) and
                  OtherPanel.Vfs.PutTree(tmp, dst, err)
          else
            ok := ActiveP.Vfs.GetFile(src, tmp, err) and
                  OtherPanel.Vfs.PutFile(tmp, dst, err);
          DeleteTree(tmp, tmp2);
        end;
        if ok and IsMove then
          ok := ActiveP.Vfs.DeletePath(src, isdir, err);
      end;
      if not ok then
      begin
        MsgBox('Error', err, ['OK']);
        Break;
      end;
    end;
    ReloadPanels;
  finally
    L.Free;
  end;
end;

procedure DoDelete;
var
  L: TStringList;
  i: Integer;
  err: AnsiString;
begin
  L := TStringList.Create;
  try
    GetTargets(L);
    if L.Count = 0 then Exit;
    if Opt.ConfirmDelete and
       (MsgBox('Delete', 'Delete ' + TargetLabel(L) + ' ?', ['Yes', 'No']) <> 0) then
      Exit;
    for i := 0 to L.Count - 1 do
      if not ActiveP.Vfs.DeletePath(VfsJoin(ActiveP.Path, L[i]),
                                    TargetIsDir(L[i]), err) then
      begin
        MsgBox('Error', err, ['OK']);
        Break;
      end;
    ReloadPanels;
  finally
    L.Free;
  end;
end;

procedure DoQuit;
begin
  if Opt.ConfirmExit and
     (MsgBox('Exit', 'Quit DN - DataNavigator ?', ['Yes', 'No']) <> 0) then
    Exit;
  Quit := True;
end;

procedure DoMkDir;
var
  name, i2: AnsiString;
  i: Integer;
begin
  name := '';
  if not InputBox('Make directory', 'Directory name:', name) then Exit;
  if name = '' then Exit;
  if not ActiveP.Vfs.MakeDir(VfsJoin(ActiveP.Path, name), i2) then
  begin
    MsgBox('Error', 'Cannot create directory "' + name + '"'#10 + i2, ['OK']);
    Exit;
  end;
  ReloadPanels;
  for i := 0 to High(ActiveP.Files) do
    if ActiveP.Files[i].Name = name then
    begin
      ActiveP.Cur := i;
      Break;
    end;
end;

{ --- command line ------------------------------------------------------ }

{$ifdef unix}
{ system()-like shell run: the child gets default SIGINT/SIGQUIT while
  dn ignores them (set at startup) — Ctrl-C aborts the command, not the
  file manager. fpSystem must not be used here: it leaves the parent's
  disposition in place, so ^C during a long command killed dn itself. }
procedure RunShell(const cmd: AnsiString);
var
  pid: TPid;
  status: cint;
begin
  pid := fpFork;
  if pid = 0 then
  begin
    fpSignal(SIGINT, SignalHandler(SIG_DFL));
    fpSignal(SIGQUIT, SignalHandler(SIG_DFL));
    fpExecl('/bin/sh', ['-c', cmd]);
    fpExit(127);
  end;
  if pid > 0 then
    fpWaitPid(pid, status, 0);
end;

{ raw byte input for the endwin'ed (shell) screen. NB: ECHO must be
  termio.ECHO — a bare ECHO resolves to ncurses' echo() function. IEXTEN
  must go too, or ^O is eaten by the driver as the VDISCARD character;
  ISIG goes so ^C at a pause is an ordinary byte, not a fatal SIGINT. }
procedure ShellTtyRaw(out saved: TermIOS);
var
  t: TermIOS;
begin
  { endwin leaves the tty canonical: a plain read would wait for Enter }
  TCGetAttr(0, saved);
  t := saved;
  t.c_lflag := t.c_lflag and
               LongWord(not (ICANON or termio.ECHO or IEXTEN or ISIG));
  t.c_cc[VMIN] := 1;
  t.c_cc[VTIME] := 0;
  TCSetAttr(0, TCSANOW, t);
end;

procedure WaitAnyKey;
var
  saved: TermIOS;
  b: Char;
begin
  ShellTtyRaw(saved);
  b := #0;
  fpRead(0, b, 1);
  TCSetAttr(0, TCSANOW, saved);
end;
{$endif}

{ Pause = show "-- Press any key --" before returning to the panels
  (user-menu commands: the user wants to read the output) }
procedure ShellExec(const cmd, dir: AnsiString; Pause: Boolean = False);
var
  old: AnsiString;
begin
  ScrSuspend;
  WriteLn;
  WriteLn(dir, '> ', cmd);
  Flush(Output);
  old := GetCurrentDir;
  SetCurrentDir(dir);
  {$ifdef unix}
  RunShell(cmd);
  {$endif}
  SetCurrentDir(old);
  if Pause then
  begin
    WriteLn;
    Write('-- Press any key --');
    Flush(Output);
    {$ifdef unix}
    WaitAnyKey;
    {$endif}
  end;
  ScrResume;
  ReloadPanels;
end;

procedure ShowUserScreen;
{$ifdef unix}
var
  saved: TermIOS;
  b: Char;
  line, dir, old, arg: AnsiString;
  histAt: Integer;

  procedure Prompt;
  begin
    Write(dir, '> ', line);
    Flush(Output);
  end;

  { erase the typed line from the screen (one column per codepoint) }
  procedure EraseInput;
  var
    n: Integer;
  begin
    for n := 1 to Utf8Len(line) do
      Write(#8' '#8);
    line := '';
  end;

  { after ESC: is a terminal sequence following? swallow it if so }
  function SwallowEscSeq: Boolean;
  var
    t: TermIOS;
    c: Char;
    got: Boolean;
  begin
    TCGetAttr(0, t);
    t.c_cc[VMIN] := 0;
    t.c_cc[VTIME] := 1;             // 100 ms: sequences arrive at once
    TCSetAttr(0, TCSANOW, t);
    Result := False;
    c := #0;
    got := fpRead(0, c, 1) = 1;
    if got and (c in ['[', 'O']) then
    begin
      Result := True;
      repeat
        c := #0;
        if fpRead(0, c, 1) <> 1 then Break;
      until not (c in ['0'..'9', ';']);
      { arrows recall the command history }
      if (c = 'A') and (CmdHist.Count > 0) and (histAt > 0) then
      begin
        Dec(histAt);
        EraseInput;
        line := CmdHist[histAt];
        Write(line);
      end
      else if c = 'B' then
      begin
        EraseInput;
        if histAt < CmdHist.Count - 1 then
        begin
          Inc(histAt);
          line := CmdHist[histAt];
        end
        else
          histAt := CmdHist.Count;
        Write(line);
      end;
      Flush(Output);
    end;
    t.c_cc[VMIN] := 1;
    t.c_cc[VTIME] := 0;
    TCSetAttr(0, TCSANOW, t);
  end;

  procedure RunLine;
  begin
    WriteLn;
    line := Trim(line);
    if line = '' then
    begin
      Prompt;
      Exit;
    end;
    if (CmdHist.Count = 0) or (CmdHist[CmdHist.Count - 1] <> line) then
    begin
      CmdHist.Add(line);
      HistorySave(CmdHist);
    end;
    histAt := CmdHist.Count;
    if (line = 'cd') or (Copy(line, 1, 3) = 'cd ') then
    begin
      arg := Trim(Copy(line, 3, MaxInt));
      if arg = '' then arg := GetUserDir;
      if arg[1] <> '/' then arg := dir + '/' + arg;
      arg := ExpandFileName(arg);
      if DirectoryExists(arg) then
        dir := arg
      else
        WriteLn('cd: no such directory: ', arg);
    end
    else
    begin
      { the child gets the original cooked terminal }
      TCSetAttr(0, TCSANOW, saved);
      old := GetCurrentDir;
      SetCurrentDir(dir);
      RunShell(line);
      SetCurrentDir(old);
      ShellTtyRaw(saved);
    end;
    line := '';
    Prompt;
  end;

begin
  { MC-style Ctrl-O: the shell screen with a live prompt. Commands run
    on the real terminal (interactive full-screen programs included);
    Ctrl-O — or Esc on an empty line — returns to the panels }
  if ActiveP.Vfs.IsLocal then dir := ActiveP.Path else dir := GetCurrentDir;
  histAt := CmdHist.Count;
  ScrSuspend;
  WriteLn;
  WriteLn('-- Ctrl-O returns to DN --');
  ShellTtyRaw(saved);
  line := '';
  Prompt;
  repeat
    b := #0;
    if fpRead(0, b, 1) <= 0 then Break;
    case b of
      #15: Break;                                  // Ctrl-O
      #27: if not SwallowEscSeq then
           begin
             if line = '' then Break;              // bare Esc on empty line
             EraseInput;
           end;
      #10, #13: RunLine;
      #8, #127:
        if line <> '' then
        begin
          while (line <> '') and ((Ord(line[Length(line)]) and $C0) = $80) do
            SetLength(line, Length(line) - 1);
          SetLength(line, Length(line) - 1);
          Write(#8' '#8);
          Flush(Output);
        end;
      #3:                                          // Ctrl-C drops the line
        begin
          WriteLn('^C');
          line := '';
          Prompt;
        end;
      #21: EraseInput;                             // Ctrl-U
    else
      if b >= #32 then                             // ASCII and UTF-8 bytes
      begin
        line := line + b;
        Write(b);
        Flush(Output);
      end;
    end;
  until False;
  TCSetAttr(0, TCSANOW, saved);
  ScrResume;
  ReloadPanels;
end;
{$else}
begin
end;
{$endif}

procedure DoChangeDir(arg: AnsiString);
var
  p, target, port, rpath, err: AnsiString;
  sv: TSftpVFS;
  items: TVfsItems;
begin
  arg := Trim(arg);
  { cd sftp://user@host[:port]/path — open a remote panel (DN 12 reborn) }
  if ParseSftpUrl(arg, target, port, rpath) then
  begin
    sv := TSftpVFS.Create(target, port);
    if sv.List(rpath, items, err) then
      ActiveP.SetVfs(sv, rpath)
    else
    begin
      sv.Free;
      MsgBox('sftp', 'Cannot connect:'#10 + err, ['OK']);
    end;
    Exit;
  end;
  if (arg = '') or (arg = '~') then
    arg := GetEnvironmentVariable('HOME')
  else if Copy(arg, 1, 2) = '~/' then
    arg := GetEnvironmentVariable('HOME') + Copy(arg, 2, MaxInt);
  if (arg <> '') and (arg[1] <> '/') then
  begin
    if not ActiveP.Vfs.IsLocal then
    begin
      MsgBox('cd', 'Relative cd is not supported on a remote panel.', ['OK']);
      Exit;
    end;
    p := IncludeTrailingPathDelimiter(ActiveP.Path) + arg;
  end
  else
    p := arg;
  p := ExpandFileName(p);
  if DirectoryExists(p) then
  begin
    if not ActiveP.Vfs.IsLocal then
      ActiveP.SetVfs(LocalVFS, ExcludeTrailingPathDelimiter(p))
    else
    begin
      ActiveP.Path := ExcludeTrailingPathDelimiter(p);
      ActiveP.Cur := 0;
      ActiveP.Top := 0;
      ActiveP.Load;
    end;
    if ActiveP.Path = '' then
    begin
      ActiveP.Path := '/';
      ActiveP.Load;
    end;
  end
  else
    MsgBox('cd', 'No such directory:'#10 + p, ['OK']);
end;

procedure CmdExec;
var
  cmd: AnsiString;
begin
  cmd := Trim(CmdLine);
  CmdLine := '';
  HistPos := -1;
  if cmd = '' then Exit;
  if (CmdHist.Count = 0) or (CmdHist[CmdHist.Count - 1] <> cmd) then
  begin
    CmdHist.Add(cmd);
    HistorySave(CmdHist);
  end;
  if (cmd = 'cd') or (Copy(cmd, 1, 3) = 'cd ') then
    DoChangeDir(Copy(cmd, 3, MaxInt))
  else if cmd = 'exit' then
    DoQuit
  else if LooksLikeUrl(cmd) then
    { a URL on the command line opens the browser instead of the shell }
    OpenBrowserWin(cmd)
  else if ActiveP.Vfs.IsLocal then
    ShellExec(cmd, ActiveP.Path)
  else
    ShellExec(cmd, GetCurrentDir);
end;

procedure HistRecall(dir: Integer);
begin
  if CmdHist.Count = 0 then Exit;
  if dir < 0 then
  begin
    if HistPos < 0 then
      HistPos := CmdHist.Count - 1
    else if HistPos > 0 then
      Dec(HistPos);
  end
  else
  begin
    if HistPos < 0 then Exit;
    Inc(HistPos);
    if HistPos > CmdHist.Count - 1 then
    begin
      HistPos := -1;
      CmdLine := '';
      Exit;
    end;
  end;
  CmdLine := CmdHist[HistPos];
end;

{ Enter on a file: dn.ext mapping first, then the executable bit (4.1/4.2) }
procedure TryLaunch;
var
  f: TFileRec;
  full, ext, cmd: AnsiString;
  w: TWin;
begin
  f := ActiveP.CurFile;
  if (f.Name = '') or (f.Name = '..') then Exit;
  if not ActiveP.Vfs.IsLocal then Exit;
  full := VfsJoin(ActiveP.Path, f.Name);
  ext := LowerCase(Copy(ExtractFileExt(f.Name), 2, MaxInt));
  cmd := ExtCommand(ext);
  if cmd = '@edit' then
  begin
    w := OpenEditor(full);
    if w <> nil then FocusWin := w;
  end
  else if cmd = '@view' then
  begin
    w := OpenViewer(full);
    if w <> nil then FocusWin := w;
  end
  else if cmd = '@browse' then
    OpenBrowserWin(full)
  else if cmd = '@play' then
    FocusWin := OpenPlayer(full)
  else if cmd <> '' then
    ShellExec(StringReplace(cmd, '%f', AnsiQuotedStr(full, ''''),
              [rfReplaceAll]), ActiveP.Path)
  else if IsAudioFile(f.Name) then
    FocusWin := OpenPlayer(full)
  {$ifdef unix}
  else if fpAccess(PChar(full), X_OK) = 0 then
    ShellExec(AnsiQuotedStr(full, ''''), ActiveP.Path)
  {$endif}
  ;
end;

{ Databases (Disk menu, Ctrl-Q): pick a connection, open it in the active
  panel or in an SQL window. }
procedure DoDatabases;
var
  c: TDbConn;
  v: TDbVFS;
  items: TVfsItems;
  err, here: AnsiString;
begin
  case DbManager(c) of
    daOpen:
      begin
        if ActiveP.Vfs.IsLocal then here := ActiveP.Path else here := GetCurrentDir;
        v := TDbVFS.CreateDb(c, here);
        if v.List('', items, err) then
          ActiveP.SetVfs(v, '')
        else
        begin
          v.Free;
          if err <> 'cancelled' then
            MsgBox('Databases', 'Cannot open ' + c.Name + ':'#10 + err, ['OK']);
        end;
      end;
    daSql: FocusWin := OpenSqlWindow(c, '');
  end;
end;

{ F3/F4/Enter on an SQLite file in a local panel: browse it as a
  database, the way an archive opens as a directory. False when the file
  under the cursor is not one. }
function OpenSqliteFile: Boolean;
var
  full, err: AnsiString;
  v: TDbVFS;
  items: TVfsItems;
begin
  Result := False;
  if not ActiveP.Vfs.IsLocal or ActiveP.CurFile.IsDir then Exit;
  full := VfsJoin(ActiveP.Path, ActiveP.CurFile.Name);
  if not IsSqliteFile(full) then Exit;
  Result := True;
  v := TDbVFS.CreateDb(SqliteFileConn(full), ActiveP.Path);
  v.LocalCursor := ActiveP.CurFile.Name;
  if v.List('', items, err) then
    ActiveP.SetVfs(v, '')
  else
  begin
    v.Free;
    if err <> 'cancelled' then
      MsgBox('SQLite', 'Cannot open ' + ActiveP.CurFile.Name + ':'#10 + err, ['OK']);
  end;
end;

{ the table under the cursor of a database panel ('' when on a schema) }
function DbPanelTable(out V: TDbVFS; out Path: AnsiString): Boolean;
begin
  Result := False;
  V := nil;
  Path := '';
  if not (ActiveP.Vfs is TDbVFS) then Exit;
  V := TDbVFS(ActiveP.Vfs);
  if ActiveP.CurFile.IsDir or (ActiveP.CurFile.Name = '') or
     (ActiveP.CurFile.Name = '..') then Exit;
  Path := VfsJoin(ActiveP.Path, ActiveP.CurFile.Name);
  Result := True;
end;

{ F3/Enter on a table: its first rows in a grid }
procedure DoDbPreview;
var
  v: TDbVFS;
  path: AnsiString;
  w: TGridWin;
begin
  if not DbPanelTable(v, path) then Exit;
  w := OpenQueryGrid(v.Conn, v.PreviewSql(path, 1000),
                     v.Conn.Name + ': ' + ActiveP.CurFile.Name);
  if w <> nil then FocusWin := w;
end;

{ F4 in a database panel: an SQL window, with a SELECT for the table }
procedure DoDbSql;
var
  v: TDbVFS;
  path: AnsiString;
begin
  if DbPanelTable(v, path) then
    FocusWin := OpenSqlWindow(v.Conn, v.PreviewSql(path, 100))
  else if v <> nil then
    FocusWin := OpenSqlWindow(v.Conn, '');
end;

var
  LastFind: TFindOptions = (Masks: '*'; Text: ''; Hex: ''; TypeFilter: '';
    Advanced: False; Recursive: True; CaseSensitive: False; WholeWords: False;
    Hidden: False; Scope: fsCurrent; DateAfter: ''; DateBefore: '';
    SizeGreater: ''; SizeLess: ''; OnlyReadOnly: False; OnlyExecutable: False);

{ the last results, kept so that the panel can show them again after the
  user went to a hit; FindSaveResults keeps them across sessions }
var
  KeptHits: TFindHits;
  KeptRoot, KeptTitle: AnsiString;

{ Commands > Find results: the last search in the active panel again }
procedure DoFindResults;
begin
  if Length(KeptHits) = 0 then
    FindLoadResults(KeptRoot, KeptTitle, KeptHits);
  if Length(KeptHits) = 0 then
  begin
    MsgBox('Find results', 'There are no saved find results.', ['OK']);
    Exit;
  end;
  ActiveP.SetVfs(TFindVFS.CreateFind(KeptRoot, KeptTitle, KeptHits), KeptRoot);
end;

{ Find File (Alt-F7): the DN dialog, then the hits in the active panel }
procedure DoFindFile;
var
  roots: array of AnsiString;
  root, err: AnsiString;
  hits: TFindHits;
  i: Integer;
  done: Boolean;
begin
  if not FindDialog(LastFind) then Exit;
  { the panel's own directory; a search from the results searches their root }
  if ActiveP.Vfs is TFindVFS then root := TFindVFS(ActiveP.Vfs).Root
  else if ActiveP.Vfs.IsLocal then root := ActiveP.Path
  else root := GetCurrentDir;
  SetLength(roots, 0);
  case LastFind.Scope of
    fsCurrent:
      begin
        SetLength(roots, 1);
        roots[0] := root;
      end;
    fsSelected:
      begin
        if ActiveP.Vfs.IsLocal then
          for i := 0 to High(ActiveP.Files) do
            if ActiveP.Files[i].Sel then
            begin
              SetLength(roots, Length(roots) + 1);
              roots[High(roots)] := VfsJoin(ActiveP.Path, ActiveP.Files[i].Name);
            end;
        { nothing selected: the item under the cursor, as DN did }
        if (Length(roots) = 0) and ActiveP.Vfs.IsLocal and
           (ActiveP.CurFile.Name <> '') and (ActiveP.CurFile.Name <> '..') then
        begin
          SetLength(roots, 1);
          roots[0] := VfsJoin(ActiveP.Path, ActiveP.CurFile.Name);
        end;
        if Length(roots) = 0 then
        begin
          MsgBox('Find file', 'Nothing is selected.', ['OK']);
          Exit;
        end;
      end;
    fsHome:
      begin
        root := ExcludeTrailingPathDelimiter(GetUserDir);
        SetLength(roots, 1);
        roots[0] := root;
      end;
    fsDisk:
      begin
        root := '/';
        SetLength(roots, 1);
        roots[0] := root;
      end;
  end;
  done := FindFiles(LastFind, roots, hits, err);
  if err <> '' then
  begin
    MsgBox('Find file', err, ['OK']);
    Exit;
  end;
  if Length(hits) = 0 then
  begin
    if done then MsgBox('Find file', 'No files found.', ['OK']);
    Exit;
  end;
  KeptHits := hits;
  KeptRoot := root;
  KeptTitle := FindTitle(LastFind);
  FindSaveResults(KeptRoot, KeptTitle, KeptHits);
  ActiveP.SetVfs(TFindVFS.CreateFind(root, KeptTitle, hits), root);
end;

{ Enter in the find results: a directory opens for real, a file is shown
  in its own directory with the cursor on it }
procedure FindResultEnter;
var
  full: AnsiString;
  i: Integer;
begin
  full := TFindVFS(ActiveP.Vfs).FullPath(ActiveP.CurFile.Name);
  if ActiveP.CurFile.IsDir then
  begin
    ActiveP.SetVfs(LocalVFS, full);
    Exit;
  end;
  ActiveP.SetVfs(LocalVFS, ExtractFileDir(full));
  for i := 0 to High(ActiveP.Files) do
    if ActiveP.Files[i].Name = ExtractFileName(full) then
    begin
      ActiveP.Cur := i;
      Break;
    end;
end;

procedure EnterOrLaunch;
var
  av: TArchiveVFS;
  mv: TMountVFS;
  items: TVfsItems;
  err, full: AnsiString;
begin
  if (ActiveP.Vfs is TFindVFS) and (ActiveP.CurFile.Name <> '') and
     (ActiveP.CurFile.Name <> '..') then
  begin
    FindResultEnter;
    Exit;
  end;
  if ActiveP.CurFile.IsDir then
  begin
    ActiveP.EnterCurrent;
    Exit;
  end;
  if ActiveP.Vfs is TDbVFS then
  begin
    DoDbPreview;
    Exit;
  end;
  if OpenSqliteFile then Exit;
  { disk images (dmg, iso, …) auto-mount and open as directories }
  if ActiveP.Vfs.IsLocal and IsImageName(ActiveP.CurFile.Name) then
  begin
    full := VfsJoin(ActiveP.Path, ActiveP.CurFile.Name);
    if MountImage(full, mv, err) then
    begin
      ActiveP.SetVfs(mv, '');
      Exit;
    end;
    { mount failed: .iso still opens read-only via the archive VFS }
    if not IsArchiveName(ActiveP.CurFile.Name) then
    begin
      MsgBox('Mount', 'Cannot mount image:'#10 + err, ['OK']);
      Exit;
    end;
  end;
  { archives open as directories (DN 3.9) }
  if ActiveP.Vfs.IsLocal and IsArchiveName(ActiveP.CurFile.Name) then
  begin
    full := VfsJoin(ActiveP.Path, ActiveP.CurFile.Name);
    av := TArchiveVFS.Create(full);
    if av.List('', items, err) then
    begin
      ActiveP.SetVfs(av, '');
      Exit;
    end;
    av.Free;
    MsgBox('Archive', 'Cannot open archive:'#10 + err, ['OK']);
    Exit;
  end;
  TryLaunch;
end;

procedure ConnectSftp(const Target, Port, Dir: AnsiString);
var
  sv: TSftpVFS;
  items: TVfsItems;
  err, d: AnsiString;
begin
  d := Dir;
  if d = '' then d := '.';
  sv := TSftpVFS.Create(Target, Port);
  if sv.List(d, items, err) then
    ActiveP.SetVfs(sv, d)
  else
  begin
    sv.Free;
    MsgBox('sftp', 'Cannot connect to ' + Target + ':'#10 + err, ['OK']);
  end;
end;

procedure RunSshInteractive(const cmd: AnsiString);
begin
  ScrSuspend;
  WriteLn;
  {$ifdef unix}
  RunShell(cmd);
  {$endif}
  Write('-- Press any key --');
  Flush(Output);
  {$ifdef unix}
  WaitAnyKey;
  {$endif}
  ScrResume;
end;

procedure DoSessions;
var
  sess: TSession;
  target, port, dir: AnsiString;
begin
  case SessionManager(sess) of
    srConnect:
      begin
        SessionTarget(sess, target, port, dir);
        ConnectSftp(target, port, dir);
      end;
    srTerminal:
      RunSshInteractive(SessionSshCmd(sess));
    srCopyId:
      RunSshInteractive(SessionCopyIdCmd(sess));
  end;
end;

procedure DoSftpConnect;
var
  url, target, port, path: AnsiString;
begin
  url := 'sftp://';
  if not InputBox('Connect', 'sftp URL (sftp://user@host/path):', url) then Exit;
  if ParseSftpUrl(url, target, port, path) then
    ConnectSftp(target, port, path)
  else
    MsgBox('Connect', 'Not a valid sftp:// URL.', ['OK']);
end;

{ Disk > Disks: the removable-media window; Enter on a mounted volume
  opens its mount point in the active panel }
procedure DoDisks;
var
  path: AnsiString;
begin
  if DisksManager(path) = drOpen then
  begin
    if not ActiveP.Vfs.IsLocal then
      ActiveP.SetVfs(LocalVFS, path)
    else
    begin
      ActiveP.Path := path;
      ActiveP.Cur := 0;
      ActiveP.Top := 0;
      ActiveP.Load;
    end;
    if ActiveP.Path = '' then
    begin
      ActiveP.Path := '/';
      ActiveP.Load;
    end;
  end;
end;

procedure SortDialog(p: TPanel);
var
  i: Integer;
begin
  i := MsgBox('Sort', 'Sort panel by:', ['Name', 'Ext', 'Size', 'Date', 'Unsort']);
  case i of
    0: p.SortMode := smName;
    1: p.SortMode := smExt;
    2: p.SortMode := smSize;
    3: p.SortMode := smDate;
    4: p.SortMode := smUnsorted;
  else
    Exit;
  end;
  p.Load;
end;

procedure FilterDialog(p: TPanel);
var
  m: AnsiString;
begin
  m := p.Mask;
  if not InputBox('Filter', 'File mask (empty = all files):', m) then Exit;
  p.Mask := Trim(m);
  p.Load;
end;

procedure SwapPanels;
var
  t: TPanel;
begin
  t := LeftP;
  LeftP := RightP;
  RightP := t;
end;

procedure CountDirSize;
var
  f: TFileRec;
begin
  f := ActiveP.CurFile;
  if not f.IsDir or (f.Name = '..') then Exit;
  if not ActiveP.Vfs.IsLocal then Exit;
  ActiveP.Files[ActiveP.Cur].Size :=
    TreeSize(VfsJoin(ActiveP.Path, f.Name));
  ActiveP.Files[ActiveP.Cur].SizeKnown := True;
end;

{ DN 3.10: select files that differ (by name+size) from the other panel }
procedure CompareDirs;

  procedure MarkDiff(a, b: TPanel);
  var
    i, j: Integer;
    found: Boolean;
  begin
    for i := 0 to High(a.Files) do
    begin
      if a.Files[i].IsDir then Continue;
      found := False;
      for j := 0 to High(b.Files) do
        if not b.Files[j].IsDir and (a.Files[i].Name = b.Files[j].Name) and
           (a.Files[i].Size = b.Files[j].Size) then
        begin
          found := True;
          Break;
        end;
      a.Files[i].Sel := not found;
    end;
  end;

begin
  MarkDiff(LeftP, RightP);
  MarkDiff(RightP, LeftP);
end;

{ local path of the current file; for VFS panels extract to a temp copy }
function MaterializeCurrent(out LocalPath: AnsiString): Boolean;
var
  err: AnsiString;
begin
  Result := False;
  if (ActiveP.CurFile.Name = '') or ActiveP.CurFile.IsDir then Exit;
  if ActiveP.Vfs.IsLocal then
  begin
    LocalPath := VfsJoin(ActiveP.Path, ActiveP.CurFile.Name);
    Exit(True);
  end;
  LocalPath := TmpName + '-' + ActiveP.CurFile.Name;
  if not ActiveP.Vfs.GetFile(VfsJoin(ActiveP.Path, ActiveP.CurFile.Name),
                             LocalPath, err) then
  begin
    MsgBox('Error', err, ['OK']);
    Exit;
  end;
  Result := True;
end;

procedure DoReadFileList;
var
  path: AnsiString;
  L, paths: TStringList;
  i: Integer;
  lv: TListVFS;
begin
  path := '';
  if not InputBox('Read file list', 'List file (one path per line):', path) then
    Exit;
  path := Trim(path);
  if (path = '') then Exit;
  if (path[1] <> '/') then
    path := IncludeTrailingPathDelimiter(ActiveP.Path) + path;
  if not FileExists(path) then
  begin
    MsgBox('Read file list', 'No such file:'#10 + path, ['OK']);
    Exit;
  end;
  L := TStringList.Create;
  paths := TStringList.Create;
  try
    L.LoadFromFile(path);
    for i := 0 to L.Count - 1 do
      if Trim(L[i]) <> '' then
      begin
        if Trim(L[i])[1] = '/' then paths.Add(Trim(L[i]))
        else paths.Add(IncludeTrailingPathDelimiter(ActiveP.Path) + Trim(L[i]));
      end;
  finally
    L.Free;
  end;
  if paths.Count = 0 then
  begin
    paths.Free;
    Exit;
  end;
  lv := TListVFS.Create(ExtractFileName(path), paths);
  ActiveP.SetVfs(lv, '/');
end;

procedure DoUUEncode;
var
  f: TFileRec;
  src, dst, err: AnsiString;
begin
  f := ActiveP.CurFile;
  if (f.Name = '') or f.IsDir or not ActiveP.Vfs.IsLocal then Exit;
  src := VfsJoin(ActiveP.Path, f.Name);
  dst := VfsJoin(ActiveP.Path, f.Name + '.uue');
  if UUEncodeFile(src, dst, err) then ReloadPanels
  else MsgBox('UU-encode', err, ['OK']);
end;

procedure DoUUDecode;
var
  f: TFileRec;
  src, dst, base, err: AnsiString;
begin
  f := ActiveP.CurFile;
  if (f.Name = '') or f.IsDir or not ActiveP.Vfs.IsLocal then Exit;
  src := VfsJoin(ActiveP.Path, f.Name);
  base := f.Name;
  if LowerCase(ExtractFileExt(base)) = '.uue' then
    base := Copy(base, 1, Length(base) - 4);
  dst := VfsJoin(ActiveP.Path, base + '.decoded');
  if UUDecodeFile(src, dst, err) then ReloadPanels
  else MsgBox('UU-decode', err, ['OK']);
end;

procedure DoView;
var
  w: TWin;
  lp: AnsiString;
begin
  if ActiveP.Vfs is TDbVFS then
  begin
    DoDbPreview;
    Exit;
  end;
  if OpenSqliteFile then Exit;
  { F3 on a directory opens the player, queued recursively (PLAYER.md) }
  if ActiveP.CurFile.IsDir and (ActiveP.CurFile.Name <> '..') and
     ActiveP.Vfs.IsLocal then
  begin
    FocusWin := OpenPlayer(VfsJoin(ActiveP.Path, ActiveP.CurFile.Name));
    Exit;
  end;
  if not MaterializeCurrent(lp) then Exit;
  w := OpenViewer(lp);
  if w <> nil then FocusWin := w;
end;

{ Tools > Player: open the player on the active panel directory. }
procedure DoPlayer;
begin
  if ActiveP.Vfs.IsLocal then
    FocusWin := OpenPlayer(ActiveP.Path)
  else
    FocusWin := OpenPlayer(GetCurrentDir);
end;

{ Tools > Browser: open the browser on the URL prompt, or on the file under
  the cursor when it is an html file in a local panel. }
procedure DoBrowser;
var
  url, ext: AnsiString;
begin
  url := '';
  if ActiveP.Vfs.IsLocal and (ActiveP.CurFile.Name <> '') and
     (ActiveP.CurFile.Name <> '..') and not ActiveP.CurFile.IsDir then
  begin
    ext := LowerCase(Copy(ExtractFileExt(ActiveP.CurFile.Name), 2, MaxInt));
    if (ext = 'htm') or (ext = 'html') or (ext = 'xhtml') or (ext = 'svg')
       or (ext = 'xml') then
      url := VfsJoin(ActiveP.Path, ActiveP.CurFile.Name);
  end;
  if url = '' then
  begin
    url := 'about:blank';
    if not InputBox('Browser', 'Open URL:', url) then Exit;
    url := Trim(url);
    if url = '' then Exit;
  end;
  OpenBrowserWin(url);
end;

{ Opens the browser on AUrl and focuses it. }
procedure OpenBrowserWin(const AUrl: AnsiString);
begin
  FocusWin := OpenBrowser(AUrl);
end;

{ Open the command-line URL, once, after the first frame. }
procedure MaybeOpenStartUrl;
begin
  if StartUrl = '' then Exit;
  OpenBrowserWin(StartUrl);
  StartUrl := '';
end;

{ Start (or refresh) LocalSend discovery. Answering other peers'
  announces only makes sense while the receive helper runs. }
procedure LsDiscEnsure(out Err: AnsiString);
var
  info: TDeviceInfo;
  identErr: AnsiString;
begin
  { the certificate HTTPS peers ask for; without openssl discovery and
    plain HTTP still work }
  LsEnsureIdentity(identErr);
  info := LsSelfInfo(Opt.LocalSendPort);
  if not LsRunning then
    info.Port := 0;            // discovery serves /register itself
  LsDiscStart(info, LsRunning, Err);
end;

const
  LsManualItem = 'Enter address manually...';
  LsSearchItem = '  searching for devices...';
  LsReannounceMs = 3000;

var
  LsPickDevs: TLsDevices;        // the devices behind rows 1.. of the picker
  LsPickNote: AnsiString;        // why discovery is off, '' when it runs
  LsPickAnnounced: QWord;

{ LiveListDialog refresh: read packets, re-announce now and then, rebuild
  the rows. Row 0 is the manual entry, so arriving devices (appended at
  the end) never move the row under the cursor. }
function LsPickRefresh(Items: TStrings): Boolean;
var
  i: Integer;
  before: AnsiString;
begin
  before := Items.Text;
  if LsDiscRunning then
  begin
    LsDiscPoll;
    DrainLsPipe;                 // /register answers come through the helper
    if GetTickCount64 - LsPickAnnounced >= LsReannounceMs then
    begin
      LsDiscAnnounce;
      LsPickAnnounced := GetTickCount64;
    end;
  end;
  LsPickDevs := LsDiscDevices;
  Items.BeginUpdate;
  try
    Items.Clear;
    Items.Add(LsManualItem);
    for i := 0 to High(LsPickDevs) do
      Items.Add(DeviceLabel(LsPickDevs[i]));
    if Length(LsPickDevs) = 0 then
    begin
      if LsPickNote <> '' then
        Items.Add('  discovery off: ' + LsPickNote)
      else if LsDiscLastError <> '' then
        Items.Add('  ' + LsDiscLastError)
      else
        Items.Add(LsSearchItem);
    end;
  finally
    Items.EndUpdate;
  end;
  Result := Items.Text <> before;
end;

{ The device picker: the address of the chosen peer ("ip:port", or
  "https://ip:port"), the typed address, or '' when cancelled. PinFp is
  the chosen device's fingerprint ('' for a typed address). }
function LsPickTarget(out PinFp: AnsiString): AnsiString;
var
  items: TStringList;
  idx: Integer;
  typed: AnsiString;
begin
  Result := '';
  PinFp := '';
  LsDiscEnsure(LsPickNote);
  LsPickAnnounced := GetTickCount64;
  items := TStringList.Create;
  try
    repeat
      LsPickRefresh(items);
      idx := LiveListDialog('LocalSend: send to', items, @LsPickRefresh,
                            200, 64);
      if idx < 0 then Exit;
      if idx = 0 then
      begin
        typed := GetEnvironmentVariable('DN_LS_ENDPOINT');
        if not InputBox('LocalSend', 'Send to host:port', typed) then
          Continue;
        if typed <> '' then Exit(typed);
        Continue;
      end;
      if idx - 1 <= High(LsPickDevs) then
      begin
        if LsPickDevs[idx - 1].Info.Protocol = 'https' then
          PinFp := LsPickDevs[idx - 1].Info.Fingerprint;
        Exit(DeviceBase(LsPickDevs[idx - 1]));
      end;
      { the "searching" row: keep looking }
    until False;
  finally
    items.Free;
  end;
end;

{ LocalSend: pick a nearby device (or type an address), then send the
  selected files to it. The helper process is not needed for the send
  path: the client runs in this process, and the dialog blocks only for
  the duration of the send. }
procedure DoLocalSend;
var
  base, err, pin: AnsiString;
  paths: TStringList;
  i, sent: Integer;
begin
  if not ActiveP.Vfs.IsLocal then
  begin
    MsgBox('LocalSend', 'Sending works from a local panel only.', ['OK']);
    Exit;
  end;
  paths := TStringList.Create;
  try
    for i := 0 to High(ActiveP.Files) do
      if ActiveP.Files[i].Sel then
        paths.Add(VfsJoin(ActiveP.Path, ActiveP.Files[i].Name));
    if (paths.Count = 0) and (ActiveP.CurFile.Name <> '') and
       (ActiveP.CurFile.Name <> '..') then
      paths.Add(VfsJoin(ActiveP.Path, ActiveP.CurFile.Name));
    if paths.Count = 0 then
    begin
      MsgBox('LocalSend', 'No file is selected.', ['OK']);
      Exit;
    end;
    base := LsPickTarget(pin);
    if base = '' then Exit;
    { prepare-upload blocks until the other side accepts: say so }
    InfoBox('LocalSend', 'Waiting for the other device to accept...');
    if LsSend(base, paths, sent, err, pin) then
      MsgBox('LocalSend', 'Sent ' + IntToStr(sent) + ' file(s).', ['OK'])
    else
      MsgBox('LocalSend', 'Send failed:'#10 + err, ['OK']);
  finally
    paths.Free;
  end;
end;

procedure DoEdit;
var
  w: TEditWin;
  lp: AnsiString;
begin
  if ActiveP.Vfs is TDbVFS then
  begin
    DoDbSql;
    Exit;
  end;
  if OpenSqliteFile then Exit;
  if not MaterializeCurrent(lp) then Exit;
  w := OpenEditor(lp);
  if w <> nil then
  begin
    if not ActiveP.Vfs.IsLocal then
    begin
      { saving writes the temp copy back into the VFS (e.g. the zip) }
      w.PutVfs := ActiveP.Vfs;
      w.PutPath := VfsJoin(ActiveP.Path, ActiveP.CurFile.Name);
      w.Title := ActiveP.CurFile.Name + ' (' + ActiveP.Vfs.Display('') + ')';
    end;
    FocusWin := w;
  end;
end;

procedure DoHelp;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('DN - DataNavigator ' + DNVersion + ' (FPC/ncurses edition)');
    L.Add('');
    L.Add('Keys');
    L.Add('  Tab              switch active panel');
    L.Add('  Enter            enter directory');
    L.Add('  Backspace        go to parent directory');
    L.Add('  Ins / Space      select/deselect file');
    L.Add('  Alt-[ / Alt-]    move the panel split left / right');
    L.Add('  Alt-=            reset the panel split to the middle');
    L.Add('  Ctrl-O           show shell screen (Ctrl-O returns)');
    L.Add('  Ctrl-R           re-read both panels');
    L.Add('  Ctrl-T           Tetris');
    L.Add('  Ctrl-Q           Databases (PostgreSQL, ClickHouse, SQLite)');
    L.Add('  Alt-F7           Find file (name, text, hex, type by content)');
    L.Add('                   Commands > Find results shows the last hits again');
    L.Add('  Alt-F8           stop the media player');
    L.Add('  F1               this help');
    L.Add('  F2               user menu (dn.mnu, see below)');
    L.Add('  F3               view file / play folder (player)');
    L.Add('  F4               edit file (MicroEd)');
    L.Add('  F5 / F6          copy / move to the other panel');
    L.Add('  F7 / F8          make directory / delete');
    L.Add('  F9               pull-down menu');
    L.Add('  F10              exit');
    L.Add('');
    L.Add('Panels');
    L.Add('  Left/Right menu > Columns...  pick Size / Date / Time columns');
    L.Add('  Ctrl-G           count directory size (shows in Size column)');
    L.Add('  Options > Panel setup > Exact sizes: bytes as 1,234,567');
    L.Add('');
    L.Add('Mouse');
    L.Add('  click            move cursor / activate panel / menu');
    L.Add('  double click     enter directory');
    L.Add('  right click      invert selection');
    L.Add('  wheel            scroll panel under pointer');
    L.Add('  scrollbar        arrows = line, track = page');
    L.Add('  drag title bar   move a window');
    L.Add('  drag corner      resize a window (bottom-right)');
    L.Add('  drag divider     change the panel split');
    L.Add('');
    L.Add('Virtual file systems');
    L.Add('  Enter on archive open zip/tar/7z/... as a directory');
    L.Add('  Enter on image    mount dmg/iso/... as a directory (macOS)');
    L.Add('  cd sftp://u@host/  connect a remote (SFTP) panel');
    L.Add('  Ctrl-S            SSH session manager');
    L.Add('  Ctrl-W            read a file list into the panel');
    L.Add('  Ctrl-F7/F8        UU-encode / UU-decode');
    L.Add('');
    L.Add('User menu (F2)');
    L.Add('  Entries live in dn.mnu: a local one in the panel directory');
    L.Add('  wins over the global <config>/dn.mnu (edit both from the');
    L.Add('  Options menu). Titles start at column 1, the indented lines');
    L.Add('  below are the shell commands. Placeholders: %f file name,');
    L.Add('  %p full path, %d panel dir, %D other panel dir,');
    L.Add('  %s selected files, %% literal %.');
    L.Add('');
    L.Add('Windows (viewer, MicroEd editor)');
    L.Add('  F5               zoom / unzoom');
    L.Add('  F6               next window / panels');
    L.Add('  Ctrl-F5          move (arrows) / resize (Shift-arrows) mode');
    L.Add('  Esc, F10         close window');
    L.Add('  [■] / [↕]        close / zoom icons (mouse)');
    L.Add('');
    L.Add('This product is based on the ideas and code analysis of the');
    L.Add('original Dos Navigator by RIT Labs. Dos Navigator is');
    L.Add('Copyright (C) RIT Labs; all credit for the original design');
    L.Add('belongs to them.');
    L.Add('');
    L.Add('Software is a meme these days.');
    L.Add('');
    L.Add('I''m proud to say: Fable is the first model capable of passing');
    L.Add('a test of reimplementing DN to modern product.');
    L.Add('');
    L.Add('Was it worth it? I bet so.');
    L.Add('');
    L.Add('Star, share, join my tg channel: https://t.me/My_CTO_Notes');
    L.Add('');
    L.Add('Best!');
    L.Add('Gregory Pletnev');
    FocusWin := OpenTextView('Help', L);
  except
    L.Free;
    raise;
  end;
end;

procedure DoPanelSetup;
var
  f: array[0..2] of Boolean;
begin
  f[0] := Opt.ShowHidden;
  f[1] := Opt.SpaceSelect;
  f[2] := Opt.ExactSizes;
  if not CheckListDialog('Panel setup',
           ['Show hidden files', 'Space selects files',
            'Exact sizes in bytes'], f) then Exit;
  Opt.ShowHidden := f[0];
  Opt.SpaceSelect := f[1];
  Opt.ExactSizes := f[2];
  OptSave;
  ReloadPanels;
end;

{ column picker for one panel; the choice becomes the default for new
  sessions (DN's "Column defaults") }
procedure ColumnsDialog(P: TPanel);
var
  f: array[0..2] of Boolean;
begin
  f[0] := P.ColSize;
  f[1] := P.ColDate;
  f[2] := P.ColTime;
  if not CheckListDialog('Columns', ['Size', 'Date', 'Time'], f) then Exit;
  P.ColSize := f[0];
  P.ColDate := f[1];
  P.ColTime := f[2];
  Opt.ColSize := f[0];
  Opt.ColDate := f[1];
  Opt.ColTime := f[2];
  OptSave;
end;

procedure DoConfirmations;
var
  f: array[0..2] of Boolean;
begin
  f[0] := Opt.ConfirmDelete;
  f[1] := Opt.ConfirmOverwrite;
  f[2] := Opt.ConfirmExit;
  if not CheckListDialog('Confirmations',
           ['Confirm delete', 'Confirm overwrite', 'Confirm exit'], f) then
    Exit;
  Opt.ConfirmDelete := f[0];
  Opt.ConfirmOverwrite := f[1];
  Opt.ConfirmExit := f[2];
  OptSave;
end;

{ highlight pairs sit on the panel bg, so re-apply after palette changes }
procedure ApplyHlPairs;
var
  i: Integer;
begin
  for i := 1 to HlGroupCount do
    SetHlPair(i, Opt.Hl[i].Color);
end;

function FontLabel: AnsiString;
var
  i: Integer;
begin
  i := FontIndex(Opt.Font);
  if i < 0 then Result := 'terminal default'
  else Result := FontCatalog[i].Name;
end;

{ a list that keeps the cursor between visits: -1 on Esc }
function PickRow(const Title: AnsiString; L: TStrings; var Cur: Integer): Integer;
begin
  Result := ListDialog(Title, L, Cur);
  if Result >= 0 then Cur := Result;
end;

{ the saved font, at startup: no download, no messages }
procedure ApplyOptFontQuiet;
var
  i: Integer;
  t: TTermInfo;
  msg: AnsiString;
begin
  i := FontIndex(Opt.Font);
  if i < 0 then Exit;
  t := DetectTermNow;
  if FontReady(FontCatalog[i]) and FontFits(FontCatalog[i], t.Kind) then
    FontApply(FontCatalog[i], Opt.FontSize, t, msg);
end;

{ try font e at Size: download when needed (asks first), apply, report.
  True when the font is in use; False on Esc or an error (the caller
  stays on its screen). }
function TryFont(const e: TFontEntry; Size: Integer): Boolean;
var
  t: TTermInfo;
  msg: AnsiString;
begin
  Result := False;
  t := DetectTermNow;
  if not FontFits(e, t.Kind) then
  begin
    FontApply(e, Size, t, msg);           // only builds the reason
    MsgBox('Font', e.Name + #10 + msg, ['OK']);
    Exit;
  end;
  if not FontReady(e) then
  begin
    if MsgBox('Font', 'Download ' + e.Name + ' (' + e.License + ', ' +
              e.Author + ')?' + #10 + e.Url, ['Download', 'Cancel']) <> 0 then
      Exit;
    if not FontDownload(e, msg) then
    begin
      if msg <> FontCancelled then MsgBox('Font', e.Name + #10 + msg, ['OK']);
      Exit;
    end;
  end;
  Result := FontApply(e, Size, t, msg);
  if Result then
    MsgBox('Font', e.Name + ', ' + IntToStr(Size) + ' pt' + #10 + msg, ['OK'])
  else
    MsgBox('Font', e.Name + #10 + msg, ['OK']);
end;

{ the font list; Esc or a failed pick stays here / goes back one step }
procedure DoFontPick;
var
  L: TStringList;
  i, idx, cur: Integer;
  t: TTermInfo;
  e: TFontEntry;
  st: AnsiString;
begin
  t := DetectTermNow;
  cur := FontIndex(Opt.Font) + 1;
  L := TStringList.Create;
  try
    repeat
      L.Clear;
      L.Add('Terminal default');
      for i := 0 to High(FontCatalog) do
      begin
        e := FontCatalog[i];
        if not FontFits(e, t.Kind) then st := 'not for this terminal'
        else if e.Bundled <> '' then st := 'bundled'
        else if FontReady(e) then st := 'downloaded'
        else st := 'download';
        L.Add(PadRight(e.Name, 28) + PadRight(e.License, 22) + st);
      end;
      idx := PickRow('Font (' + t.Name + ')', L, cur);
      if idx < 0 then Exit;
      if idx = 0 then
      begin
        FontRestore;
        Opt.Font := '';
        OptSave;
        Exit;
      end;
      if TryFont(FontCatalog[idx - 1], Opt.FontSize) then
      begin
        Opt.Font := FontCatalog[idx - 1].Id;
        OptSave;
        Exit;
      end;
    until False;
  finally
    L.Free;
  end;
end;

{ a bad number keeps the input open with what was typed; Esc goes back }
procedure DoFontSize;
var
  v: AnsiString;
  n, i: Integer;
begin
  v := IntToStr(Opt.FontSize);
  repeat
    if not InputBox('Font size', 'Size in points (6-72):', v) then Exit;
    n := StrToIntDef(Trim(v), 0);
    if (n < 6) or (n > 72) then
    begin
      MsgBox('Font size', 'Enter a number from 6 to 72', ['OK']);
      Continue;
    end;
    i := FontIndex(Opt.Font);
    { the size is kept only when the font takes it (or none is chosen) }
    if (i >= 0) and FontFits(FontCatalog[i], DetectTermNow.Kind) and
       not TryFont(FontCatalog[i], n) then Continue;
    Opt.FontSize := n;
    OptSave;
    Exit;
  until False;
end;

function PaletteIdx: Integer;
begin
  Result := DnPaletteIndex(Opt.Colors);
  if Result < 0 then Result := 0;
end;

{ the DN 1.51 palettes; Esc goes back, the cursor starts on the current one }
procedure DoColorScheme;
var
  L: TStringList;
  i, cur: Integer;
begin
  L := TStringList.Create;
  try
    for i := 0 to DnPalCount - 1 do L.Add(DnPalettes[i].Name);
    cur := PaletteIdx;
    i := ListDialog('Color scheme', L, cur);
  finally
    L.Free;
  end;
  if i < 0 then Exit;
  Opt.Colors := DnPalettes[i].Id;
  ApplyPalette(i);
  ApplyHlPairs;
  OptSave;
end;

{ Options > Fonts/Colors: stays open after each sub-dialog; Esc closes }
procedure DoColors;
var
  L: TStringList;
  cur: Integer;
begin
  cur := 0;
  L := TStringList.Create;
  try
    repeat
      L.Clear;
      L.Add('Font: ' + FontLabel);
      L.Add('Font size: ' + IntToStr(Opt.FontSize));
      L.Add('Color scheme: ' + DnPalettes[PaletteIdx].Name);
      case PickRow('Fonts/Colors', L, cur) of
        0: DoFontPick;
        1: DoFontSize;
        2: DoColorScheme;
      else
        Exit;
      end;
    until False;
  finally
    L.Free;
  end;
end;

procedure DoHighlight;
begin
  if not HighlightDialog(Opt.Hl) then Exit;
  ApplyHlPairs;
  OptSave;
end;

{ Options > Info: what DN knows about the terminal it runs in. }
procedure DoInfo;
var
  t: TTermInfo;
  m, s, tty: AnsiString;

  procedure Line(const k, v: AnsiString);
  begin
    if v = '' then m := m + PadRight(k, 14) + '-' + #10
    else m := m + PadRight(k, 14) + v + #10;
  end;

begin
  t := DetectTermNow;
  tty := CurrentTty;
  m := '';
  s := t.Name;
  if t.Version <> '' then s := s + ' ' + t.Version;
  Line('Terminal:', s);
  if t.Source <> '' then Line('Detected by:', t.Source);
  if t.Mux <> '' then Line('Multiplexer:', t.Mux);
  s := FontMethod(t.Kind);
  if s = '' then s := 'not supported';
  if (t.Mux <> '') and (t.Kind <> tkLinuxConsole) and (s <> 'not supported') then
    s := s + ' (via ' + t.Mux + ' passthrough)';
  Line('Font change:', s);
  Line('TERM:', GetEnvironmentVariable('TERM'));
  Line('TERM_PROGRAM:', GetEnvironmentVariable('TERM_PROGRAM'));
  Line('TTY:', tty);
  Line('Size:', IntToStr(COLS) + 'x' + IntToStr(LINES));
  if has_colors then
    Line('Colors:', IntToStr(COLORS) + ', ' + IntToStr(COLOR_PAIRS) + ' pairs')
  else
    Line('Colors:', 'none');
  s := GetEnvironmentVariable('LC_ALL');
  if s = '' then s := GetEnvironmentVariable('LC_CTYPE');
  if s = '' then s := GetEnvironmentVariable('LANG');
  Line('Locale:', s);
  if GpmActive then Line('Mouse:', 'gpm (Linux console)')
  else Line('Mouse:', 'xterm protocol');
  SetLength(m, Length(m) - 1);
  MsgBox('Info', m, ['OK']);
end;

procedure SaverSetupPreview(Cur, py, px, ph, pw: Integer); forward;

{ the picker lists only implemented savers, but their dnsaver kinds are not
  contiguous. This maps a list position to the sv* kind; index 0 is the
  disabled entry (svOff). }
const
  SaverKindByPos: array[0..9] of Integer =
    (svOff, svStarSky, svClock, svBlank, svWater, svFire, svColines,
     svBundles, svChik, svAscope);



procedure DoSaverSetup;
var
  L: TStringList;
  idx, mins, start, i: Integer;
begin
  L := TStringList.Create;
  try
    L.Add('Off');
    L.Add('Starry sky');
    L.Add('Clock');
    L.Add('Blank screen');
    L.Add('Water (DOS AZ_WATER)');
    L.Add('Fire (DOS AZ_FIRE)');
    L.Add('Color lines (DOS COLINES)');
    L.Add('Bundles (DOS BUNDLES)');
    L.Add('CHIK.SS walking hole');
    L.Add('Oscilloscope (DOS ASCOPE)');
    mins := Opt.SaverDelay;
    if mins <= 0 then mins := 5;
    { open on the configured saver, so OK without a move keeps it;
      "Off" only when the saver is disabled }
    start := 0;
    if Opt.SaverDelay > 0 then
      for i := 1 to High(SaverKindByPos) do
        if SaverKindByPos[i] = Opt.SaverType then start := i;
    idx := LiveListDialog('Screen saver', L, nil, 120, 24,
                          start, @SaverSetupPreview, 46,
                          'Start after minutes (Tab):', @mins);
  finally
    L.Free;
  end;
  if idx < 0 then Exit;
  if idx = 0 then
    Opt.SaverDelay := 0
  else
  begin
    Opt.SaverType := SaverKindByPos[idx];
    if mins <= 0 then mins := 5;
    Opt.SaverDelay := mins;
  end;
  OptSave;
end;

{ the picker's live preview: the focused row minus the "Off" entry is a
  sv* saver kind; row 0 shows the disabled state }
procedure SaverSetupPreview(Cur, py, px, ph, pw: Integer);
begin
  if (Cur < 0) or (Cur > High(SaverKindByPos)) then Exit;
  SaverPreviewDraw(SaverKindByPos[Cur], py, px, ph, pw);
end;

{ --- user menu (F2) ------------------------------------------------------ }

procedure DoUserMenu;
var
  Menu: TUserMenu;
  L, Sel: TStringList;
  i, idx: Integer;
  mfile, cmd, selstr, dir: AnsiString;
begin
  if ActiveP.Vfs.IsLocal then
    mfile := UserMenuFile(ActiveP.Path)
  else
    mfile := GlobalMenuFile;
  if not LoadUserMenu(mfile, Menu) or (Length(Menu) = 0) then
  begin
    if MsgBox('User menu', 'No user menu entries found.'#10 +
              'Create a template menu and edit it?', ['Yes', 'No']) = 0 then
    begin
      EnsureGlobalMenu;
      FocusWin := OpenEditor(GlobalMenuFile);
    end;
    Exit;
  end;

  L := TStringList.Create;
  try
    for i := 0 to High(Menu) do
      L.Add(Menu[i].Title);
    idx := ListDialog('User menu', L);
  finally
    L.Free;
  end;
  if idx < 0 then Exit;

  Sel := TStringList.Create;
  try
    GetTargets(Sel);
    selstr := '';
    for i := 0 to Sel.Count - 1 do
    begin
      if selstr <> '' then selstr := selstr + ' ';
      selstr := selstr + AnsiQuotedStr(Sel[i], '''');
    end;
  finally
    Sel.Free;
  end;

  { a command that wants a file must have one: with the cursor on '..'
    and nothing selected, "du -sh %s" would silently scan the whole dir }
  if (selstr = '') and
     ((Pos('%f', Menu[idx].Command) > 0) or
      (Pos('%p', Menu[idx].Command) > 0) or
      (Pos('%s', Menu[idx].Command) > 0)) then
  begin
    MsgBox('User menu', 'No file is selected.', ['OK']);
    Exit;
  end;

  if ActiveP.Vfs.IsLocal then dir := ActiveP.Path else dir := GetCurrentDir;
  cmd := ExpandUserCmd(Menu[idx].Command,
                       ActiveP.CurFile.Name,
                       VfsJoin(ActiveP.Path, ActiveP.CurFile.Name),
                       ActiveP.Path, OtherPanel.Path, selstr);
  ShellExec(cmd, dir, True);
end;

procedure DoMenuEdit(GlobalMenu: Boolean);
var
  path: AnsiString;
  f: Text;
begin
  if GlobalMenu then
  begin
    EnsureGlobalMenu;
    path := GlobalMenuFile;
  end
  else
  begin
    if not ActiveP.Vfs.IsLocal then
    begin
      MsgBox('User menu', 'A local menu needs a local directory.', ['OK']);
      Exit;
    end;
    path := VfsJoin(ActiveP.Path, 'dn.mnu');
    if not FileExists(path) then
    begin
      Assign(f, path);
      {$I-} Rewrite(f); {$I+}
      if IOResult = 0 then
      begin
        WriteLn(f, '# local user menu for ', ActiveP.Path);
        Close(f);
      end;
    end;
  end;
  FocusWin := OpenEditor(path);
end;

procedure ExecCmd(cmd: Integer);
begin
  case cmd of
    cmQuit: DoQuit;
    cmRereadLeft: LeftP.Load;
    cmRereadRight: RightP.Load;
    cmRereadAll: ReloadPanels;
    cmView: DoView;
    cmEdit: DoEdit;
    cmCopy: DoCopyOrMove(False);
    cmMove: DoCopyOrMove(True);
    cmMkDir: DoMkDir;
    cmDelete: DoDelete;
    cmInvert: ActiveP.ToggleSelect;
    cmTetris: DoTetris;
    cmHelp: DoHelp;
    cmSortLeft: SortDialog(LeftP);
    cmSortRight: SortDialog(RightP);
    cmFilterLeft: FilterDialog(LeftP);
    cmFilterRight: FilterDialog(RightP);
    cmSessions: DoSessions;
    cmSftpConnect: DoSftpConnect;
    cmDisks: DoDisks;
    cmDatabases: DoDatabases;
    cmFindFile: DoFindFile;
    cmFindResults: DoFindResults;
    cmUUEncode: DoUUEncode;
    cmUUDecode: DoUUDecode;
    cmPanelSetup: DoPanelSetup;
    cmConfirmations: DoConfirmations;
    cmColors: DoColors;
    cmHighlight: DoHighlight;
    cmUserMenu: DoUserMenu;
    cmMenuEditGlobal: DoMenuEdit(True);
    cmMenuEditLocal: DoMenuEdit(False);
    cmColumnsLeft: ColumnsDialog(LeftP);
    cmColumnsRight: ColumnsDialog(RightP);
    { cmSyntaxHl is a checkbox: RunMenuBar toggles it in place }
    cmSaverSetup: DoSaverSetup;
    cmInfo: DoInfo;
    cmPlayer: DoPlayer;
    cmLocalSend: DoLocalSend;
    cmBrowser: DoBrowser;
    cmConsole:
      if ActiveP.Vfs.IsLocal then
        FocusWin := OpenConsole(ActiveP.Path)
      else
        FocusWin := OpenConsole(GetCurrentDir);
  end;
end;

procedure OpenMenu(startSel: Integer);
begin
  ExecCmd(RunMenuBar(startSel));
end;

function WinIndex(w: TWin): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(Wins) do
    if Wins[i] = w then Exit(i);
end;

procedure CycleFocus;
var
  i: Integer;
begin
  if FocusWin = nil then
    FocusWin := WinTop        // may stay nil
  else
  begin
    i := WinIndex(FocusWin);
    if i > 0 then
      FocusWin := Wins[i - 1]
    else
      FocusWin := nil;        // wrapped below the bottom window: panels
  end;
end;

procedure TryCloseFocus;
var
  w: TWin;
begin
  if FocusWin = nil then Exit;
  if not FocusWin.ConfirmClose then Exit;
  w := FocusWin;
  WinClose(w);
  FocusWin := WinTop;
  ReloadPanels;               // an editor may have saved a file
end;

procedure HandleWindowKey(ch: LongInt);
begin
  case ch of
    KEY_F0 + 1: DoHelp;
    KEY_F0 + 5: FocusWin.ZoomToggle;
    KEY_F0 + 6: CycleFocus;
    KEY_F0 + 9: OpenMenu(0);
    KEY_F0 + 29: MoveMode := True;   // Ctrl-F5
    15: ShowUserScreen;              // Ctrl-O: global, works over any window
  else
    case FocusWin.HandleKey(ch) of
      kaClose: TryCloseFocus;
    end;
  end;
end;

procedure HandleMoveMode(ch: LongInt);
begin
  if FocusWin = nil then
  begin
    MoveMode := False;
    Exit;
  end;
  case ch of
    KEY_LEFT: Dec(FocusWin.X);
    KEY_RIGHT: Inc(FocusWin.X);
    KEY_UP: Dec(FocusWin.Y);
    KEY_DOWN: Inc(FocusWin.Y);
    KEY_SLEFT: Dec(FocusWin.W);
    KEY_SRIGHT: Inc(FocusWin.W);
    KEY_SR: Dec(FocusWin.H);         // Shift-Up
    KEY_SF: Inc(FocusWin.H);         // Shift-Down
    10, 13, KEY_ENTER, 27: MoveMode := False;
  end;
  FocusWin.ClampToDesk;
end;

procedure DoFKey(n: Integer);
begin
  case n of
    1: DoHelp;
    2: DoUserMenu;
    3: DoView;
    4: DoEdit;
    5: DoCopyOrMove(False);
    6: DoCopyOrMove(True);
    7: DoMkDir;
    8: DoDelete;
    9: OpenMenu(0);
    10: DoQuit;
  end;
end;

procedure LogMouse(const me: MEVENT);
var
  f: Text;
  path: AnsiString;
begin
  path := GetEnvironmentVariable('DN_MOUSE_LOG');
  if path = '' then Exit;
  Assign(f, path);
  if FileExists(path) then Append(f) else Rewrite(f);
  WriteLn(f, Format('y=%d x=%d bstate=$%x', [me.y, me.x, me.bstate]));
  Close(f);
end;

procedure LogMouseLine(const s: AnsiString);
var
  f: Text;
  path: AnsiString;
begin
  path := GetEnvironmentVariable('DN_MOUSE_LOG');
  if path = '' then Exit;
  Assign(f, path);
  if FileExists(path) then Append(f) else Rewrite(f);
  WriteLn(f, s);
  Close(f);
end;

procedure HandleMouse;
var
  me: MEVENT;
  p: TPanel;
  w: TWin;
  idx, t: Integer;
  press: Boolean;
begin
  if getmouse(@me) <> OK then Exit;
  LogMouse(me);
  press := (me.bstate and (mbtn1Pressed or mbtn1Clicked or mbtn1Double or
                           mbtn1Triple)) <> 0;

  { active drag: motion events move/resize, release applies the final
    position and ends it (gpm on the Linux console reports no motion,
    only press and release) }
  if Drag <> dmNone then
  begin
    if (Drag <> dmSplit) and (WinIndex(DragWin) < 0) then
    begin
      Drag := dmNone;   // the window vanished under the pointer
      DragWin := nil;
      Exit;
    end;
    case Drag of
      dmMoveWin:
        begin
          DragWin.X := me.x - DragOffX;
          DragWin.Y := me.y - DragOffY;
          DragWin.ClampToDesk;
        end;
      dmResizeWin:
        begin
          DragWin.W := me.x - DragWin.X + 1;
          DragWin.H := me.y - DragWin.Y + 1;
          DragWin.ClampToDesk;
        end;
      dmSplit:
        SetSplit(me.x);
    end;
    if (me.bstate and mbtn1Released) <> 0 then
    begin
      Drag := dmNone;
      DragWin := nil;
    end;
    Exit;
  end;

  { menu bar (DN: <L> on menu bar) }
  if me.y = 0 then
  begin
    if press or ((me.bstate and (mbtn3Clicked or mbtn3Pressed)) <> 0) then
    begin
      t := TitleAt(me.x);
      if t >= 0 then OpenMenu(t);
    end;
    Exit;
  end;

  { status line: pick operation (DN: <C> on wanted operation) }
  if me.y = LINES - 1 then
  begin
    if press or ((me.bstate and (mbtn3Clicked or mbtn3Pressed)) <> 0) then
    begin
      idx := me.x div (COLS div 10) + 1;
      if FocusWin <> nil then
        HandleWindowKey(KEY_F0 + idx)
      else
        DoFKey(idx);
    end;
    Exit;
  end;

  { windows above the panels }
  w := WinAt(me.x, me.y);
  if w <> nil then
  begin
    if press then
    begin
      FocusWin := w;
      WinRaise(w);
      if w.OnCloseIcon(me.x, me.y) then
      begin
        TryCloseFocus;
        Exit;
      end;
      if w.OnZoomIcon(me.x, me.y) then
      begin
        w.ZoomToggle;
        Exit;
      end;
      if w.OnScrollbar(me.x, me.y) then
      begin
        w.ClickScrollbar(me.y);
        Exit;
      end;
      if me.y = w.Y then
      begin
        { grab the title bar: move the window }
        Drag := dmMoveWin;
        DragWin := w;
        DragOffX := me.x - w.X;
        DragOffY := me.y - w.Y;
        Exit;
      end;
      if (me.y = w.Y + w.H - 1) and (me.x = w.X + w.W - 1) then
      begin
        { grab the bottom-right corner: resize }
        Drag := dmResizeWin;
        DragWin := w;
        Exit;
      end;
    end;
    w.HandleClick(me.x, me.y, me.bstate);
    Exit;
  end;
  if press then
    FocusWin := nil;   // clicking the panels focuses them

  { grab the divider between the panels: change the split }
  if press and (me.x = RightP.X0) and (me.y >= 1) and (me.y <= LINES - 3) then
  begin
    Drag := dmSplit;
    Exit;
  end;

  if me.x < LeftP.W then p := LeftP else p := RightP;

  { wheel scrolls the panel under the pointer }
  if (me.bstate and mbtnWheelUp) <> 0 then
  begin
    SetActive(p);
    p.MoveCursor(-3);
    Exit;
  end;
  if (me.bstate and mbtnWheelDown) <> 0 then
  begin
    SetActive(p);
    p.MoveCursor(3);
    Exit;
  end;

  { scrollbar on the right border (DN: arrows = line, track = page) }
  if (me.x = p.X0 + p.W - 1) and p.ScrollbarVisible and
     (me.y >= 3) and (me.y < 3 + p.ListHeight) and
     ((me.bstate and (mbtn1Clicked or mbtn1Pressed or mbtn1Double or mbtn1Triple)) <> 0) then
  begin
    SetActive(p);
    p.ClickScrollbar(me.y - 3);
    Exit;
  end;

  { file rows: press = cursor, second press on same row = enter,
    right press = invert selection }
  if (me.y >= 3) and (me.y < 3 + p.ListHeight) and
     (me.x > p.X0) and (me.x < p.X0 + p.W - 1) then
  begin
    idx := p.Top + (me.y - 3);
    if (idx >= 0) and (idx < Length(p.Files)) then
    begin
      if (me.bstate and (mbtn3Pressed or mbtn3Clicked or
                         mbtn3Double or mbtn3Triple)) <> 0 then
      begin
        SetActive(p);
        p.Cur := idx;
        p.InvertSel;
        LogMouseLine(Format('right-click idx=%d name=%s sel=%s',
          [idx, p.Files[idx].Name, BoolToStr(p.Files[idx].Sel, True)]));
      end
      else if (me.bstate and (mbtn1Pressed or mbtn1Clicked or
                              mbtn1Double or mbtn1Triple)) <> 0 then
      begin
        SetActive(p);
        p.Cur := idx;
        if ((me.bstate and (mbtn1Double or mbtn1Triple)) <> 0) or
           ((p = LastClickPanel) and (idx = LastClickIdx) and
            (GetTickCount64 - LastClickTick < 400)) then
        begin
          LastClickTick := 0;   // consume: a third press starts fresh
          p.EnterCurrent;
        end
        else
        begin
          LastClickPanel := p;
          LastClickIdx := idx;
          LastClickTick := GetTickCount64;
        end;
      end;
    end;
  end;
end;

{ read continuation bytes of a UTF-8 character whose first byte is b }
function CollectUtf8(b: LongInt): AnsiString;
var
  n, i, c: LongInt;
begin
  Result := Chr(b);
  if (b and $E0) = $C0 then n := 1
  else if (b and $F0) = $E0 then n := 2
  else if (b and $F8) = $F0 then n := 3
  else Exit;
  timeout(50);
  for i := 1 to n do
  begin
    c := getch;
    if (c < $80) or (c > $BF) then
    begin
      if c <> ERR then ungetch(c);
      Break;
    end;
    Result := Result + Chr(c);
  end;
  timeout(1000);
end;

procedure HandleKey(ch: LongInt);
var
  c2: LongInt;
  u: AnsiString;
begin
  { Alt+key arrives as ESC-prefix: translate to 3000+code. A non-printable
    follow-up (arrow, F-key) is NOT Alt — push it back and keep plain Esc. }
  if ch = 27 then
  begin
    timeout(0);
    c2 := getch;
    timeout(1000);
    if c2 <> ERR then
      if (c2 >= 32) and (c2 < 127) then
        ch := 3000 + c2
      else
        ungetch(c2);
  end;
  if ch = KEY_MOUSE then
  begin
    HandleMouse;
    Exit;
  end;
  if ch = KEY_RESIZE then Exit;
  { Alt-F8: stop playback in every player window, global (PLAYER.md) }
  if ch = KEY_F0 + 8 + 1000 then
  begin
    StopPlayers;
    Exit;
  end;
  if (ch = KEY_F0 + 7 + 1000) and (FocusWin = nil) then
  begin
    DoFindFile;                 // Alt-F7
    Exit;
  end;
  if MoveMode then
  begin
    HandleMoveMode(ch);
    Exit;
  end;
  { UTF-8 lead byte: assemble the character, route as text }
  if (ch >= $C2) and (ch <= $F4) then
  begin
    u := CollectUtf8(ch);
    if FocusWin <> nil then
      FocusWin.HandleText(u)
    else
    begin
      CmdLine := CmdLine + u;
      HistPos := -1;
    end;
    Exit;
  end;
  if FocusWin <> nil then
  begin
    HandleWindowKey(ch);
    Exit;
  end;
  case ch of
    KEY_UP:    ActiveP.MoveCursor(-1);
    KEY_DOWN:  ActiveP.MoveCursor(1);
    KEY_PPAGE: ActiveP.MoveCursor(-ActiveP.ListHeight);
    KEY_NPAGE: ActiveP.MoveCursor(ActiveP.ListHeight);
    KEY_HOME:  ActiveP.MoveCursor(-Length(ActiveP.Files));
    KEY_END:   ActiveP.MoveCursor(Length(ActiveP.Files));
    KEY_IC:    ActiveP.ToggleSelect;
    9:         SwitchPanel;                    // Tab
    10, 13, KEY_ENTER:
      if CmdLine <> '' then CmdExec else EnterOrLaunch;
    KEY_BACKSPACE, 127:
      if CmdLine <> '' then
        SetLength(CmdLine, Length(CmdLine) - 1)
      else
        ActiveP.GoUp;
    27:        CmdLine := '';                  // Esc clears the command line
    3:         CompareDirs;                    // Ctrl+C: compare directories
    7:         CountDirSize;                   // Ctrl+G
    19:        DoSessions;                     // Ctrl+S: SSH sessions
    4:         DoDisks;                        // Ctrl+D: removable disks
    17:        DoDatabases;                    // Ctrl+Q: databases
    21:        SwapPanels;                     // Ctrl+U
    5:         HistRecall(-1);                 // Ctrl+E: previous command
    24:        HistRecall(1);                  // Ctrl+X: next command
    6:         begin                           // Ctrl+F: insert current name
                 if (ActiveP.CurFile.Name <> '') and (ActiveP.CurFile.Name <> '..') then
                   CmdLine := CmdLine + ActiveP.CurFile.Name + ' ';
               end;
    15:        ShowUserScreen;                 // Ctrl+O
    23:        DoReadFileList;                 // Ctrl+W: read file list
    18:        ReloadPanels;                   // Ctrl+R
    20:        DoTetris;                       // Ctrl+T
    2:         DoBrowser;                      // Ctrl+B: browser
  else
    if (ch >= KEY_F0 + 1) and (ch <= KEY_F0 + 10) then
      DoFKey(ch - KEY_F0)
    else if (ch = 32) and Opt.SpaceSelect and (CmdLine = '') then
      ActiveP.ToggleSelect                 // MC-style Space select
    else if (CmdLine = '') and (ch in [Ord('+'), Ord('-'), Ord('*')]) then
    begin
      { DN 2.3: select / deselect / invert by mask }
      if ch = Ord('*') then
        ActiveP.InvertAll
      else
      begin
        MaskBuf := '*';
        if InputBox('Select', 'Mask:', MaskBuf) and (MaskBuf <> '') then
          ActiveP.SelectByMask(MaskBuf, ch = Ord('+'));
      end;
    end
    else if (ch >= 3000 + 32) and (ch < 3000 + 127) then
    begin
      { Alt+letter: S = sort dialog, [ ] = = panel split,
        others = quick jump (DN 2.10) }
      if Chr(ch - 3000) in ['s', 'S'] then
        SortDialog(ActiveP)
      else if ch = 3000 + Ord('[') then
        SetSplit(RightP.X0 - 2)
      else if ch = 3000 + Ord(']') then
        SetSplit(RightP.X0 + 2)
      else if ch = 3000 + Ord('=') then
        PanelSplit := 0
      else
        ActiveP.QuickJump(Chr(ch - 3000));
    end
    else if (ch >= 32) and (ch < 127) then
    begin
      CmdLine := CmdLine + Chr(ch);
      HistPos := -1;
    end;
  end;
end;

{ Create LocalBinDir/dn as a symlink to the real file of the running
  executable. Returns False and fills Err on failure; on success Exe and
  Link name both ends. Prints nothing: the caller reports. }
function InstallPathSymlink(out Exe, Link, Err: AnsiString): Boolean;
var
  dir: AnsiString;
begin
  Result := False;
  Err := '';
  Link := '';
  { the real path, so a run through the link itself never makes the
    link point at itself }
  Exe := ExecutablePath;
  if Exe = '' then
  begin
    Err := 'cannot resolve executable path: ' + ParamStr(0);
    Exit;
  end;
  dir := LocalBinDir;
  if dir = '' then
  begin
    Err := 'HOME is not set';
    Exit;
  end;
  if not ForceDirectories(dir) then
  begin
    Err := 'cannot create ' + dir;
    Exit;
  end;
  Link := IncludeTrailingPathDelimiter(dir) + 'dn';
  { lstat, not FileExists: a dangling link left by a moved checkout must
    be replaced, not reported as "cannot create" }
  if LinkExists(Link) then
  begin
    if RealPath(Link) = Exe then
    begin
      Result := True;   { already resolves here (or is this very file) }
      Exit;
    end;
    if not DeleteFile(Link) then
    begin
      Err := 'cannot replace ' + Link;
      Exit;
    end;
  end;
  if fpSymlink(PChar(Exe), PChar(Link)) <> 0 then
  begin
    Err := 'cannot create symlink ' + Link;
    Exit;
  end;
  Result := True;
end;

{ One-time hint when dn is not reachable from the shell. Returns True
  when the hint must be printed; the caller prints it after the TUI exits,
  so ncurses never overwrites the line. Fires for a path-qualified launch
  (`./bin/dn`, `~/src/dn/bin/dn`) when no `dn` is in PATH. Silent for a
  bare-name launch (the shell found it, so it is in PATH), for a bundle,
  when the terminal is not interactive, when DN_NO_PATH_HINT is set, and
  when the hint was shown before. }
function PathHintWanted: Boolean;
var
  exe: AnsiString;
begin
  Result := False;
  if Opt.PathHintShown then Exit;
  if GetEnvironmentVariable('DN_NO_PATH_HINT') <> '' then Exit;
  if (IsATTY(0) = 0) or (IsATTY(1) = 0) then Exit;
  if IsRelativeCommand(ParamStr(0)) then Exit;
  exe := ExecutablePath;
  if (exe = '') or IsAppBundle(exe) then Exit;
  if FindInPath('dn', GetEnvironmentVariable('PATH')) <> '' then Exit;
  if LocalBinDir = '' then Exit;
  Result := True;
end;

{ Print the hint and remember it, so it appears once. The command is
  spelled the way the user launched dn, since a bare `dn` would not run. }
procedure PathHintShow;
begin
  WriteLn('dn is not in PATH. Run `', ParamStr(0),
          ' --install-path` to link it into ', LocalBinDir, '.');
  Opt.PathHintShown := True;
  OptSave;
end;

var
  ch: LongInt;
  startL, startR: AnsiString;
  idleSecs, saverLimit: Integer;
  lastTick, lastPlayerTick: QWord;
  loopMs: Integer;
  lsErr: AnsiString;
  lsPort: Integer;
  lsName: AnsiString;
  ShowPathHint: Boolean;
  instExe, instLink, instErr: AnsiString;
  scanInfo: TDeviceInfo;
  scanDevs: TLsDevices;
  scanEnd, scanNext: QWord;
  scanI: Integer;

begin
  {$ifdef unix}
  { the tty gives Ctrl-C to dn as a plain key (raw mode), but a SIGINT
    can still arrive while a shell command runs — it must kill the
    command (RunShell resets the child), never the file manager }
  fpSignal(SIGINT, SignalHandler(SIG_IGN));
  fpSignal(SIGQUIT, SignalHandler(SIG_IGN));
  {$endif}
  {$ifdef darwin}
  SetupTerminfo;
  {$endif}
  { LocalSend helper mode: run the HTTP server and never enter the TUI.
    The main process starts this with --localsend-server <port>. }
  if (ParamCount >= 1) and (ParamStr(1) = '--localsend-server') then
  begin
    lsPort := LsDefaultPort;
    if ParamCount >= 2 then
      lsPort := StrToIntDef(ParamStr(2), LsDefaultPort);
    lsName := 'DN';
    if ParamCount >= 3 then
      lsName := ParamStr(3);
    LsSetDeviceName(lsName);
    LsHelperMain(lsPort, lsName, GetUserDir);
    Halt(0);
  end;
  { dn --localsend-scan [seconds]: announce, print every discovery packet
    and the devices found, exit. A plain-terminal diagnostic for "the
    device list stays empty". }
  if (ParamCount >= 1) and (ParamStr(1) = '--localsend-scan') then
  begin
    OptLoad;
    LsSetDeviceName(Opt.LocalSendName);
    if not LsEnsureIdentity(lsErr) then
      WriteLn('dn: no certificate (HTTPS devices will refuse): ', lsErr);
    scanInfo := LsSelfInfo(0);
    scanInfo.Port := 0;          // serve /register answers ourselves
    if not LsDiscStart(scanInfo, False, lsErr) then
    begin
      WriteLn(StdErr, 'dn: discovery failed: ', lsErr);
      Halt(1);
    end;
    WriteLn('dn: scanning as "', scanInfo.Alias, '" fingerprint ',
            scanInfo.Fingerprint, ', answers on port ', LsDiscSelfPort);
    { trace from here on: the header comes first, then a traced announce }
    LsDiscTrace := True;
    LsDiscAnnounce;
    scanEnd := GetTickCount64 + QWord(1000 * StrToIntDef(ParamStr(2), 6));
    scanNext := GetTickCount64 + 2000;
    while GetTickCount64 < scanEnd do
    begin
      LsDiscPoll;
      if GetTickCount64 >= scanNext then
      begin
        LsDiscAnnounce;
        scanNext := GetTickCount64 + 2000;
      end;
      Sleep(50);
    end;
    scanDevs := LsDiscDevices;
    WriteLn('dn: ', Length(scanDevs), ' device(s) found');
    for scanI := 0 to High(scanDevs) do
      WriteLn('  ', DeviceLabel(scanDevs[scanI]));
    if LsDiscLastError <> '' then
      WriteLn('dn: ', LsDiscLastError);
    LsDiscStop;
    if Length(scanDevs) > 0 then Halt(0) else Halt(2);
  end;
  { dn --install-path: link the executable into ~/.local/bin and exit.
    Runs before the TUI so the result goes to the plain terminal. }
  if (ParamCount >= 1) and (ParamStr(1) = '--install-path') then
  begin
    if InstallPathSymlink(instExe, instLink, instErr) then
    begin
      WriteLn('dn: linked ', instLink, ' -> ', instExe);
      if not DirInList(LocalBinDir, GetEnvironmentVariable('PATH')) then
        WriteLn('dn: note: ', LocalBinDir, ' is not in PATH');
      Halt(0);
    end;
    WriteLn(StdErr, 'dn: install-path failed: ', instErr);
    Halt(1);
  end;
  if (ParamCount >= 1) and LooksLikeUrl(ParamStr(1)) then
  begin
    { dn <url>: the browser opens after the first frame }
    StartUrl := ParamStr(1);
    startL := GetCurrentDir;
    startR := GetUserDir;
  end
  else
  begin
    if ParamCount >= 1 then startL := ParamStr(1) else startL := GetCurrentDir;
    if ParamCount >= 2 then startR := ParamStr(2) else startR := GetUserDir;
  end;
  CmdHist := TStringList.Create;
  HistoryLoad(CmdHist);
  OptLoad;
  ShowPathHint := PathHintWanted;
  LeftP := TPanel.Create(startL);
  RightP := TPanel.Create(startR);
  LeftP.Active := True;
  RightP.Active := False;
  ActiveP := LeftP;

  ScrInit;
  { slow external commands (archives, disk images, sftp) show a progress
    box with Esc to cancel }
  RunBusyHook := @BusyBox;
  { saved DB passwords: the master password prompt; DB password prompt }
  VaultAskHook := @AskVaultMaster;
  DbPasswordHook := @AskDbPassword;
  ApplyPalette(PaletteIdx);
  ApplyHlPairs;
  ApplyOptFontQuiet;
  RedrawBase := @DrawBase;
  try
    { with a player open the loop wakes 4 times a second (visualizer, track
      end); otherwise once a second, for the clock }
    if PlayerActive then timeout(PlayerTickMs) else timeout(1000);
    { start the LocalSend receive helper; failure is not fatal, the send
      path and the rest of dn still work }
    if Opt.LocalSendPort > 0 then
    begin
      lsErr := '';
      LsSetDeviceName(Opt.LocalSendName);
      { receiving on: show up in other devices' "Nearby devices" list
        right away, and answer their announces from now on }
      LsEnsureIdentity(lsErr);   // before the helper reads it
      if LsStart(ParamStr(0), Opt.LocalSendPort, lsErr) then
        LsDiscEnsure(lsErr);
    end;
    idleSecs := 0;
    lastTick := GetTickCount64;
    lastPlayerTick := 0;
    MaybeOpenStartUrl;
    repeat
      DrawAll;
      ch := getch;
      if ch <> ERR then
      begin
        idleSecs := 0;
        HandleKey(ch);
      end
      else
      begin
        { a player window needs a fast tick for the visualizer and for
          end-of-track detection; a running game wakes the loop more
          often, so keep the player at its own pace }
        if PlayerActive and
           (GetTickCount64 - lastPlayerTick >= QWord(PlayerTickMs)) then
        begin
          TickPlayers;
          lastPlayerTick := GetTickCount64;
        end;
        { LocalSend: read helper events once per idle tick. A live session
          resets the screen saver timer, so the saver never covers a
          transfer dialog. }
        DrainLsPipe;
        if LsDiscRunning then LsDiscPoll;
        { a game in play is not idle: the saver must not cover it }
        if LsActive or GameActive then idleSecs := 0;
        { the screen saver counts real seconds of quiet, not ticks }
        if GetTickCount64 - lastTick >= 1000 then
        begin
          Inc(idleSecs);
          lastTick := GetTickCount64;
        end;
        saverLimit := SaverIdleLimit;
        if (saverLimit > 0) and (idleSecs >= saverLimit) then
        begin
          RunSaver(Opt.SaverType);
          idleSecs := 0;
        end;
      end;
      { gravity runs on every pass, key or not, so holding a key never
        stalls the falling piece }
      TickGames;
      { the main-loop timeout: the smallest period of everything active }
      loopMs := 1000;
      if GameActive then loopMs := TetrisTickMs;
      if PlayerActive and (PlayerTickMs < loopMs) then loopMs := PlayerTickMs;
      if LsActive and (LsTickMs < loopMs) then loopMs := LsTickMs;
      timeout(loopMs);
      if Quit then
        while WinCount > 0 do
        begin
          FocusWin := WinTop;
          if FocusWin.ConfirmClose then
          begin
            WinClose(FocusWin);
            FocusWin := WinTop;
          end
          else
          begin
            Quit := False;
            Break;
          end;
        end;
    until Quit;
  finally
    FontRestore;
    ScrDone;
  end;

  HistorySave(CmdHist);
  CmdHist.Free;
  LsStop;
  LsDiscStop;
  LeftP.Free;
  RightP.Free;
  if ShowPathHint then PathHintShow;
end.
