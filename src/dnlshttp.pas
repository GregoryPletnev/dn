{ dnlshttp — HTTP client and server for the LocalSend v2 protocol
  (LOCALSEND.md). Client: send a file to a peer. Server: receive files
  from a peer. TLS is added in stage 6; stage 2 uses plain HTTP.

  The transport is a plain socket stream for uploads, because LocalSend
  sends each file as a raw octet-stream body, not multipart. }
unit dnlshttp;

{$mode objfpc}{$H+}

interface

uses
  Classes, httpdefs, fphttpserver, dnlsproto;

type
  { result of a peer query or a send }
  TLsHttpResult = record
    Ok: Boolean;
    Code: Integer;
    Body: AnsiString;
    Err: AnsiString;
  end;

  { what the server does with an incoming upload }
  TUploadDecision = (udAccept, udReject);
  TLsUploadDecisionFn = function(const Req: TUploadRequest): TUploadDecision of object;

  { callbacks the helper installs on the server }
  TLsServerCallbacks = class
  public
    OnDecision: TLsUploadDecisionFn;   // nil = accept all
    OnProgress: procedure(SessionId: AnsiString; Done, Total: Int64) of object;
    OnDone: procedure(SessionId: AnsiString; Saved: Integer) of object;
    OnError: procedure(SessionId, Err: AnsiString) of object;
    { a peer answered our announce over HTTP (POST /register) }
    OnPeer: procedure(const Info: TDeviceInfo; const Addr: AnsiString) of object;
  end;

  { the request handler lives on a class so it can be an "of object" method,
    which TFPHTTPServer.OnRequest requires }
  TLsHttpHandler = class
  public
    procedure Handle(Sender: TObject;
                     var ARequest: TFPHTTPConnectionRequest;
                     var AResponse: TFPHTTPConnectionResponse);
  end;

{ --- client --- }

{ progress callback: called with bytes done and total }
type
  TLsProgressFn = procedure(Done, Total: Int64) of object;

{ GET {Base}/api/localsend/v2/info }
function LsQueryInfo(const Base: AnsiString; out Info: TDeviceInfo;
                     out Res: TLsHttpResult): Boolean;

{ POST prepare-upload, then POST upload with the file bodies.
  Base is host:port, e.g. '192.168.1.5:53317'.
  SrcFiles is a list of TFileMeta with FileName holding the local path.
  Returns the number of files the peer accepted, or -1 on transport error. }
function LsSendFiles(const Base: AnsiString; const Info: TDeviceInfo;
                     const SrcFiles: TFileMetas;
                     Progress: TLsProgressFn;
                     out Sent: Integer; out Res: TLsHttpResult;
                     const PinFp: AnsiString = ''): Boolean;

{ True when the curl binary the HTTPS path runs is on PATH }
function LsCurlAvailable: Boolean;

{ --- server --- }

{ start the server; returns False when the port is busy }
function LsServerStart(Port: Integer; Callbacks: TLsServerCallbacks;
                       out Err: AnsiString): Boolean;
procedure LsServerStop;
function LsServerRunning: Boolean;
function LsServerPort: Integer;

{ the directory where accepted files land }
function LsReceiveDir: AnsiString;
procedure LsSetReceiveDir(const Dir: AnsiString);

{ device name peers see in /info }
procedure LsSetServerAlias(const Alias: AnsiString);

{ device id peers see in /info and /register (see LsFingerprint) }
procedure LsSetServerFingerprint(const Fingerprint: AnsiString);

implementation

uses
  SysUtils, fphttpclient, ssockets, process, dnsha256, dnlsident;

var
  Srv: TFPHTTPServer = nil;
  SrvPort: Integer = 0;
  RecvDir: AnsiString = '';
  SrvAlias: AnsiString = 'DN';
  SrvFingerprint: AnsiString = '';
  SrvCb: TLsServerCallbacks = nil;
  Handler: TLsHttpHandler = nil;
  { accepted uploads: "<sessionId>/<fileId>" = "<token>|<file name>",
    written by prepare-upload and read by upload. The server is threaded,
    so every access holds UploadLock. }
  Uploads: TStringList = nil;
  UploadLock: TRTLCriticalSection;

procedure UploadRemember(const SessionId, FileId, Token, Name: AnsiString);
begin
  EnterCriticalSection(UploadLock);
  try
    if Uploads = nil then Uploads := TStringList.Create;
    Uploads.Values[SessionId + '/' + FileId] := Token + '|' + Name;
  finally
    LeaveCriticalSection(UploadLock);
  end;
end;

{ False when prepare-upload never announced this file }
function UploadLookup(const SessionId, FileId: AnsiString;
                      out Token, Name: AnsiString): Boolean;
var
  v: AnsiString;
  p: Integer;
begin
  Token := '';
  Name := '';
  EnterCriticalSection(UploadLock);
  try
    if Uploads = nil then v := ''
    else v := Uploads.Values[SessionId + '/' + FileId];
  finally
    LeaveCriticalSection(UploadLock);
  end;
  Result := v <> '';
  if not Result then Exit;
  p := Pos('|', v);
  Token := Copy(v, 1, p - 1);
  Name := Copy(v, p + 1, Length(v));
end;

{ Dir/Name, or "name (2).ext" and so on when that file exists already }
function UniquePath(const Dir, Name: AnsiString): AnsiString;
var
  base, ext: AnsiString;
  n: Integer;
begin
  Result := IncludeTrailingPathDelimiter(Dir) + Name;
  ext := ExtractFileExt(Name);
  base := Copy(Name, 1, Length(Name) - Length(ext));
  n := 1;
  while FileExists(Result) or DirectoryExists(Result) do
  begin
    Inc(n);
    Result := IncludeTrailingPathDelimiter(Dir) + base + ' (' + IntToStr(n) +
              ')' + ext;
  end;
end;

function AcceptedContains(const Resp: TPrepareResponse;
                          const Id: AnsiString): Boolean; forward;
function TokenFor(const Resp: TPrepareResponse;
                  const Id: AnsiString): AnsiString; forward;
function TotalSize(const Files: TFileMetas): Int64; forward;

{ query parameter value, '' when missing }
function QueryValue(const ARequest: TFPHTTPConnectionRequest;
                    const Name: AnsiString): AnsiString;
begin
  Result := ARequest.QueryFields.Values[Name];
end;

{ receive one uploaded file: body goes to RecvDir/<sessionId>_<fileId> }
procedure SaveUpload(var ARequest: TFPHTTPConnectionRequest;
                     var AResponse: TFPHTTPConnectionResponse);
var
  sessionId, fileId, dst, name, token: AnsiString;
  fs: TFileStream;
  total: Int64;
begin
  sessionId := QueryValue(ARequest, 'sessionId');
  fileId := QueryValue(ARequest, 'fileId');
  if (sessionId = '') or (fileId = '') then
  begin
    AResponse.Code := 400;
    AResponse.Content := '{"error":"missing sessionId or fileId"}';
    Exit;
  end;
  if RecvDir = '' then
  begin
    AResponse.Code := 500;
    AResponse.Content := '{"error":"no receive directory"}';
    Exit;
  end;
  if UploadLookup(sessionId, fileId, token, name) then
  begin
    if QueryValue(ARequest, 'token') <> token then
    begin
      AResponse.Code := 403;
      AResponse.Content := '{"error":"invalid token"}';
      Exit;
    end;
  end
  else
    name := sessionId + '_' + fileId;   // no prepare-upload: a bare upload
  dst := UniquePath(RecvDir, name);
  total := 0;
  try
    fs := TFileStream.Create(dst, fmCreate);
    try
      total := Length(ARequest.Content);
      if total > 0 then
        fs.WriteBuffer(ARequest.Content[1], total);
    finally
      fs.Free;
    end;
  except
    on E: Exception do
    begin
      if (SrvCb <> nil) and Assigned(SrvCb.OnError) then
        SrvCb.OnError(sessionId, E.Message);
      AResponse.Code := 500;
      AResponse.Content := '{"error":"write failed"}';
      Exit;
    end;
  end;
  if (SrvCb <> nil) and Assigned(SrvCb.OnProgress) then
    SrvCb.OnProgress(sessionId, total, total);
  if (SrvCb <> nil) and Assigned(SrvCb.OnDone) then
    SrvCb.OnDone(sessionId, 1);
  AResponse.Code := 200;
  AResponse.Content := '{}';
end;

procedure TLsHttpHandler.Handle(Sender: TObject;
                       var ARequest: TFPHTTPConnectionRequest;
                       var AResponse: TFPHTTPConnectionResponse);
var
  path, method: AnsiString;
  req: TUploadRequest;
  resp: TPrepareResponse;
  info, peer: TDeviceInfo;
  dec: TUploadDecision;
  i, p: Integer;
begin
  path := ARequest.URI;
  { the URI carries the query string: keep the path part only }
  p := Pos('?', path);
  if p > 0 then
    path := Copy(path, 1, p - 1);
  method := UpperCase(ARequest.Method);
  AResponse.ContentType := 'application/json';

  info.Alias := SrvAlias;
  info.Version := LsProtocolVersion;
  info.DeviceModel := 'DN - DataNavigator';
  info.DeviceType := 'desktop';
  info.Fingerprint := SrvFingerprint;
  info.Port := SrvPort;
  info.Protocol := 'http';

  if (method = 'GET') and (path = LsApiPrefix + '/info') then
  begin
    AResponse.Code := 200;
    AResponse.Content := BuildDeviceInfo(info);
    Exit;
  end;

  { a peer answers our multicast announce here: it sends its own info and
    expects ours back }
  if (method = 'POST') and (path = LsApiPrefix + '/register') then
  begin
    if ParseDeviceInfo(ARequest.Content, peer) and (peer.Alias <> '') then
    begin
      if peer.Port <= 0 then peer.Port := LsDefaultPort;
      if peer.Protocol = '' then peer.Protocol := 'https';
      if (SrvCb <> nil) and Assigned(SrvCb.OnPeer) then
        SrvCb.OnPeer(peer, ARequest.RemoteAddress);
    end;
    AResponse.Code := 200;
    AResponse.Content := BuildDeviceInfo(info);
    Exit;
  end;

  if (method = 'POST') and (path = LsApiPrefix + '/prepare-upload') then
  begin
    if not ParseUploadRequest(ARequest.Content, req) then
    begin
      AResponse.Code := 400;
      AResponse.Content := '{"error":"bad request"}';
      Exit;
    end;
    { protocol v2: the receiver names the session; a sender that sends a
      sessionId (older DN) keeps it }
    if req.SessionId = '' then
      req.SessionId := LowerCase(Copy(LsFingerprint(IntToStr(GetTickCount64) +
                         '/' + IntToStr(Random(MaxInt)) + '/' +
                         ARequest.RemoteAddress), 1, 24));
    dec := udAccept;
    if (SrvCb <> nil) and Assigned(SrvCb.OnDecision) then
      dec := SrvCb.OnDecision(req);
    resp.SessionId := req.SessionId;
    SetLength(resp.Accepted, 0);
    SetLength(resp.Tokens, 0);
    if dec = udAccept then
      for i := 0 to High(req.Files) do
      begin
        SetLength(resp.Accepted, Length(resp.Accepted) + 1);
        SetLength(resp.Tokens, Length(resp.Accepted));
        resp.Accepted[High(resp.Accepted)] := req.Files[i].Id;
        resp.Tokens[High(resp.Tokens)] :=
          LsFingerprint(req.SessionId + '/' + req.Files[i].Id + '/' +
                        IntToStr(GetTickCount64) + '/' + IntToStr(Random(MaxInt)));
        UploadRemember(req.SessionId, req.Files[i].Id,
                       resp.Tokens[High(resp.Tokens)],
                       SafeLocalName(req.Files[i].FileName));
      end;
    AResponse.Code := 200;
    AResponse.Content := BuildPrepareResponse(resp);
    Exit;
  end;

  { protocol v2 uploads with POST; PUT is what DN before 2026-11 sent }
  if ((method = 'POST') or (method = 'PUT')) and
     (path = LsApiPrefix + '/upload') then
  begin
    SaveUpload(ARequest, AResponse);
    Exit;
  end;

  if (method = 'POST') and (path = LsApiPrefix + '/cancel') then
  begin
    AResponse.Code := 200;
    AResponse.Content := '{}';
    Exit;
  end;

  AResponse.Code := 404;
  AResponse.Content := '{"error":"not found"}';
end;

function LsReceiveDir: AnsiString;
begin
  Result := RecvDir;
end;

procedure LsSetReceiveDir(const Dir: AnsiString);
begin
  RecvDir := Dir;
end;

{ --- client --- }

function JoinUrl(const Base, Path: AnsiString): AnsiString;
begin
  if Pos('://', Base) > 0 then
    Result := Base + Path
  else
    Result := 'http://' + Base + Path;
end;

function LsQueryInfo(const Base: AnsiString; out Info: TDeviceInfo;
                     out Res: TLsHttpResult): Boolean;
var
  c: TFPHTTPClient;
begin
  Result := False;
  Info.Alias := ''; Info.Version := ''; Info.DeviceModel := '';
  Info.DeviceType := ''; Info.Fingerprint := ''; Info.Port := 0;
  Info.Protocol := '';
  Res.Ok := False; Res.Code := 0; Res.Body := ''; Res.Err := '';
  c := TFPHTTPClient.Create(nil);
  try
    c.ConnectTimeout := 5000;
    c.IOTimeout := 10000;
    c.KeepConnection := False;
    try
      Res.Body := c.Get(JoinUrl(Base, LsApiPrefix + '/info'));
      Res.Code := c.ResponseStatusCode;
    except
      on E: Exception do
      begin
        Res.Err := E.Message;
        Exit;
      end;
    end;
    Res.Ok := (Res.Code >= 200) and (Res.Code < 300);
    if Res.Ok then
      ParseDeviceInfo(Res.Body, Info);
    Result := Res.Ok;
  finally
    c.Free;
  end;
end;

{ POST a JSON body and return the response body. FPC writes the response
  into the same stream after the request body: skip the request length. }
function PostJson(c: TFPHTTPClient; const Url, Body: AnsiString;
                  out Res: TLsHttpResult): Boolean;
var
  req: TStringStream;
  all: AnsiString;
begin
  Result := False;
  Res.Ok := False; Res.Code := 0; Res.Body := ''; Res.Err := '';
  req := TStringStream.Create(Body);
  try
    c.RequestHeaders.Clear;
    c.RequestBody := req;
    c.AddHeader('Content-Type', 'application/json');
    try
      c.HTTPMethod('POST', Url, req, []);
      Res.Code := c.ResponseStatusCode;
      all := req.DataString;
      if Length(all) > Length(Body) then
        Res.Body := Copy(all, Length(Body) + 1, Length(all) - Length(Body))
      else
        Res.Body := '';
    except
      on E: Exception do
      begin
        Res.Err := E.Message;
        Exit;
      end;
    end;
    Res.Ok := (Res.Code >= 200) and (Res.Code < 300);
    Result := Res.Ok;
  finally
    req.Free;
  end;
end;

{ PUT a raw file body with the session and file id query parameters. }
function PutFile(c: TFPHTTPClient; const Url, SessionId, FileId, Token: AnsiString;
                const SrcPath: AnsiString;
                Progress: TLsProgressFn;
                out Res: TLsHttpResult): Boolean;
var
  fs: TFileStream;
  st: TStringStream;
  url2: AnsiString;
  total: Int64;
  body: AnsiString;
begin
  Result := False;
  Res.Ok := False; Res.Code := 0; Res.Body := ''; Res.Err := '';
  total := 0;
  if not FileExists(SrcPath) then
  begin
    Res.Err := 'no such file: ' + SrcPath;
    Exit;
  end;
  { read the file into memory and send it as a string body: FPC's
    HTTPMethod uses chunked encoding for a bare TStream, which LocalSend
    peers do not accept. A TStringStream body sends Content-Length. }
  fs := TFileStream.Create(SrcPath, fmOpenRead or fmShareDenyNone);
  try
    total := fs.Size;
    if total > 0 then
    begin
      SetLength(body, total);
      fs.ReadBuffer(body[1], total);
    end
    else
      body := '';
  finally
    fs.Free;
  end;
  st := TStringStream.Create(body);
  try
    if Assigned(Progress) then
      Progress(0, total);
    url2 := Url + '?sessionId=' + EncodeURLElement(SessionId) +
            '&fileId=' + EncodeURLElement(FileId);
    if Token <> '' then
      url2 := url2 + '&token=' + EncodeURLElement(Token);
    c.RequestHeaders.Clear;
    c.RequestBody := st;
    c.AddHeader('Content-Type', 'application/octet-stream');
    try
      c.HTTPMethod('POST', url2, st, []);   // protocol v2: POST /upload
      Res.Code := c.ResponseStatusCode;
    except
      on E: Exception do
      begin
        Res.Err := E.Message;
        Exit;
      end;
    end;
    if Assigned(Progress) then
      Progress(total, total);
    Res.Ok := (Res.Code >= 200) and (Res.Code < 300);
    Result := Res.Ok;
  finally
    st.Free;
  end;
end;

{ --- HTTPS through curl -------------------------------------------------

  LocalSend's HTTPS uses a self-signed certificate per device; the device
  announces the SHA-256 of that certificate as its fingerprint. curl runs
  with -k (no CA check) and prints the certificate it saw (%{certs}); the
  request only counts when that certificate hashes to the fingerprint the
  device announced. FPC's own TLS would need OpenSSL wired in at run time,
  which on macOS means the system stub library that aborts the process. }

const
  CurlMark = #10'@@DN-CURL@@';

function LsCurlAvailable: Boolean;
begin
  Result := ExeSearch('curl', GetEnvironmentVariable('PATH')) <> '';
end;

function CurlExitText(Code: Integer): AnsiString;
begin
  case Code of
    6: Result := 'cannot resolve the host';
    7: Result := 'connection refused';
    28: Result := 'timed out (nobody accepted on the other device?)';
    35: Result := 'TLS handshake failed';
    52: Result := 'empty reply';
    56: Result := 'connection reset during TLS or transfer';
  else
    Result := 'curl failed with exit code ' + IntToStr(Code);
  end;
end;

{ "host:port" of an https:// URL }
function HostPortOf(const Url: AnsiString): AnsiString;
var
  p: Integer;
begin
  Result := Url;
  p := Pos('://', Result);
  if p > 0 then Delete(Result, 1, p + 2);
  p := Pos('/', Result);
  if p > 0 then Result := Copy(Result, 1, p - 1);
end;

{ the PEM the peer presents, from `openssl s_client`: the fallback when
  curl's TLS backend does not report certificates }
function OpensslPeerCert(const HostPort: AnsiString): AnsiString;
var
  status, i: Integer;
begin
  Result := '';
  if ExeSearch('openssl', GetEnvironmentVariable('PATH')) = '' then Exit;
  { goes through sh for the </dev/null (s_client would wait for input):
    only an address-shaped HostPort may reach the command line }
  for i := 1 to Length(HostPort) do
    if not (HostPort[i] in ['0'..'9', 'a'..'z', 'A'..'Z', '.', ':', '-']) then
      Exit;
  if RunCommandIndir(GetCurrentDir, '/bin/sh',
       ['-c', 'openssl s_client -connect ' + HostPort +
              ' -showcerts </dev/null 2>/dev/null'],
       Result, status, []) <> 0 then
    Result := '';
end;

{ Run curl with Args plus the -w trailer; split stdout into the body, the
  HTTP status and the certificate chain. Stderr is discarded (-s): it
  would land on the TUI. }
function CurlCall(const Args: array of AnsiString; const PinFp: AnsiString;
                  out Res: TLsHttpResult): Boolean;
var
  argv: array of AnsiString;
  cert: TStringArray;
  outp, tail, certs, der: AnsiString;
  i, p, rc, status: Integer;
begin
  Result := False;
  Res.Ok := False; Res.Code := 0; Res.Body := ''; Res.Err := '';
  { LocalSend runs mutual TLS: present our certificate (dnlsident) }
  cert := LsCurlClientCertArgs;
  SetLength(argv, 5 + Length(cert) + Length(Args));
  argv[0] := '-sk';
  argv[1] := '--connect-timeout';
  argv[2] := '5';
  argv[3] := '-w';
  argv[4] := CurlMark + '%{http_code}'#10'%{certs}';
  for i := 0 to High(cert) do
    argv[5 + i] := cert[i];
  for i := 0 to High(Args) do
    argv[5 + Length(cert) + i] := Args[i];
  rc := RunCommandIndir(GetCurrentDir, 'curl', argv, outp, status, []);
  if rc <> 0 then
  begin
    Res.Err := 'cannot run curl';
    Exit;
  end;
  { on Unix RunCommandIndir hands back the raw wait() status }
  if status > 255 then
    status := (status shr 8) and $FF;
  p := Pos(CurlMark, outp);
  if p = 0 then
  begin
    if status <> 0 then Res.Err := CurlExitText(status)
    else Res.Err := 'unexpected curl output';
    Exit;
  end;
  Res.Body := Copy(outp, 1, p - 1);
  tail := Copy(outp, p + Length(CurlMark), Length(outp));
  p := Pos(#10, tail);
  if p = 0 then p := Length(tail) + 1;
  Res.Code := StrToIntDef(Trim(Copy(tail, 1, p - 1)), 0);
  certs := Copy(tail, p + 1, Length(tail));
  if status <> 0 then
  begin
    Res.Err := CurlExitText(status);
    Exit;
  end;
  if PinFp <> '' then
  begin
    der := PemFirstCertDer(certs);
    if der = '' then
      der := PemFirstCertDer(OpensslPeerCert(HostPortOf(Args[High(Args)])));
    if der = '' then
    begin
      Res.Err := 'cannot check the device certificate (needs curl 7.88+ or openssl)';
      Exit;
    end;
    if UpperCase(Sha256Hex(der)) <> UpperCase(PinFp) then
    begin
      Res.Err := 'the device certificate does not match its fingerprint';
      Exit;
    end;
  end;
  if (Res.Code < 200) or (Res.Code > 299) then
  begin
    Res.Err := 'HTTP ' + IntToStr(Res.Code);
    if Res.Code = 403 then Res.Err := Res.Err + ' (rejected on the other device)';
    Exit;
  end;
  Res.Ok := True;
  Result := True;
end;

function SendFilesCurl(const Base: AnsiString; const Req: TUploadRequest;
                       const SrcFiles: TFileMetas; const PinFp: AnsiString;
                       Progress: TLsProgressFn;
                       out Sent: Integer; out Res: TLsHttpResult): Boolean;
var
  rprep: TPrepareResponse;
  i, n: Integer;
  done: Int64;
  url, tok: AnsiString;
begin
  Result := False;
  Sent := 0;
  if not LsCurlAvailable then
  begin
    Res.Ok := False; Res.Code := 0; Res.Body := '';
    Res.Err := 'HTTPS needs curl, which is not on PATH';
    Exit;
  end;
  if not CurlCall(['--max-time', '120', '-H', 'Content-Type: application/json',
                   '--data-binary', BuildUploadRequest(Req),
                   JoinUrl(Base, LsApiPrefix + '/prepare-upload')],
                  PinFp, Res) then
    Exit;
  if not ParsePrepareResponse(Res.Body, rprep) then
  begin
    Res.Err := 'bad prepare response';
    Exit;
  end;
  n := 0;
  done := 0;
  for i := 0 to High(Req.Files) do
  begin
    if (Length(rprep.Accepted) > 0) and
       not AcceptedContains(rprep, Req.Files[i].Id) then
      Continue;
    url := JoinUrl(Base, LsApiPrefix + '/upload') +
           '?sessionId=' + EncodeURLElement(rprep.SessionId) +
           '&fileId=' + EncodeURLElement(Req.Files[i].Id);
    tok := TokenFor(rprep, Req.Files[i].Id);
    if tok <> '' then
      url := url + '&token=' + EncodeURLElement(tok);
    if not CurlCall(['--max-time', '3600', '-X', 'POST',
                     '-H', 'Content-Type: application/octet-stream',
                     '--data-binary', '@' + SrcFiles[i].FileName, url],
                    PinFp, Res) then
      Exit;
    Inc(n);
    done := done + Req.Files[i].Size;
    if Assigned(Progress) then
      Progress(done, TotalSize(Req.Files));
  end;
  Sent := n;
  Result := True;
end;

function LsSendFiles(const Base: AnsiString; const Info: TDeviceInfo;
                     const SrcFiles: TFileMetas;
                     Progress: TLsProgressFn;
                     out Sent: Integer; out Res: TLsHttpResult;
                     const PinFp: AnsiString): Boolean;
var
  c: TFPHTTPClient;
  req: TUploadRequest;
  prep, rprep: TPrepareResponse;
  i, done, n: Integer;
  body: AnsiString;
begin
  Result := False;
  Sent := 0;
  Res.Ok := False; Res.Code := 0; Res.Body := ''; Res.Err := '';
  if Length(SrcFiles) = 0 then Exit;

  { session id: peer fingerprint + time, unique enough for a single run }
  req.SessionId := IntToStr(GetTickCount64);
  req.Info := Info;
  { the peer sees the bare name; the full local path stays in SrcFiles }
  SetLength(req.Files, Length(SrcFiles));
  for i := 0 to High(SrcFiles) do
  begin
    req.Files[i] := SrcFiles[i];
    req.Files[i].FileName := ExtractFileName(SrcFiles[i].FileName);
  end;

  if LowerCase(Copy(Base, 1, 8)) = 'https://' then
  begin
    Result := SendFilesCurl(Base, req, SrcFiles, PinFp, Progress, Sent, Res);
    Exit;
  end;

  c := TFPHTTPClient.Create(nil);
  try
    c.ConnectTimeout := 5000;
    { prepare-upload waits until the person on the other side accepts }
    c.IOTimeout := 120000;
    c.KeepConnection := False;

    { 1. prepare-upload }
    if not PostJson(c, JoinUrl(Base, LsApiPrefix + '/prepare-upload'),
                     BuildUploadRequest(req), Res) then
      Exit;
    if not ParsePrepareResponse(Res.Body, rprep) then
    begin
      Res.Err := 'bad prepare response';
      Exit;
    end;

    { 2. upload each accepted file }
    done := 0;
    n := 0;
    for i := 0 to High(req.Files) do
    begin
      if Length(rprep.Accepted) > 0 then
      begin
        if not AcceptedContains(rprep, req.Files[i].Id) then Continue;
      end;
      if not PutFile(c, JoinUrl(Base, LsApiPrefix + '/upload'),
                     rprep.SessionId, req.Files[i].Id,
                     TokenFor(rprep, req.Files[i].Id),
                     SrcFiles[i].FileName, Progress, Res) then
      begin
        Exit;
      end;
      Inc(n);
      done := done + req.Files[i].Size;
      if Assigned(Progress) then
        Progress(done, TotalSize(req.Files));
    end;
    Sent := n;
    Result := True;
  finally
    c.Free;
  end;
end;

function TokenFor(const Resp: TPrepareResponse;
                  const Id: AnsiString): AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Resp.Accepted) do
    if (Resp.Accepted[i] = Id) and (i <= High(Resp.Tokens)) then
      Exit(Resp.Tokens[i]);
end;

function AcceptedContains(const Resp: TPrepareResponse;
                          const Id: AnsiString): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Resp.Accepted) do
    if Resp.Accepted[i] = Id then Exit(True);
end;

function TotalSize(const Files: TFileMetas): Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Files) do
    Result := Result + Files[i].Size;
end;

{ --- server --- }

function LsServerRunning: Boolean;
begin
  Result := Srv <> nil;
end;

procedure LsSetServerAlias(const Alias: AnsiString);
begin
  if Alias <> '' then
    SrvAlias := Alias;
end;

procedure LsSetServerFingerprint(const Fingerprint: AnsiString);
begin
  SrvFingerprint := Fingerprint;
end;

function LsServerPort: Integer;
begin
  Result := SrvPort;
end;

type
  { TFPHTTPServer.Active := True runs the accept loop and returns only when
    the server stops, so it gets a thread of its own }
  TLsServerThread = class(TThread)
  public
    Server: TFPHTTPServer;
    Err: AnsiString;
    procedure Execute; override;
  end;

var
  SrvThread: TLsServerThread = nil;

procedure TLsServerThread.Execute;
begin
  try
    Server.Active := True;
  except
    on E: Exception do
      Err := E.Message;
  end;
end;

function LsServerStart(Port: Integer; Callbacks: TLsServerCallbacks;
                       out Err: AnsiString): Boolean;
var
  s: TFPHTTPServer;
  t: TLsServerThread;
  i: Integer;
begin
  Result := False;
  Err := '';
  if Srv <> nil then
  begin
    Err := 'already running';
    Exit;
  end;
  s := TFPHTTPServer.Create(nil);
  s.Port := Port;
  s.Threaded := True;
  if Handler = nil then
    Handler := TLsHttpHandler.Create;
  s.OnRequest := @Handler.Handle;
  SrvCb := Callbacks;
  SrvPort := Port;
  t := TLsServerThread.Create(True);
  t.Server := s;
  t.FreeOnTerminate := False;
  t.Start;
  { a busy port fails at once: give the bind 300 ms to report }
  for i := 1 to 30 do
  begin
    if t.Finished then Break;
    Sleep(10);
  end;
  if t.Finished then
  begin
    Err := t.Err;
    if Err = '' then Err := 'server stopped';
    t.Free;
    s.Free;
    SrvCb := nil;
    SrvPort := 0;
    Exit;
  end;
  Srv := s;
  SrvThread := t;
  Result := True;
end;

procedure LsServerStop;
begin
  if Srv = nil then Exit;
  { the accept loop may not notice at once; the helper is killed right
    after anyway, so neither the thread nor the server is waited for }
  Srv.Active := False;
  Srv := nil;
  SrvThread := nil;
  SrvCb := nil;
  SrvPort := 0;
end;

initialization
  InitCriticalSection(UploadLock);
finalization
  DoneCriticalSection(UploadLock);
  Uploads.Free;
end.
