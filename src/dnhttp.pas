{ dnhttp — HTTP/HTTPS fetching for the text browser (BROWSER.md).
  Pure logic where possible: no ncurses, no terminal, unit-testable.

  The transfer is delegated to an external `curl`, the same pattern the
  project already uses for archives (bsdtar), SFTP (the OpenSSH client) and
  audio (ffplay/mpg123). DN never sees a TLS certificate. The command is
  resolved from DN_CURL_CMD (the test seam, like DN_SFTP_CMD), then from
  PATH. TUrl does the RFC 3986 reference resolution; the cookie file is a
  Netscape file curl reads and writes; the disk cache keeps a body and its
  headers keyed by the URL. }
unit dnhttp;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  THttpResult = record
    Ok: Boolean;
    Status: Integer;          // HTTP status code, 0 if unknown
    FinalUrl: AnsiString;     // after redirects
    ContentType: AnsiString;  // lower-case, without parameters
    Charset: AnsiString;      // lower-case, '' if none
    Cached: Boolean;
    Body: AnsiString;
    Err: AnsiString;
  end;

  { Parsed URL. Scheme/Host are lower-case; Path/Query/Fragment are kept. }
  TUrl = record
    Scheme: AnsiString;       // 'http', 'https', 'file', 'data', '' (none)
    User: AnsiString;
    Host: AnsiString;
    Port: Integer;            // 0 = default for the scheme
    Path: AnsiString;         // '/...' for http(s), a local path for file
    Query: AnsiString;        // without '?'
    Fragment: AnsiString;     // without '#'
    Valid: Boolean;
  end;

  THttpClient = class
  private
    FUserAgent: AnsiString;
    FTimeout: Integer;        // seconds
    FCacheDir: AnsiString;    // '' disables the cache
    FCookieFile: AnsiString;
    FMaxBody: Int64;          // bytes; 0 = unlimited
    function Fetch(const Method, Url, PostBody, PostType: AnsiString;
                   out R: THttpResult): Boolean;
  public
    constructor Create;
    function Get(const Url: AnsiString; out R: THttpResult): Boolean;
    { POST a form body; never cached }
    function Post(const Url, Body, PostType: AnsiString;
                  out R: THttpResult): Boolean;
    property UserAgent: AnsiString read FUserAgent write FUserAgent;
    property Timeout: Integer read FTimeout write FTimeout;
    property CacheDir: AnsiString read FCacheDir write FCacheDir;
    property CookieFile: AnsiString read FCookieFile write FCookieFile;
    property MaxBody: Int64 read FMaxBody write FMaxBody;
  end;

{ --- URL helpers ------------------------------------------------------- }

function UrlParse(const S: AnsiString): TUrl;
function UrlResolve(const Base, Ref: AnsiString): AnsiString;
function UrlToString(const U: TUrl): AnsiString;
function UrlHostPort(const U: TUrl): AnsiString;
function UrlDecode(const S: AnsiString): AnsiString;
function UrlEncode(const S: AnsiString): AnsiString;
function FormDecode(const S: AnsiString): AnsiString;
function FormEncode(const S: AnsiString): AnsiString;
function UrlScheme(const S: AnsiString): AnsiString;
function IsHttpUrl(const S: AnsiString): Boolean;
function FileUrlToPath(const U: TUrl): AnsiString;
function DefaultPort(const Scheme: AnsiString): Integer;

{ The curl command line for a GET; exported for tests and the status line. }
function CurlGetCmd(const Url, CookieFile, HeaderFile: AnsiString;
                    Timeout: Integer; const UserAgent: AnsiString): AnsiString;
{ HTTP status and final URL from curl's -w tail, or from a header block. }
function StatusFromHeaders(const Headers: AnsiString): Integer;
function HeaderValue(const Headers, Name: AnsiString): AnsiString;
function ParseContentType(const Ct: AnsiString;
                          out Mime, Charset: AnsiString): Boolean;

implementation

uses
  SysUtils, dnvfs;

const
  DefTimeout = 30;
  DefMaxBody = 8 * 1024 * 1024;   // 8 MiB

function DefUa: AnsiString;
begin
  Result := GetEnvironmentVariable('DN_BROWSER_UA');
  if Result = '' then Result := 'dn/1.0 (text browser)';
end;

function IsAlpha(c: AnsiChar): Boolean; inline;
begin
  Result := ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z'));
end;

function IsDigit(c: AnsiChar): Boolean; inline;
begin
  Result := (c >= '0') and (c <= '9');
end;

function IsAlnum(c: AnsiChar): Boolean; inline;
begin
  Result := IsAlpha(c) or IsDigit(c);
end;

function HexVal(c: AnsiChar): Integer;
begin
  case c of
    '0'..'9': Result := Ord(c) - Ord('0');
    'a'..'f': Result := Ord(c) - Ord('a') + 10;
    'A'..'F': Result := Ord(c) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function IsUnreserved(c: AnsiChar): Boolean; inline;
begin
  Result := IsAlnum(c) or (c = '-') or (c = '.') or (c = '_') or (c = '~');
end;

function UrlDecode(const S: AnsiString): AnsiString;
var
  i, n, hi, lo: Integer;
begin
  Result := '';
  i := 1;
  n := Length(S);
  while i <= n do
  begin
    if (S[i] = '%') and (i + 2 <= n) then
    begin
      hi := HexVal(S[i + 1]);
      lo := HexVal(S[i + 2]);
      if (hi >= 0) and (lo >= 0) then
      begin
        Result := Result + AnsiChar(hi * 16 + lo);
        Inc(i, 3);
        Continue;
      end;
    end;
    Result := Result + S[i];
    Inc(i);
  end;
end;

function UrlEncode(const S: AnsiString): AnsiString;
var
  i: Integer;
  c: AnsiChar;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if IsUnreserved(c) then
      Result := Result + c
    else
      Result := Result + '%' + IntToHex(Ord(c), 2);
  end;
end;

function FormDecode(const S: AnsiString): AnsiString;
var
  i: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = '+' then
    begin
      Result := Result + ' ';
      Inc(i);
    end
    else if (S[i] = '%') and (i + 2 <= Length(S)) then
    begin
      Result := Result + UrlDecode(Copy(S, i, 3));
      Inc(i, 3);
    end
    else
    begin
      Result := Result + S[i];
      Inc(i);
    end;
  end;
end;

function FormEncode(const S: AnsiString): AnsiString;
var
  i: Integer;
  c: AnsiChar;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if IsAlnum(c) or (c = '-') or (c = '.') or (c = '_') or (c = '*') then
      Result := Result + c
    else if c = ' ' then
      Result := Result + '+'
    else
      Result := Result + '%' + IntToHex(Ord(c), 2);
  end;
end;

function UrlScheme(const S: AnsiString): AnsiString;
var
  i: Integer;
  c: AnsiChar;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if c = ':' then Exit;
    if not (IsAlnum(c) or (c = '+') or (c = '-') or (c = '.')) then Exit;
  end;
  Result := '';
end;

function DefaultPort(const Scheme: AnsiString): Integer;
begin
  if Scheme = 'http' then Result := 80
  else if Scheme = 'https' then Result := 443
  else Result := 0;
end;

function UrlParse(const S: AnsiString): TUrl;
var
  rest, hostport: AnsiString;
  p, q: Integer;
begin
  Result.Scheme := '';
  Result.User := '';
  Result.Host := '';
  Result.Port := 0;
  Result.Path := '';
  Result.Query := '';
  Result.Fragment := '';
  Result.Valid := False;
  rest := Trim(S);
  if rest = '' then Exit;
  p := Pos(':', rest);
  if p <= 1 then Exit;
  Result.Scheme := LowerCase(Copy(rest, 1, p - 1));
  if Result.Scheme = 'data' then
  begin
    Result.Valid := True;
    Result.Path := Copy(rest, p + 1, MaxInt);
    Exit;
  end;
  if Result.Scheme = 'file' then
  begin
    Result.Valid := True;
    Result.Path := Copy(rest, p + 1, MaxInt);
    if Copy(Result.Path, 1, 2) = '//' then
      Result.Path := Copy(Result.Path, 3, MaxInt);
    q := Pos('/', Result.Path);
    if q > 0 then
    begin
      Result.Host := LowerCase(Copy(Result.Path, 1, q - 1));
      Result.Path := Copy(Result.Path, q, MaxInt);
    end
    else
    begin
      Result.Host := LowerCase(Result.Path);
      Result.Path := '/';
    end;
    Exit;
  end;
  if (Result.Scheme <> 'http') and (Result.Scheme <> 'https') then Exit;
  rest := Copy(rest, p + 3, MaxInt);   // after '://'
  q := Pos('#', rest);
  if q > 0 then
  begin
    Result.Fragment := Copy(rest, q + 1, MaxInt);
    rest := Copy(rest, 1, q - 1);
  end;
  q := Pos('?', rest);
  if q > 0 then
  begin
    Result.Query := Copy(rest, q + 1, MaxInt);
    rest := Copy(rest, 1, q - 1);
  end;
  q := Pos('/', rest);
  if q > 0 then
  begin
    Result.Path := Copy(rest, q, MaxInt);
    rest := Copy(rest, 1, q - 1);
  end
  else
    Result.Path := '/';
  q := Pos('@', rest);
  if q > 0 then
  begin
    Result.User := Copy(rest, 1, q - 1);
    rest := Copy(rest, q + 1, MaxInt);
  end;
  if (Length(rest) > 0) and (rest[1] = '[') then
  begin
    q := Pos(']', rest);
    if q = 0 then Exit;
    Result.Host := LowerCase(Copy(rest, 2, q - 2));
    hostport := Copy(rest, q + 1, MaxInt);
  end
  else
  begin
    q := Pos(':', rest);
    if q > 0 then
    begin
      hostport := Copy(rest, q, MaxInt);
      rest := Copy(rest, 1, q - 1);
    end
    else
      hostport := '';
    Result.Host := LowerCase(rest);
  end;
  if Result.Host = '' then Exit;
  if hostport <> '' then
  begin
    if hostport[1] <> ':' then Exit;
    Result.Port := StrToIntDef(Copy(hostport, 2, MaxInt), 0);
    if Result.Port = 0 then Exit;
  end;
  if Result.Port = 0 then Result.Port := DefaultPort(Result.Scheme);
  Result.Valid := True;
end;

function UrlToString(const U: TUrl): AnsiString;
begin
  if U.Scheme = 'data' then
    Exit('data:' + U.Path);
  if U.Scheme = 'file' then
  begin
    Result := 'file://';
    if U.Host <> '' then Result := Result + U.Host;
    Result := Result + U.Path;
    Exit;
  end;
  Result := U.Scheme + '://';
  if U.User <> '' then Result := Result + U.User + '@';
  Result := Result + U.Host;
  if (U.Port <> 0) and (U.Port <> DefaultPort(U.Scheme)) then
    Result := Result + ':' + IntToStr(U.Port);
  Result := Result + U.Path;
  if U.Query <> '' then Result := Result + '?' + U.Query;
  if U.Fragment <> '' then Result := Result + '#' + U.Fragment;
end;

function UrlHostPort(const U: TUrl): AnsiString;
begin
  Result := U.Host;
  if (U.Port <> 0) and (U.Port <> DefaultPort(U.Scheme)) then
    Result := Result + ':' + IntToStr(U.Port);
end;

function FileUrlToPath(const U: TUrl): AnsiString;
begin
  Result := UrlDecode(U.Path);
end;

function IsHttpUrl(const S: AnsiString): Boolean;
var
  sc: AnsiString;
begin
  sc := UrlScheme(S);
  Result := (sc = 'http') or (sc = 'https');
end;

function MergePaths(const BasePath, Ref: AnsiString): AnsiString;
var
  i: Integer;
begin
  i := Length(BasePath);
  while (i > 0) and (BasePath[i] <> '/') do Dec(i);
  if i = 0 then
    Result := Ref
  else
    Result := Copy(BasePath, 1, i) + Ref;
end;

function RemoveDotSegments(const P: AnsiString): AnsiString;
var
  inp, out, seg: AnsiString;
  i: Integer;
begin
  inp := P;
  out := '';
  while inp <> '' do
  begin
    if Copy(inp, 1, 3) = '../' then
      inp := Copy(inp, 4, MaxInt)
    else if Copy(inp, 1, 2) = './' then
      inp := Copy(inp, 3, MaxInt)
    else if Copy(inp, 1, 3) = '/./' then
      inp := '/' + Copy(inp, 4, MaxInt)
    else if inp = '/.' then
      inp := '/'
    else if Copy(inp, 1, 4) = '/../' then
    begin
      inp := '/' + Copy(inp, 5, MaxInt);
      i := Length(out);
      while (i > 0) and (out[i] <> '/') do Dec(i);
      out := Copy(out, 1, i - 1);
    end
    else if inp = '/..' then
    begin
      inp := '/';
      i := Length(out);
      while (i > 0) and (out[i] <> '/') do Dec(i);
      out := Copy(out, 1, i - 1);
    end
    else if (inp = '.') or (inp = '..') then
      inp := ''
    else
    begin
      if inp[1] = '/' then i := 2 else i := 1;
      while (i <= Length(inp)) and (inp[i] <> '/') do Inc(i);
      seg := Copy(inp, 1, i - 1);
      out := out + seg;
      inp := Copy(inp, i, MaxInt);
    end;
  end;
  Result := out;
end;

function UrlResolve(const Base, Ref: AnsiString): AnsiString;
var
  b, r, t: TUrl;
  refpath: AnsiString;
  q: Integer;
begin
  if Ref = '' then Exit(Base);
  if UrlScheme(Ref) <> '' then
  begin
    r := UrlParse(Ref);
    if r.Valid then
      Exit(UrlToString(r))
    else
      Exit(Ref);
  end;
  b := UrlParse(Base);
  if not b.Valid then
  begin
    if (Ref <> '') and (Ref[1] = '/') then Exit(Ref);
    Exit(Base);
  end;
  FillChar(t, SizeOf(t), 0);
  t.Scheme := b.Scheme;
  t.User := b.User;
  t.Host := b.Host;
  t.Port := b.Port;
  t.Path := '';
  t.Query := '';
  t.Fragment := '';
  t.Valid := True;
  if Ref[1] = '#' then
  begin
    t.Path := b.Path;
    t.Query := b.Query;
    t.Fragment := Copy(Ref, 2, MaxInt);
    Exit(UrlToString(t));
  end;
  if Ref[1] = '?' then
  begin
    t.Path := b.Path;
    t.Query := Copy(Ref, 2, MaxInt);
    Exit(UrlToString(t));
  end;
  refpath := Ref;
  q := Pos('#', refpath);
  if q > 0 then
  begin
    t.Fragment := Copy(refpath, q + 1, MaxInt);
    refpath := Copy(refpath, 1, q - 1);
  end;
  q := Pos('?', refpath);
  if q > 0 then
  begin
    t.Query := Copy(refpath, q + 1, MaxInt);
    refpath := Copy(refpath, 1, q - 1);
  end;
  if Copy(refpath, 1, 2) = '//' then
  begin
    r := UrlParse(t.Scheme + ':' + refpath);
    if r.Valid then Exit(UrlToString(r));
  end;
  if refpath = '' then
  begin
    t.Path := b.Path;
    Exit(UrlToString(t));
  end;
  if refpath[1] = '/' then
    t.Path := RemoveDotSegments(refpath)
  else
    t.Path := RemoveDotSegments(MergePaths(b.Path, refpath));
  Result := UrlToString(t);
end;

function HeaderValue(const Headers, Name: AnsiString): AnsiString;
var
  L: TStringList;
  i, p: Integer;
  line, key: AnsiString;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := Headers;
    key := LowerCase(Name) + ':';
    for i := 0 to L.Count - 1 do
    begin
      line := L[i];
      p := Pos(':', line);
      if p = 0 then Continue;
      if LowerCase(Copy(line, 1, p)) = key then
        Exit(Trim(Copy(line, p + 1, MaxInt)));
    end;
  finally
    L.Free;
  end;
end;

function StatusFromHeaders(const Headers: AnsiString): Integer;
var
  L: TStringList;
  i, p, sp: Integer;
  line, tail: AnsiString;
  last: Integer;
begin
  Result := 0;
  last := 0;
  L := TStringList.Create;
  try
    L.Text := Headers;
    for i := 0 to L.Count - 1 do
    begin
      line := L[i];
      if Copy(line, 1, 5) <> 'HTTP/' then Continue;
      p := Pos(' ', line);
      if p = 0 then Continue;
      tail := Copy(line, p + 1, MaxInt);
      sp := Pos(' ', tail);
      if sp > 0 then tail := Copy(tail, 1, sp - 1);
      last := StrToIntDef(Trim(tail), 0);
    end;
  finally
    L.Free;
  end;
  Result := last;
end;

function ParseContentType(const Ct: AnsiString;
                          out Mime, Charset: AnsiString): Boolean;
var
  parts: TStringList;
  i, p: Integer;
  s: AnsiString;
begin
  Mime := '';
  Charset := '';
  parts := TStringList.Create;
  try
    parts.Delimiter := ';';
    parts.StrictDelimiter := True;
    parts.DelimitedText := Ct;
    if parts.Count > 0 then
      Mime := LowerCase(Trim(parts[0]));
    for i := 1 to parts.Count - 1 do
    begin
      s := LowerCase(Trim(parts[i]));
      p := Pos('charset=', s);
      if p = 1 then
      begin
        Charset := Trim(Copy(s, p + 8, MaxInt));
        if (Length(Charset) >= 2) and (Charset[1] = '"') then
          Charset := Trim(Copy(Charset, 2, Length(Charset) - 2));
      end;
    end;
  finally
    parts.Free;
  end;
  Result := True;
end;

{ --- cache ------------------------------------------------------------- }

function CacheKey(const Url: AnsiString): AnsiString;
var
  h: QWord;
  i: Integer;
begin
  { FNV-1a 64: no dependency, stable across runs, fine for a cache key }
  h := 14695981039346656037;
  for i := 1 to Length(Url) do
  begin
    h := h xor QWord(Ord(Url[i]));
    h := h * 1099511628211;
  end;
  Result := IntToHex(h, 16);
end;

function CacheBodyPath(const Dir, Url: AnsiString): AnsiString;
begin
  Result := IncludeTrailingPathDelimiter(Dir) + CacheKey(Url) + '.body';
end;

function CacheHeadPath(const Dir, Url: AnsiString): AnsiString;
begin
  Result := IncludeTrailingPathDelimiter(Dir) + CacheKey(Url) + '.head';
end;

function ReadFileText(const Path: AnsiString): AnsiString;
var
  L: TStringList;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    Result := L.Text;
  except
    Result := '';
  end;
  L.Free;
end;

procedure WriteFileText(const Path, S: AnsiString);
var
  L: TStringList;
begin
  try
    ForceDirectories(ExtractFileDir(Path));
    L := TStringList.Create;
    try
      L.Text := S;
      L.SaveToFile(Path);
    finally
      L.Free;
    end;
  except
    { non-fatal }
  end;
end;

function CacheRead(const Dir, Url: AnsiString;
                   out Body, Head: AnsiString): Boolean;
begin
  Result := False;
  if Dir = '' then Exit;
  if not FileExists(CacheBodyPath(Dir, Url)) then Exit;
  Body := ReadFileText(CacheBodyPath(Dir, Url));
  Head := ReadFileText(CacheHeadPath(Dir, Url));
  Result := True;
end;

procedure CacheWrite(const Dir, Url, Body, Head: AnsiString);
begin
  if Dir = '' then Exit;
  WriteFileText(CacheBodyPath(Dir, Url), Body);
  WriteFileText(CacheHeadPath(Dir, Url), Head);
end;

{ --- curl -------------------------------------------------------------- }

function ShellQuote(const S: AnsiString): AnsiString;
begin
  Result := AnsiQuotedStr(S, '''');
end;

function CurlGetCmd(const Url, CookieFile, HeaderFile: AnsiString;
                    Timeout: Integer; const UserAgent: AnsiString): AnsiString;
begin
  Result := 'curl -sS -L --compressed --max-time ' + IntToStr(Timeout);
  if UserAgent <> '' then
    Result := Result + ' -A ' + ShellQuote(UserAgent);
  if CookieFile <> '' then
    Result := Result + ' --cookie ' + ShellQuote(CookieFile) +
              ' --cookie-jar ' + ShellQuote(CookieFile);
  if HeaderFile <> '' then
    Result := Result + ' -D ' + ShellQuote(HeaderFile);
  Result := Result + ' -w ' + ShellQuote('%{http_code} %{url_effective}') +
            ' ' + ShellQuote(Url);
end;

function CurlCmd: AnsiString;
begin
  Result := GetEnvironmentVariable('DN_CURL_CMD');
  if Result = '' then Result := 'curl';
end;

function TempPath(const Suffix: AnsiString): AnsiString;
begin
  Result := GetTempDir + 'dnhttp-' + IntToStr(GetProcessID) + '-' +
            IntToStr(Random(1000000)) + Suffix;
end;

constructor THttpClient.Create;
begin
  inherited Create;
  FUserAgent := DefUa;
  FTimeout := DefTimeout;
  FMaxBody := DefMaxBody;
  FCacheDir := GetEnvironmentVariable('DN_BROWSER_CACHE_DIR');
  if FCacheDir = '' then
  begin
    FCacheDir := GetEnvironmentVariable('XDG_CACHE_HOME');
    if FCacheDir = '' then
      FCacheDir := GetEnvironmentVariable('HOME') + '/.cache';
    FCacheDir := FCacheDir + '/dnfpc/browser';
  end;
  FCookieFile := IncludeTrailingPathDelimiter(FCacheDir) + 'cookies';
end;

function THttpClient.Get(const Url: AnsiString; out R: THttpResult): Boolean;
begin
  Result := Fetch('GET', Url, '', '', R);
end;

function THttpClient.Post(const Url, Body, PostType: AnsiString;
                          out R: THttpResult): Boolean;
begin
  Result := Fetch('POST', Url, Body, PostType, R);
end;

function THttpClient.Fetch(const Method, Url, PostBody, PostType: AnsiString;
                           out R: THttpResult): Boolean;
var
  head, outfile, postfile, cmd, outp, tail: AnsiString;
  rc, sp, status: Integer;
  body, ctype, eff: AnsiString;
  mime, charset: AnsiString;
begin
  Result := False;
  R.Ok := False;
  R.Status := 0;
  R.FinalUrl := Url;
  R.ContentType := '';
  R.Charset := '';
  R.Cached := False;
  R.Body := '';
  R.Err := '';
  if not IsHttpUrl(Url) then
  begin
    R.Err := 'not an http(s) url';
    Exit;
  end;

  if Method = 'GET' then
    if CacheRead(FCacheDir, Url, body, head) then
    begin
      ParseContentType(HeaderValue(head, 'content-type'), mime, charset);
      R.Ok := True;
      R.Status := 200;
      R.Cached := True;
      R.Body := body;
      R.ContentType := mime;
      R.Charset := charset;
      R.FinalUrl := Url;
      Exit(True);
    end;

  head := TempPath('.head');
  outfile := TempPath('.body');
  postfile := '';
  cmd := CurlCmd + ' -sS -L --compressed --max-time ' + IntToStr(FTimeout);
  if FUserAgent <> '' then
    cmd := cmd + ' -A ' + ShellQuote(FUserAgent);
  if FCookieFile <> '' then
    cmd := cmd + ' --cookie ' + ShellQuote(FCookieFile) +
           ' --cookie-jar ' + ShellQuote(FCookieFile);
  cmd := cmd + ' -D ' + ShellQuote(head);
  if Method = 'POST' then
  begin
    postfile := TempPath('.post');
    WriteFileText(postfile, PostBody);
    cmd := cmd + ' --data-binary @' + ShellQuote(postfile) +
           ' -H ' + ShellQuote('Content-Type: ' + PostType);
  end;
  cmd := cmd + ' -o ' + ShellQuote(outfile) +
         ' -w ' + ShellQuote('%{http_code} %{url_effective}') +
         ' ' + ShellQuote(Url);

  rc := RunCapture(cmd, outp);
  { curl's -w tail is the last line: "<status> <url_effective>" }
  tail := Trim(outp);
  sp := Pos(' ', tail);
  status := 0;
  eff := '';
  if sp > 0 then
  begin
    status := StrToIntDef(Copy(tail, 1, sp - 1), 0);
    eff := Trim(Copy(tail, sp + 1, MaxInt));
  end
  else
    status := StrToIntDef(tail, 0);

  if (rc <> 0) and (status = 0) then
  begin
    R.Err := 'curl failed (rc=' + IntToStr(rc) + ')';
    if outp <> '' then R.Err := R.Err + ': ' + Trim(outp);
    DeleteFile(head);
    DeleteFile(outfile);
    if postfile <> '' then DeleteFile(postfile);
    Exit;
  end;

  if not FileExists(outfile) then
  begin
    R.Err := 'no response body';
    DeleteFile(head);
    if postfile <> '' then DeleteFile(postfile);
    Exit;
  end;

  body := ReadFileText(outfile);
  if (FMaxBody > 0) and (Length(body) > FMaxBody) then
    body := Copy(body, 1, FMaxBody);

  ctype := ReadFileText(head);
  ParseContentType(HeaderValue(ctype, 'content-type'), mime, charset);

  R.Ok := (status >= 200) and (status < 400);
  R.Status := status;
  R.Body := body;
  R.ContentType := mime;
  R.Charset := charset;
  if eff <> '' then R.FinalUrl := eff;

  if R.Ok and (Method = 'GET') then
    CacheWrite(FCacheDir, Url, body, ctype);

  DeleteFile(head);
  DeleteFile(outfile);
  if postfile <> '' then DeleteFile(postfile);
  Result := R.Ok;
end;

end.
