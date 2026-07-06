{ dnarcvfs — archives as directories (DN 3.9), backed by bsdtar.
  Reading (browse, view, copy out) works for anything bsdtar reads:
  zip, tar, tgz/tbz/txz, 7z, iso… Writing (copy in, delete) is supported
  for .zip via the `zip` tool; other formats are read-only. }
unit dnarcvfs;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnvfs;

type
  TArchiveVFS = class(TVFS)
  private
    FArchive: AnsiString;            // absolute path of the archive file
    FEntries: array of TVfsItem;     // full inner paths in Name
    FLoaded: Boolean;
    FLoadErr: AnsiString;
    function EnsureLoaded: Boolean;
    function IsZip: Boolean;
  public
    constructor Create(const ArchivePath: AnsiString);
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
    function Display(const Path: AnsiString): AnsiString; override;
    function ParentExit(out LocalDir, CursorName: AnsiString): Boolean; override;
    property Archive: AnsiString read FArchive;
  end;

{ does the filename look like an archive we can open? }
function IsArchiveName(const Name: AnsiString): Boolean;

implementation

uses
  SysUtils, dnfileops;

const
  ArchiveExts: array[0..9] of AnsiString =
    ('.zip', '.tar', '.tgz', '.tbz', '.txz', '.gz', '.bz2', '.xz', '.7z', '.iso');

function IsArchiveName(const Name: AnsiString): Boolean;
var
  e: AnsiString;
  i: Integer;
begin
  e := LowerCase(ExtractFileExt(Name));
  for i := 0 to High(ArchiveExts) do
    if e = ArchiveExts[i] then Exit(True);
  Result := False;
end;

function Q(const s: AnsiString): AnsiString;
begin
  Result := AnsiQuotedStr(s, '''');
end;

constructor TArchiveVFS.Create(const ArchivePath: AnsiString);
begin
  FArchive := ExpandFileName(ArchivePath);
  FLoaded := False;
end;

function TArchiveVFS.IsZip: Boolean;
begin
  Result := LowerCase(ExtractFileExt(FArchive)) = '.zip';
end;

function NormEntry(const s: AnsiString): AnsiString;
begin
  Result := s;
  if Copy(Result, 1, 2) = './' then
    Delete(Result, 1, 2);
  if (Result <> '') and (Result[Length(Result)] = '/') then
    SetLength(Result, Length(Result) - 1);
end;

function TArchiveVFS.EnsureLoaded: Boolean;
var
  outp, full: AnsiString;
  L: TStringList;
  it: TVfsItem;
  i, n: Integer;
begin
  if FLoaded then Exit(FLoadErr = '');
  FLoaded := True;
  FLoadErr := '';
  SetLength(FEntries, 0);
  if RunCapture('bsdtar -tvf ' + Q(FArchive), outp) <> 0 then
  begin
    FLoadErr := 'bsdtar: cannot read ' + FArchive;
    Exit(False);
  end;
  L := TStringList.Create;
  try
    L.Text := outp;
    n := 0;
    for i := 0 to L.Count - 1 do
      if ParseLsLine(L[i], it, full) then
      begin
        it.Name := NormEntry(full);
        if it.Name = '' then Continue;   // the './' root entry
        SetLength(FEntries, n + 1);
        FEntries[n] := it;
        Inc(n);
      end;
  finally
    L.Free;
  end;
  Result := True;
end;

function TArchiveVFS.List(const Dir: AnsiString; out Items: TVfsItems;
                          out Err: AnsiString): Boolean;
var
  i, n, p: Integer;
  prefix, rest, head: AnsiString;
  seen: TStringList;
  isdir: Boolean;
begin
  Err := '';
  SetLength(Items, 0);
  if not EnsureLoaded then
  begin
    Err := FLoadErr;
    Exit(False);
  end;
  if (Dir = '') or (Dir = '/') then prefix := ''
  else prefix := Dir + '/';
  seen := TStringList.Create;
  try
    seen.Sorted := True;
    seen.Duplicates := dupIgnore;
    n := 0;
    for i := 0 to High(FEntries) do
    begin
      if Copy(FEntries[i].Name, 1, Length(prefix)) <> prefix then Continue;
      rest := Copy(FEntries[i].Name, Length(prefix) + 1, MaxInt);
      if rest = '' then Continue;
      p := Pos('/', rest);
      isdir := FEntries[i].IsDir;
      if p > 0 then
      begin
        head := Copy(rest, 1, p - 1);   // implied intermediate directory
        isdir := True;
      end
      else
        head := rest;
      if seen.IndexOf(head + '/' + IntToStr(Ord(isdir))) >= 0 then Continue;
      seen.Add(head + '/' + IntToStr(Ord(isdir)));
      SetLength(Items, n + 1);
      Items[n].Name := head;
      Items[n].IsDir := isdir;
      if p > 0 then
      begin
        Items[n].Size := 0;
        Items[n].MTime := 0;
      end
      else
      begin
        Items[n].Size := FEntries[i].Size;
        Items[n].MTime := FEntries[i].MTime;
      end;
      Inc(n);
    end;
  finally
    seen.Free;
  end;
  Result := True;
end;

function TArchiveVFS.GetFile(const Path, LocalDest: AnsiString;
                             out Err: AnsiString): Boolean;
var
  outp: AnsiString;
begin
  Err := '';
  { subshell keeps the inner "> dest" redirect intact — RunCapture appends
    its own stdout redirect to the whole command }
  Result := RunCapture('( bsdtar -xOf ' + Q(FArchive) + ' ' + Q(Path) +
                       ' > ' + Q(LocalDest) + ' )', outp) = 0;
  { bsdtar of some formats stores './name' }
  if not Result then
    Result := RunCapture('( bsdtar -xOf ' + Q(FArchive) + ' ' + Q('./' + Path) +
                         ' > ' + Q(LocalDest) + ' )', outp) = 0;
  if not Result then
    Err := 'cannot extract ' + Path + ': ' + Trim(outp);
end;

function TArchiveVFS.GetTree(const Path, LocalDest: AnsiString;
                             out Err: AnsiString): Boolean;
var
  tmp, outp: AnsiString;
  rc: Integer;
begin
  Err := '';
  tmp := GetTempDir + 'dnarc-' + IntToStr(GetProcessID) + '-' +
         IntToStr(Random(1000000));
  ForceDirectories(tmp);
  rc := RunCapture('bsdtar -xf ' + Q(FArchive) + ' -C ' + Q(tmp) + ' ' +
                   Q(Path) + ' ' + Q(Path + '/*') + ' 2>/dev/null || ' +
                   'bsdtar -xf ' + Q(FArchive) + ' -C ' + Q(tmp) + ' ' +
                   Q('./' + Path) + ' ' + Q('./' + Path + '/*'), outp);
  if (rc <> 0) or not DirectoryExists(tmp + '/' + Path) then
  begin
    Err := 'cannot extract ' + Path;
    DeleteTree(tmp, outp);
    Exit(False);
  end;
  Result := MoveTree(tmp + '/' + Path, LocalDest, Err);
  DeleteTree(tmp, outp);
end;

function TArchiveVFS.PutFile(const LocalSrc, Path: AnsiString;
                             out Err: AnsiString): Boolean;
var
  tmp, dir, outp: AnsiString;
  rc: Integer;
begin
  if not IsZip then
  begin
    Err := 'writing is only supported for .zip archives';
    Exit(False);
  end;
  { stage the file under its inner path, then zip from the staging dir }
  tmp := GetTempDir + 'dnarc-' + IntToStr(GetProcessID) + '-' +
         IntToStr(Random(1000000));
  dir := ExtractFileDir(tmp + '/' + Path);
  ForceDirectories(dir);
  if not CopyTree(LocalSrc, tmp + '/' + Path, Err) then Exit(False);
  rc := RunCapture('cd ' + Q(tmp) + ' && zip -q ' + Q(FArchive) + ' ' + Q(Path),
                   outp);
  DeleteTree(tmp, outp);
  Result := rc = 0;
  if not Result then Err := 'zip failed: ' + Trim(outp);
  FLoaded := False;   // invalidate the cached listing
end;

function TArchiveVFS.PutTree(const LocalSrc, Path: AnsiString;
                             out Err: AnsiString): Boolean;
var
  tmp, dir, outp: AnsiString;
  rc: Integer;
begin
  if not IsZip then
  begin
    Err := 'writing is only supported for .zip archives';
    Exit(False);
  end;
  tmp := GetTempDir + 'dnarc-' + IntToStr(GetProcessID) + '-' +
         IntToStr(Random(1000000));
  dir := ExtractFileDir(tmp + '/' + Path);
  ForceDirectories(dir);
  if not CopyTree(LocalSrc, tmp + '/' + Path, Err) then Exit(False);
  rc := RunCapture('cd ' + Q(tmp) + ' && zip -qr ' + Q(FArchive) + ' ' + Q(Path),
                   outp);
  DeleteTree(tmp, outp);
  Result := rc = 0;
  if not Result then Err := 'zip failed: ' + Trim(outp);
  FLoaded := False;
end;

function TArchiveVFS.DeletePath(const Path: AnsiString; IsDir: Boolean;
                                out Err: AnsiString): Boolean;
var
  outp, arg: AnsiString;
begin
  if not IsZip then
  begin
    Err := 'deleting is only supported in .zip archives';
    Exit(False);
  end;
  if IsDir then arg := Q(Path) + ' ' + Q(Path + '/*')
  else arg := Q(Path);
  Result := RunCapture('zip -qd ' + Q(FArchive) + ' ' + arg, outp) = 0;
  if not Result then Err := 'zip -d failed: ' + Trim(outp);
  FLoaded := False;
end;

function TArchiveVFS.Display(const Path: AnsiString): AnsiString;
begin
  Result := FArchive + '://' + Path;
end;

function TArchiveVFS.ParentExit(out LocalDir, CursorName: AnsiString): Boolean;
begin
  LocalDir := ExtractFileDir(FArchive);
  CursorName := ExtractFileName(FArchive);
  Result := True;
end;

end.
