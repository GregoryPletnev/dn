{ dnjs — the external JavaScript bridge for the text browser (BROWSER.md).
  Pure logic: no ncurses, no terminal, fully unit-testable.

  DN does not embed a JS engine. The scripts of a page run in an external
  process (deno, node, quickjs or d8), and the bridge exchanges a serialized
  DOM with it over a temp file. The external process owns the GC and the
  event loop; DN stays synchronous and single-threaded.

  The flat DOM is a JSON array of nodes in document order:
    [{"id":0,"parent":-1,"tag":"#document"},
     {"id":1,"parent":0,"tag":"html","attrs":{...}},
     {"id":2,"parent":1,"tag":"#text","text":"hi"}]
  A child always follows its parent, so the child rebuilds the tree in one
  pass. The shim (shipped as a string, written to a temp file at Start)
  rebuilds a minimal DOM, runs the page scripts in order, and serializes the
  DOM back. }
unit dnjs;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnhtml;

type
  TBrowserJs = class
  private
    FCmd: AnsiString;        // resolved engine command, '' if off
    FTimeout: Integer;       // milliseconds
    FMaxNodes: Integer;      // node cap
    FShimPath: AnsiString;   // the shim file, written at ResolveEngine
  public
    constructor Create;
    destructor Destroy; override;
    { Resolve the engine from DN_JS_CMD, then deno, node, quickjs, d8.
      Returns '' when no engine is present; the bridge is then off. }
    function ResolveEngine: AnsiString;
    { Run the page's scripts on the document. On success Doc is replaced in
      place with the post-script DOM; on failure Doc is unchanged and Err
      explains why. }
    function ApplyDom(Doc: TDomDoc; out Err: AnsiString): Boolean;
    property EngineCmd: AnsiString read FCmd;
    property Timeout: Integer read FTimeout write FTimeout;
    property MaxNodes: Integer read FMaxNodes write FMaxNodes;
  end;

{ --- the flat DOM (exported for tests) --------------------------------- }

function SerializeDom(Doc: TDomDoc): AnsiString;
function DeserializeDom(const Json: AnsiString): TDomDoc;

{ --- JSON helpers (exported for tests) --------------------------------- }

function JsonEscape(const S: AnsiString): AnsiString;
function JsonUnescape(const S: AnsiString): AnsiString;
function JsonGetString(const Json, Key: AnsiString): AnsiString;

{ --- the shim source --------------------------------------------------- }

function ShimSource: AnsiString;

implementation

uses
  SysUtils, dnvfs;

const
  DefTimeout = 3000;
  DefMaxNodes = 20000;

{ --- JSON helpers ------------------------------------------------------ }

function JsonEscape(const S: AnsiString): AnsiString;
var
  i: Integer;
  c: AnsiChar;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8:  Result := Result + '\b';
      #9:  Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if Ord(c) < 32 then
        Result := Result + '\u' + IntToHex(Ord(c), 4)
      else
        Result := Result + c;
    end;
  end;
end;

function JsonUnescape(const S: AnsiString): AnsiString;
var
  i, n: Integer;
  c: AnsiChar;
begin
  Result := '';
  i := 1;
  n := Length(S);
  while i <= n do
  begin
    if (S[i] = '\') and (i < n) then
    begin
      c := S[i + 1];
      case c of
        '"': Result := Result + '"';
        '\': Result := Result + '\';
        '/': Result := Result + '/';
        'b': Result := Result + #8;
        't': Result := Result + #9;
        'n': Result := Result + #10;
        'f': Result := Result + #12;
        'r': Result := Result + #13;
        'u':
          begin
            Result := Result + AnsiChar(StrToIntDef('$' + Copy(S, i + 2, 4), 63));
            Inc(i, 4);
          end;
      else
        Result := Result + c;
      end;
      Inc(i, 2);
      Continue;
    end;
    Result := Result + S[i];
    Inc(i);
  end;
end;

{ --- small shell/file helpers ------------------------------------------- }

function ShellQuote(const S: AnsiString): AnsiString;
begin
  Result := AnsiQuotedStr(S, #39);
end;

procedure WriteFileText(const Path, S: AnsiString);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := S;
    L.SaveToFile(Path);
  finally
    L.Free;
  end;
end;

{ --- flat DOM ---------------------------------------------------------- }

var
  NextId: Integer = 0;

procedure AssignIds(N: TDomNode);
var
  i: Integer;
begin
  N.Id := NextId;
  Inc(NextId);
  for i := 0 to High(N.Children) do
    AssignIds(N.Children[i]);
end;

function SerializeDom(Doc: TDomDoc): AnsiString;
var
  L: TStringList;

  procedure Walk(N: TDomNode);
  var
    i: Integer;
    s, attrs: AnsiString;
  begin
    s := '{"id":' + IntToStr(N.Id);
    if N.Parent <> nil then
      s := s + ',"parent":' + IntToStr(N.Parent.Id)
    else
      s := s + ',"parent":-1';
    case N.Kind of
      nkDocument: s := s + ',"tag":"#document"';
      nkText:     s := s + ',"tag":"#text","text":"' + JsonEscape(N.Text) + '"';
      nkComment:  s := s + ',"tag":"#comment"';
    else
      begin
        s := s + ',"tag":"' + JsonEscape(N.Tag) + '"';
        attrs := '';
        for i := 0 to High(N.Attrs) do
        begin
          if attrs <> '' then attrs := attrs + ',';
          attrs := attrs + '"' + JsonEscape(N.Attrs[i].Name) + '":"' +
                   JsonEscape(N.Attrs[i].Value) + '"';
        end;
        s := s + ',"attrs":{' + attrs + '}';
      end;
    end;
    s := s + '}';
    L.Add(s);
    for i := 0 to High(N.Children) do
      Walk(N.Children[i]);
  end;

var
  i: Integer;
  all: AnsiString;
begin
  L := TStringList.Create;
  try
    NextId := 0;
    if Doc.Root <> nil then
      AssignIds(Doc.Root);
    Walk(Doc.Root);
    all := '';
    for i := 0 to L.Count - 1 do
    begin
      if all <> '' then all := all + ',';
      all := all + L[i];
    end;
    Result := '[' + all + ']';
  finally
    L.Free;
  end;
end;

{ Find the substring of a JSON object value by key, or '' }
function JsonRawValue(const Json, Key: AnsiString): AnsiString;
var
  pat: AnsiString;
  p, depth: Integer;
  c: AnsiChar;
  start: Integer;
begin
  Result := '';
  pat := '"' + Key + '"';
  p := Pos(pat, Json);
  if p = 0 then Exit;
  p := p + Length(pat);
  while (p <= Length(Json)) and (Json[p] <> ':') do Inc(p);
  if p > Length(Json) then Exit;
  Inc(p);
  while (p <= Length(Json)) and
        ((Json[p] = ' ') or (Json[p] = #9) or (Json[p] = #10) or
         (Json[p] = #13)) do Inc(p);
  if p > Length(Json) then Exit;
  if Json[p] = '"' then
  begin
    start := p;
    Inc(p);
    while p <= Length(Json) do
    begin
      if Json[p] = '\' then
        Inc(p, 2)
      else if Json[p] = '"' then
      begin
        Inc(p);
        Break;
      end
      else
        Inc(p);
    end;
    Exit(Copy(Json, start, p - start));
  end;
  if Json[p] = '{' then
  begin
    start := p;
    depth := 0;
    while p <= Length(Json) do
    begin
      c := Json[p];
      if c = '{' then Inc(depth)
      else if c = '}' then
      begin
        Dec(depth);
        if depth = 0 then
        begin
          Inc(p);
          Break;
        end;
      end;
      Inc(p);
    end;
    Exit(Copy(Json, start, p - start));
  end;
  start := p;
  while (p <= Length(Json)) and (Json[p] <> ',') and (Json[p] <> '}') do Inc(p);
  Result := Trim(Copy(Json, start, p - start));
end;

function JsonGetInt(const Json, Key: AnsiString; Def: Integer): Integer;
begin
  Result := StrToIntDef(JsonRawValue(Json, Key), Def);
end;

function JsonGetString(const Json, Key: AnsiString): AnsiString;
var
  v: AnsiString;
begin
  v := JsonRawValue(Json, Key);
  if (Length(v) >= 2) and (v[1] = '"') then
    Result := JsonUnescape(Copy(v, 2, Length(v) - 2))
  else
    Result := v;
end;

function DeserializeDom(const Json: AnsiString): TDomDoc;
var
  s: AnsiString;
  i, depth, start: Integer;
  objs: TStringList;
  ids: array of TDomNode;
  id, parent, p: Integer;
  tag, text, attrsJson: AnsiString;
  n, par: TDomNode;
  aStart, aEnd: Integer;
  attrName, attrVal: AnsiString;
  keyPos: Integer;
begin
  Result := nil;
  s := Trim(Json);
  if (Length(s) < 2) or (s[1] <> '[') then Exit;
  objs := TStringList.Create;
  try
    { split the top-level array into objects }
    depth := 0;
    start := 0;
    for i := 1 to Length(s) do
    begin
      if s[i] = '{' then
      begin
        if depth = 0 then start := i;
        Inc(depth);
      end
      else if s[i] = '}' then
      begin
        Dec(depth);
        if depth = 0 then
          objs.Add(Copy(s, start, i - start + 1));
      end;
    end;

    Result := TDomDoc.Create;
    SetLength(ids, objs.Count + 1);
    for i := 0 to objs.Count - 1 do
    begin
      id := JsonGetInt(objs[i], 'id', i);
      parent := JsonGetInt(objs[i], 'parent', -1);
      tag := JsonGetString(objs[i], 'tag');
      text := JsonGetString(objs[i], 'text');
      if tag = '#document' then
        n := TDomNode.Create(nkDocument, '')
      else if tag = '#text' then
        n := TDomNode.Create(nkText, '')
      else if tag = '#comment' then
        n := TDomNode.Create(nkComment, '')
      else
        n := TDomNode.Create(nkElement, tag);
      n.Text := text;
      n.Id := id;
      if id >= 0 then
        ids[id] := n;
      if parent >= 0 then
      begin
        par := nil;
        if (parent <= High(ids)) then par := ids[parent];
        if par <> nil then
        begin
          par.AppendChild(n);
          if par.Kind = nkDocument then Result.Root := n;
          if tag = 'html' then Result.Html := n;
          if tag = 'head' then Result.Head := n;
          if tag = 'body' then Result.Body := n;
        end;
      end
      else
      begin
        Result.Root := n;
        Result.Html := n;
      end;
    end;
    if Result.Html = nil then Result.Html := Result.Root;
  finally
    objs.Free;
  end;
end;

{ --- the shim ---------------------------------------------------------- }

function ShimSource: AnsiString;
begin
  Result :=
    'const fs = require("fs");' + #10 +
    'const req = JSON.parse(fs.readFileSync(0, "utf8"));' + #10 +
    'const data = req.dom;' + #10 +
    'const byId = new Map();' + #10 +
    'const nodes = [];' + #10 +
    'for (const n of data) {' + #10 +
    '  const o = { id: n.id, parent: n.parent, tag: n.tag, text: n.text || "",' + #10 +
    '    attrs: n.attrs || {}, children: [] };' + #10 +
    '  nodes.push(o); byId.set(n.id, o);' + #10 +
    '}' + #10 +
    'let root = null;' + #10 +
    'for (const o of nodes) {' + #10 +
    '  if (o.parent < 0) { root = o; }' + #10 +
    '  else { const p = byId.get(o.parent); if (p) p.children.push(o); }' + #10 +
    '}' + #10 +
    'function wrap(o) {' + #10 +
    '  return {' + #10 +
    '    get tagName() { return o.tag.toUpperCase(); },' + #10 +
    '    get textContent() { let s = o.text; for (const c of o.children) s += wrap(c).textContent; return s; },' + #10 +
    '    set textContent(v) { o.text = String(v); o.children = []; },' + #10 +
    '    get children() { return o.children.map(wrap); },' + #10 +
    '    getAttribute(n) { return (n in o.attrs) ? o.attrs[n] : null; },' + #10 +
    '    setAttribute(n, v) { o.attrs[n] = String(v); },' + #10 +
    '    removeAttribute(n) { delete o.attrs[n]; },' + #10 +
    '    appendChild(c) { const t = unwrap(c); o.children.push(t); t.parent = o.id; return c; },' + #10 +
    '    removeChild(c) { const t = unwrap(c); const i = o.children.indexOf(t); if (i >= 0) o.children.splice(i, 1); return c; },' + #10 +
    '    getElementById(id) { for (const n of nodes) if (n.attrs.id === id) return wrap(n); return null; },' + #10 +
    '    querySelector(sel) { return queryAll(o, sel)[0] || null; },' + #10 +
    '    querySelectorAll(sel) { return queryAll(o, sel); },' + #10 +
    '    addEventListener() {},' + #10 +
    '    get classList() { return {' + #10 +
    '      add(c) { o.attrs["class"] = ((o.attrs["class"] || "") + " " + c).trim(); },' + #10 +
    '      remove(c) { o.attrs["class"] = (o.attrs["class"] || "").split(/\s+/).filter(x => x !== c).join(" "); },' + #10 +
    '      contains(c) { return (o.attrs["class"] || "").split(/\s+/).includes(c); } }; },' + #10 +
    '    get parentNode() { return o.parent >= 0 ? wrap(byId.get(o.parent)) : null; },' + #10 +
    '    get childNodes() { return o.children.map(wrap); },' + #10 +
    '    get firstChild() { return o.children.length ? wrap(o.children[0]) : null; }' + #10 +
    '  };' + #10 +
    '}' + #10 +
    'function unwrap(c) { return c && c.__o ? c.__o : c; }' + #10 +
    'function wrapAll(o) { const w = wrap(o); w.__o = o; return w; }' + #10 +
    'function queryAll(o, sel) {' + #10 +
    '  sel = String(sel).trim(); const out = [];' + #10 +
    '  const m = sel.match(/^([a-zA-Z0-9]*)(?:\.([\w-]+))?(?:#([\w-]+))?$/);' + #10 +
    '  if (!m) return out;' + #10 +
    '  const tag = (m[1] || "").toLowerCase(), cls = m[2], id = m[3];' + #10 +
    '  (function walk(n) {' + #10 +
    '    let ok = true;' + #10 +
    '    if (tag && n.tag.toLowerCase() !== tag) ok = false;' + #10 +
    '    if (id && n.attrs.id !== id) ok = false;' + #10 +
    '    if (cls && !(n.attrs["class"] || "").split(/\s+/).includes(cls)) ok = false;' + #10 +
    '    if (ok) out.push(wrap(n));' + #10 +
    '    for (const c of n.children) walk(c);' + #10 +
    '  })(o);' + #10 +
    '  return out;' + #10 +
    '}' + #10 +
    'globalThis.document = {' + #10 +
    '  getElementById: id => { for (const n of nodes) if (n.attrs.id === id) return wrap(n); return null; },' + #10 +
    '  querySelector: s => { const r = queryAll(root, s); return r[0] || null; },' + #10 +
    '  querySelectorAll: s => queryAll(root, s),' + #10 +
    '  createElement: t => { const n = { id: nodes.length, parent: -1, tag: t, text: "", attrs: {}, children: [] }; nodes.push(n); return wrapAll(n); },' + #10 +
    '  get body() { for (const n of nodes) if (n.tag === "body") return wrap(n); return wrap(root); },' + #10 +
    '  addEventListener() {}' + #10 +
    '};' + #10 +
    'for (const s of (req.scripts || [])) { try { new Function(s)(); } catch (e) {} }' + #10 +
    'const out = [];' + #10 +
    '(function ser(n) { out.push({ id: n.id, parent: n.parent, tag: n.tag, text: n.text || "", attrs: n.attrs || {} }); for (const c of n.children) ser(c); })(root);' + #10 +
    'fs.writeSync(1, JSON.stringify({ op: "dom", html: JSON.stringify(out) }));' + #10;
end;

{ --- TBrowserJs -------------------------------------------------------- }

{ Move the content of From into To, leaving From empty. }
procedure SwapDom(ADest, ASrc: TDomDoc);
var
  r: TDomNode;
begin
  if (ADest = nil) or (ASrc = nil) then Exit;
  ADest.Root.Free;
  r := ASrc.Root;
  ADest.Root := r;
  ADest.Html := ASrc.Html;
  ADest.Head := ASrc.Head;
  ADest.Body := ASrc.Body;
  ASrc.Root := nil;
  ASrc.Html := nil;
  ASrc.Head := nil;
  ASrc.Body := nil;
end;

constructor TBrowserJs.Create;
begin
  inherited Create;
  FTimeout := DefTimeout;
  FMaxNodes := DefMaxNodes;
  FCmd := '';
  FShimPath := '';
end;

destructor TBrowserJs.Destroy;
begin
  if (FShimPath <> '') and FileExists(FShimPath) then
    DeleteFile(FShimPath);
  inherited Destroy;
end;

function TBrowserJs.ResolveEngine: AnsiString;
begin
  Result := GetEnvironmentVariable('DN_JS_CMD');
  if Result <> '' then Exit;
  if FileExists('/opt/homebrew/bin/deno') or FileExists('/usr/local/bin/deno') then
    Exit('deno');
  if FileExists('/opt/homebrew/bin/node') or FileExists('/usr/local/bin/node') then
    Exit('node');
  if FileExists('/opt/homebrew/bin/quickjs') or
     FileExists('/usr/local/bin/quickjs') then
    Exit('quickjs');
  Result := '';
end;

function TBrowserJs.ApplyDom(Doc: TDomDoc; out Err: AnsiString): Boolean;
var
  engine, json, script, cmd, outp: AnsiString;
  scripts: TStringList;
  rc, i: Integer;
  newDoc: TDomDoc;
begin
  Result := False;
  Err := '';
  engine := ResolveEngine;
  if engine = '' then
  begin
    FCmd := '';
    Err := 'no js engine';
    Exit;
  end;
  FCmd := engine;
  if Doc = nil then Exit;
  scripts := Doc.Scripts;
  try
    if scripts.Count = 0 then
    begin
      Err := '';
      Exit(True);
    end;
  finally
    scripts.Free;
  end;

  { build the request JSON: the flat DOM plus the scripts }
  json := SerializeDom(Doc);
  script := '{"dom":' + json + ',"scripts":[';
  scripts := Doc.Scripts;
  try
    for i := 0 to scripts.Count - 1 do
    begin
      if i > 0 then script := script + ',';
      script := script + '"' + JsonEscape(scripts[i]) + '"';
    end;
  finally
    scripts.Free;
  end;
  script := script + ']}';

  FShimPath := GetTempDir + 'dnjs-' + IntToStr(GetProcessID) + '-' +
                IntToStr(Random(1000000)) + '.js';
  WriteFileText(FShimPath, ShimSource);
  cmd := engine + ' ' + ShellQuote(FShimPath);
  rc := RunCaptureInput(cmd, script, outp);
  DeleteFile(FShimPath);
  if GetEnvironmentVariable('DN_JS_DEBUG') <> '' then
    WriteFileText(GetEnvironmentVariable('DN_JS_DEBUG'), 'OUT=' + outp + #10 + 'ERRNO=' + IntToStr(rc));
  if rc <> 0 then
  begin
    Err := 'js engine failed';
    Exit;
  end;
  if Pos('"op":"error"', outp) > 0 then
  begin
    Err := 'js error';
    Exit;
  end;

  { replace the document with the post-script DOM }
  newDoc := DeserializeDom(JsonGetString(outp, 'html'));
  if newDoc = nil then
  begin
    Err := 'js returned a bad dom';
    Exit;
  end;
  SwapDom(Doc, newDoc);
  newDoc.Free;
  Result := True;
end;

end.
