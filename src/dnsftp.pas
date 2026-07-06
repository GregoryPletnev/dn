{ dnsftp — RemoteFS over sftp (the Navigator Link replacement, M3).
  Uses the OpenSSH sftp client in batch mode with a shared ControlMaster
  connection; honors ~/.config/dnfpc/sessions (ssh_config format) so
  saved session aliases work as targets.

  DN_SFTP_CMD overrides the transport command (tests use a local fake). }
unit dnsftp;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnvfs;

type
  TSftpVFS = class(TVFS)
  private
    FTarget: AnsiString;    // user@host, host or session alias
    FPort: AnsiString;      // '' = default
    function BaseCmd: AnsiString;
    function RunBatch(const Batch: AnsiString; out Outp: AnsiString): Boolean;
  public
    constructor Create(const Target, Port: AnsiString);
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
    property Target: AnsiString read FTarget;
  end;

{ parse sftp://[user@]host[:port]/path; False if Url is not an sftp URL }
function ParseSftpUrl(const Url: AnsiString;
                      out Target, Port, Path: AnsiString): Boolean;

implementation

uses
  SysUtils, dnconfig, dnfileops;

function Q(const s: AnsiString): AnsiString;
begin
  Result := AnsiQuotedStr(s, '''');
end;

function ParseSftpUrl(const Url: AnsiString;
                      out Target, Port, Path: AnsiString): Boolean;
var
  rest, hostpart: AnsiString;
  p: Integer;
begin
  Result := False;
  if LowerCase(Copy(Url, 1, 7)) <> 'sftp://' then Exit;
  rest := Copy(Url, 8, MaxInt);
  p := Pos('/', rest);
  if p = 0 then
  begin
    hostpart := rest;
    Path := '/';
  end
  else
  begin
    hostpart := Copy(rest, 1, p - 1);
    Path := Copy(rest, p, MaxInt);
  end;
  if hostpart = '' then Exit;
  { user@host:port — the ':' after the last '@' }
  p := Length(hostpart);
  while (p > 0) and (hostpart[p] <> ':') and (hostpart[p] <> '@') do
    Dec(p);
  if (p > 0) and (hostpart[p] = ':') then
  begin
    Port := Copy(hostpart, p + 1, MaxInt);
    Target := Copy(hostpart, 1, p - 1);
  end
  else
  begin
    Port := '';
    Target := hostpart;
  end;
  Result := Target <> '';
end;

constructor TSftpVFS.Create(const Target, Port: AnsiString);
begin
  FTarget := Target;
  FPort := Port;
end;

function TSftpVFS.BaseCmd: AnsiString;
var
  sess: AnsiString;
begin
  Result := GetEnvironmentVariable('DN_SFTP_CMD');
  if Result <> '' then Exit;
  Result := 'sftp -q -oBatchMode=yes' +
            ' -oControlMaster=auto' +
            ' -oControlPath=' + Q(ConfigDir + '/cm-%r@%h-%p') +
            ' -oControlPersist=60';
  sess := ConfigDir + '/sessions';
  if FileExists(sess) then
    Result := Result + ' -F ' + Q(sess);
  if FPort <> '' then
    Result := Result + ' -P ' + FPort;
end;

function TSftpVFS.RunBatch(const Batch: AnsiString;
                           out Outp: AnsiString): Boolean;
var
  bf: AnsiString;
  L: TStringList;
begin
  bf := GetTempDir + 'dnsftp-' + IntToStr(GetProcessID) + '-' +
        IntToStr(Random(1000000)) + '.batch';
  L := TStringList.Create;
  try
    L.Text := Batch;
    L.SaveToFile(bf);
  finally
    L.Free;
  end;
  Result := RunCapture(BaseCmd + ' -b ' + Q(bf) + ' ' + Q(FTarget), Outp) = 0;
  DeleteFile(bf);
end;

function TSftpVFS.List(const Dir: AnsiString; out Items: TVfsItems;
                       out Err: AnsiString): Boolean;
var
  outp, full: AnsiString;
  L: TStringList;
  it: TVfsItem;
  i, n: Integer;
  d: AnsiString;
begin
  Err := '';
  SetLength(Items, 0);
  d := Dir;
  if d = '' then d := '/';
  if not RunBatch('ls -la ' + Q(d), outp) then
  begin
    Err := 'sftp: ' + Trim(outp);
    Exit(False);
  end;
  L := TStringList.Create;
  try
    L.Text := outp;
    n := 0;
    for i := 0 to L.Count - 1 do
      if ParseLsLine(L[i], it, full) then
      begin
        if (it.Name = '.') or (it.Name = '..') then Continue;
        SetLength(Items, n + 1);
        Items[n] := it;
        Inc(n);
      end;
  finally
    L.Free;
  end;
  Result := True;
end;

function TSftpVFS.GetFile(const Path, LocalDest: AnsiString;
                          out Err: AnsiString): Boolean;
var
  outp: AnsiString;
begin
  Err := '';
  Result := RunBatch('get ' + Q(Path) + ' ' + Q(LocalDest), outp);
  if not Result then Err := 'sftp get: ' + Trim(outp);
end;

function TSftpVFS.GetTree(const Path, LocalDest: AnsiString;
                          out Err: AnsiString): Boolean;
var
  outp: AnsiString;
begin
  Err := '';
  Result := RunBatch('get -r ' + Q(Path) + ' ' + Q(LocalDest), outp);
  if not Result then Err := 'sftp get -r: ' + Trim(outp);
end;

function TSftpVFS.PutFile(const LocalSrc, Path: AnsiString;
                          out Err: AnsiString): Boolean;
var
  outp: AnsiString;
begin
  Err := '';
  Result := RunBatch('put ' + Q(LocalSrc) + ' ' + Q(Path), outp);
  if not Result then Err := 'sftp put: ' + Trim(outp);
end;

function TSftpVFS.PutTree(const LocalSrc, Path: AnsiString;
                          out Err: AnsiString): Boolean;
var
  batch, outp: AnsiString;

  procedure Walk(const LDir, RDir: AnsiString);
  var
    sr: TSearchRec;
  begin
    batch := batch + 'mkdir ' + Q(RDir) + #10;
    if FindFirst(IncludeTrailingPathDelimiter(LDir) + '*', faAnyFile, sr) = 0 then
    begin
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if (sr.Attr and faDirectory) <> 0 then
          Walk(LDir + '/' + sr.Name, RDir + '/' + sr.Name)
        else
          batch := batch + 'put ' + Q(LDir + '/' + sr.Name) + ' ' +
                   Q(RDir + '/' + sr.Name) + #10;
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  end;

begin
  Err := '';
  batch := '';
  Walk(LocalSrc, Path);
  Result := RunBatch(batch, outp);
  if not Result then Err := 'sftp put -r: ' + Trim(outp);
end;

function TSftpVFS.DeletePath(const Path: AnsiString; IsDir: Boolean;
                             out Err: AnsiString): Boolean;
var
  items: TVfsItems;
  i: Integer;
  outp: AnsiString;
begin
  Err := '';
  if IsDir then
  begin
    { sftp has no recursive rm: walk down ourselves }
    if not List(Path, items, Err) then Exit(False);
    for i := 0 to High(items) do
      if not DeletePath(Path + '/' + items[i].Name, items[i].IsDir, Err) then
        Exit(False);
    Result := RunBatch('rmdir ' + Q(Path), outp);
    if not Result then Err := 'sftp rmdir: ' + Trim(outp);
  end
  else
  begin
    Result := RunBatch('rm ' + Q(Path), outp);
    if not Result then Err := 'sftp rm: ' + Trim(outp);
  end;
end;

function TSftpVFS.MakeDir(const Path: AnsiString;
                          out Err: AnsiString): Boolean;
var
  outp: AnsiString;
begin
  Err := '';
  Result := RunBatch('mkdir ' + Q(Path), outp);
  if not Result then Err := 'sftp mkdir: ' + Trim(outp);
end;

function TSftpVFS.Display(const Path: AnsiString): AnsiString;
begin
  Result := 'sftp://' + FTarget;
  if FPort <> '' then Result := Result + ':' + FPort;
  Result := Result + Path;
end;

end.
