{ dnsession — SSH connection manager (ROADMAP M3, à la redial).
  Saved sessions live in ~/.config/dnfpc/sessions in ssh_config format;
  folders are expressed with a `#folder: path` comment before a Host
  block so the manager can present a tree. Extra per-session settings use
  `#dn-<key> value` comments that ssh ignores but we read.

  This unit owns parsing/serialising and the connect actions; the modal
  picker UI lives in dnsessui. }
unit dnsession;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TForwardKind = (fwLocal, fwRemote, fwDynamic);
  TForward = record
    Kind: TForwardKind;
    Spec: AnsiString;      // e.g. '8080:localhost:80' or '1080' for dynamic
  end;

  TSession = record
    Folder: AnsiString;    // '' = top level; 'work/db' = nested
    Name: AnsiString;      // Host alias
    HostName: AnsiString;
    User: AnsiString;
    Port: AnsiString;
    IdentityFile: AnsiString;
    RemoteDir: AnsiString; // where the sftp panel opens ('' = default)
    Forwards: array of TForward;
  end;
  TSessionArray = array of TSession;

function SessionsPath: AnsiString;
procedure LoadSessions(out A: TSessionArray);
procedure SaveSessions(const A: TSessionArray);
{ sftp target and port for a session (respects HostName/User overrides) }
procedure SessionTarget(const S: TSession; out Target, Port, Dir: AnsiString);
{ build the ssh command line for a terminal login (with forwards) }
function SessionSshCmd(const S: TSession): AnsiString;
{ ssh-copy-id command for this session }
function SessionCopyIdCmd(const S: TSession): AnsiString;

implementation

uses
  SysUtils, dnconfig;

function SessionsPath: AnsiString;
begin
  Result := ConfigDir + '/sessions';
end;

function Unquote(const s: AnsiString): AnsiString;
begin
  Result := Trim(s);
  if (Length(Result) >= 2) and (Result[1] = '"') and
     (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

procedure LoadSessions(out A: TSessionArray);
var
  L: TStringList;
  i, n: Integer;
  line, kw, val, curFolder: AnsiString;
  p: Integer;

  procedure StartHost(const alias: AnsiString);
  begin
    SetLength(A, n + 1);
    A[n].Folder := curFolder;
    A[n].Name := alias;
    A[n].HostName := '';
    A[n].User := '';
    A[n].Port := '';
    A[n].IdentityFile := '';
    A[n].RemoteDir := '';
    SetLength(A[n].Forwards, 0);
    Inc(n);
  end;

  procedure AddForward(k: TForwardKind; const spec: AnsiString);
  var
    m: Integer;
  begin
    if n = 0 then Exit;
    m := Length(A[n - 1].Forwards);
    SetLength(A[n - 1].Forwards, m + 1);
    A[n - 1].Forwards[m].Kind := k;
    A[n - 1].Forwards[m].Spec := spec;
  end;

begin
  SetLength(A, 0);
  n := 0;
  curFolder := '';
  if not FileExists(SessionsPath) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(SessionsPath);
    for i := 0 to L.Count - 1 do
    begin
      line := Trim(L[i]);
      if line = '' then Continue;
      if line[1] = '#' then
      begin
        { our own metadata comments }
        val := Trim(Copy(line, 2, MaxInt));
        p := Pos(':', val);
        if (Copy(val, 1, 7) = 'folder:') then
          curFolder := Trim(Copy(val, 8, MaxInt))
        else if (n > 0) and (Copy(val, 1, 7) = 'dn-dir ') then
          A[n - 1].RemoteDir := Trim(Copy(val, 8, MaxInt));
        Continue;
      end;
      p := 1;
      while (p <= Length(line)) and (line[p] <> ' ') and (line[p] <> #9) do
        Inc(p);
      kw := LowerCase(Copy(line, 1, p - 1));
      val := Unquote(Copy(line, p + 1, MaxInt));
      if kw = 'host' then
        StartHost(val)
      else if n = 0 then
        Continue
      else if kw = 'hostname' then A[n - 1].HostName := val
      else if kw = 'user' then A[n - 1].User := val
      else if kw = 'port' then A[n - 1].Port := val
      else if kw = 'identityfile' then A[n - 1].IdentityFile := val
      else if kw = 'localforward' then AddForward(fwLocal, val)
      else if kw = 'remoteforward' then AddForward(fwRemote, val)
      else if kw = 'dynamicforward' then AddForward(fwDynamic, val);
    end;
  finally
    L.Free;
  end;
end;

procedure SaveSessions(const A: TSessionArray);
var
  L: TStringList;
  i, j: Integer;
  lastFolder: AnsiString;
begin
  L := TStringList.Create;
  try
    L.Add('# DOS Navigator FPC — saved SSH sessions (ssh_config format).');
    L.Add('# Folders and extra settings use #-comments ssh ignores.');
    L.Add('');
    lastFolder := #1;   // impossible value
    for i := 0 to High(A) do
    begin
      if A[i].Folder <> lastFolder then
      begin
        L.Add('#folder: ' + A[i].Folder);
        lastFolder := A[i].Folder;
      end;
      L.Add('Host ' + A[i].Name);
      if A[i].HostName <> '' then L.Add('    HostName ' + A[i].HostName);
      if A[i].User <> '' then L.Add('    User ' + A[i].User);
      if A[i].Port <> '' then L.Add('    Port ' + A[i].Port);
      if A[i].IdentityFile <> '' then
        L.Add('    IdentityFile ' + A[i].IdentityFile);
      for j := 0 to High(A[i].Forwards) do
        case A[i].Forwards[j].Kind of
          fwLocal:   L.Add('    LocalForward ' + A[i].Forwards[j].Spec);
          fwRemote:  L.Add('    RemoteForward ' + A[i].Forwards[j].Spec);
          fwDynamic: L.Add('    DynamicForward ' + A[i].Forwards[j].Spec);
        end;
      if A[i].RemoteDir <> '' then L.Add('    #dn-dir ' + A[i].RemoteDir);
      L.Add('');
    end;
    ForceDirectories(ConfigDir);
    L.SaveToFile(SessionsPath);
  finally
    L.Free;
  end;
end;

procedure SessionTarget(const S: TSession; out Target, Port, Dir: AnsiString);
begin
  { the Host alias is enough: ssh/sftp -F sessions resolves the rest }
  Target := S.Name;
  Port := '';                 // -F file carries the port
  Dir := S.RemoteDir;
  if Dir = '' then Dir := '.';
end;

function SessionSshCmd(const S: TSession): AnsiString;
begin
  Result := 'ssh -F ' + AnsiQuotedStr(SessionsPath, '''') + ' ' +
            AnsiQuotedStr(S.Name, '''');
end;

function SessionCopyIdCmd(const S: TSession): AnsiString;
begin
  Result := 'ssh-copy-id -F ' + AnsiQuotedStr(SessionsPath, '''');
  if S.IdentityFile <> '' then
    Result := Result + ' -i ' + AnsiQuotedStr(S.IdentityFile, '''');
  Result := Result + ' ' + AnsiQuotedStr(S.Name, '''');
end;

end.
