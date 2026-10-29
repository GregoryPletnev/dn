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
                     out Sent: Integer; out Res: TLsHttpResult): Boolean;

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

implementation

uses
  SysUtils, fphttpclient, ssockets;

var
  Srv: TFPHTTPServer = nil;
  SrvPort: Integer = 0;
  RecvDir: AnsiString = '';
  SrvAlias: AnsiString = 'DN';
  SrvCb: TLsServerCallbacks = nil;
  Handler: TLsHttpHandler = nil;

function AcceptedContains(const Resp: TPrepareResponse;
                          const Id: AnsiString): Boolean; forward;
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
  sessionId, fileId, dst, name: AnsiString;
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
  name := sessionId + '_' + fileId;
  dst := IncludeTrailingPathDelimiter(RecvDir) + name;
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
  info: TDeviceInfo;
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

  if (method = 'GET') and (path = LsApiPrefix + '/info') then
  begin
    info.Alias := SrvAlias;
    info.Version := LsProtocolVersion;
    info.DeviceModel := 'DN - DataNavigator';
    info.DeviceType := 'desktop';
    info.Fingerprint := '';
    info.Port := SrvPort;
    info.Protocol := 'http';
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
    dec := udAccept;
    if (SrvCb <> nil) and Assigned(SrvCb.OnDecision) then
      dec := SrvCb.OnDecision(req);
    resp.SessionId := req.SessionId;
    SetLength(resp.Accepted, 0);
    if dec = udAccept then
      for i := 0 to High(req.Files) do
      begin
        SetLength(resp.Accepted, Length(resp.Accepted) + 1);
        resp.Accepted[High(resp.Accepted)] := req.Files[i].Id;
      end;
    AResponse.Code := 200;
    AResponse.Content := BuildPrepareResponse(resp);
    Exit;
  end;

  if (method = 'PUT') and (path = LsApiPrefix + '/upload') then
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
function PutFile(c: TFPHTTPClient; const Url, SessionId, FileId: AnsiString;
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
    url2 := Url + '?sessionId=' + SessionId + '&fileId=' + FileId;
    c.RequestHeaders.Clear;
    c.RequestBody := st;
    c.AddHeader('Content-Type', 'application/octet-stream');
    try
      c.HTTPMethod('PUT', url2, st, []);
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

function LsSendFiles(const Base: AnsiString; const Info: TDeviceInfo;
                     const SrcFiles: TFileMetas;
                     Progress: TLsProgressFn;
                     out Sent: Integer; out Res: TLsHttpResult): Boolean;
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
  SetLength(req.Files, Length(SrcFiles));
  for i := 0 to High(SrcFiles) do
    req.Files[i] := SrcFiles[i];

  c := TFPHTTPClient.Create(nil);
  try
    c.ConnectTimeout := 5000;
    c.IOTimeout := 30000;
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
                     req.Files[i].FileName, Progress, Res) then
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

function LsServerPort: Integer;
begin
  Result := SrvPort;
end;

function LsServerStart(Port: Integer; Callbacks: TLsServerCallbacks;
                       out Err: AnsiString): Boolean;
var
  srv: TFPHTTPServer;
begin
  Result := False;
  Err := '';
  srv := nil;
  if Srv <> nil then
  begin
    Err := 'already running';
    Exit;
  end;
  srv := TFPHTTPServer.Create(nil);
  srv.Port := Port;
  srv.Threaded := True;
  if Handler = nil then
    Handler := TLsHttpHandler.Create;
  srv.OnRequest := @Handler.Handle;
  try
    srv.Active := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      srv.Free;
      Exit;
    end;
  end;
  Srv := srv;
  SrvPort := Port;
  Result := True;
end;

procedure LsServerStop;
begin
  if Srv = nil then Exit;
  Srv.Active := False;
  Srv.Free;
  Srv := nil;
  SrvPort := 0;
end;

end.
