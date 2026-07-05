{ dn — Dos Navigator look-and-feel file manager for the modern terminal.
  FPC + ncurses, macOS / Linux. }
program dn;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}clocale, Unix, BaseUnix, termio,{$endif}
  SysUtils, Classes, ncurses,
  dnscreen, dnpanel, dnmenu, dndialog, dnfileops, dntetris,
  dnwin, dnview, dnedit, dnconfig;

const
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
  s := ActiveP.Path + '>' + CmdLine;
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

procedure Layout;
var
  pw: Integer;
begin
  pw := COLS div 2;
  LeftP.X0 := 0;   LeftP.W := pw;         LeftP.H := LINES - 4;
  RightP.X0 := pw; RightP.W := COLS - pw; RightP.H := LINES - 4;
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
  err, verb, src, dst: AnsiString;
  ok: Boolean;
begin
  L := TStringList.Create;
  try
    GetTargets(L);
    if L.Count = 0 then Exit;
    if IsMove then verb := 'Move' else verb := 'Copy';
    if MsgBox(verb, verb + ' ' + TargetLabel(L) + ' to' + #10 +
              OtherPanel.Path + ' ?', ['Yes', 'No']) <> 0 then
      Exit;
    for i := 0 to L.Count - 1 do
    begin
      src := IncludeTrailingPathDelimiter(ActiveP.Path) + L[i];
      dst := IncludeTrailingPathDelimiter(OtherPanel.Path) + L[i];
      if IsMove then ok := MoveTree(src, dst, err)
      else ok := CopyTree(src, dst, err);
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
    if MsgBox('Delete', 'Delete ' + TargetLabel(L) + ' ?', ['Yes', 'No']) <> 0 then
      Exit;
    for i := 0 to L.Count - 1 do
      if not DeleteTree(IncludeTrailingPathDelimiter(ActiveP.Path) + L[i], err) then
      begin
        MsgBox('Error', err, ['OK']);
        Break;
      end;
    ReloadPanels;
  finally
    L.Free;
  end;
end;

procedure DoMkDir;
var
  name: AnsiString;
  i: Integer;
begin
  name := '';
  if not InputBox('Make directory', 'Directory name:', name) then Exit;
  if name = '' then Exit;
  if not CreateDir(IncludeTrailingPathDelimiter(ActiveP.Path) + name) then
  begin
    MsgBox('Error', 'Cannot create directory "' + name + '"', ['OK']);
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

procedure ShellExec(const cmd, dir: AnsiString);
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
  fpSystem(cmd);
  {$endif}
  SetCurrentDir(old);
  reset_prog_mode;
  refresh;
  ReloadPanels;
end;

{$ifdef unix}
procedure WaitAnyKey;
var
  saved, t: TermIOS;
  b: Char;
begin
  { endwin leaves the tty canonical: a plain read would wait for Enter }
  TCGetAttr(0, saved);
  t := saved;
  t.c_lflag := t.c_lflag and LongWord(not (ICANON or ECHO));
  t.c_cc[VMIN] := 1;
  t.c_cc[VTIME] := 0;
  TCSetAttr(0, TCSANOW, t);
  fpRead(0, b, 1);
  TCSetAttr(0, TCSANOW, saved);
end;
{$endif}

procedure ShowUserScreen;
begin
  def_prog_mode;
  endwin;
  WriteLn;
  Write('-- Press any key --');
  Flush(Output);
  {$ifdef unix}
  WaitAnyKey;
  {$endif}
  reset_prog_mode;
  refresh;
end;

procedure DoChangeDir(arg: AnsiString);
var
  p: AnsiString;
begin
  arg := Trim(arg);
  if (arg = '') or (arg = '~') then
    arg := GetEnvironmentVariable('HOME')
  else if Copy(arg, 1, 2) = '~/' then
    arg := GetEnvironmentVariable('HOME') + Copy(arg, 2, MaxInt);
  if (arg <> '') and (arg[1] <> '/') then
    p := IncludeTrailingPathDelimiter(ActiveP.Path) + arg
  else
    p := arg;
  p := ExpandFileName(p);
  if DirectoryExists(p) then
  begin
    ActiveP.Path := ExcludeTrailingPathDelimiter(p);
    if ActiveP.Path = '' then ActiveP.Path := '/';
    ActiveP.Cur := 0;
    ActiveP.Top := 0;
    ActiveP.Load;
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
    Quit := True
  else
    ShellExec(cmd, ActiveP.Path);
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
  full := IncludeTrailingPathDelimiter(ActiveP.Path) + f.Name;
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
begin
  if ActiveP.CurFile.IsDir then
    ActiveP.EnterCurrent
  else
    TryLaunch;
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
  ActiveP.Files[ActiveP.Cur].Size :=
    TreeSize(IncludeTrailingPathDelimiter(ActiveP.Path) + f.Name);
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

procedure DoView;
var
  w: TWin;
begin
  if (ActiveP.CurFile.Name = '') or ActiveP.CurFile.IsDir then Exit;
  w := OpenViewer(IncludeTrailingPathDelimiter(ActiveP.Path) + ActiveP.CurFile.Name);
  if w <> nil then FocusWin := w;
end;

procedure DoEdit;
var
  w: TWin;
begin
  if (ActiveP.CurFile.Name = '') or ActiveP.CurFile.IsDir then Exit;
  w := OpenEditor(IncludeTrailingPathDelimiter(ActiveP.Path) + ActiveP.CurFile.Name);
  if w <> nil then FocusWin := w;
end;

procedure DoHelp;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('DOS NAVIGATOR (FPC/ncurses edition)');
    L.Add('');
    L.Add('Keys');
    L.Add('  Tab              switch active panel');
    L.Add('  Enter            enter directory');
    L.Add('  Backspace        go to parent directory');
    L.Add('  Ins              select/deselect file');
    L.Add('  Ctrl-R           re-read both panels');
    L.Add('  Ctrl-T           Tetris');
    L.Add('  F1               this help');
    L.Add('  F3               view file');
    L.Add('  F4               edit file (MicroEd)');
    L.Add('  F5 / F6          copy / move to the other panel');
    L.Add('  F7 / F8          make directory / delete');
    L.Add('  F9               pull-down menu');
    L.Add('  F10              exit');
    L.Add('');
    L.Add('Mouse');
    L.Add('  click            move cursor / activate panel / menu');
    L.Add('  double click     enter directory');
    L.Add('  right click      invert selection');
    L.Add('  wheel            scroll panel under pointer');
    L.Add('  scrollbar        arrows = line, track = page');
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
    FocusWin := OpenTextView('Help', L);
  except
    L.Free;
    raise;
  end;
end;

procedure ExecCmd(cmd: Integer);
begin
  case cmd of
    cmQuit: Quit := True;
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
    2: MsgBox('User menu', 'The user menu is not implemented yet.', ['OK']);
    3: DoView;
    4: DoEdit;
    5: DoCopyOrMove(False);
    6: DoCopyOrMove(True);
    7: DoMkDir;
    8: DoDelete;
    9: OpenMenu(0);
    10: Quit := True;
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
    end;
    w.HandleClick(me.x, me.y, me.bstate);
    Exit;
  end;
  if press then
    FocusWin := nil;   // clicking the panels focuses them

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
    21:        SwapPanels;                     // Ctrl+U
    5:         HistRecall(-1);                 // Ctrl+E: previous command
    24:        HistRecall(1);                  // Ctrl+X: next command
    6:         begin                           // Ctrl+F: insert current name
                 if (ActiveP.CurFile.Name <> '') and (ActiveP.CurFile.Name <> '..') then
                   CmdLine := CmdLine + ActiveP.CurFile.Name + ' ';
               end;
    15:        ShowUserScreen;                 // Ctrl+O
    18:        ReloadPanels;                   // Ctrl+R
    20:        RunTetris;                      // Ctrl+T
  else
    if (ch >= KEY_F0 + 1) and (ch <= KEY_F0 + 10) then
      DoFKey(ch - KEY_F0)
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
      { Alt+letter: S = sort dialog, others = quick jump (DN 2.10) }
      if Chr(ch - 3000) in ['s', 'S'] then
        SortDialog(ActiveP)
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
  if ParamCount >= 1 then startL := ParamStr(1) else startL := GetCurrentDir;
  if ParamCount >= 2 then startR := ParamStr(2) else startR := GetUserDir;
  CmdHist := TStringList.Create;
  HistoryLoad(CmdHist);
  LeftP := TPanel.Create(startL);
  RightP := TPanel.Create(startR);
  LeftP.Active := True;
  RightP.Active := False;
  ActiveP := LeftP;

  ScrInit;
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
