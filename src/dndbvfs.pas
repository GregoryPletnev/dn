{ dndbvfs — a database as a directory tree in a panel.

  PostgreSQL:  db://name/            the schemas, as directories
               db://name/public/     its tables and views, as files
  ClickHouse:  the same with databases instead of schemas
  SQLite:      db://name/            the tables and views directly

  A table's "size" is its row count: an estimate from PostgreSQL and
  ClickHouse (pg_class.reltuples, system.tables.total_rows). SQLite keeps no
  estimate, so the listing leaves the size unknown (0) and never runs
  count(*): on a large file that scan hangs the panel. F3/Enter show the
  rows in a grid, F4 opens an SQL window, F5 to a local panel exports the
  table as CSV (GetFile). Writing (PutFile, delete, mkdir) is refused:
  changes go through SQL. }
unit dndbvfs;

{$mode objfpc}{$H+}

interface

uses
  dnvfs, dndb;

type
  TDbVFS = class(TVFS)
  public
    Conn: TDbConn;
    LocalDir: AnsiString;         // where Ctrl-PgUp from the root goes back to
    LocalCursor: AnsiString;      // and the name the cursor lands on there
    constructor CreateDb(const AConn: TDbConn; const ALocalDir: AnsiString);
    function List(const Dir: AnsiString; out Items: TVfsItems;
                  out Err: AnsiString): Boolean; override;
    function GetFile(const Path, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function PutFile(const LocalSrc, Path: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function DeletePath(const Path: AnsiString; IsDir: Boolean;
                        out Err: AnsiString): Boolean; override;
    function MakeDir(const Path: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function Display(const Path: AnsiString): AnsiString; override;
    function IsLocal: Boolean; override;
    function ParentExit(out ALocalDir, CursorName: AnsiString): Boolean; override;
    { split a panel path into schema and table ('' when absent) }
    procedure SplitPath(const Path: AnsiString; out Schema, Table: AnsiString);
    { the SELECT that shows a table's first rows }
    function PreviewSql(const Path: AnsiString; Limit: Integer): AnsiString;
  end;

{ an SQLite database file, told by its header ("SQLite format 3\0"),
  whatever its name: app.db, data.sqlite3, a browser's History }
function IsSqliteFile(const Path: AnsiString): Boolean;

{ an ad-hoc connection for a database file (not in the registry) }
function SqliteFileConn(const Path: AnsiString): TDbConn;

implementation

uses
  SysUtils;

const
  SqliteMagic = 'SQLite format 3'#0;     // the first 16 bytes of every file

function IsSqliteFile(const Path: AnsiString): Boolean;
var
  head: AnsiString;
  f: THandle;
begin
  Result := False;
  f := FileOpen(Path, fmOpenRead or fmShareDenyNone);
  if f = THandle(-1) then Exit;
  try
    SetLength(head, Length(SqliteMagic));
    Result := (FileRead(f, head[1], Length(head)) = Length(head)) and
              (head = SqliteMagic);
  finally
    FileClose(f);
  end;
end;
function SqliteFileConn(const Path: AnsiString): TDbConn;
begin
  Result.Name := ExtractFileName(Path);
  Result.Folder := '';
  Result.Kind := dbSqlite;
  Result.Host := '';
  Result.Port := '';
  Result.User := '';
  Result.Database := ExpandFileName(Path);
  Result.Options := '';
  Result.SavePassword := False;
end;

const
  ReadOnlyMsg = 'the database panel is read-only: use an SQL window (F4)';

constructor TDbVFS.CreateDb(const AConn: TDbConn; const ALocalDir: AnsiString);
begin
  inherited Create;
  Conn := AConn;
  LocalDir := ALocalDir;
  LocalCursor := '';
end;

procedure TDbVFS.SplitPath(const Path: AnsiString; out Schema, Table: AnsiString);
var
  p: AnsiString;
  i: Integer;
begin
  p := Path;
  while (p <> '') and (p[1] = '/') do Delete(p, 1, 1);
  while (p <> '') and (p[Length(p)] = '/') do SetLength(p, Length(p) - 1);
  Schema := '';
  Table := '';
  if DbHasSchemas(Conn) then
  begin
    i := Pos('/', p);
    if i = 0 then Schema := p
    else
    begin
      Schema := Copy(p, 1, i - 1);
      Table := Copy(p, i + 1, Length(p));
    end;
  end
  else
    Table := p;
end;

function TDbVFS.List(const Dir: AnsiString; out Items: TVfsItems;
                     out Err: AnsiString): Boolean;
var
  schema, table: AnsiString;
  names: TStringArray;
  objs: TDbObjects;
  i: Integer;
begin
  SetLength(Items, 0);
  SplitPath(Dir, schema, table);
  if table <> '' then
  begin
    Err := 'not a directory';
    Exit(False);
  end;
  if DbHasSchemas(Conn) and (schema = '') then
  begin
    Result := DbListSchemas(Conn, names, Err);
    if not Result then Exit;
    SetLength(Items, Length(names));
    for i := 0 to High(names) do
    begin
      Items[i].Name := names[i];
      Items[i].Size := 0;
      Items[i].MTime := 0;
      Items[i].IsDir := True;
    end;
    Exit;
  end;
  Result := DbListObjects(Conn, schema, objs, Err);
  if not Result then Exit;
  SetLength(Items, Length(objs));
  for i := 0 to High(objs) do
  begin
    Items[i].Name := objs[i].Name;
    if objs[i].Rows > 0 then Items[i].Size := objs[i].Rows
    else Items[i].Size := 0;
    Items[i].MTime := 0;
    Items[i].IsDir := False;
  end;
end;

function TDbVFS.GetFile(const Path, LocalDest: AnsiString;
                        out Err: AnsiString): Boolean;
var
  schema, table: AnsiString;
begin
  SplitPath(Path, schema, table);
  if table = '' then
  begin
    Err := 'not a table';
    Exit(False);
  end;
  Result := DbExportCsv(Conn, schema, table, LocalDest, Err);
end;

function TDbVFS.PutFile(const LocalSrc, Path: AnsiString;
                        out Err: AnsiString): Boolean;
begin
  Err := ReadOnlyMsg;
  Result := False;
end;

function TDbVFS.DeletePath(const Path: AnsiString; IsDir: Boolean;
                           out Err: AnsiString): Boolean;
begin
  Err := ReadOnlyMsg;
  Result := False;
end;

function TDbVFS.MakeDir(const Path: AnsiString; out Err: AnsiString): Boolean;
begin
  Err := ReadOnlyMsg;
  Result := False;
end;

function TDbVFS.Display(const Path: AnsiString): AnsiString;
begin
  Result := 'db://' + Conn.Name + '/' + Path;
end;

function TDbVFS.IsLocal: Boolean;
begin
  Result := False;
end;

function TDbVFS.ParentExit(out ALocalDir, CursorName: AnsiString): Boolean;
begin
  ALocalDir := LocalDir;
  CursorName := LocalCursor;
  Result := ALocalDir <> '';
end;

function TDbVFS.PreviewSql(const Path: AnsiString; Limit: Integer): AnsiString;
var
  schema, table: AnsiString;
begin
  SplitPath(Path, schema, table);
  Result := 'SELECT * FROM ' + DbQualify(Conn, schema, table) +
            ' LIMIT ' + IntToStr(Limit) + ';';
end;

end.
