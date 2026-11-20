{ dnls — the LocalSend subsystem (LOCALSEND.md).

  Two roles in one unit:

  - Helper process (`dn --localsend-server`): starts the HTTP server from
    dnlshttp, writes one JSON event per line to stdout. The helper never
    touches ncurses.

  - Main process: starts the helper with fpFork + setpgid, reads its stdout
    non-blocking from the main loop (`DrainLsPipe`), keeps the session state
    the UI draws, and stops the helper on exit.

  The helper accepts every incoming session in stage 3; the approve/reject dialog
  is stage 4 and lands on top of the same event stream.

  Test seams:
    DN_LS_CMD       replaces the helper command (like DN_PLAYER_CMD)
    DN_LS_ENDPOINT  the peer address for the send path
    DN_LS_TICK_MS   the main-loop tick while a session is live }

unit dnls;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnlsproto, dnlshttp;

type
  { one live transfer the UI shows }
  TLsSession = record
    Id: AnsiString;
    PeerName: AnsiString;
    PeerAddr: AnsiString;
    Files: TFileMetas;
    BytesDone: Int64;
    BytesTotal: Int64;
    State: AnsiString;        // 'incoming', 'active', 'done', 'error'
    Err: AnsiString;
  end;
  TLsSessions = array of TLsSession;

  { the helper's server callbacks: methods on a class, because
    TLsServerCallbacks wants "of object" procedures }
  TLsHelperCallbacks = class
  public
    function OnDecision(const Req: TUploadRequest): TUploadDecision;
    procedure OnProgress(SessionId: AnsiString; Done, Total: Int64);
    procedure OnDone(SessionId: AnsiString; Saved: Integer);
    procedure OnError(SessionId, Err: AnsiString);
    procedure OnPeer(const Info: TDeviceInfo; const Addr: AnsiString);
  end;

{ --- helper process: entry point --- }

{ run the helper until the process is killed; never returns normally }
procedure LsHelperMain(Port: Integer; Alias, RecvDir: AnsiString);

{ --- main process: helper lifecycle --- }

{ start the helper; the command comes from DN_LS_CMD or the default }
function LsStart(const ExePath: AnsiString; Port: Integer;
                 out Err: AnsiString): Boolean;
procedure LsStop;
function LsRunning: Boolean;

{ read the helper stdout once, non-blocking, and fold events into Sessions.
  Returns the number of events read; 0 means nothing new. }
function DrainLsPipe: Integer;

{ the sessions the UI draws }
function LsSessionCount: Integer;
function LsSessionAt(Index: Integer): TLsSession;

{ True while any session is incoming or active: the main loop then wakes
  faster and must not run the screen saver }
function LsActive: Boolean;

{ the main-loop timeout in ms while a session is live }
function LsTickMs: Integer;

{ the device name peers see; the helper inherits it from the main process }
function LsDeviceName: AnsiString;
procedure LsSetDeviceName(const Name: AnsiString);

{ this device's id: stable per user and host, the same in the main
  process and the helper (both compute it) }
function LsSelfFingerprint: AnsiString;

{ this device as peers see it; Port 0 means "not receiving" (the default
  port is announced then, a peer's /register to it simply fails) }
function LsSelfInfo(Port: Integer): TDeviceInfo;

{ send files to a peer; SrcPaths holds local file paths. An "https://"
  Base goes through curl; PinFp, when set, is the fingerprint the device
  announced and its certificate must match it. }
function LsSend(const Base: AnsiString; SrcPaths: TStrings;
                out Sent: Integer; out Err: AnsiString;
                const PinFp: AnsiString = ''): Boolean;

implementation

uses
  SysUtils, Unix, BaseUnix, fphttpserver, httpdefs, fpjson, dnlsdisc, dnlsident;

const
  LsTickDefault = 200;
  DefPort = 53317;
  MaxSessions = 64;

var
  { main-process side }
  HelperPid: TPid = 0;
  HelperOut: LongInt = -1;
  Partial: AnsiString = '';
  Sessions: TLsSessions;

  { helper side }
  HelperPort: Integer = DefPort;

  { main-process side: the port the helper listens on, 0 = not receiving }
  MainPort: Integer = 0;

  { the device name peers see, set by the main process before LsStart }
  DeviceName: AnsiString = 'DN';

function LsSelfFingerprint: AnsiString;
begin
  { the certificate's hash, as LocalSend devices identify each other;
    without a certificate (no openssl) a stable per-user id }
  Result := LsIdentityFingerprint;
  if Result = '' then
    Result := LsFingerprint('dn:' + GetHostName + ':' +
                            GetEnvironmentVariable('USER') + ':' +
                            GetEnvironmentVariable('HOME'));
end;
function LsSelfInfo(Port: Integer): TDeviceInfo;
begin
  Result.Alias := DeviceName;
  Result.Version := LsProtocolVersion;
  Result.DeviceModel := 'DN';
  Result.DeviceType := 'desktop';
  Result.Fingerprint := LsSelfFingerprint;
  if Port > 0 then Result.Port := Port else Result.Port := LsDefaultPort;
  Result.Protocol := 'http';
end;

function LsDeviceName: AnsiString;
begin
  Result := DeviceName;
end;

procedure LsSetDeviceName(const Name: AnsiString);
begin
  if Name <> '' then
    DeviceName := Name;
end;

function c_setpgid(pid, pgid: LongInt): LongInt;
  cdecl; external 'c' name 'setpgid';
function c_waitpid(pid: LongInt; var status: LongInt; options: LongInt): LongInt;
  cdecl; external 'c' name 'waitpid';

function LsTickMs: Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable('DN_LS_TICK_MS'), LsTickDefault);
end;

function LsRunning: Boolean;
begin
  Result := HelperPid > 0;
end;

function LsActive: Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Sessions) do
    if (Sessions[i].State = 'incoming') or (Sessions[i].State = 'active') then
      Exit(True);
end;

function LsSessionCount: Integer;
begin
  Result := Length(Sessions);
end;

function LsSessionAt(Index: Integer): TLsSession;
begin
  Result := Sessions[Index];
end;

{ --- helper side: write one event line to stdout --- }

procedure HelperEmit(const Ev: TLsEvent);
var
  line: AnsiString;
begin
  line := BuildEventLine(Ev) + #10;
  { a broken pipe means the main process is gone: the helper has no reader,
    so it must exit rather than keep running and filling the pipe buffer }
  if fpWrite(1, @line[1], Length(line)) < 0 then
    Halt(1);
end;

function TLsHelperCallbacks.OnDecision(const Req: TUploadRequest): TUploadDecision;
var
  ev: TLsEvent;
begin
  Result := udAccept;
  ev.Kind := leIncoming;
  ev.SessionId := Req.SessionId;
  ev.PeerName := Req.Info.Alias;
  ev.PeerAddr := Req.Info.DeviceModel;
  ev.Err := '';
  ev.BytesDone := 0;
  ev.BytesTotal := 0;
  ev.Files := Req.Files;
  HelperEmit(ev);
end;

procedure TLsHelperCallbacks.OnProgress(SessionId: AnsiString; Done, Total: Int64);
var
  ev: TLsEvent;
begin
  ev.Kind := leProgress;
  ev.SessionId := SessionId;
  ev.PeerName := '';
  ev.PeerAddr := '';
  ev.Err := '';
  ev.BytesDone := Done;
  ev.BytesTotal := Total;
  SetLength(ev.Files, 0);
  HelperEmit(ev);
end;

procedure TLsHelperCallbacks.OnDone(SessionId: AnsiString; Saved: Integer);
var
  ev: TLsEvent;
begin
  ev.Kind := leDone;
  ev.SessionId := SessionId;
  ev.PeerName := '';
  ev.PeerAddr := '';
  ev.Err := IntToStr(Saved);
  ev.BytesDone := 0;
  ev.BytesTotal := 0;
  SetLength(ev.Files, 0);
  HelperEmit(ev);
end;

procedure TLsHelperCallbacks.OnError(SessionId, Err: AnsiString);
var
  ev: TLsEvent;
begin
  ev.Kind := leError;
  ev.SessionId := SessionId;
  ev.PeerName := '';
  ev.PeerAddr := '';
  ev.Err := Err;
  ev.BytesDone := 0;
  ev.BytesTotal := 0;
  SetLength(ev.Files, 0);
  HelperEmit(ev);
end;

procedure TLsHelperCallbacks.OnPeer(const Info: TDeviceInfo;
                                    const Addr: AnsiString);
var
  ev: TLsEvent;
begin
  ev.Kind := lePeer;
  ev.SessionId := '';
  ev.PeerName := Info.Alias;
  ev.PeerAddr := Addr;
  ev.Err := '';
  ev.BytesDone := 0;
  ev.BytesTotal := 0;
  SetLength(ev.Files, 0);
  ev.PeerInfo := BuildDeviceInfo(Info);
  HelperEmit(ev);
end;

procedure LsHelperMain(Port: Integer; Alias, RecvDir: AnsiString);
var
  parent: TPid;
  cb: TLsServerCallbacks;
  hcb: TLsHelperCallbacks;
  err: AnsiString;
  ev: TLsEvent;
begin
  HelperPort := Port;
  LsSetServerAlias(Alias);
  LsSetServerFingerprint(LsSelfFingerprint);
  LsSetReceiveDir(RecvDir);
  hcb := TLsHelperCallbacks.Create;
  cb := TLsServerCallbacks.Create;
  cb.OnDecision := @hcb.OnDecision;
  cb.OnProgress := @hcb.OnProgress;
  cb.OnDone := @hcb.OnDone;
  cb.OnError := @hcb.OnError;
  cb.OnPeer := @hcb.OnPeer;
  if not LsServerStart(Port, cb, err) then
  begin
    ev.Kind := leError;
    ev.SessionId := '';
    ev.PeerName := '';
    ev.PeerAddr := '';
    ev.Err := 'cannot start server: ' + err;
    ev.BytesDone := 0;
    ev.BytesTotal := 0;
    SetLength(ev.Files, 0);
    HelperEmit(ev);
    Exit;
  end;
  { signal readiness }
  ev.Kind := leOk;
  ev.SessionId := '';
  ev.PeerName := '';
  ev.PeerAddr := '';
  ev.Err := '';
  ev.BytesDone := 0;
  ev.BytesTotal := 0;
  SetLength(ev.Files, 0);
  HelperEmit(ev);
  { the server runs in its own threads; the main helper thread watches
    for the parent: if dn dies without LsStop (killed, crashed), the
    helper must not live on holding the port }
  parent := fpGetPPid;
  while fpGetPPid = parent do
    Sleep(500);
  Halt(0);
end;

{ --- main process --- }

function LsStart(const ExePath: AnsiString; Port: Integer;
                 out Err: AnsiString): Boolean;
var
  cmd: AnsiString;
  pfd: TFilDes;
  pid: TPid;
  devnull: cint;
begin
  Result := False;
  Err := '';
  if HelperPid > 0 then
  begin
    Err := 'already running';
    Exit;
  end;
  cmd := GetEnvironmentVariable('DN_LS_CMD');
  if cmd = '' then
    { exec: the helper replaces the shell, so its parent is dn itself
      (the helper exits when that parent goes away) }
    cmd := 'exec "' + ExePath + '" --localsend-server ' + IntToStr(Port) +
           ' "' + LsDeviceName + '"';  if fpPipe(pfd) <> 0 then
  begin
    Err := 'cannot create pipe';
    Exit;
  end;
  pid := fpFork;
  if pid = 0 then
  begin
    c_setpgid(0, 0);
    fpSignal(SIGINT, SignalHandler(SIG_DFL));
    fpSignal(SIGQUIT, SignalHandler(SIG_DFL));
    devnull := fpOpen('/dev/null', O_RDONLY);
    fpDup2(devnull, 0);
    fpClose(pfd[0]);
    fpDup2(pfd[1], 1);
    fpClose(pfd[1]);
    fpExecl('/bin/sh', ['-c', cmd]);
    fpExit(127);
  end;
  fpClose(pfd[1]);
  if pid < 0 then
  begin
    fpClose(pfd[0]);
    Err := 'cannot fork';
    Exit;
  end;
  fpFcntl(pfd[0], F_SETFL, fpFcntl(pfd[0], F_GETFL) or O_NONBLOCK);
  HelperPid := pid;
  HelperOut := pfd[0];
  MainPort := Port;
  Partial := '';
  SetLength(Sessions, 0);
  Result := True;
end;

procedure LsStop;
var
  st: LongInt;
begin
  if HelperPid <= 0 then Exit;
  if HelperOut >= 0 then fpClose(HelperOut);
  fpKill(-HelperPid, SIGTERM);
  st := 0;
  if c_waitpid(HelperPid, st, WNOHANG) = 0 then
  begin
    Sleep(300);
    if c_waitpid(HelperPid, st, WNOHANG) = 0 then
      fpKill(-HelperPid, SIGKILL);
    c_waitpid(HelperPid, st, 0);
  end;
  HelperPid := 0;
  MainPort := 0;
  HelperOut := -1;
  Partial := '';
  SetLength(Sessions, 0);
end;

function FindSession(const Id: AnsiString): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(Sessions) do
    if Sessions[i].Id = Id then Exit(i);
end;

{ drop the oldest finished sessions so a long run cannot grow the list
  without bound; live sessions are kept }
procedure TrimSessions;
var
  i: Integer;
  kept: TLsSessions;
begin
  if Length(Sessions) <= MaxSessions then Exit;
  SetLength(kept, 0);
  for i := 0 to High(Sessions) do
    if (Sessions[i].State = 'incoming') or (Sessions[i].State = 'active') then
    begin
      SetLength(kept, Length(kept) + 1);
      kept[High(kept)] := Sessions[i];
    end;
  { keep the newest finished sessions up to the limit }
  for i := High(Sessions) downto 0 do
  begin
    if Length(kept) >= MaxSessions then Break;
    if not ((Sessions[i].State = 'incoming') or
            (Sessions[i].State = 'active')) then
    begin
      SetLength(kept, Length(kept) + 1);
      kept[High(kept)] := Sessions[i];
    end;
  end;
  Sessions := kept;
end;

procedure ApplyEvent(const Ev: TLsEvent);
var
  idx: Integer;
  s: TLsSession;
  peer: TDeviceInfo;
begin
  if Ev.Kind = lePeer then
  begin
    { a peer answered our announce over HTTP: into the device list }
    if ParseDeviceInfo(Ev.PeerInfo, peer) and (peer.Alias <> '') and
       (Ev.PeerAddr <> '') then
      LsDiscAdd(peer, Ev.PeerAddr);
    Exit;
  end;
  idx := FindSession(Ev.SessionId);
  if idx < 0 then
  begin
    if (Ev.Kind = leIncoming) or (Ev.Kind = leProgress) then
    begin
      SetLength(Sessions, Length(Sessions) + 1);
      idx := High(Sessions);
      s.Id := Ev.SessionId;
      s.PeerName := Ev.PeerName;
      s.PeerAddr := Ev.PeerAddr;
      s.Files := Ev.Files;
      s.BytesDone := 0;
      s.BytesTotal := 0;
      s.Err := '';
      s.State := 'incoming';
      Sessions[idx] := s;
    end
    else
      Exit;
  end;
  case Ev.Kind of
    leIncoming:
      begin
        Sessions[idx].State := 'incoming';
        if Ev.PeerName <> '' then Sessions[idx].PeerName := Ev.PeerName;
        if Ev.PeerAddr <> '' then Sessions[idx].PeerAddr := Ev.PeerAddr;
        if Length(Ev.Files) > 0 then Sessions[idx].Files := Ev.Files;
      end;
    leProgress:
      begin
        Sessions[idx].State := 'active';
        Sessions[idx].BytesDone := Ev.BytesDone;
        Sessions[idx].BytesTotal := Ev.BytesTotal;
      end;
    leDone:
      Sessions[idx].State := 'done';
    leError:
      begin
        Sessions[idx].State := 'error';
        Sessions[idx].Err := Ev.Err;
      end;
    lePeer: ;
  else
    ;
  end;
  TrimSessions;
end;

function DrainLsPipe: Integer;
var
  buf: array[0..4095] of Byte;
  n, cnt: Integer;
  chunk, line: AnsiString;
  p: Integer;
  ev: TLsEvent;
begin
  Result := 0;
  if HelperOut < 0 then Exit;
  cnt := 0;
  repeat
    n := fpRead(HelperOut, buf, SizeOf(buf));
    if n > 0 then
    begin
      SetString(chunk, @buf[0], n);
      Partial := Partial + chunk;
    end;
  until n <= 0;
  repeat
    p := Pos(#10, Partial);
    if p = 0 then Break;
    line := Copy(Partial, 1, p - 1);
    Partial := Copy(Partial, p + 1, Length(Partial) - p);
    if Trim(line) <> '' then
      if ParseEventLine(line, ev) then
      begin
        if ev.Kind <> leOk then
          ApplyEvent(ev);
        Inc(cnt);
      end;
  until False;
  Result := cnt;
end;

function LsSend(const Base: AnsiString; SrcPaths: TStrings;
                out Sent: Integer; out Err: AnsiString;
                const PinFp: AnsiString): Boolean;
var
  info: TDeviceInfo;
  files: TFileMetas;
  res: TLsHttpResult;
  i: Integer;
begin
  Result := False;
  Sent := 0;
  Err := '';
  { who we are: the receiving app shows this name and remembers the
    fingerprint }
  info := LsSelfInfo(MainPort);
  SetLength(files, SrcPaths.Count);
  for i := 0 to SrcPaths.Count - 1 do
  begin
    files[i].Id := IntToStr(i + 1);
    files[i].FileName := SrcPaths[i];
    files[i].Size := 0;
    if FileExists(SrcPaths[i]) then
      with TFileStream.Create(SrcPaths[i], fmOpenRead or fmShareDenyNone) do
      try
        files[i].Size := Size;
      finally
        Free;
      end;
    files[i].FileType := FileTypeOf(SrcPaths[i]);
    files[i].Mime := '';
  end;
  if not LsSendFiles(Base, info, files, nil, Sent, res, PinFp) then
  begin
    Err := res.Err;
    Exit;
  end;
  Result := True;
end;

end.
