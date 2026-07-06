{ dnvfs — the virtual file system layer (ROADMAP M3).
  A panel lists any TVFS: local disk, an archive, a remote host.
  Paths inside a VFS use '/' separators; '' or '/' is the VFS root. }
unit dnvfs;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TVfsItem = record
    Name: AnsiString;
    Size: Int64;
    MTime: TDateTime;
    IsDir: Boolean;
  end;
  TVfsItems = array of TVfsItem;

  TVFS = class
  public
    function List(const Dir: AnsiString; out Items: TVfsItems;
                  out Err: AnsiString): Boolean; virtual; abstract;
    { fetch one file to a local destination }
    function GetFile(const Path, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean; virtual; abstract;
    { fetch a whole subtree into local directory LocalDest (created) }
    function GetTree(const Path, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean; virtual;
    function PutFile(const LocalSrc, Path: AnsiString;
                     out Err: AnsiString): Boolean; virtual;
    function PutTree(const LocalSrc, Path: AnsiString;
                     out Err: AnsiString): Boolean; virtual;
    function DeletePath(const Path: AnsiString; IsDir: Boolean;
                        out Err: AnsiString): Boolean; virtual;
    function MakeDir(const Path: AnsiString;
                     out Err: AnsiString): Boolean; virtual;
    { display form of an inner path (panel title, command line) }
    function Display(const Path: AnsiString): AnsiString; virtual;
    function IsLocal: Boolean; virtual;
    { leaving the VFS root upwards: where to land in the local world.
      False = the root is the top (stay). }
    function ParentExit(out LocalDir, CursorName: AnsiString): Boolean; virtual;
  end;

  { a virtual panel listing arbitrary local files by full path (Ctrl-W) }
  TListVFS = class(TVFS)
  private
    FPaths: TStringList;   // owned; full local paths
    FTitle: AnsiString;
  public
    constructor Create(const ATitle: AnsiString; APaths: TStringList);
    destructor Destroy; override;
    function List(const Dir: AnsiString; out Items: TVfsItems;
                  out Err: AnsiString): Boolean; override;
    function GetFile(const Path, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function GetTree(const Path, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function Display(const Path: AnsiString): AnsiString; override;
    function RealPath(const Name: AnsiString): AnsiString;
  end;

  TLocalVFS = class(TVFS)
  public
    function List(const Dir: AnsiString; out Items: TVfsItems;
                  out Err: AnsiString): Boolean; override;
    function GetFile(const Path, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function GetTree(const Path, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function PutFile(const LocalSrc, Path: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function PutTree(const LocalSrc, Path: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function DeletePath(const Path: AnsiString; IsDir: Boolean;
                        out Err: AnsiString): Boolean; override;
    function MakeDir(const Path: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function IsLocal: Boolean; override;
  end;

function LocalVFS: TLocalVFS;   // shared singleton

function VfsJoin(const Dir, Name: AnsiString): AnsiString;
{ run a shell command, capture stdout+stderr; returns exit code }
function RunCapture(const Cmd: AnsiString; out Output: AnsiString): Integer;
{ parse 'ls -la'-style listing lines (bsdtar -tv, sftp ls -la) }
function ParseLsLine(const Line: AnsiString; out Item: TVfsItem;
                     out FullName: AnsiString): Boolean;

implementation

uses
  SysUtils, DateUtils, {$ifdef unix}Unix,{$endif} dnfileops;

var
  LocalSingleton: TLocalVFS = nil;

function LocalVFS: TLocalVFS;
begin
  if LocalSingleton = nil then
    LocalSingleton := TLocalVFS.Create;
  Result := LocalSingleton;
end;

function VfsJoin(const Dir, Name: AnsiString): AnsiString;
begin
  if (Dir = '') or (Dir = '/') then
    Result := Dir + Name
  else
    Result := Dir + '/' + Name;
end;

function RunCapture(const Cmd: AnsiString; out Output: AnsiString): Integer;
var
  tmp: AnsiString;
  L: TStringList;
begin
  Result := -1;
  Output := '';
  tmp := GetTempDir + 'dnvfs-' + IntToStr(GetProcessID) + '-' +
         IntToStr(Random(1000000)) + '.out';
  {$ifdef unix}
  Result := fpSystem(Cmd + ' >' + AnsiQuotedStr(tmp, '''') + ' 2>&1');
  if (Result and $7F) = 0 then
    Result := (Result shr 8) and $FF;    // wait status -> exit code
  {$endif}
  if FileExists(tmp) then
  begin
    L := TStringList.Create;
    try
      L.LoadFromFile(tmp);
      Output := L.Text;
    finally
      L.Free;
    end;
    DeleteFile(tmp);
  end;
end;

function MonthNum(const m: AnsiString): Integer;
const
  Names: array[1..12] of AnsiString =
    ('jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec');
var
  i: Integer;
begin
  Result := 1;
  for i := 1 to 12 do
    if LowerCase(m) = Names[i] then Exit(i);
end;

function ParseLsLine(const Line: AnsiString; out Item: TVfsItem;
                     out FullName: AnsiString): Boolean;
var
  parts: array[0..8] of AnsiString;
  n, i, p0: Integer;
  s: AnsiString;
  mon, day, yr, hh, nn: Integer;
begin
  Result := False;
  FullName := '';
  s := TrimRight(Line);
  if (s = '') or not (s[1] in ['-', 'd', 'l']) then Exit;
  { split into 9 fields, the last one keeps embedded spaces }
  n := 0;
  i := 1;
  while (n < 8) and (i <= Length(s)) do
  begin
    while (i <= Length(s)) and (s[i] = ' ') do Inc(i);
    p0 := i;
    while (i <= Length(s)) and (s[i] <> ' ') do Inc(i);
    parts[n] := Copy(s, p0, i - p0);
    Inc(n);
  end;
  while (i <= Length(s)) and (s[i] = ' ') do Inc(i);
  parts[8] := Copy(s, i, MaxInt);
  if (n < 8) or (parts[8] = '') then Exit;

  Item.IsDir := s[1] = 'd';
  Item.Size := StrToInt64Def(parts[4], 0);
  mon := MonthNum(parts[5]);
  day := StrToIntDef(parts[6], 1);
  yr := YearOf(Now);
  hh := 0;
  nn := 0;
  if Pos(':', parts[7]) > 0 then
  begin
    hh := StrToIntDef(Copy(parts[7], 1, Pos(':', parts[7]) - 1), 0);
    nn := StrToIntDef(Copy(parts[7], Pos(':', parts[7]) + 1, 2), 0);
    { a recent-file date; if it lands in the future the year is last year }
    if EncodeDate(yr, mon, day) > Now + 1 then Dec(yr);
  end
  else
    yr := StrToIntDef(parts[7], yr);
  try
    Item.MTime := EncodeDate(yr, mon, day) + EncodeTime(hh, nn, 0, 0);
  except
    Item.MTime := 0;
  end;
  FullName := parts[8];
  { symlinks: 'name -> target' }
  p0 := Pos(' -> ', FullName);
  if p0 > 0 then
    FullName := Copy(FullName, 1, p0 - 1);
  Item.Name := FullName;
  Result := True;
end;

{ --- TVFS defaults ------------------------------------------------------ }

function TVFS.GetTree(const Path, LocalDest: AnsiString;
                      out Err: AnsiString): Boolean;
begin
  Err := 'not supported by this file system';
  Result := False;
end;

function TVFS.PutFile(const LocalSrc, Path: AnsiString;
                      out Err: AnsiString): Boolean;
begin
  Err := 'read-only file system';
  Result := False;
end;

function TVFS.PutTree(const LocalSrc, Path: AnsiString;
                      out Err: AnsiString): Boolean;
begin
  Err := 'read-only file system';
  Result := False;
end;

function TVFS.DeletePath(const Path: AnsiString; IsDir: Boolean;
                         out Err: AnsiString): Boolean;
begin
  Err := 'read-only file system';
  Result := False;
end;

function TVFS.MakeDir(const Path: AnsiString; out Err: AnsiString): Boolean;
begin
  Err := 'read-only file system';
  Result := False;
end;

function TVFS.Display(const Path: AnsiString): AnsiString;
begin
  Result := Path;
end;

function TVFS.IsLocal: Boolean;
begin
  Result := False;
end;

function TVFS.ParentExit(out LocalDir, CursorName: AnsiString): Boolean;
begin
  LocalDir := '';
  CursorName := '';
  Result := False;
end;

{ --- TLocalVFS ---------------------------------------------------------- }

constructor TListVFS.Create(const ATitle: AnsiString; APaths: TStringList);
begin
  FTitle := ATitle;
  FPaths := APaths;
end;

destructor TListVFS.Destroy;
begin
  FPaths.Free;
  inherited;
end;

function TListVFS.RealPath(const Name: AnsiString): AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FPaths.Count - 1 do
    if ExtractFileName(FPaths[i]) = Name then Exit(FPaths[i]);
end;

function TListVFS.List(const Dir: AnsiString; out Items: TVfsItems;
                       out Err: AnsiString): Boolean;
var
  i, n: Integer;
  sr: TSearchRec;
begin
  Err := '';
  SetLength(Items, 0);
  n := 0;
  for i := 0 to FPaths.Count - 1 do
    if FindFirst(FPaths[i], faAnyFile, sr) = 0 then
    begin
      SetLength(Items, n + 1);
      Items[n].Name := ExtractFileName(FPaths[i]);
      Items[n].IsDir := False;
      Items[n].Size := sr.Size;
      Items[n].MTime := FileDateToDateTime(sr.Time);
      Inc(n);
      FindClose(sr);
    end;
  Result := True;
end;

function TListVFS.GetFile(const Path, LocalDest: AnsiString;
                          out Err: AnsiString): Boolean;
begin
  Result := CopyTree(RealPath(ExtractFileName(Path)), LocalDest, Err);
end;

function TListVFS.GetTree(const Path, LocalDest: AnsiString;
                          out Err: AnsiString): Boolean;
begin
  Result := GetFile(Path, LocalDest, Err);
end;

function TListVFS.Display(const Path: AnsiString): AnsiString;
begin
  Result := 'list:' + FTitle;
end;

function TLocalVFS.List(const Dir: AnsiString; out Items: TVfsItems;
                        out Err: AnsiString): Boolean;
var
  sr: TSearchRec;
  n: Integer;
begin
  Err := '';
  SetLength(Items, 0);
  n := 0;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      SetLength(Items, n + 1);
      Items[n].Name := sr.Name;
      Items[n].IsDir := (sr.Attr and faDirectory) <> 0;
      Items[n].Size := sr.Size;
      Items[n].MTime := FileDateToDateTime(sr.Time);
      Inc(n);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  Result := True;
end;

function TLocalVFS.GetFile(const Path, LocalDest: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Result := CopyTree(Path, LocalDest, Err);
end;

function TLocalVFS.GetTree(const Path, LocalDest: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Result := CopyTree(Path, LocalDest, Err);
end;

function TLocalVFS.PutFile(const LocalSrc, Path: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Result := CopyTree(LocalSrc, Path, Err);
end;

function TLocalVFS.PutTree(const LocalSrc, Path: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Result := CopyTree(LocalSrc, Path, Err);
end;

function TLocalVFS.DeletePath(const Path: AnsiString; IsDir: Boolean;
                              out Err: AnsiString): Boolean;
begin
  Result := DeleteTree(Path, Err);
end;

function TLocalVFS.MakeDir(const Path: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Err := '';
  Result := CreateDir(Path);
  if not Result then
    Err := 'cannot create directory ' + Path;
end;

function TLocalVFS.IsLocal: Boolean;
begin
  Result := True;
end;

finalization
  LocalSingleton.Free;
end.
