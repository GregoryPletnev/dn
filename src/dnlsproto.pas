{ dnlsproto — LocalSend v2 protocol models and JSON codec (LOCALSEND.md).
  Pure logic: no sockets, no ncurses. Parses and builds the JSON bodies of the
  LocalSend HTTP API, and the line protocol between the helper process and the
  main dn process. Unit-tested in tests/unittests.pas.

  Protocol reference: https://github.com/localsend/localsend — /api/localsend/v2 }

unit dnlsproto;

{$mode objfpc}{$H+}

interface

uses
  Classes;

const
  LsProtocolVersion = '2.1';
  LsDefaultPort = 53317;
  LsMulticastAddr = '224.0.0.167';
  LsApiPrefix = '/api/localsend/v2';

type
  { a file announced in a prepare-upload or upload request }
  TFileMeta = record
    Id: AnsiString;          // file id, unique within the request
    FileName: AnsiString;
    Size: Int64;
    FileType: AnsiString;    // 'file' or 'text'
    Mime: AnsiString;        // optional MIME type
  end;
  TFileMetas = array of TFileMeta;

  TDeviceInfo = record
    Alias: AnsiString;        // device name shown to peers
    Version: AnsiString;      // protocol version
    DeviceModel: AnsiString;
    DeviceType: AnsiString;   // mobile, desktop, headless, web
    Fingerprint: AnsiString;   // TLS certificate fingerprint
    Port: Integer;
    Protocol: AnsiString;     // 'http' or 'https'
  end;

  TUploadRequest = record
    SessionId: AnsiString;
    Info: TDeviceInfo;
    Files: TFileMetas;
  end;

  TPrepareResponse = record
    SessionId: AnsiString;
    Accepted: array of AnsiString;   // file ids the receiver will accept
  end;

  { one event line on the helper <-> main pipe (newline-delimited JSON) }
  TLsEventKind = (leIncoming, leProgress, leDone, leError, lePeer, leOk);
  TLsEvent = record
    Kind: TLsEventKind;
    SessionId: AnsiString;
    PeerName: AnsiString;
    PeerAddr: AnsiString;
    Files: TFileMetas;
    BytesDone: Int64;
    BytesTotal: Int64;
    Err: AnsiString;
  end;

{ --- JSON codec --- }

function BuildDeviceInfo(const Info: TDeviceInfo): AnsiString;
function ParseDeviceInfo(const Json: AnsiString; out Info: TDeviceInfo): Boolean;

function BuildUploadRequest(const Req: TUploadRequest): AnsiString;
function ParseUploadRequest(const Json: AnsiString; out Req: TUploadRequest): Boolean;

function BuildPrepareResponse(const Resp: TPrepareResponse): AnsiString;
function ParsePrepareResponse(const Json: AnsiString;
                              out Resp: TPrepareResponse): Boolean;

{ request to accept/reject an incoming session, written to the helper pipe }
function BuildDecision(const SessionId: AnsiString; Accept: Boolean): AnsiString;

{ --- event line protocol (helper -> main) --- }

function BuildEventLine(const Ev: TLsEvent): AnsiString;
function ParseEventLine(const Line: AnsiString; out Ev: TLsEvent): Boolean;

{ file type hint from the extension, as LocalSend sends it }
function FileTypeOf(const FileName: AnsiString): AnsiString;

{ a safe default local filename for a remote FileName: strips any directory
  part and rejects empty or dot names }
function SafeLocalName(const FileName: AnsiString): AnsiString;

implementation

uses
  SysUtils, fpjson, jsonparser;

function FileTypeOf(const FileName: AnsiString): AnsiString;
begin
  if SameText(ExtractFileExt(FileName), '.txt') then
    Result := 'text'
  else
    Result := 'file';
end;

function SafeLocalName(const FileName: AnsiString): AnsiString;
var
  s: AnsiString;
  i: Integer;
begin
  s := FileName;
  { a peer may send a path: keep only the last component }
  for i := Length(s) downto 1 do
    if (s[i] = '/') or (s[i] = '\') then
    begin
      s := Copy(s, i + 1, Length(s) - i);
      Break;
    end;
  { strip control characters }
  Result := '';
  for i := 1 to Length(s) do
    if s[i] >= ' ' then
      Result := Result + s[i];
  if (Result = '') or (Result = '.') or (Result = '..') then
    Result := 'unnamed';
end;

function BuildDeviceInfo(const Info: TDeviceInfo): AnsiString;
var
  o: TJSONObject;
begin
  o := TJSONObject.Create;
  try
    o.Add('alias', Info.Alias);
    o.Add('version', Info.Version);
    o.Add('deviceModel', Info.DeviceModel);
    o.Add('deviceType', Info.DeviceType);
    if Info.Fingerprint <> '' then
      o.Add('fingerprint', Info.Fingerprint);
    if Info.Port > 0 then
      o.Add('port', Info.Port);
    if Info.Protocol <> '' then
      o.Add('protocol', Info.Protocol);
    Result := o.AsJSON;
  finally
    o.Free;
  end;
end;

function GetStr(const o: TJSONObject; const Name: AnsiString): AnsiString;
begin
  if o.Find(Name) <> nil then
    Result := o.Get(Name, '')
  else
    Result := '';
end;

function ParseDeviceInfo(const Json: AnsiString; out Info: TDeviceInfo): Boolean;
var
  d: TJSONData;
  o: TJSONObject;
begin
  Result := False;
  Info.Alias := ''; Info.Version := ''; Info.DeviceModel := '';
  Info.DeviceType := ''; Info.Fingerprint := ''; Info.Port := 0;
  Info.Protocol := '';
  try
    d := GetJSON(Json);
  except
    Exit;
  end;
  try
    if not (d is TJSONObject) then Exit;
    o := TJSONObject(d);
    Info.Alias := GetStr(o, 'alias');
    Info.Version := GetStr(o, 'version');
    Info.DeviceModel := GetStr(o, 'deviceModel');
    Info.DeviceType := GetStr(o, 'deviceType');
    Info.Fingerprint := GetStr(o, 'fingerprint');
    Info.Protocol := GetStr(o, 'protocol');
    if o.Find('port') <> nil then
      Info.Port := o.Get('port', 0);
    Result := True;
  finally
    d.Free;
  end;
end;

function BuildUploadRequest(const Req: TUploadRequest): AnsiString;
var
  o, info, files, f: TJSONObject;
  i: Integer;
begin
  o := TJSONObject.Create;
  try
    o.Add('sessionId', Req.SessionId);
    info := TJSONObject.Create;
    info.Add('alias', Req.Info.Alias);
    info.Add('version', Req.Info.Version);
    info.Add('deviceModel', Req.Info.DeviceModel);
    info.Add('deviceType', Req.Info.DeviceType);
    if Req.Info.Fingerprint <> '' then
      info.Add('fingerprint', Req.Info.Fingerprint);
    if Req.Info.Port > 0 then
      info.Add('port', Req.Info.Port);
    if Req.Info.Protocol <> '' then
      info.Add('protocol', Req.Info.Protocol);
    o.Add('info', info);
    files := TJSONObject.Create;
    for i := 0 to High(Req.Files) do
    begin
      f := TJSONObject.Create;
      f.Add('id', Req.Files[i].Id);
      f.Add('fileName', Req.Files[i].FileName);
      f.Add('size', Req.Files[i].Size);
      f.Add('fileType', Req.Files[i].FileType);
      if Req.Files[i].Mime <> '' then
        f.Add('mimeType', Req.Files[i].Mime);
      files.Add(Req.Files[i].Id, f);
    end;
    o.Add('files', files);
    Result := o.AsJSON;
  finally
    o.Free;
  end;
end;

procedure ParseFiles(const o: TJSONObject; var Files: TFileMetas);
var
  fd: TJSONData;
  fo: TJSONObject;
  i: Integer;
  key: AnsiString;
  fm: TFileMeta;
begin
  SetLength(Files, 0);
  fd := o.Find('files');
  if (fd = nil) or not (fd is TJSONObject) then Exit;
  fo := TJSONObject(fd);
  for i := 0 to fo.Count - 1 do
  begin
    if not (fo.Items[i].JSONType = jtObject) then Continue;
    key := fo.Names[i];
    fm.Id := key;
    fm.FileName := GetStr(TJSONObject(fo.Items[i]), 'fileName');
    fm.Size := TJSONObject(fo.Items[i]).Get('size', Int64(0));
    fm.FileType := GetStr(TJSONObject(fo.Items[i]), 'fileType');
    fm.Mime := GetStr(TJSONObject(fo.Items[i]), 'mimeType');
    SetLength(Files, Length(Files) + 1);
    Files[High(Files)] := fm;
  end;
end;

function ParseUploadRequest(const Json: AnsiString; out Req: TUploadRequest): Boolean;
var
  d: TJSONData;
  o, io: TJSONObject;
begin
  Result := False;
  Req.SessionId := '';
  SetLength(Req.Files, 0);
  Req.Info.Alias := ''; Req.Info.Version := ''; Req.Info.DeviceModel := '';
  Req.Info.DeviceType := ''; Req.Info.Fingerprint := '';
  Req.Info.Port := 0; Req.Info.Protocol := '';
  try
    d := GetJSON(Json);
  except
    Exit;
  end;
  try
    if not (d is TJSONObject) then Exit;
    o := TJSONObject(d);
    Req.SessionId := GetStr(o, 'sessionId');
    if o.Find('info') <> nil then
    begin
      if o.Find('info').JSONType = jtObject then
      begin
        io := TJSONObject(o.Find('info'));
        Req.Info.Alias := GetStr(io, 'alias');
        Req.Info.Version := GetStr(io, 'version');
        Req.Info.DeviceModel := GetStr(io, 'deviceModel');
        Req.Info.DeviceType := GetStr(io, 'deviceType');
        Req.Info.Fingerprint := GetStr(io, 'fingerprint');
        Req.Info.Protocol := GetStr(io, 'protocol');
        if io.Find('port') <> nil then
          Req.Info.Port := io.Get('port', 0);
      end;
    end;
    ParseFiles(o, Req.Files);
    Result := True;
  finally
    d.Free;
  end;
end;

function BuildPrepareResponse(const Resp: TPrepareResponse): AnsiString;
var
  o, files, f: TJSONObject;
  i: Integer;
begin
  o := TJSONObject.Create;
  try
    o.Add('sessionId', Resp.SessionId);
    files := TJSONObject.Create;
    for i := 0 to High(Resp.Accepted) do
    begin
      f := TJSONObject.Create;
      f.Add('id', Resp.Accepted[i]);
      files.Add(Resp.Accepted[i], f);
    end;
    o.Add('files', files);
    Result := o.AsJSON;
  finally
    o.Free;
  end;
end;

function ParsePrepareResponse(const Json: AnsiString;
                              out Resp: TPrepareResponse): Boolean;
var
  d: TJSONData;
  o, fo: TJSONObject;
  i: Integer;
begin
  Result := False;
  Resp.SessionId := '';
  SetLength(Resp.Accepted, 0);
  try
    d := GetJSON(Json);
  except
    Exit;
  end;
  try
    if not (d is TJSONObject) then Exit;
    o := TJSONObject(d);
    Resp.SessionId := GetStr(o, 'sessionId');
    if o.Find('files') <> nil then
      if o.Find('files').JSONType = jtObject then
      begin
        fo := TJSONObject(o.Find('files'));
        for i := 0 to fo.Count - 1 do
        begin
          SetLength(Resp.Accepted, Length(Resp.Accepted) + 1);
          Resp.Accepted[High(Resp.Accepted)] := fo.Names[i];
        end;
      end;
    Result := True;
  finally
    d.Free;
  end;
end;

function BuildDecision(const SessionId: AnsiString; Accept: Boolean): AnsiString;
var
  o: TJSONObject;
begin
  o := TJSONObject.Create;
  try
    o.Add('kind', 'ok');
    o.Add('sessionId', SessionId);
    o.Add('accept', Accept);
    Result := o.AsJSON;
  finally
    o.Free;
  end;
end;

function KindName(const K: TLsEventKind): AnsiString;
begin
  case K of
    leIncoming: Result := 'incoming';
    leProgress: Result := 'progress';
    leDone: Result := 'done';
    leError: Result := 'error';
    lePeer: Result := 'peer';
    leOk: Result := 'ok';
  else
    Result := 'error';
  end;
end;

function KindOf(const Name: AnsiString): TLsEventKind;
begin
  if Name = 'incoming' then Result := leIncoming
  else if Name = 'progress' then Result := leProgress
  else if Name = 'done' then Result := leDone
  else if Name = 'peer' then Result := lePeer
  else if Name = 'ok' then Result := leOk
  else Result := leError;
end;

function BuildEventLine(const Ev: TLsEvent): AnsiString;
var
  o, files, f: TJSONObject;
  i: Integer;
begin
  o := TJSONObject.Create;
  try
    o.Add('kind', KindName(Ev.Kind));
    if Ev.SessionId <> '' then o.Add('sessionId', Ev.SessionId);
    if Ev.PeerName <> '' then o.Add('peerName', Ev.PeerName);
    if Ev.PeerAddr <> '' then o.Add('peerAddr', Ev.PeerAddr);
    if Ev.BytesTotal > 0 then
    begin
      o.Add('bytesDone', Ev.BytesDone);
      o.Add('bytesTotal', Ev.BytesTotal);
    end;
    if Ev.Err <> '' then o.Add('err', Ev.Err);
    if Length(Ev.Files) > 0 then
    begin
      files := TJSONObject.Create;
      for i := 0 to High(Ev.Files) do
      begin
        f := TJSONObject.Create;
        f.Add('id', Ev.Files[i].Id);
        f.Add('fileName', Ev.Files[i].FileName);
        f.Add('size', Ev.Files[i].Size);
        f.Add('fileType', Ev.Files[i].FileType);
        files.Add(Ev.Files[i].Id, f);
      end;
      o.Add('files', files);
    end;
    Result := o.AsJSON;
  finally
    o.Free;
  end;
end;

function ParseEventLine(const Line: AnsiString; out Ev: TLsEvent): Boolean;
var
  d: TJSONData;
  o: TJSONObject;
begin
  Result := False;
  Ev.Kind := leError;
  Ev.SessionId := ''; Ev.PeerName := ''; Ev.PeerAddr := '';
  Ev.Err := ''; Ev.BytesDone := 0; Ev.BytesTotal := 0;
  SetLength(Ev.Files, 0);
  if Trim(Line) = '' then Exit;
  try
    d := GetJSON(Line);
  except
    Exit;
  end;
  try
    if not (d is TJSONObject) then Exit;
    o := TJSONObject(d);
    Ev.Kind := KindOf(GetStr(o, 'kind'));
    Ev.SessionId := GetStr(o, 'sessionId');
    Ev.PeerName := GetStr(o, 'peerName');
    Ev.PeerAddr := GetStr(o, 'peerAddr');
    Ev.Err := GetStr(o, 'err');
    if o.Find('bytesDone') <> nil then Ev.BytesDone := o.Get('bytesDone', Int64(0));
    if o.Find('bytesTotal') <> nil then Ev.BytesTotal := o.Get('bytesTotal', Int64(0));
    ParseFiles(o, Ev.Files);
    Result := True;
  finally
    d.Free;
  end;
end;

end.
