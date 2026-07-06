{ dnmount — disk images (dmg, iso, img…) as directories: Enter on an image
  attaches it with hdiutil and the panel browses the mount point; leaving
  the root (or switching the panel elsewhere) detaches it. macOS only —
  on other systems mounting fails and .iso falls back to the archive VFS. }
unit dnmount;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnvfs;

type
  TMountVFS = class(TVFS)
  private
    FImage: AnsiString;       // absolute path of the image file
    FMount: AnsiString;       // hdiutil mount point (/Volumes/...)
    function Map(const Path: AnsiString): AnsiString;
  public
    destructor Destroy; override;
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
    function Display(const Path: AnsiString): AnsiString; override;
    function ParentExit(out LocalDir, CursorName: AnsiString): Boolean; override;
    property MountPoint: AnsiString read FMount;
  end;

{ does the filename look like a mountable disk image? }
function IsImageName(const Name: AnsiString): Boolean;

{ attach the image; on success returns a VFS positioned at its root }
function MountImage(const ImagePath: AnsiString; out Vfs: TMountVFS;
                    out Err: AnsiString): Boolean;

implementation

uses
  SysUtils, dnfileops;

const
  ImageExts: array[0..4] of AnsiString =
    ('.dmg', '.iso', '.img', '.sparseimage', '.cdr');

function IsImageName(const Name: AnsiString): Boolean;
var
  e: AnsiString;
  i: Integer;
begin
  e := LowerCase(ExtractFileExt(Name));
  for i := 0 to High(ImageExts) do
    if e = ImageExts[i] then Exit(True);
  Result := False;
end;

function Q(const s: AnsiString): AnsiString;
begin
  Result := AnsiQuotedStr(s, '''');
end;

function MountImage(const ImagePath: AnsiString; out Vfs: TMountVFS;
                    out Err: AnsiString): Boolean;
var
  outp, mp: AnsiString;
  L: TStringList;
  i, p: Integer;
begin
  Result := False;
  Vfs := nil;
  Err := '';
  if RunCapture('hdiutil attach -nobrowse ' + Q(ExpandFileName(ImagePath)),
                outp) <> 0 then
  begin
    Err := Trim(outp);
    if Err = '' then Err := 'hdiutil attach failed';
    Exit;
  end;
  { mount point = the '/Volumes/...' tail of the last line that has one }
  mp := '';
  L := TStringList.Create;
  try
    L.Text := outp;
    for i := 0 to L.Count - 1 do
    begin
      p := Pos('/Volumes/', L[i]);
      if p > 0 then mp := Trim(Copy(L[i], p, MaxInt));
    end;
  finally
    L.Free;
  end;
  if mp = '' then
  begin
    Err := 'no mountable volume in ' + ExtractFileName(ImagePath);
    Exit;
  end;
  Vfs := TMountVFS.Create;
  Vfs.FImage := ExpandFileName(ImagePath);
  Vfs.FMount := mp;
  Result := True;
end;

function TMountVFS.Map(const Path: AnsiString): AnsiString;
begin
  if (Path = '') or (Path = '/') then
    Result := FMount
  else if Path[1] = '/' then
    Result := FMount + Path
  else
    Result := FMount + '/' + Path;
end;

destructor TMountVFS.Destroy;
var
  outp: AnsiString;
begin
  if FMount <> '' then
    RunCapture('hdiutil detach ' + Q(FMount), outp);   // best effort
  inherited;
end;

function TMountVFS.List(const Dir: AnsiString; out Items: TVfsItems;
                        out Err: AnsiString): Boolean;
begin
  Result := LocalVFS.List(Map(Dir), Items, Err);
end;

function TMountVFS.GetFile(const Path, LocalDest: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Result := CopyTree(Map(Path), LocalDest, Err);
end;

function TMountVFS.GetTree(const Path, LocalDest: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Result := CopyTree(Map(Path), LocalDest, Err);
end;

function TMountVFS.PutFile(const LocalSrc, Path: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Result := CopyTree(LocalSrc, Map(Path), Err);
end;

function TMountVFS.PutTree(const LocalSrc, Path: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Result := CopyTree(LocalSrc, Map(Path), Err);
end;

function TMountVFS.DeletePath(const Path: AnsiString; IsDir: Boolean;
                              out Err: AnsiString): Boolean;
begin
  Result := DeleteTree(Map(Path), Err);
end;

function TMountVFS.MakeDir(const Path: AnsiString;
                           out Err: AnsiString): Boolean;
begin
  Result := ForceDirectories(Map(Path));
  if Result then Err := '' else Err := 'cannot create ' + Map(Path);
end;

function TMountVFS.Display(const Path: AnsiString): AnsiString;
begin
  Result := FImage + '://' + Path;
end;

function TMountVFS.ParentExit(out LocalDir, CursorName: AnsiString): Boolean;
begin
  LocalDir := ExtractFileDir(FImage);
  CursorName := ExtractFileName(FImage);
  Result := True;
end;

end.
