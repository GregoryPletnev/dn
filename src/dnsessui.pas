{ dnsessui — the modal SSH session picker (ROADMAP M3).
  A tree of folders and saved sessions. Enter/Connect returns the chosen
  session so the caller can open a RemoteFS panel; Ctrl-Enter/Terminal and
  copy-id run ssh directly (the caller suspends curses). Add/Edit/Delete
  manage the session list persisted by dnsession. }
unit dnsessui;

{$mode objfpc}{$H+}

interface

uses
  dnsession;

type
  TSessResult = (srCancel, srConnect, srTerminal, srCopyId);

{ Run the picker. On srConnect/srTerminal/srCopyId, Chosen holds the
  selected session. }
function SessionManager(out Chosen: TSession): TSessResult;

implementation

uses
  SysUtils, Classes, ncurses, dnscreen, dndialog;

type
  TRow = record
    IsFolder: Boolean;
    Folder: AnsiString;      // folder path this row belongs to
    Depth: Integer;
    SessIdx: Integer;        // -1 for folder rows
    Label_: AnsiString;
  end;

var
  Sessions: TSessionArray;
  Expanded: TStringList;     // expanded folder paths
  Rows: array of TRow;

function FolderExpanded(const f: AnsiString): Boolean;
begin
  Result := (f = '') or (Expanded.IndexOf(f) >= 0);
end;

procedure ToggleFolder(const f: AnsiString);
var
  i: Integer;
begin
  if f = '' then Exit;
  i := Expanded.IndexOf(f);
  if i >= 0 then Expanded.Delete(i) else Expanded.Add(f);
end;

{ collect the distinct folder paths, including intermediate ones }
procedure CollectFolders(L: TStringList);
var
  i, p: Integer;
  f, acc: AnsiString;
begin
  L.Clear;
  L.Sorted := True;
  L.Duplicates := dupIgnore;
  for i := 0 to High(Sessions) do
  begin
    f := Sessions[i].Folder;
    acc := '';
    while f <> '' do
    begin
      p := Pos('/', f);
      if p = 0 then
      begin
        if acc = '' then acc := f else acc := acc + '/' + f;
        f := '';
      end
      else
      begin
        if acc = '' then acc := Copy(f, 1, p - 1)
        else acc := acc + '/' + Copy(f, 1, p - 1);
        f := Copy(f, p + 1, MaxInt);
      end;
      L.Add(acc);
    end;
  end;
end;

function FolderDepth(const f: AnsiString): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to Length(f) do
    if f[i] = '/' then Inc(Result);
end;

function FolderLeaf(const f: AnsiString): AnsiString;
var
  p: Integer;
begin
  p := Length(f);
  while (p > 0) and (f[p] <> '/') do Dec(p);
  Result := Copy(f, p + 1, MaxInt);
end;

function FolderParent(const f: AnsiString): AnsiString;
var
  p: Integer;
begin
  p := Length(f);
  while (p > 0) and (f[p] <> '/') do Dec(p);
  if p = 0 then Result := '' else Result := Copy(f, 1, p - 1);
end;

function AncestorsVisible(const f: AnsiString): Boolean;
var
  par: AnsiString;
begin
  par := FolderParent(f);
  while par <> '' do
  begin
    if not FolderExpanded(par) then Exit(False);
    par := FolderParent(par);
  end;
  Result := True;
end;

procedure BuildRows;
var
  folders: TStringList;
  n: Integer;

  procedure AddSessionsOf(const f: AnsiString; depth: Integer);
  var
    i: Integer;
  begin
    for i := 0 to High(Sessions) do
      if Sessions[i].Folder = f then
      begin
        SetLength(Rows, n + 1);
        Rows[n].IsFolder := False;
        Rows[n].Folder := f;
        Rows[n].Depth := depth;
        Rows[n].SessIdx := i;
        Rows[n].Label_ := Sessions[i].Name;
        if Sessions[i].HostName <> '' then
          Rows[n].Label_ := Rows[n].Label_ + '  (' + Sessions[i].HostName + ')';
        Inc(n);
      end;
  end;

  { depth-first walk: a folder row, then (if expanded) its child folders
    and its sessions }
  procedure WalkFolder(const f: AnsiString; depth: Integer);
  var
    i: Integer;
  begin
    SetLength(Rows, n + 1);
    Rows[n].IsFolder := True;
    Rows[n].Folder := f;
    Rows[n].Depth := depth;
    Rows[n].SessIdx := -1;
    if FolderExpanded(f) then Rows[n].Label_ := '[-] ' + FolderLeaf(f)
    else Rows[n].Label_ := '[+] ' + FolderLeaf(f);
    Inc(n);
    if not FolderExpanded(f) then Exit;
    for i := 0 to folders.Count - 1 do
      if FolderParent(folders[i]) = f then
        WalkFolder(folders[i], depth + 1);
    AddSessionsOf(f, depth + 1);
  end;

var
  i: Integer;
begin
  SetLength(Rows, 0);
  n := 0;
  folders := TStringList.Create;
  try
    CollectFolders(folders);
    { top-level folders (no parent) }
    for i := 0 to folders.Count - 1 do
      if FolderParent(folders[i]) = '' then
        WalkFolder(folders[i], 0);
    { top-level sessions }
    AddSessionsOf('', 0);
  finally
    folders.Free;
  end;
end;

procedure EditSession(idx: Integer);
var
  s: TSession;
  isNew: Boolean;
  v: AnsiString;
begin
  isNew := idx < 0;
  if isNew then
  begin
    s.Folder := '';
    s.Name := '';
    s.HostName := '';
    s.User := '';
    s.Port := '';
    s.IdentityFile := '';
    s.RemoteDir := '';
    SetLength(s.Forwards, 0);
  end
  else
    s := Sessions[idx];

  v := s.Name;
  if not InputBox('Session', 'Alias (Host):', v) or (Trim(v) = '') then Exit;
  s.Name := Trim(v);
  v := s.HostName; InputBox('Session', 'HostName:', v); s.HostName := Trim(v);
  v := s.User; InputBox('Session', 'User:', v); s.User := Trim(v);
  v := s.Port; InputBox('Session', 'Port:', v); s.Port := Trim(v);
  v := s.IdentityFile; InputBox('Session', 'IdentityFile:', v);
  s.IdentityFile := Trim(v);
  v := s.Folder; InputBox('Session', 'Folder (a/b, empty = top):', v);
  s.Folder := Trim(v);
  v := s.RemoteDir; InputBox('Session', 'Remote start dir:', v);
  s.RemoteDir := Trim(v);

  if isNew then
  begin
    SetLength(Sessions, Length(Sessions) + 1);
    Sessions[High(Sessions)] := s;
  end
  else
    Sessions[idx] := s;
  SaveSessions(Sessions);
end;

procedure DeleteSession(idx: Integer);
var
  i: Integer;
begin
  if idx < 0 then Exit;
  if MsgBox('Delete', 'Delete session "' + Sessions[idx].Name + '"?',
            ['Yes', 'No']) <> 0 then Exit;
  for i := idx to High(Sessions) - 1 do
    Sessions[i] := Sessions[i + 1];
  SetLength(Sessions, Length(Sessions) - 1);
  SaveSessions(Sessions);
end;

function SessionManager(out Chosen: TSession): TSessResult;
var
  x, y, w, h, cur, top, ph, ch, i: Integer;
  me: MEVENT;

  procedure Draw;
  var
    j, row, pair: Integer;
    line: AnsiString;
  begin
    if Assigned(RedrawBase) then RedrawBase();
    PutStr(y, x, bxTL + Rep(bxH, w - 2) + bxTR, cpMenuBar);
    PutStr(y, x + (w - 14) div 2, ' SSH Sessions ', cpTitleAct);
    for j := 0 to ph - 1 do
    begin
      row := y + 1 + j;
      PutStr(row, x, bxV, cpMenuBar);
      PutStr(row, x + w - 1, bxV, cpMenuBar);
      if top + j <= High(Rows) then
      begin
        if top + j = cur then pair := cpMenuSel else pair := cpMenuBar;
        line := StringOfChar(' ', Rows[top + j].Depth * 2) + Rows[top + j].Label_;
        PutStr(row, x + 1, PadRight(' ' + line, w - 2), pair);
      end
      else
        PutStr(row, x + 1, StringOfChar(' ', w - 2), cpMenuBar);
    end;
    PutStr(y + h - 2, x, bxSepL + Rep(bxSepH, w - 2) + bxSepR, cpMenuBar);
    PutStr(y + h - 1, x, bxSBL + Rep(bxSepH, w - 2) + bxSBR, cpMenuBar);
    PutStr(y + h - 2, x + 1,
      PadRight(' Enter connect  ^T term  Ins add  F4 edit  Del rm  Esc', w - 2),
      cpMenuBar);
    refresh;
  end;

  procedure ActivateRow;
  begin
    if (cur < 0) or (cur > High(Rows)) then Exit;
    if Rows[cur].IsFolder then
    begin
      ToggleFolder(Rows[cur].Folder);
      BuildRows;
      if cur > High(Rows) then cur := High(Rows);
    end;
  end;

  function CurSess: Integer;
  begin
    if (cur >= 0) and (cur <= High(Rows)) then Result := Rows[cur].SessIdx
    else Result := -1;
  end;

begin
  Result := srCancel;
  Sessions := nil;
  LoadSessions(Sessions);
  Expanded := TStringList.Create;
  try
    BuildRows;
    w := 60; h := 18;
    if w > COLS - 2 then w := COLS - 2;
    if h > LINES - 2 then h := LINES - 2;
    x := (COLS - w) div 2;
    y := (LINES - h) div 2;
    ph := h - 3;
    cur := 0;
    top := 0;

    repeat
      if cur < top then top := cur;
      if cur >= top + ph then top := cur - ph + 1;
      Draw;
      ch := getch;
      case ch of
        ERR: ;
        KEY_UP: if cur > 0 then Dec(cur);
        KEY_DOWN: if cur < High(Rows) then Inc(cur);
        KEY_HOME: cur := 0;
        KEY_END: cur := High(Rows);
        10, 13, KEY_ENTER:
          if (cur <= High(Rows)) and Rows[cur].IsFolder then
            ActivateRow
          else if CurSess >= 0 then
          begin
            Chosen := Sessions[CurSess];
            Exit(srConnect);
          end;
        20:  { Ctrl-T: terminal login }
          if CurSess >= 0 then
          begin
            Chosen := Sessions[CurSess];
            Exit(srTerminal);
          end;
        11:  { Ctrl-K: copy-id }
          if CurSess >= 0 then
          begin
            Chosen := Sessions[CurSess];
            Exit(srCopyId);
          end;
        KEY_IC:
          begin
            EditSession(-1);
            BuildRows;
          end;
        KEY_F0 + 4:
          if CurSess >= 0 then
          begin
            EditSession(CurSess);
            BuildRows;
          end;
        KEY_DC:
          if CurSess >= 0 then
          begin
            DeleteSession(CurSess);
            BuildRows;
            if cur > High(Rows) then cur := High(Rows);
            if cur < 0 then cur := 0;
          end;
        27, KEY_F0 + 10: Exit(srCancel);
        KEY_MOUSE:
          if getmouse(@me) = OK then
            if (me.bstate and (mbtn1Pressed or mbtn1Clicked or mbtn1Double)) <> 0 then
            begin
              i := me.y - y - 1 + top;
              if (i >= 0) and (i <= High(Rows)) then
              begin
                cur := i;
                if (me.bstate and mbtn1Double) <> 0 then ActivateRow;
              end;
            end;
      end;
    until False;
  finally
    Expanded.Free;
  end;
end;

end.
