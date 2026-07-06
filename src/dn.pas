{ dn — DN - DataNavigator: a Dos Navigator look-and-feel file manager
  for the modern terminal. FPC + ncurses, macOS / Linux. }
program dn;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}clocale, Unix, BaseUnix, termio,{$endif}
  SysUtils, Classes, ncurses,
  dnscreen, dnpanel, dnmenu, dndialog, dnfileops, dntetris,
  dnwin, dnview, dnedit, dnconfig, dnoptions, dnvfs, dnarcvfs, dnmount,
  dnsftp, dnsession, dnsessui, dnuu, dnusermenu;

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

type
  TDragMode = (dmNone, dmMoveWin, dmResizeWin, dmSplit);

var
  { mouse drag in progress (button-motion events, xterm 1002) }
  Drag: TDragMode = dmNone;
  DragWin: TWin = nil;
  DragOffX, DragOffY: Integer;

procedure DrawMenuBar;
begin
  DrawBar(-1);
  PutStr(0, COLS - 9, FormatDateTime('hh:nn:ss', Now), cpMenuBar);
end;

procedure DrawCmdLine;
var
  s: AnsiString;
begin
  FillRow(LINES - 2, 0, COLS, cpCmdLine);
  s := ActiveP.DisplayPath + '>' + CmdLine;
  if Length(s) > COLS - 2 then
    s := Copy(s, Length(s) - (COLS - 3), COLS - 2);
  PutStr(LINES - 2, 0, s, cpCmdLine);
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
  def_prog_mode;
  endwin;
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
  reset_prog_mode;
  refresh;
  ReloadPanels;
end;

procedure ShowUserScreen;
{$ifdef unix}
var
  saved: TermIOS;
  b: Char;
{$endif}
begin
  { MC-style Ctrl-O: switch to the shell screen and stay there until
    Ctrl-O (or Esc) switches back — other keys are ignored }
  def_prog_mode;
  endwin;
  WriteLn;
  Write('-- Ctrl-O to return --');
  Flush(Output);
  {$ifdef unix}
  ShellTtyRaw(saved);
  repeat
    b := #0;
    if fpRead(0, b, 1) <= 0 then Break;
  until b in [#3, #15, #27];   // Ctrl-C / Ctrl-O / Esc return
  TCSetAttr(0, TCSANOW, saved);
  {$endif}
  reset_prog_mode;
  refresh;
end;

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
  else if cmd <> '' then
    ShellExec(StringReplace(cmd, '%f', AnsiQuotedStr(full, ''''),
              [rfReplaceAll]), ActiveP.Path)
  {$ifdef unix}
  else if fpAccess(PChar(full), X_OK) = 0 then
    ShellExec(AnsiQuotedStr(full, ''''), ActiveP.Path)
  {$endif}
  ;
end;

procedure EnterOrLaunch;
var
  av: TArchiveVFS;
  mv: TMountVFS;
  items: TVfsItems;
  err, full: AnsiString;
begin
  if ActiveP.CurFile.IsDir then
  begin
    ActiveP.EnterCurrent;
    Exit;
  end;
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
  def_prog_mode;
  endwin;
  WriteLn;
  {$ifdef unix}
  RunShell(cmd);
  {$endif}
  Write('-- Press any key --');
  Flush(Output);
  {$ifdef unix}
  WaitAnyKey;
  {$endif}
  reset_prog_mode;
  refresh;
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
  path, err: AnsiString;
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
  err := '';
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
  if not MaterializeCurrent(lp) then Exit;
  w := OpenViewer(lp);
  if w <> nil then FocusWin := w;
end;

procedure DoEdit;
var
  w: TEditWin;
  lp: AnsiString;
begin
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
    L.Add('  F1               this help');
    L.Add('  F2               user menu (dn.mnu, see below)');
    L.Add('  F3               view file');
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

procedure DoColors;
var
  i: Integer;
begin
  i := MsgBox('Colors', 'Color scheme:', ['Classic', 'Dark', 'Mono']);
  if i < 0 then Exit;
  Opt.Palette := i;
  ApplyPalette(Opt.Palette);
  ApplyHlPairs;
  OptSave;
end;

procedure DoHighlight;
begin
  if not HighlightDialog(Opt.Hl) then Exit;
  ApplyHlPairs;
  OptSave;
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
    cmTetris: RunTetris;
    cmHelp: DoHelp;
    cmSortLeft: SortDialog(LeftP);
    cmSortRight: SortDialog(RightP);
    cmFilterLeft: FilterDialog(LeftP);
    cmFilterRight: FilterDialog(RightP);
    cmSessions: DoSessions;
    cmSftpConnect: DoSftpConnect;
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

  { active drag: motion events move/resize, release ends it }
  if Drag <> dmNone then
  begin
    if (Drag <> dmSplit) and (WinIndex(DragWin) < 0) then
    begin
      Drag := dmNone;   // the window vanished under the pointer
      DragWin := nil;
      Exit;
    end;
    if (me.bstate and mbtn1Released) <> 0 then
    begin
      Drag := dmNone;
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
    20:        RunTetris;                      // Ctrl+T
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

var
  ch: LongInt;
  startL, startR: AnsiString;

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
  if ParamCount >= 1 then startL := ParamStr(1) else startL := GetCurrentDir;
  if ParamCount >= 2 then startR := ParamStr(2) else startR := GetUserDir;
  CmdHist := TStringList.Create;
  HistoryLoad(CmdHist);
  OptLoad;
  LeftP := TPanel.Create(startL);
  RightP := TPanel.Create(startR);
  LeftP.Active := True;
  RightP.Active := False;
  ActiveP := LeftP;

  ScrInit;
  ApplyPalette(Opt.Palette);
  ApplyHlPairs;
  RedrawBase := @DrawBase;
  try
    timeout(1000);  // wake up every second for the clock
    repeat
      DrawAll;
      ch := getch;
      if ch <> ERR then
        HandleKey(ch);
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
    ScrDone;
  end;

  HistorySave(CmdHist);
  CmdHist.Free;
  LeftP.Free;
  RightP.Free;
end.
