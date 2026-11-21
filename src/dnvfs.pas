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
    { the top of this VFS: '..' there leaves it (ParentExit) }
    function IsRootPath(const Path: AnsiString): Boolean; virtual;
    { leaving the VFS root upwards: where to land in the local world.
      False = the root is the top (stay). }
    function ParentExit(out LocalDir, CursorName: AnsiString): Boolean; virtual;
    { a list worth returning to (the find results): the panel keeps it
      while a database, archive or image opened from it is shown }
    function KeepWhenLeft: Boolean; virtual;
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
{ --- external commands -------------------------------------------------

  Every external tool (bsdtar, zip, hdiutil, diskutil, sftp, curl) runs
  through RunCapture. The command runs in the background, in a process
  group of its own with stdin from /dev/null, and RunCapture waits for it
  in a loop: after RunBusyDelayMs it calls RunBusyHook every
  RunBusyTickMs, so the UI can show a progress box and offer a cancel.
  This unit draws nothing: the hook lives in the UI (dndialog). }

type
  { what the progress box shows about one running command }
  TRunBusy = record
    Title: AnsiString;       // 'Reading archive'
    Detail: AnsiString;      // 'photos.zip'
    CountWhat: AnsiString;   // 'entries': show the output line count, '' = no
    Lines: Int64;            // output lines so far
    Percent: Integer;        // last "PERCENT:n" in the output, -1 = unknown
    ElapsedMs: QWord;
  end;
  { called while a command runs; set Cancel to stop it }
  TRunBusyHook = procedure(const Busy: TRunBusy; var Cancel: Boolean);

const
  RunBusyDelayMs = 300;      // quicker commands never show a box
  RunBusyTickMs = 100;
  RunCancelledExit = -2;     // RunCapture's result when the user cancelled

var
  RunBusyHook: TRunBusyHook = nil;

{ run a shell command, capture stdout+stderr; returns exit code, or
  RunCancelledExit (Output: 'cancelled') when the user stopped it.
  Title/Detail/CountWhat label the progress box; without them it says
  "Working" and the program name. }
function RunCapture(const Cmd: AnsiString; out Output: AnsiString): Integer;
function RunCapture(const Cmd: AnsiString; out Output: AnsiString;
                    const Title: AnsiString; const Detail: AnsiString = '';
                    const CountWhat: AnsiString = ''): Integer;
{ run a shell command with Input on stdin, capture stdout+stderr }
function RunCaptureInput(const Cmd, Input: AnsiString;
                          out Output: AnsiString): Integer;
{ the full form: Input on stdin, Env ('NAME=value', set in the child only,
  so a password never shows in `ps`), stdout and stderr apart }
function RunCaptureEx(const Cmd, Input: AnsiString;
                      const Env: array of AnsiString;
                      out Output, ErrOutput: AnsiString;
                      const Title: AnsiString = ''; const Detail: AnsiString = '';
                      const CountWhat: AnsiString = ''): Integer;
{ parse 'ls -la'-style listing lines (bsdtar -tv, sftp ls -la) }
function ParseLsLine(const Line: AnsiString; out Item: TVfsItem;
                     out FullName: AnsiString): Boolean;

implementation

uses
  SysUtils, DateUtils, {$ifdef unix}Unix, BaseUnix,{$endif} dnfileops;

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

{ --- external commands ------------------------------------------------- }

{$ifdef unix}
function c_setpgid(pid, pgid: LongInt): LongInt; cdecl;
  external 'c' name 'setpgid';
{$endif}

function TempName(const Kind, Ext: AnsiString): AnsiString;
begin
  Result := GetTempDir + 'dnvfs-' + Kind + IntToStr(GetProcessID) + '-' +
            IntToStr(Random(1000000)) + Ext;
end;

function ReadWhole(const Path: AnsiString): AnsiString;
var
  f: THandle;
  n: Int64;
begin
  Result := '';
  f := FileOpen(Path, fmOpenRead or fmShareDenyNone);
  if f = THandle(-1) then Exit;
  try
    n := FileSeek(f, Int64(0), 2);
    FileSeek(f, 0, 0);
    if n > 0 then
    begin
      SetLength(Result, n);
      if FileRead(f, Result[1], n) <> n then Result := '';
    end;
  finally
    FileClose(f);
  end;
end;

{ the program a shell command runs: "bsdtar" for "( bsdtar -xOf ..." }
function ProgramOf(const Cmd: AnsiString): AnsiString;
var
  s: AnsiString;
  p: Integer;
begin
  s := Cmd;
  p := Pos('&&', s);                         // "cd dir && zip ..."
  if p > 0 then s := Copy(s, p + 2, Length(s));
  s := TrimLeft(StringReplace(s, '(', ' ', [rfReplaceAll]));
  p := Pos(' ', s);
  if p > 0 then s := Copy(s, 1, p - 1);
  Result := ExtractFileName(s);
end;

{ fold the output written since the last look into Busy: count lines,
  pick up "PERCENT:n" (hdiutil -puppetstrings) }
procedure ScanOutput(const OutF: AnsiString; var Seen: Int64;
                     var Busy: TRunBusy);
var
  f: THandle;
  size: Int64;
  chunk, rest: AnsiString;
  i, p, e: Integer;
begin
  f := FileOpen(OutF, fmOpenRead or fmShareDenyNone);
  if f = THandle(-1) then Exit;
  try
    size := FileSeek(f, Int64(0), 2);
    if size <= Seen then Exit;
    FileSeek(f, Seen, 0);
    { a long listing is read in 64 KiB steps: counted, not kept }
    while size > Seen do
    begin
      if size - Seen > 65536 then SetLength(chunk, 65536)
      else SetLength(chunk, size - Seen);
      if FileRead(f, chunk[1], Length(chunk)) <> Length(chunk) then Break;
      for i := 1 to Length(chunk) do
        if chunk[i] = #10 then Inc(Busy.Lines);
      rest := chunk;
      p := Pos('PERCENT:', rest);
      while p > 0 do
      begin
        Delete(rest, 1, p + 7);
        e := Pos(#10, rest);
        if e = 0 then e := Length(rest) + 1;
        Busy.Percent := Trunc(StrToFloatDef(Trim(Copy(rest, 1, e - 1)),
                                            Busy.Percent));
        p := Pos('PERCENT:', rest);
      end;
      Inc(Seen, Length(chunk));
    end;
  finally
    FileClose(f);
  end;
end;

{ run ShellCmd (its own redirections included) in the background and wait,
  feeding RunBusyHook; returns the exit code or RunCancelledExit }
function RunWaiting(const ShellCmd, OutF: AnsiString;
                    var Busy: TRunBusy;
                    const Env: array of AnsiString): Integer;
{$ifdef unix}
var
  i, j, k: Integer;
  envs: TStringList;
  envStr: array of AnsiString;
  envp: array of PChar;
  argStr: array[0..2] of AnsiString;
  argv: array[0..3] of PChar;
  pid, r: TPid;
  status: cint;
  start: QWord;
  seen: Int64;
  cancel: Boolean;
begin
  Result := -1;
  { built before the fork: dn's environment plus Env (Env wins) }
  envs := TStringList.Create;
  try
    for i := 1 to GetEnvironmentVariableCount do
      envs.Add(GetEnvironmentString(i));
    for i := 0 to High(Env) do
    begin
      k := Pos('=', Env[i]);
      j := envs.IndexOfName(Copy(Env[i], 1, k - 1));
      if j >= 0 then envs[j] := Env[i] else envs.Add(Env[i]);
    end;
    SetLength(envStr, envs.Count);
    for i := 0 to envs.Count - 1 do envStr[i] := envs[i];
  finally
    envs.Free;
  end;
  SetLength(envp, Length(envStr) + 1);
  for i := 0 to High(envStr) do envp[i] := PChar(envStr[i]);
  envp[High(envp)] := nil;
  argStr[0] := '/bin/sh';
  argStr[1] := '-c';
  argStr[2] := ShellCmd;
  for i := 0 to 2 do argv[i] := PChar(argStr[i]);
  argv[3] := nil;
  pid := fpFork;
  if pid < 0 then Exit;
  if pid = 0 then
  begin
    { own process group: a cancel stops the whole pipeline }
    c_setpgid(0, 0);
    { an explicit environment: FPC's exec passes the one captured at
      startup, so a putenv() here would not reach the command }
    fpExecve('/bin/sh', @argv[0], @envp[0]);
    fpExit(127);
  end;
  start := GetTickCount64;
  seen := 0;
  cancel := False;
  repeat
    r := fpWaitPid(pid, status, WNOHANG);
    if r = pid then Break;
    if r < 0 then Exit;
    Busy.ElapsedMs := GetTickCount64 - start;
    if Assigned(RunBusyHook) and (Busy.ElapsedMs >= RunBusyDelayMs) then
    begin
      ScanOutput(OutF, seen, Busy);
      RunBusyHook(Busy, cancel);
      if cancel then
      begin
        fpKill(-pid, SIGTERM);
        Sleep(200);
        fpKill(-pid, SIGKILL);
        fpWaitPid(pid, status, 0);
        Exit(RunCancelledExit);
      end;
      Sleep(RunBusyTickMs);
    end
    else
      Sleep(10);
  until False;
  if WIFEXITED(status) then
    Result := WEXITSTATUS(status)
  else
    Result := 128 + WTERMSIG(status);
end;
{$else}
begin
  Result := ExecuteProcess('/bin/sh', ['-c', ShellCmd]);
end;
{$endif}

function RunLabelledEx(const Cmd, InF: AnsiString;
                       const Env: array of AnsiString; SplitErr: Boolean;
                       out Output, ErrOutput: AnsiString;
                       const Title, Detail, CountWhat: AnsiString): Integer;
var
  outF, errF, sh: AnsiString;
  busy: TRunBusy;
begin
  Output := '';
  ErrOutput := '';
  outF := TempName('out-', '.out');
  errF := TempName('err-', '.out');
  busy.Title := Title;
  busy.Detail := Detail;
  if busy.Title = '' then
  begin
    busy.Title := 'Working';
    if busy.Detail = '' then busy.Detail := ProgramOf(Cmd);
  end;
  busy.CountWhat := CountWhat;
  busy.Lines := 0;
  busy.Percent := -1;
  busy.ElapsedMs := 0;
  { the subshell gives the whole command line one redirection; stdin is
    /dev/null (or InF), so no tool can sit waiting for the terminal }
  sh := '( ' + Cmd + #10' ) >' + AnsiQuotedStr(outF, '''');
  if SplitErr then sh := sh + ' 2>' + AnsiQuotedStr(errF, '''')
  else sh := sh + ' 2>&1';
  if InF <> '' then sh := sh + ' <' + AnsiQuotedStr(InF, '''')
  else sh := sh + ' </dev/null';
  Result := RunWaiting(sh, outF, busy, Env);
  if Result = RunCancelledExit then
  begin
    Output := '';
    ErrOutput := 'cancelled';
    if not SplitErr then Output := 'cancelled';
  end
  else
  begin
    Output := ReadWhole(outF);
    if SplitErr then ErrOutput := ReadWhole(errF);
  end;
  DeleteFile(outF);
  DeleteFile(errF);
end;

function RunLabelled(const Cmd, InF: AnsiString; out Output: AnsiString;
                     const Title, Detail, CountWhat: AnsiString): Integer;
var
  dummy: AnsiString;
begin
  Result := RunLabelledEx(Cmd, InF, [], False, Output, dummy, Title, Detail,
                          CountWhat);
end;

function WriteTemp(const Data: AnsiString): AnsiString;
var
  f: THandle;
begin
  Result := TempName('in-', '.txt');
  f := FileCreate(Result, &600);
  if f = THandle(-1) then Exit('');
  try
    if Length(Data) > 0 then FileWrite(f, Data[1], Length(Data));
  finally
    FileClose(f);
  end;
end;

function RunCaptureEx(const Cmd, Input: AnsiString;
                      const Env: array of AnsiString;
                      out Output, ErrOutput: AnsiString;
                      const Title: AnsiString; const Detail: AnsiString;
                      const CountWhat: AnsiString): Integer;
var
  inF: AnsiString;
begin
  inF := WriteTemp(Input);
  if inF = '' then
  begin
    Output := '';
    ErrOutput := 'cannot write a temporary file';
    Exit(-1);
  end;
  Result := RunLabelledEx(Cmd, inF, Env, True, Output, ErrOutput, Title,
                          Detail, CountWhat);
  DeleteFile(inF);
end;

function RunCapture(const Cmd: AnsiString; out Output: AnsiString): Integer;
begin
  Result := RunLabelled(Cmd, '', Output, '', '', '');
end;

function RunCapture(const Cmd: AnsiString; out Output: AnsiString;
                    const Title: AnsiString; const Detail: AnsiString;
                    const CountWhat: AnsiString): Integer;
begin
  Result := RunLabelled(Cmd, '', Output, Title, Detail, CountWhat);
end;

function RunCaptureInput(const Cmd, Input: AnsiString;
                          out Output: AnsiString): Integer;
var
  inF: AnsiString;
  f: THandle;
begin
  Result := -1;
  Output := '';
  inF := TempName('in-', '.txt');
  f := FileCreate(inF);
  if f = THandle(-1) then Exit;
  try
    if Length(Input) > 0 then
      FileWrite(f, Input[1], Length(Input));
  finally
    FileClose(f);
  end;
  Result := RunLabelled(Cmd, inF, Output, '', '', '');
  DeleteFile(inF);
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

function TVFS.IsRootPath(const Path: AnsiString): Boolean;
begin
  Result := (Path = '') or (Path = '/');
end;

function TVFS.ParentExit(out LocalDir, CursorName: AnsiString): Boolean;
begin
  LocalDir := '';
  CursorName := '';
  Result := False;
end;

function TVFS.KeepWhenLeft: Boolean;
begin
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
