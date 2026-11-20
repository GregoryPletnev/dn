{ dndb — database connections: the registry, the CLI clients, results.

  dn talks to the databases through their own command-line clients, the
  way it uses bsdtar or sftp: psql, `clickhouse client` (or
  clickhouse-client) and sqlite3. Each query is one client run with the
  SQL on stdin and machine-readable output (CSV with a header row), so
  TLS, every auth method and ~/.pgpass come with the client, and the
  RunCapture progress box (with Esc) covers slow queries.

  The registry is ConfigDir/databases, one INI section per connection.
  Passwords are not in it: they sit in the vault (dnvault) when the user
  chose to save them, else they are asked for once per dn run and kept in
  memory. A password reaches a client through its child environment
  (PGPASSWORD) or a 0600 temporary config file (ClickHouse), never the
  command line.

  Test seams: DN_DB_PSQL, DN_DB_CLICKHOUSE, DN_DB_SQLITE replace the
  client commands. }
unit dndb;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

type
  TDbKind = (dbPostgres, dbClickHouse, dbSqlite);

  TDbConn = record
    Name: AnsiString;
    Folder: AnsiString;       // '' = top level; 'work/prod' = nested
    Kind: TDbKind;
    Host: AnsiString;
    Port: AnsiString;
    User: AnsiString;
    Database: AnsiString;     // SQLite: the database file
    Options: AnsiString;      // extra client arguments, as typed
    SavePassword: Boolean;    // keep the password in the vault
  end;
  TDbConns = array of TDbConn;

  TDbRow = array of AnsiString;
  TCsvRows = array of TStringArray;
  TDbResult = record
    Columns: TDbRow;
    Rows: array of TDbRow;
    Message: AnsiString;      // a statement without rows: 'INSERT 0 1', 'OK'
    Truncated: Boolean;       // more rows than MaxRows came back
  end;

  { one entry of a schema listing }
  TDbObject = record
    Name: AnsiString;
    Kind: AnsiString;         // 'table', 'view', ...
    Rows: Int64;              // an estimate, -1 = unknown
  end;
  TDbObjects = array of TDbObject;

  { ask for a connection's password; Save: also store it in the vault }
  TDbPasswordHook = function(const C: TDbConn; const Why: AnsiString;
                             out Password: AnsiString;
                             out Save: Boolean): Boolean;

var
  DbPasswordHook: TDbPasswordHook = nil;

const
  DbKindNames: array[TDbKind] of AnsiString = ('postgres', 'clickhouse', 'sqlite');

function DbRegistryPath: AnsiString;
procedure DbLoadConns(out A: TDbConns);
procedure DbSaveConns(const A: TDbConns);
function DbKindOf(const S: AnsiString; out K: TDbKind): Boolean;
{ the vault id of a connection's password }
function DbConnId(const C: TDbConn): AnsiString;
{ one line for lists: 'name  postgres  user@host:port/db' }
function DbConnLabel(const C: TDbConn): AnsiString;

{ RFC 4180 CSV: quoted fields may hold commas, quotes ("") and newlines }
procedure ParseCsv(const Text: AnsiString; out Rows: TCsvRows);

{ run Sql; MaxRows <= 0 = all rows }
function DbQuery(var C: TDbConn; const Sql: AnsiString; MaxRows: Integer;
                 out R: TDbResult; out Err: AnsiString;
                 const Title: AnsiString = 'Query'): Boolean;

{ schemas (PostgreSQL) or databases (ClickHouse); SQLite has none }
function DbHasSchemas(const C: TDbConn): Boolean;
function DbListSchemas(var C: TDbConn; out Names: TStringArray;
                       out Err: AnsiString): Boolean;
{ tables and views; Schema is ignored for SQLite }
function DbListObjects(var C: TDbConn; const Schema: AnsiString;
                       out Objs: TDbObjects; out Err: AnsiString): Boolean;
{ the quoted, qualified name for SQL text }
function DbQualify(const C: TDbConn; const Schema, Name: AnsiString): AnsiString;
{ 'abc' with quotes doubled, for literals }
function DbLiteral(const S: AnsiString): AnsiString;

{ write the whole table as CSV (header included) to LocalDest }
function DbExportCsv(var C: TDbConn; const Schema, Name, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean;

{ forget the passwords typed during this run }
procedure DbForgetPasswords;

implementation

uses
  IniFiles, dnvfs, dnvault, dnconfig;

var
  Typed: TStringList = nil;   // ConnId=password typed this run

function DbRegistryPath: AnsiString;
begin
  Result := IncludeTrailingPathDelimiter(ConfigDir) + 'databases';
end;

function DbKindOf(const S: AnsiString; out K: TDbKind): Boolean;
var
  k2: TDbKind;
  t: AnsiString;
begin
  t := LowerCase(Trim(S));
  if (t = 'pg') or (t = 'postgresql') then t := 'postgres';
  if t = 'ch' then t := 'clickhouse';
  if t = 'sqlite3' then t := 'sqlite';
  for k2 := Low(TDbKind) to High(TDbKind) do
    if DbKindNames[k2] = t then
    begin
      K := k2;
      Exit(True);
    end;
  K := dbPostgres;
  Result := False;
end;

procedure DbLoadConns(out A: TDbConns);
var
  ini: TIniFile;
  secs: TStringList;
  i: Integer;
  c: TDbConn;
begin
  SetLength(A, 0);
  if not FileExists(DbRegistryPath) then Exit;
  ini := TIniFile.Create(DbRegistryPath);
  secs := TStringList.Create;
  try
    ini.ReadSections(secs);
    for i := 0 to secs.Count - 1 do
    begin
      c.Name := secs[i];
      c.Folder := ini.ReadString(secs[i], 'folder', '');
      if not DbKindOf(ini.ReadString(secs[i], 'kind', 'postgres'), c.Kind) then
        Continue;
      c.Host := ini.ReadString(secs[i], 'host', '');
      c.Port := ini.ReadString(secs[i], 'port', '');
      c.User := ini.ReadString(secs[i], 'user', '');
      c.Database := ini.ReadString(secs[i], 'database', '');
      c.Options := ini.ReadString(secs[i], 'options', '');
      c.SavePassword := ini.ReadBool(secs[i], 'save_password', False);
      SetLength(A, Length(A) + 1);
      A[High(A)] := c;
    end;
  finally
    secs.Free;
    ini.Free;
  end;
end;

procedure DbSaveConns(const A: TDbConns);
var
  L: TStringList;
  i: Integer;
begin
  ForceDirectories(ConfigDir);
  L := TStringList.Create;
  try
    L.Add('# dn database connections (passwords live in vault.db)');
    for i := 0 to High(A) do
    begin
      L.Add('');
      L.Add('[' + A[i].Name + ']');
      if A[i].Folder <> '' then L.Add('folder=' + A[i].Folder);
      L.Add('kind=' + DbKindNames[A[i].Kind]);
      if A[i].Host <> '' then L.Add('host=' + A[i].Host);
      if A[i].Port <> '' then L.Add('port=' + A[i].Port);
      if A[i].User <> '' then L.Add('user=' + A[i].User);
      if A[i].Database <> '' then L.Add('database=' + A[i].Database);
      if A[i].Options <> '' then L.Add('options=' + A[i].Options);
      if A[i].SavePassword then L.Add('save_password=1');
    end;
    L.SaveToFile(DbRegistryPath);
  finally
    L.Free;
  end;
end;

function DbConnId(const C: TDbConn): AnsiString;
begin
  Result := 'db:' + C.Folder + '/' + C.Name;
end;

function DbConnLabel(const C: TDbConn): AnsiString;
var
  where: AnsiString;
begin
  if C.Kind = dbSqlite then
    where := C.Database
  else
  begin
    where := C.Host;
    if where = '' then where := 'localhost';
    if C.User <> '' then where := C.User + '@' + where;
    if C.Port <> '' then where := where + ':' + C.Port;
    if C.Database <> '' then where := where + '/' + C.Database;
  end;
  Result := Format('%-20s %-10s %s', [Copy(C.Name, 1, 20), DbKindNames[C.Kind],
                                      where]);
end;

{ --- CSV ------------------------------------------------------------------ }

procedure ParseCsv(const Text: AnsiString; out Rows: TCsvRows);
var
  i, n: Integer;
  field: AnsiString;
  row: TStringArray;
  inQ, any: Boolean;

  procedure EndField;
  begin
    SetLength(row, Length(row) + 1);
    row[High(row)] := field;
    field := '';
  end;

  procedure EndRow;
  begin
    EndField;
    SetLength(Rows, Length(Rows) + 1);
    Rows[High(Rows)] := row;
    SetLength(row, 0);
  end;

begin
  SetLength(Rows, 0);
  SetLength(row, 0);
  field := '';
  inQ := False;
  any := False;
  n := Length(Text);
  i := 1;
  while i <= n do
  begin
    if inQ then
    begin
      if Text[i] = '"' then
      begin
        if (i < n) and (Text[i + 1] = '"') then
        begin
          field := field + '"';
          Inc(i);
        end
        else
          inQ := False;
      end
      else
        field := field + Text[i];
    end
    else
      case Text[i] of
        '"': begin inQ := True; any := True; end;
        ',': begin EndField; any := True; end;
        #13: ;
        #10: begin EndRow; any := False; end;
      else
        begin
          field := field + Text[i];
          any := True;
        end;
      end;
    Inc(i);
  end;
  if any or (field <> '') or (Length(row) > 0) then EndRow;
end;

{ --- running the clients -------------------------------------------------- }

function Q(const S: AnsiString): AnsiString;
begin
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function ClientCmd(const EnvName, Default: AnsiString): AnsiString;
begin
  Result := GetEnvironmentVariable(EnvName);
  if Result = '' then Result := Default;
end;

function ClickHouseBinary: AnsiString;
begin
  Result := GetEnvironmentVariable('DN_DB_CLICKHOUSE');
  if Result <> '' then Exit;
  if ExeSearch('clickhouse-client', GetEnvironmentVariable('PATH')) <> '' then
    Result := 'clickhouse-client'
  else
    Result := 'clickhouse client';
end;

function AuthFailed(const Msg: AnsiString): Boolean;
var
  m: AnsiString;
begin
  m := LowerCase(Msg);
  Result := (Pos('password authentication failed', m) > 0) or
            (Pos('no password supplied', m) > 0) or
            (Pos('authentication failed', m) > 0) or
            (Pos('authentication_failed', m) > 0) or
            (Pos('password is incorrect', m) > 0);
end;

function KnownPassword(const C: TDbConn; out Pw: AnsiString): Boolean;
var
  err: AnsiString;
begin
  Pw := '';
  if (Typed <> nil) and (Typed.IndexOfName(DbConnId(C)) >= 0) then
  begin
    Pw := Typed.Values[DbConnId(C)];
    Exit(True);
  end;
  Result := C.SavePassword and VaultHas(DbConnId(C)) and
            VaultGet(DbConnId(C), Pw, err);
end;

procedure RememberTyped(const C: TDbConn; const Pw: AnsiString);
begin
  if Typed = nil then Typed := TStringList.Create;
  Typed.Values[DbConnId(C)] := Pw;
end;

procedure DbForgetPasswords;
begin
  FreeAndNil(Typed);
end;

function RunClient(const C: TDbConn; const Sql, Password, Title: AnsiString;
                   const Redirect: AnsiString;
                   out Output, ErrOut: AnsiString): Integer;
var
  cmd, cfg: AnsiString;
  env: array of AnsiString;
  L: TStringList;
begin
  SetLength(env, 0);
  cfg := '';
  case C.Kind of
    dbPostgres:
      begin
        { -X no psqlrc, -w never prompt (stdin is the SQL), --csv rows }
        cmd := ClientCmd('DN_DB_PSQL', 'psql') +
               ' -X -w -v ON_ERROR_STOP=1 --csv';
        if C.Host <> '' then cmd := cmd + ' -h ' + Q(C.Host);
        if C.Port <> '' then cmd := cmd + ' -p ' + Q(C.Port);
        if C.User <> '' then cmd := cmd + ' -U ' + Q(C.User);
        if C.Database <> '' then cmd := cmd + ' -d ' + Q(C.Database);
        if C.Options <> '' then cmd := cmd + ' ' + C.Options;
        cmd := cmd + ' -f -';
        SetLength(env, 1);
        env[0] := 'PGCONNECT_TIMEOUT=10';
        if Password <> '' then
        begin
          SetLength(env, 2);
          env[1] := 'PGPASSWORD=' + Password;
        end;
      end;
    dbClickHouse:
      begin
        cmd := ClickHouseBinary + ' --format CSVWithNames --multiquery';
        if C.Host <> '' then cmd := cmd + ' --host ' + Q(C.Host);
        if C.Port <> '' then cmd := cmd + ' --port ' + Q(C.Port);
        if C.User <> '' then cmd := cmd + ' --user ' + Q(C.User);
        if C.Database <> '' then cmd := cmd + ' --database ' + Q(C.Database);
        if Password <> '' then
        begin
          { the password goes through a 0600 config file, not argv }
          cfg := GetTempDir + 'dn-ch-' + IntToStr(GetProcessID) + '-' +
                 IntToStr(Random(1000000)) + '.xml';
          L := TStringList.Create;
          try
            L.Add('<config><password>' +
                  StringReplace(StringReplace(StringReplace(Password, '&', '&amp;',
                    [rfReplaceAll]), '<', '&lt;', [rfReplaceAll]), '>', '&gt;',
                    [rfReplaceAll]) + '</password></config>');
            FileClose(FileCreate(cfg, &600));
            L.SaveToFile(cfg);
          finally
            L.Free;
          end;
          cmd := cmd + ' --config-file ' + Q(cfg);
        end;
        if C.Options <> '' then cmd := cmd + ' ' + C.Options;
      end;
    dbSqlite:
      cmd := ClientCmd('DN_DB_SQLITE', 'sqlite3') + ' -bail -csv -header ' +
             Q(C.Database);
  end;
  cmd := cmd + Redirect;
  Result := RunCaptureEx(cmd, Sql, env, Output, ErrOut, Title, C.Name, 'rows');
  if cfg <> '' then DeleteFile(cfg);
end;

{ the registry entry of C now keeps its password in the vault }
procedure MarkSaved(const C: TDbConn);
var
  a: TDbConns;
  i: Integer;
begin
  DbLoadConns(a);
  for i := 0 to High(a) do
    if (a[i].Name = C.Name) and (a[i].Folder = C.Folder) then
    begin
      a[i].SavePassword := True;
      DbSaveConns(a);
      Exit;
    end;
end;

{ run with the known password; on an auth failure ask once and retry }
function RunAuthed(var C: TDbConn; const Sql, Title, Redirect: AnsiString;
                   out Output, ErrOut: AnsiString): Integer;
var
  pw: AnsiString;
  save: Boolean;
  err: AnsiString;
  attempt: Integer;
begin
  KnownPassword(C, pw);
  for attempt := 1 to 3 do
  begin
    Result := RunClient(C, Sql, pw, Title, Redirect, Output, ErrOut);
    if (Result = 0) or (Result = RunCancelledExit) or
       (C.Kind = dbSqlite) or not AuthFailed(ErrOut + Output) then
      Exit;
    if not Assigned(DbPasswordHook) then Exit;
    if not DbPasswordHook(C, Trim(ErrOut), pw, save) then Exit;
    RememberTyped(C, pw);
    if save and VaultPut(DbConnId(C), pw, err) then
    begin
      C.SavePassword := True;
      MarkSaved(C);
    end;
  end;
end;

function IsCommandTag(const S: AnsiString): Boolean;
var
  i: Integer;
begin
  { psql prints 'INSERT 0 1', 'CREATE TABLE', 'UPDATE 3' for statements
    without rows }
  Result := (S <> '') and (S[1] in ['A'..'Z']);
  if Result then
    for i := 1 to Length(S) do
      if not (S[i] in ['A'..'Z', '0'..'9', ' ']) then Exit(False);
end;

function DbQuery(var C: TDbConn; const Sql: AnsiString; MaxRows: Integer;
                 out R: TDbResult; out Err: AnsiString;
                 const Title: AnsiString): Boolean;
var
  outp, errp: AnsiString;
  rows: TCsvRows;
  rc, i, first, n: Integer;
  lines: TStringList;
begin
  Result := False;
  Err := '';
  SetLength(R.Columns, 0);
  SetLength(R.Rows, 0);
  R.Message := '';
  R.Truncated := False;
  rc := RunAuthed(C, Sql, Title, '', outp, errp);
  if rc <> 0 then
  begin
    if rc = RunCancelledExit then Err := 'cancelled'
    else
    begin
      Err := Trim(errp);
      if Err = '' then Err := Trim(outp);
      if Err = '' then Err := 'the client failed (exit ' + IntToStr(rc) + ')';
    end;
    Exit;
  end;
  { command tags (psql) before or instead of the rows }
  lines := TStringList.Create;
  try
    lines.Text := outp;
    first := 0;
    while (first < lines.Count) and IsCommandTag(Trim(lines[first])) and
          (Pos(',', lines[first]) = 0) do
    begin
      if R.Message <> '' then R.Message := R.Message + '; ';
      R.Message := R.Message + Trim(lines[first]);
      Inc(first);
    end;
    if first > 0 then
    begin
      for i := 1 to first do lines.Delete(0);
      outp := lines.Text;
    end;
  finally
    lines.Free;
  end;
  ParseCsv(outp, rows);
  if Length(rows) > 0 then
  begin
    R.Columns := rows[0];
    n := Length(rows) - 1;
    if (MaxRows > 0) and (n > MaxRows) then
    begin
      n := MaxRows;
      R.Truncated := True;
    end;
    SetLength(R.Rows, n);
    for i := 0 to n - 1 do
      R.Rows[i] := rows[i + 1];
  end
  else if R.Message = '' then
    R.Message := 'OK';
  Result := True;
end;

{ --- schema ----------------------------------------------------------------- }

function DbLiteral(const S: AnsiString): AnsiString;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

function QuoteIdent(const C: TDbConn; const S: AnsiString): AnsiString;
begin
  if C.Kind = dbClickHouse then
    Result := '`' + StringReplace(S, '`', '``', [rfReplaceAll]) + '`'
  else
    Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"';
end;

function DbQualify(const C: TDbConn; const Schema, Name: AnsiString): AnsiString;
begin
  if (Schema = '') or (C.Kind = dbSqlite) then
    Result := QuoteIdent(C, Name)
  else
    Result := QuoteIdent(C, Schema) + '.' + QuoteIdent(C, Name);
end;

function DbHasSchemas(const C: TDbConn): Boolean;
begin
  Result := C.Kind <> dbSqlite;
end;

function DbListSchemas(var C: TDbConn; out Names: TStringArray;
                       out Err: AnsiString): Boolean;
var
  r: TDbResult;
  sql: AnsiString;
  i: Integer;
begin
  SetLength(Names, 0);
  case C.Kind of
    dbPostgres:
      sql := 'SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE ''pg\_%'' ' +
             'AND nspname <> ''information_schema'' ORDER BY 1;';
    dbClickHouse:
      sql := 'SELECT name FROM system.databases ORDER BY name';
  else
    begin
      Err := '';
      Exit(True);
    end;
  end;
  Result := DbQuery(C, sql, 0, r, Err, 'Reading schemas');
  if not Result then Exit;
  SetLength(Names, Length(r.Rows));
  for i := 0 to High(r.Rows) do
    if Length(r.Rows[i]) > 0 then Names[i] := r.Rows[i][0];
end;

function DbListObjects(var C: TDbConn; const Schema: AnsiString;
                       out Objs: TDbObjects; out Err: AnsiString): Boolean;
var
  r: TDbResult;
  sql: AnsiString;
  i: Integer;
begin
  SetLength(Objs, 0);
  case C.Kind of
    dbPostgres:
      sql := 'SELECT c.relname, CASE c.relkind WHEN ''r'' THEN ''table'' ' +
             'WHEN ''p'' THEN ''table'' WHEN ''v'' THEN ''view'' ' +
             'WHEN ''m'' THEN ''matview'' ELSE ''foreign'' END, ' +
             'GREATEST(c.reltuples, -1)::bigint FROM pg_class c ' +
             'JOIN pg_namespace n ON n.oid = c.relnamespace ' +
             'WHERE n.nspname = ' + DbLiteral(Schema) +
             ' AND c.relkind IN (''r'', ''p'', ''v'', ''m'', ''f'') ORDER BY 1;';
    dbClickHouse:
      sql := 'SELECT name, lower(engine), ifNull(total_rows, -1) FROM system.tables ' +
             'WHERE database = ' + DbLiteral(Schema) + ' ORDER BY name';
    dbSqlite:
      sql := 'SELECT name, type, -1 FROM sqlite_master WHERE type IN ' +
             '(''table'', ''view'') AND name NOT LIKE ''sqlite\_%'' ESCAPE ''\'' ' +
             'ORDER BY name;';
  end;
  Result := DbQuery(C, sql, 0, r, Err, 'Reading tables');
  if not Result then Exit;
  SetLength(Objs, Length(r.Rows));
  for i := 0 to High(r.Rows) do
  begin
    Objs[i].Name := '';
    Objs[i].Kind := '';
    Objs[i].Rows := -1;
    if Length(r.Rows[i]) > 0 then Objs[i].Name := r.Rows[i][0];
    if Length(r.Rows[i]) > 1 then Objs[i].Kind := r.Rows[i][1];
    if Length(r.Rows[i]) > 2 then
      Objs[i].Rows := StrToInt64Def(r.Rows[i][2], -1);
  end;
end;

function DbExportCsv(var C: TDbConn; const Schema, Name, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean;
var
  outp, errp: AnsiString;
  rc: Integer;
begin
  Err := '';
  { stdout goes straight to the file: a big table never sits in memory }
  rc := RunAuthed(C, 'SELECT * FROM ' + DbQualify(C, Schema, Name) + ';',
                  'Exporting', ' > ' + Q(LocalDest), outp, errp);
  Result := rc = 0;
  if not Result then
  begin
    if rc = RunCancelledExit then Err := 'cancelled'
    else Err := Trim(errp);
    if Err = '' then Err := 'export failed';
  end;
end;

finalization
  Typed.Free;
end.
