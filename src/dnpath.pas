{ dnpath — the `dn` executable and PATH.

  `FindInPath` locates a program in a PATH-style string; `PathList` keeps
  the string form of an environment list; `IsAppBundle` and
  `IsRelativeCommand` gate the "not in PATH" hint so it fires only for a
  path-qualified launch outside a bundle; `ExecutablePath` names the real
  file behind the running process; `LocalBinDir` names the default link
  directory. Apart from `RealPath`, `ExecutablePath` and `LinkExists`,
  which ask the file system, the unit is pure text logic, so the unit
  tests cover it without a terminal. }

unit dnpath;

{$mode objfpc}{$H+}

interface

uses
  Classes;

{ Directories in a PATH-style list joined by Sep (default ':' on Unix). }
function PathList(const List: AnsiString; Sep: Char = ':'): TStringList;

{ Full path of FileName in List, '' when no directory holds it. Empty
  entries are skipped (they mean the current directory, which the panels
  already cover). }
function FindInPath(const FileName, List: AnsiString): AnsiString;

{ True when Dir appears as a whole entry of List. }
function DirInList(const Dir, List: AnsiString): Boolean;

{ True when the executable path is inside a macOS .app bundle. }
function IsAppBundle(const ExePath: AnsiString): Boolean;

{ True when the launch is a bare command name, not a path: no path
  separator, so the shell found it through PATH. }
function IsRelativeCommand(const ExePath: AnsiString): Boolean;

{ The file argv[0] names: a path-qualified Arg0 expands against the
  current directory, a bare name is looked up in PathEnv. '' when the
  bare name is not found. }
function ResolveCommand(const Arg0, PathEnv: AnsiString): AnsiString;

{ Canonical absolute path with every symlink resolved, '' when P does
  not exist. }
function RealPath(const P: AnsiString): AnsiString;

{ Real path of the running executable, '' when it cannot be determined. }
function ExecutablePath: AnsiString;

{ True when something (a file, a directory, a symlink — dangling or
  not) occupies P. }
function LinkExists(const P: AnsiString): Boolean;

{ $XDG_BIN_HOME when set, else $HOME/.local/bin; '' when neither variable
  is set. The caller creates it. }
function LocalBinDir: AnsiString;

implementation

uses
  {$ifdef unix}BaseUnix,{$endif} SysUtils;

{$ifdef unix}
function c_realpath(path, resolved: PChar): PChar; cdecl;
  external 'c' name 'realpath';
{$endif}
{$ifdef darwin}
function NSGetExecutablePath(buf: PChar; var size: UInt32): LongInt; cdecl;
  external 'c' name '_NSGetExecutablePath';
{$endif}

function PathList(const List: AnsiString; Sep: Char): TStringList;
var
  i: Integer;
  cur: AnsiString;
begin
  Result := TStringList.Create;
  cur := '';
  for i := 1 to Length(List) do
    if List[i] = Sep then
    begin
      if cur <> '' then Result.Add(cur);
      cur := '';
    end
    else
      cur := cur + List[i];
  if cur <> '' then Result.Add(cur);
end;

function FindInPath(const FileName, List: AnsiString): AnsiString;
var
  dirs: TStringList;
  i: Integer;
  p: AnsiString;
begin
  Result := '';
  dirs := PathList(List);
  try
    for i := 0 to dirs.Count - 1 do
    begin
      p := IncludeTrailingPathDelimiter(dirs[i]) + FileName;
      if FileExists(p) then Exit(p);
    end;
  finally
    dirs.Free;
  end;
end;

function DirInList(const Dir, List: AnsiString): Boolean;
var
  dirs: TStringList;
  i: Integer;
  want: AnsiString;
begin
  Result := False;
  want := ExcludeTrailingPathDelimiter(ExpandFileName(Dir));
  dirs := PathList(List);
  try
    for i := 0 to dirs.Count - 1 do
      if ExcludeTrailingPathDelimiter(ExpandFileName(dirs[i])) = want then
        Exit(True);
  finally
    dirs.Free;
  end;
end;

function IsAppBundle(const ExePath: AnsiString): Boolean;
var
  p: AnsiString;
begin
  p := ExpandFileName(ExePath);
  Result := (Pos('.app/', p) > 0) or (Pos('.app\', p) > 0);
end;

function IsRelativeCommand(const ExePath: AnsiString): Boolean;
begin
  Result := (ExePath <> '') and
            (Pos('/', ExePath) = 0) and (Pos('\', ExePath) = 0);
end;

function ResolveCommand(const Arg0, PathEnv: AnsiString): AnsiString;
begin
  if Arg0 = '' then
    Result := ''
  else if IsRelativeCommand(Arg0) then
    Result := FindInPath(Arg0, PathEnv)
  else
    Result := ExpandFileName(Arg0);
end;

function RealPath(const P: AnsiString): AnsiString;
{$ifdef unix}
var
  buf: array[0..4095] of Char;
begin
  Result := '';
  if P = '' then Exit;
  if c_realpath(PChar(P), @buf[0]) <> nil then
    Result := StrPas(@buf[0]);
end;
{$else}
begin
  if FileExists(P) or DirectoryExists(P) then
    Result := ExpandFileName(P)
  else
    Result := '';
end;
{$endif}

function ExecutablePath: AnsiString;
{$ifdef darwin}
var
  buf: array[0..4095] of Char;
  size: UInt32;
{$endif}
begin
  Result := '';
  {$ifdef darwin}
  { argv[0] on macOS is whatever the launcher passed, often a bare name;
    the loader knows the real image path. }
  size := SizeOf(buf);
  if NSGetExecutablePath(@buf[0], size) = 0 then
    Result := RealPath(StrPas(@buf[0]));
  {$endif}
  if Result = '' then
    Result := RealPath(ResolveCommand(ParamStr(0),
                                      GetEnvironmentVariable('PATH')));
end;

function LinkExists(const P: AnsiString): Boolean;
{$ifdef unix}
var
  st: Stat;
begin
  Result := fpLStat(PChar(P), st) = 0;
end;
{$else}
begin
  Result := FileExists(P) or DirectoryExists(P);
end;
{$endif}

function LocalBinDir: AnsiString;
var
  home: AnsiString;
begin
  Result := GetEnvironmentVariable('XDG_BIN_HOME');
  if Result <> '' then Exit;
  home := GetEnvironmentVariable('HOME');
  if home <> '' then
    Result := ExcludeTrailingPathDelimiter(home) + '/.local/bin';
end;

end.
