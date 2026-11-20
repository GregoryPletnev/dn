{ dndbui — the database UI: the connection manager, the SQL window and
  the password prompts.

  Connection manager (Disk > Databases, Ctrl-Q): the registry as a list.
    Enter  open the database in the active panel
    F2     SQL window          F5   test the connection
    Ins    new connection      F4   edit          F8  delete
  SQL window: a MicroEd editor on ConfigDir/sql/<name>.sql (kept between
  runs). Ctrl-R runs the block under the cursor (the lines between blank
  lines); the rows appear in a result grid under the editor. }
unit dndbui;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnwin, dnedit, dngrid, dndb;

type
  TDbAction = (daCancel, daOpen, daSql);

  TSqlWin = class(TEditWin)
  public
    Conn: TDbConn;
    Grid: TGridWin;
    constructor CreateSql(const AConn: TDbConn; const APath: AnsiString;
                          ALines: TStringList);
    function HandleKey(ch: LongInt): TKeyAction; override;
    function StatusText: AnsiString; override;
    function ConfirmClose: Boolean; override;
    { the statement block under the cursor }
    function CurrentBlock: AnsiString;
    procedure Run;
  end;

{ the manager; Chosen is the connection for daOpen/daSql }
function DbManager(out Chosen: TDbConn): TDbAction;

{ an SQL window for C; Initial (if any) is appended and the cursor put
  on it }
function OpenSqlWindow(const C: TDbConn; const Initial: AnsiString): TSqlWin;

{ run Sql and show the rows in a grid; nil (after a message) on error }
function OpenQueryGrid(var C: TDbConn; const Sql, Title: AnsiString): TGridWin;

{ the prompts dndb and dnvault call: install once the screen is up }
function AskVaultMaster(NewVault: Boolean; const Hint: AnsiString;
                        out Master: AnsiString): Boolean;
function AskDbPassword(const C: TDbConn; const Why: AnsiString;
                       out Password: AnsiString; out Save: Boolean): Boolean;

implementation

uses
  SysUtils, ncurses, dnscreen, dndialog, dnconfig, dnvault;

const
  SqlMaxRows = 10000;
  PreviewRows = 1000;

{ --- prompts ---------------------------------------------------------------- }

function AskVaultMaster(NewVault: Boolean; const Hint: AnsiString;
                        out Master: AnsiString): Boolean;
var
  again: AnsiString;
begin
  Master := '';
  if not NewVault then
  begin
    if Hint <> '' then
      MsgBox('Vault', Hint, ['OK']);
    Result := PasswordBox('Vault', 'Master password (saved DB passwords):', Master);
    Exit;
  end;
  repeat
    Master := '';
    if not PasswordBox('New vault', 'Choose a master password for saved DB passwords:',
                       Master) then
      Exit(False);
    if Master = '' then Continue;
    again := '';
    if not PasswordBox('New vault', 'Type the master password again:', again) then
      Exit(False);
    if again = Master then Exit(True);
    MsgBox('New vault', 'The two passwords differ. Try again.', ['OK']);
  until False;
end;

function AskDbPassword(const C: TDbConn; const Why: AnsiString;
                       out Password: AnsiString; out Save: Boolean): Boolean;
var
  prompt: AnsiString;
begin
  Password := '';
  Save := False;
  prompt := 'Password for ' + C.Name;
  if C.User <> '' then prompt := prompt + ' (' + C.User + ')';
  Result := PasswordBox('Database', prompt + ':', Password);
  if not Result then Exit;
  if not C.SavePassword then
    Save := MsgBox('Database', 'Save this password in the vault?'#10 +
                   '(encrypted with your master password)', ['Yes', 'No']) = 0;
end;

{ --- the grid of a query ----------------------------------------------------- }

function RunToResult(var C: TDbConn; const Sql: AnsiString; MaxRows: Integer;
                     out R: TDbResult; out Info: AnsiString): Boolean;
var
  t0: QWord;
  err: AnsiString;
begin
  t0 := GetTickCount64;
  Result := DbQuery(C, Sql, MaxRows, R, err, 'Query');
  if not Result then
  begin
    if err <> 'cancelled' then MsgBox('SQL error', err, ['OK']);
    Exit;
  end;
  Info := IntToStr(GetTickCount64 - t0) + ' ms';
  if R.Truncated then
    Info := Info + ', first ' + IntToStr(MaxRows) + ' rows';
end;

function OpenQueryGrid(var C: TDbConn; const Sql, Title: AnsiString): TGridWin;
var
  r: TDbResult;
  info: AnsiString;
begin
  Result := nil;
  if not RunToResult(C, Sql, PreviewRows, r, info) then Exit;
  Result := OpenGrid(Title, r, info);
end;

{ --- the SQL window --------------------------------------------------------- }

function SqlPath(const C: TDbConn): AnsiString;
var
  n: AnsiString;
  i: Integer;
begin
  n := C.Folder + '_' + C.Name;
  for i := 1 to Length(n) do
    if not (n[i] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.']) then n[i] := '_';
  Result := IncludeTrailingPathDelimiter(ConfigDir) + 'sql/' + n + '.sql';
end;

constructor TSqlWin.CreateSql(const AConn: TDbConn; const APath: AnsiString;
                              ALines: TStringList);
begin
  inherited CreateEdit(APath, ALines);
  Conn := AConn;
  Grid := nil;
  Title := 'SQL: ' + Conn.Name;
  { the editor in the top part, the result grid below it }
  X := 0;
  Y := DeskY0;
  W := COLS;
  H := (DeskY1 - DeskY0 + 1) * 2 div 5;
  if H < 6 then H := 6;
  ClampToDesk;
end;

function TSqlWin.StatusText: AnsiString;
begin
  Result := 'Ctrl-R run  ' + inherited StatusText;
end;

function TSqlWin.ConfirmClose: Boolean;
begin
  { the text is a scratch pad: keep it without asking }
  if Modified then Save;
  Result := True;
end;

function TSqlWin.CurrentBlock: AnsiString;
var
  a, b, i: Integer;
begin
  Result := '';
  if Lines.Count = 0 then Exit;
  a := CurY;
  if Trim(Lines[a]) = '' then
  begin
    { on a blank line: the block above it }
    while (a > 0) and (Trim(Lines[a]) = '') do Dec(a);
    if Trim(Lines[a]) = '' then Exit;
  end;
  b := a;
  while (a > 0) and (Trim(Lines[a - 1]) <> '') do Dec(a);
  while (b < Lines.Count - 1) and (Trim(Lines[b + 1]) <> '') do Inc(b);
  for i := a to b do
    Result := Result + Lines[i] + #10;
end;

function WinAlive(w: TWin): Boolean;
var
  i: Integer;
begin
  for i := 0 to WinCount - 1 do
    if Wins[i] = w then Exit(True);
  Result := False;
end;

procedure TSqlWin.Run;
var
  sql, info: AnsiString;
  r: TDbResult;
begin
  sql := CurrentBlock;
  if Trim(sql) = '' then
  begin
    MsgBox('SQL', 'Nothing to run: put the cursor on a statement.', ['OK']);
    Exit;
  end;
  if Modified then Save;
  if not RunToResult(Conn, sql, SqlMaxRows, r, info) then Exit;
  if (Grid = nil) or not WinAlive(Grid) then
  begin
    Grid := TGridWin.CreateGrid(0, Y + H, COLS, DeskY1 - (Y + H) + 1,
                                'Result: ' + Conn.Name);
    WinAdd(Grid);
  end;
  Grid.SetResult(r, info);
end;

function TSqlWin.HandleKey(ch: LongInt): TKeyAction;
begin
  if ch = 18 then              // Ctrl-R
  begin
    Run;
    Result := kaConsumed;
  end
  else
    Result := inherited HandleKey(ch);
end;

function OpenSqlWindow(const C: TDbConn; const Initial: AnsiString): TSqlWin;
var
  L: TStringList;
  path: AnsiString;
begin
  path := SqlPath(C);
  ForceDirectories(ExtractFileDir(path));
  L := TStringList.Create;
  try
    if FileExists(path) then L.LoadFromFile(path);
  except
    L.Clear;
  end;
  if Initial <> '' then
  begin
    while (L.Count > 0) and (Trim(L[L.Count - 1]) = '') do L.Delete(L.Count - 1);
    if L.Count > 0 then L.Add('');
    L.Add(Initial);
  end;
  Result := TSqlWin.CreateSql(C, path, L);
  if Initial <> '' then
  begin
    Result.CurY := L.Count - 1;
    Result.Modified := True;
  end;
  WinAdd(Result);
end;

{ --- the connection manager --------------------------------------------------- }

procedure SortConns(var A: TDbConns);
var
  i, j: Integer;
  t: TDbConn;
begin
  for i := 1 to High(A) do
  begin
    t := A[i];
    j := i - 1;
    while (j >= 0) and (LowerCase(A[j].Folder + '/' + A[j].Name) >
                        LowerCase(t.Folder + '/' + t.Name)) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := t;
  end;
end;

function NameTaken(const A: TDbConns; const Name: AnsiString; Skip: Integer): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(A) do
    if (i <> Skip) and SameText(A[i].Name, Name) then Exit(True);
  Result := False;
end;

{ ask the fields one by one, as the SSH session editor does }
function EditConn(var A: TDbConns; Idx: Integer): Boolean;
var
  c: TDbConn;
  v, pw, err: AnsiString;
  kinds: TStringList;
  k: Integer;
  wasSaved: Boolean;
begin
  Result := False;
  if Idx >= 0 then c := A[Idx]
  else
  begin
    c.Name := ''; c.Folder := ''; c.Kind := dbPostgres; c.Host := '';
    c.Port := ''; c.User := ''; c.Database := ''; c.Options := '';
    c.SavePassword := False;
  end;
  wasSaved := c.SavePassword;

  v := c.Name;
  repeat
    if not InputBox('Connection', 'Name:', v) then Exit;
    v := Trim(v);
    if v = '' then Exit;
    if not NameTaken(A, v, Idx) then Break;
    MsgBox('Connection', 'There is a connection named "' + v + '" already.', ['OK']);
  until False;
  c.Name := v;

  kinds := TStringList.Create;
  try
    kinds.Add('PostgreSQL  (psql)');
    kinds.Add('ClickHouse  (clickhouse client)');
    kinds.Add('SQLite      (sqlite3)');
    k := ListDialog('Database kind', kinds);
  finally
    kinds.Free;
  end;
  if k < 0 then Exit;
  c.Kind := TDbKind(k);

  if c.Kind = dbSqlite then
  begin
    v := c.Database;
    if not InputBox('Connection', 'Database file:', v) then Exit;
    c.Database := ExpandFileName(Trim(v));
    c.Host := ''; c.Port := ''; c.User := '';
    c.SavePassword := False;
  end
  else
  begin
    v := c.Host;
    if not InputBox('Connection', 'Host (empty = local):', v) then Exit;
    c.Host := Trim(v);
    v := c.Port;
    if not InputBox('Connection', 'Port (empty = default):', v) then Exit;
    c.Port := Trim(v);
    v := c.User;
    if not InputBox('Connection', 'User:', v) then Exit;
    c.User := Trim(v);
    v := c.Database;
    if not InputBox('Connection', 'Database:', v) then Exit;
    c.Database := Trim(v);
  end;
  v := c.Options;
  if not InputBox('Connection', 'Extra client options (e.g. --secure):', v) then Exit;
  c.Options := Trim(v);
  v := c.Folder;
  if not InputBox('Connection', 'Folder (a/b, empty = top):', v) then Exit;
  c.Folder := Trim(v);

  if c.Kind <> dbSqlite then
  begin
    c.SavePassword := MsgBox('Connection',
      'Keep the password in the vault?'#10 +
      '(encrypted with a master password; "No" asks once per dn run)',
      ['Yes', 'No']) = 0;
    if c.SavePassword then
    begin
      pw := '';
      if PasswordBox('Connection', 'Password for ' + c.Name +
                     ' (empty = keep the saved one):', pw) and (pw <> '') then
        if not VaultPut(DbConnId(c), pw, err) then
        begin
          MsgBox('Vault', 'The password was not saved:'#10 + err, ['OK']);
          c.SavePassword := False;
        end;
    end;
  end;
  { a renamed or no longer saved entry leaves no secret behind }
  if wasSaved and (Idx >= 0) and
     ((not c.SavePassword) or (DbConnId(c) <> DbConnId(A[Idx]))) then
    VaultDelete(DbConnId(A[Idx]), err);

  if Idx >= 0 then A[Idx] := c
  else
  begin
    SetLength(A, Length(A) + 1);
    A[High(A)] := c;
  end;
  DbSaveConns(A);
  Result := True;
end;

procedure TestConn(var C: TDbConn);
var
  r: TDbResult;
  err: AnsiString;
begin
  if DbQuery(C, 'SELECT 1;', 1, r, err, 'Connecting') then
    MsgBox('Connection', C.Name + ': connected.', ['OK'])
  else if err <> 'cancelled' then
    MsgBox('Connection', C.Name + ':'#10 + err, ['OK']);
end;

function DbManager(out Chosen: TDbConn): TDbAction;
var
  a: TDbConns;
  items: TStringList;
  cur, i: Integer;
  key: LongInt;
  err, added: AnsiString;

  procedure Fill;
  var
    j: Integer;
    s: AnsiString;
  begin
    SortConns(a);
    items.Clear;
    for j := 0 to High(a) do
    begin
      s := DbConnLabel(a[j]);
      if a[j].Folder <> '' then s := a[j].Folder + '/ ' + s;
      items.Add(s);
    end;
    if items.Count = 0 then
      items.Add('(no connections: Ins adds one)');
  end;

begin
  Result := daCancel;
  DbLoadConns(a);
  items := TStringList.Create;
  try
    cur := 0;
    repeat
      Fill;
      if not KeyListDialog('Databases',
           'Enter panel  F2 SQL  F5 test  Ins new  F4 edit  F8 delete',
           items, [10, KEY_F0 + 2, KEY_F0 + 5, KEY_IC, KEY_F0 + 4, KEY_F0 + 8,
                   KEY_DC], cur, key) then
        Exit;
      { Ins adds; on an empty list Enter and F4 add too }
      if (key = KEY_IC) or (Length(a) = 0) then
      begin
        if (key = KEY_IC) or (key = 10) or (key = KEY_F0 + 4) then
          if EditConn(a, -1) then
          begin
            added := a[High(a)].Name;
            SortConns(a);
            for i := 0 to High(a) do
              if a[i].Name = added then cur := i;
          end;
        Continue;
      end;
      case key of
        10:
          begin
            Chosen := a[cur];
            Exit(daOpen);
          end;
        KEY_F0 + 2:
          begin
            Chosen := a[cur];
            Exit(daSql);
          end;
        KEY_F0 + 5: TestConn(a[cur]);
        KEY_F0 + 4: EditConn(a, cur);
        KEY_F0 + 8, KEY_DC:
          if MsgBox('Databases', 'Delete the connection "' + a[cur].Name + '"?',
                    ['Delete', 'Cancel']) = 0 then
          begin
            VaultDelete(DbConnId(a[cur]), err);
            for i := cur to High(a) - 1 do a[i] := a[i + 1];
            SetLength(a, Length(a) - 1);
            DbSaveConns(a);
            if cur > High(a) then cur := High(a);
          end;
      end;
    until False;
  finally
    items.Free;
  end;
end;

end.
