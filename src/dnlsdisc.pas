{ dnlsdisc — LocalSend device discovery (LOCALSEND.md, section 4).

  Runs in the main dn process, next to the TUI: one non-blocking UDP
  socket bound to the LocalSend port and joined to the multicast group
  224.0.0.167. The main loop polls it on every idle tick (LsDiscPoll).

  - LsDiscStart sends an announce (announce: true); every LocalSend peer
    answers over HTTP POST /register to the announced port: the receive
    helper's server when it runs (it forwards a `peer` event, see dnls),
    else the small listener here (LsDiscPoll serves it). A multicast
    answer (announce: false) is read too.
  - Peers announce themselves on start and on refresh; those packets
    fill the list as well.
  - When receiving is on, dn answers other peers' announces with a
    multicast packet too, so it shows up in their "Nearby devices".
  - Our own packets come back through multicast loopback; the
    fingerprint filters them out.

  The bound socket shares the port with a LocalSend app on the same
  machine (SO_REUSEADDR + SO_REUSEPORT), as multicast receivers do.

  Test seam: DN_LS_DISC_PORT replaces the multicast port. }

unit dnlsdisc;

{$mode objfpc}{$H+}

interface

uses
  dnlsproto;

{ Open the socket and announce. Info describes this device; Answer makes
  dn reply to other peers' announces (only useful while dn can receive).
  Info.Port = 0 means dn is not receiving: discovery then opens a small
  HTTP listener of its own on a free port and announces that port, so a
  peer's answer (POST /register, the path LocalSend actually uses) lands
  in dn and not in a LocalSend app on the same machine.
  Calling it again re-announces and updates Info/Answer. False when the
  socket cannot be set up (Err says why); discovery is then off, and the
  manual address entry still works. }
function LsDiscStart(const Info: TDeviceInfo; Answer: Boolean;
                     out Err: AnsiString): Boolean;

{ Ask every peer to answer again (the picker's refresh). }
procedure LsDiscAnnounce;

{ Read every pending packet. Returns True when the device list changed. }
function LsDiscPoll: Boolean;

{ A device learned some other way (the helper's /register). Returns True
  when the list changed. }
function LsDiscAdd(const Info: TDeviceInfo; const Addr: AnsiString): Boolean;


function LsDiscRunning: Boolean;
function LsDiscDevices: TLsDevices;
procedure LsDiscStop;

{ the port this device announces (the listener's when not receiving) }
function LsDiscSelfPort: Integer;

{ why the last announce did not leave the machine, '' when it did. On
  macOS a refused send usually means the terminal app lacks the Local
  Network permission (System Settings > Privacy & Security). }
function LsDiscLastError: AnsiString;

var
  { `dn --localsend-scan`: print every packet sent and received. Never set
    while the TUI runs. }
  LsDiscTrace: Boolean = False;

implementation

uses
  SysUtils, BaseUnix, Unix, Sockets;

const
  {$ifdef darwin}
  SO_REUSEPORT_ = $0200;
  IP_ADD_MEMBERSHIP_ = 12;
  {$else}
  SO_REUSEPORT_ = 15;
  IP_ADD_MEMBERSHIP_ = 35;
  {$endif}
  IPPROTO_IP_ = 0;

type
  TIpMreq = packed record
    imr_multiaddr: in_addr;
    imr_interface: in_addr;
  end;

var
  Sock: LongInt = -1;
  Self_: TDeviceInfo;
  DoAnswer: Boolean = False;
  GroupPort: Word = LsDefaultPort;
  Devices: TLsDevices;
  LastErr: AnsiString = '';

function LsDiscLastError: AnsiString;
begin
  Result := LastErr;
end;

function LsDiscSelfPort: Integer;
begin
  Result := Self_.Port;
end;

function LsDiscRunning: Boolean;
begin
  Result := Sock >= 0;
end;

function LsDiscDevices: TLsDevices;
begin
  Result := Devices;
end;

{ --- the /register listener (not receiving) --------------------------- }

var
  Listen: LongInt = -1;
  ListenPort: Integer = 0;

function OpenListener: Boolean;
var
  s, one: LongInt;
  addr: TInetSockAddr;
  len: TSockLen;
begin
  Result := Listen >= 0;
  if Result then Exit;
  s := fpSocket(AF_INET, SOCK_STREAM, 0);
  if s < 0 then Exit;
  one := 1;
  fpSetSockOpt(s, SOL_SOCKET, SO_REUSEADDR, @one, SizeOf(one));
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  len := SizeOf(addr);
  if (fpBind(s, @addr, SizeOf(addr)) <> 0) or (fpListen(s, 8) <> 0) or
     (fpGetSockName(s, @addr, @len) <> 0) then
  begin
    CloseSocket(s);
    Exit;
  end;
  fpFcntl(s, F_SETFL, fpFcntl(s, F_GETFL) or O_NONBLOCK);
  Listen := s;
  ListenPort := ntohs(addr.sin_port);
  Result := True;
end;

{ read one small HTTP request (headers + Content-Length body) within
  300 ms; '' on timeout or garbage }
function ReadRequest(c: LongInt): AnsiString;
var
  buf: array[0..4095] of Char;
  n, hdrEnd, clen, p: Integer;
  deadline: QWord;
  fds: TFDSet;
  tv: TTimeVal;
  head, chunk: AnsiString;
begin
  Result := '';
  deadline := GetTickCount64 + 300;
  hdrEnd := 0;
  clen := 0;
  while GetTickCount64 < deadline do
  begin
    fpFD_ZERO(fds);
    fpFD_SET(c, fds);
    tv.tv_sec := 0;
    tv.tv_usec := 50000;
    if fpSelect(c + 1, @fds, nil, nil, @tv) <= 0 then Continue;
    n := fpRecv(c, @buf[0], SizeOf(buf), 0);
    if n <= 0 then Break;
    SetString(chunk, @buf[0], n);
    Result := Result + chunk;
    if hdrEnd = 0 then
    begin
      hdrEnd := Pos(#13#10#13#10, Result);
      if hdrEnd > 0 then
      begin
        head := LowerCase(Copy(Result, 1, hdrEnd));
        p := Pos('content-length:', head);
        if p > 0 then
          clen := StrToIntDef(Trim(Copy(head, p + 15,
                    Pos(#13, Copy(head, p, Length(head))) - 16)), 0);
      end;
    end;
    if (hdrEnd > 0) and (Length(Result) >= hdrEnd + 3 + clen) then Exit;
    if Length(Result) > 65536 then Break;
  end;
  if hdrEnd = 0 then Result := '';
end;

procedure Reply(c: LongInt; Code: Integer; const Body: AnsiString);
var
  r: AnsiString;
begin
  if Code = 200 then r := 'HTTP/1.1 200 OK' else r := 'HTTP/1.1 404 Not Found';
  r := r + #13#10'Content-Type: application/json'#13#10 +
       'Content-Length: ' + IntToStr(Length(Body)) + #13#10 +
       'Connection: close'#13#10#13#10 + Body;
  fpSend(c, @r[1], Length(r), 0);
end;

{ answer every pending connection; True when a /register added a device }
function ServeListener: Boolean;
var
  c: LongInt;
  from: TInetSockAddr;
  flen: TSockLen;
  req, line, body: AnsiString;
  p: Integer;
  info: TDeviceInfo;
begin
  Result := False;
  if Listen < 0 then Exit;
  repeat
    flen := SizeOf(from);
    c := fpAccept(Listen, @from, @flen);
    if c < 0 then Break;
    try
      req := ReadRequest(c);
      p := Pos(#13#10, req);
      line := Copy(req, 1, p - 1);
      body := Copy(req, Pos(#13#10#13#10, req) + 4, Length(req));
      if LsDiscTrace then
        WriteLn('http  ', NetAddrToStr(from.sin_addr), '  ', line, '  ', body);
      if (Copy(line, 1, 5) = 'POST ') and
         (Pos(LsApiPrefix + '/register', line) > 0) then
      begin
        if ParseDeviceInfo(body, info) and (info.Alias <> '') then
        begin
          if info.Port <= 0 then info.Port := LsDefaultPort;
          if info.Protocol = '' then info.Protocol := 'https';
          if LsDiscAdd(info, NetAddrToStr(from.sin_addr)) then
            Result := True;
        end;
        Reply(c, 200, BuildDeviceInfo(Self_));
      end
      else if (Copy(line, 1, 4) = 'GET ') and
              (Pos(LsApiPrefix + '/info', line) > 0) then
        Reply(c, 200, BuildDeviceInfo(Self_))
      else
        Reply(c, 404, '{}');
    finally
      CloseSocket(c);
    end;
  until False;
end;

procedure SendDto(Announce: Boolean);
var
  dst: TInetSockAddr;
  body: AnsiString;
  e: LongInt;
begin
  if Sock < 0 then Exit;
  body := BuildAnnounce(Self_, Announce);
  FillChar(dst, SizeOf(dst), 0);
  dst.sin_family := AF_INET;
  dst.sin_port := htons(GroupPort);
  dst.sin_addr := StrToNetAddr(LsMulticastAddr);
  if fpSendTo(Sock, @body[1], Length(body), 0, @dst, SizeOf(dst)) < 0 then
  begin
    e := fpGetErrno;
    LastErr := 'announce not sent: ' + SysErrorMessage(e);
    {$ifdef darwin}
    if (e = ESysEHOSTUNREACH) or (e = ESysENETUNREACH) or (e = ESysEPERM) then
      LastErr := LastErr + ' (allow Local Network for your terminal app in' +
                 ' System Settings > Privacy & Security)';
    {$endif}
  end
  else
    LastErr := '';
  if LsDiscTrace then
  begin
    if LastErr <> '' then
      WriteLn('send  ', LsMulticastAddr, ':', GroupPort, '  FAILED: ', LastErr)
    else
      WriteLn('send  ', LsMulticastAddr, ':', GroupPort, '  ', body);
  end;
end;

procedure LsDiscAnnounce;
begin
  SendDto(True);
end;

function LsDiscStart(const Info: TDeviceInfo; Answer: Boolean;
                     out Err: AnsiString): Boolean;
var
  s, one: LongInt;
  addr: TInetSockAddr;
  mreq: TIpMreq;
begin
  Err := '';
  Self_ := Info;
  DoAnswer := Answer;
  if Self_.Port <= 0 then
  begin
    if OpenListener then
      Self_.Port := ListenPort
    else
      Self_.Port := LsDefaultPort;
  end;
  if Sock >= 0 then
  begin
    LsDiscAnnounce;
    Exit(True);
  end;
  Result := False;
  GroupPort := StrToIntDef(GetEnvironmentVariable('DN_LS_DISC_PORT'),
                           LsDefaultPort);
  s := fpSocket(AF_INET, SOCK_DGRAM, 0);
  if s < 0 then
  begin
    Err := 'cannot create UDP socket';
    Exit;
  end;
  one := 1;
  fpSetSockOpt(s, SOL_SOCKET, SO_REUSEADDR, @one, SizeOf(one));
  fpSetSockOpt(s, SOL_SOCKET, SO_REUSEPORT_, @one, SizeOf(one));
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(GroupPort);
  addr.sin_addr.s_addr := 0;          // INADDR_ANY
  if fpBind(s, @addr, SizeOf(addr)) <> 0 then
  begin
    Err := 'cannot bind UDP port ' + IntToStr(GroupPort);
    CloseSocket(s);
    Exit;
  end;
  FillChar(mreq, SizeOf(mreq), 0);
  mreq.imr_multiaddr := StrToNetAddr(LsMulticastAddr);
  mreq.imr_interface.s_addr := 0;
  if fpSetSockOpt(s, IPPROTO_IP_, IP_ADD_MEMBERSHIP_, @mreq,
                  SizeOf(mreq)) <> 0 then
  begin
    Err := 'cannot join multicast group ' + LsMulticastAddr;
    CloseSocket(s);
    Exit;
  end;
  fpFcntl(s, F_SETFL, fpFcntl(s, F_GETFL) or O_NONBLOCK);
  Sock := s;
  LsDiscAnnounce;
  Result := True;
end;

function LsDiscAdd(const Info: TDeviceInfo; const Addr: AnsiString): Boolean;
begin
  Result := False;
  if (Info.Fingerprint <> '') and (Info.Fingerprint = Self_.Fingerprint) then
    Exit;
  Result := DevicesUpsert(Devices, Info, Addr, GetTickCount64);
end;

function LsDiscPoll: Boolean;
var
  buf: array[0..8191] of Char;
  from: TInetSockAddr;
  flen: TSockLen;
  n: ssize_t;
  body: AnsiString;
  info: TDeviceInfo;
  announce: Boolean;
begin
  Result := ServeListener;
  if Sock < 0 then Exit;
  repeat
    flen := SizeOf(from);
    n := fpRecvFrom(Sock, @buf[0], SizeOf(buf), 0, @from, @flen);
    if n <= 0 then Break;
    SetString(body, @buf[0], n);
    if LsDiscTrace then
      WriteLn('recv  ', NetAddrToStr(from.sin_addr), ':', ntohs(from.sin_port),
              '  ', body);
    if not ParseAnnounce(body, info, announce) then Continue;
    if (info.Fingerprint <> '') and (info.Fingerprint = Self_.Fingerprint) then
      Continue;                                   // our own loopback
    if LsDiscAdd(info, NetAddrToStr(from.sin_addr)) then
      Result := True;
    if announce and DoAnswer then
      SendDto(False);
  until False;
end;

procedure LsDiscStop;
begin
  if Listen >= 0 then
  begin
    CloseSocket(Listen);
    Listen := -1;
  end;
  if Sock >= 0 then
  begin
    CloseSocket(Sock);
    Sock := -1;
  end;
  SetLength(Devices, 0);
end;

end.
