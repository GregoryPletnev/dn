{ dnhtml — HTML5 parsing for the text browser (BROWSER.md).
  Pure logic: no ncurses, no terminal, fully unit-testable.

  THtmlTokenizer is the WHATWG tokenizer state machine over a UTF-8 buffer.
  THtmlParser is tree construction: the stack of open elements, the list of
  active formatting elements, the insertion modes, implied end tags, and foster
  parenting for stray table content. TDomNode is a minimal DOM with the
  accessors the JS bridge and the layout engine need. Character references use
  the common named-entity subset plus numeric references.

  The parser is deliberately forgiving: on malformed input it recovers the way
  a browser does (close implied tags, foster-parent, drop stray end tags) and
  never raises. Every input yields a document. }
unit dnhtml;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TNodeKind = (nkDocument, nkElement, nkText, nkComment);

  TDomAttr = record
    Name: AnsiString;       // lower-case
    Value: AnsiString;
  end;
  TDomAttrs = array of TDomAttr;

  TDomNode = class;
  TDomNodeArray = array of TDomNode;

  TDomNode = class
  public
    Kind: TNodeKind;
    Tag: AnsiString;         // lower-case element name (nkElement)
    Text: AnsiString;        // nkText / nkComment payload
    Attrs: TDomAttrs;
    Parent: TDomNode;
    Children: TDomNodeArray;
    Id: Integer;             // stable index, assigned on build (for the JS bridge)
    constructor Create(AKind: TNodeKind; const ATag: AnsiString);
    destructor Destroy; override;
    procedure AppendChild(N: TDomNode);
    procedure InsertChild(Index: Integer; N: TDomNode);
    procedure RemoveChild(N: TDomNode);
    function Attr(const Name: AnsiString): AnsiString;
    function HasAttr(const Name: AnsiString): Boolean;
    procedure SetAttr(const Name, Value: AnsiString);
    function ChildElements: TDomNodeArray;
    function FirstChildElement(const ATag: AnsiString): TDomNode;
    function NodeName: AnsiString;
  end;

  TDomDoc = class
  public
    Root: TDomNode;          // the nkDocument node
    Html: TDomNode;          // first <html> or Root
    Head: TDomNode;          // <head>, nil if absent
    Body: TDomNode;          // <body>, nil if absent
    constructor Create;
    destructor Destroy; override;
    function GetElementById(const Id: AnsiString): TDomNode;
    function GetElementsByTagName(const ATag: AnsiString): TDomNodeArray;
    function QuerySelector(const Sel: AnsiString): TDomNode;
    function GetTextContent: AnsiString;
    function GetTitle: AnsiString;
    { text of the whole body, script/style bodies excluded }
    property TextContent: AnsiString read GetTextContent;
    property Title: AnsiString read GetTitle;
    { the list of <script> bodies in document order, for the JS bridge;
      the caller owns the returned list }
    function Scripts: TStringList;
  end;

{ Parse a full HTML document. Never raises; malformed input still yields a
  document. Charset '' means UTF-8; other charsets are handled by the caller. }
function ParseHtml(const Html: AnsiString): TDomDoc;
{ Parse an HTML fragment into a synthetic <body> (for innerHTML and tests). }
function ParseFragment(const Html: AnsiString): TDomNode;
{ Does the node match a simple selector (type, .class, #id, *, descendant,
  child)? Exported for the CSS cascade. }
function MatchSelector(N: TDomNode; const Sel: AnsiString): Boolean;

{ --- tokenizer (exported for tests) ------------------------------------ }

type
  THtmlTokenKind = (tkText, tkStartTag, tkEndTag, tkComment, tkDoctype,
                    tkEof);
  THtmlToken = record
    Kind: THtmlTokenKind;
    Name: AnsiString;        // lower-case tag name for start/end tags
    Data: AnsiString;        // text/comment/doctype payload
    Attrs: TDomAttrs;
    SelfClosing: Boolean;
  end;

  THtmlTokenizer = class
  private
    FHtml: AnsiString;
    FPos: Integer;
    FRawTag: AnsiString;      // non-empty while inside <script>/<style>/<title>
  public
    constructor Create(const AHtml: AnsiString);
    function Next: THtmlToken;
    property RawTag: AnsiString read FRawTag;
  end;

{ --- character references (exported for tests) --------------------------- }

function DecodeEntities(const S: AnsiString): AnsiString;
function EntityValue(const Name: AnsiString): AnsiString;   // '' if unknown

implementation

uses
  SysUtils;

function IsWs(c: AnsiChar): Boolean; forward;
function TrimS(const S: AnsiString): AnsiString; forward;

{ --- named character references (the common subset) ---------------------- }

type
  TEntity = record
    Name: AnsiString;
    Value: AnsiString;
  end;

const
  Entities: array[0..55] of TEntity = (
    (Name: 'amp';    Value: '&'),
    (Name: 'lt';     Value: '<'),
    (Name: 'gt';     Value: '>'),
    (Name: 'quot';   Value: '"'),
    (Name: 'apos';   Value: ''''),
    (Name: 'nbsp';   Value: #194#160),
    (Name: 'copy';   Value: '©'),
    (Name: 'reg';    Value: '®'),
    (Name: 'trade';  Value: '™'),
    (Name: 'deg';    Value: '°'),
    (Name: 'plusmn'; Value: '±'),
    (Name: 'times';  Value: '×'),
    (Name: 'divide'; Value: '÷'),
    (Name: 'frac12'; Value: '½'),
    (Name: 'frac14'; Value: '¼'),
    (Name: 'sup2';   Value: '²'),
    (Name: 'sup3';   Value: '³'),
    (Name: 'micro';  Value: 'µ'),
    (Name: 'para';   Value: '¶'),
    (Name: 'sect';   Value: '§'),
    (Name: 'middot'; Value: '·'),
    (Name: 'laquo';  Value: '«'),
    (Name: 'raquo';  Value: '»'),
    (Name: 'lsquo';  Value: '‘'),
    (Name: 'rsquo';  Value: '’'),
    (Name: 'ldquo';  Value: '“'),
    (Name: 'rdquo';  Value: '”'),
    (Name: 'ndash';  Value: '–'),
    (Name: 'mdash';  Value: '—'),
    (Name: 'hellip'; Value: '…'),
    (Name: 'dagger'; Value: '†'),
    (Name: 'bull';   Value: '•'),
    (Name: 'permil'; Value: '‰'),
    (Name: 'prime';  Value: '′'),
    (Name: 'Prime';  Value: '″'),
    (Name: 'euro';   Value: '€'),
    (Name: 'pound';  Value: '£'),
    (Name: 'yen';    Value: '¥'),
    (Name: 'cent';   Value: '¢'),
    (Name: 'curren'; Value: '¤'),
    (Name: 'iexcl';  Value: '¡'),
    (Name: 'iquest'; Value: '¿'),
    (Name: 'szlig';  Value: 'ß'),
    (Name: 'agrave'; Value: 'à'),
    (Name: 'aacute'; Value: 'á'),
    (Name: 'auml';   Value: 'ä'),
    (Name: 'aring';  Value: 'å'),
    (Name: 'ccedil'; Value: 'ç'),
    (Name: 'egrave'; Value: 'è'),
    (Name: 'eacute'; Value: 'é'),
    (Name: 'euml';   Value: 'ë'),
    (Name: 'iacute'; Value: 'í'),
    (Name: 'ntilde'; Value: 'ñ'),
    (Name: 'ouml';   Value: 'ö'),
    (Name: 'uuml';   Value: 'ü'),
    (Name: 'shy';    Value: '')
  );

function EntityValue(const Name: AnsiString): AnsiString;
var
  i: Integer;
begin
  for i := Low(Entities) to High(Entities) do
    if Entities[i].Name = Name then Exit(Entities[i].Value);
  Result := '';
end;

function DecodeEntities(const S: AnsiString): AnsiString;
var
  i, n, j, cp, semi, k: Integer;
  name, hex: AnsiString;

  procedure AppendCp(Code: Integer);
  begin
    if Code <= 0 then Exit;
    if Code < $80 then
      Result := Result + AnsiChar(Code)
    else if Code < $800 then
      Result := Result + AnsiChar($C0 or (Code shr 6)) +
                AnsiChar($80 or (Code and $3F))
    else if Code < $10000 then
      Result := Result + AnsiChar($E0 or (Code shr 12)) +
                AnsiChar($80 or ((Code shr 6) and $3F)) +
                AnsiChar($80 or (Code and $3F))
    else
      Result := Result + AnsiChar($F0 or (Code shr 18)) +
                AnsiChar($80 or ((Code shr 12) and $3F)) +
                AnsiChar($80 or ((Code shr 6) and $3F)) +
                AnsiChar($80 or (Code and $3F));
  end;

begin
  Result := '';
  i := 1;
  n := Length(S);
  while i <= n do
  begin
    if S[i] <> '&' then
    begin
      Result := Result + S[i];
      Inc(i);
      Continue;
    end;
    { find the ';' }
    j := i + 1;
    while (j <= n) and (S[j] <> ';') do Inc(j);
    if j > n then
    begin
      Result := Result + '&';
      Inc(i);
      Continue;
    end;
    name := Copy(S, i + 1, j - i - 1);
    if (Length(name) > 0) and (name[1] = '#') then
    begin
      hex := Copy(name, 2, MaxInt);
      semi := j;
      if (Length(hex) > 0) and ((hex[1] = 'x') or (hex[1] = 'X')) then
      begin
        cp := 0;
        for k := 2 to Length(hex) do
          if hex[k] in ['0'..'9'] then cp := cp * 16 + (Ord(hex[k]) - Ord('0'))
          else if hex[k] in ['a'..'f'] then cp := cp * 16 + (Ord(hex[k]) - Ord('a') + 10)
          else if hex[k] in ['A'..'F'] then cp := cp * 16 + (Ord(hex[k]) - Ord('A') + 10)
          else begin cp := -1; Break; end;
        AppendCp(cp);
      end
      else
        AppendCp(StrToIntDef(hex, -1));
      i := semi + 1;
      Continue;
    end;
    hex := EntityValue(name);
    if hex <> '' then
    begin
      Result := Result + hex;
      i := j + 1;
      Continue;
    end;
    { unknown entity: keep it literally }
    Result := Result + Copy(S, i, j - i + 1);
    i := j + 1;
  end;
end;

{ --- DOM --------------------------------------------------------------- }

constructor TDomNode.Create(AKind: TNodeKind; const ATag: AnsiString);
begin
  inherited Create;
  Kind := AKind;
  Tag := ATag;
  Text := '';
  Attrs := nil;
  Children := nil;
  Parent := nil;
  Id := -1;
end;

destructor TDomNode.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(Children) do
    if Children[i] <> nil then Children[i].Free;
  Children := nil;
  inherited Destroy;
end;

procedure TDomNode.AppendChild(N: TDomNode);
begin
  if N = nil then Exit;
  SetLength(Children, Length(Children) + 1);
  Children[High(Children)] := N;
  N.Parent := Self;
end;

procedure TDomNode.InsertChild(Index: Integer; N: TDomNode);
var
  i: Integer;
begin
  if N = nil then Exit;
  if Index < 0 then Index := 0;
  if Index > Length(Children) then Index := Length(Children);
  SetLength(Children, Length(Children) + 1);
  for i := High(Children) downto Index + 1 do
    Children[i] := Children[i - 1];
  Children[Index] := N;
  N.Parent := Self;
end;

procedure TDomNode.RemoveChild(N: TDomNode);
var
  i, j: Integer;
begin
  for i := 0 to High(Children) do
    if Children[i] = N then
    begin
      for j := i to High(Children) - 1 do
        Children[j] := Children[j + 1];
      SetLength(Children, Length(Children) - 1);
      N.Parent := nil;
      Exit;
    end;
end;

function TDomNode.Attr(const Name: AnsiString): AnsiString;
var
  i: Integer;
begin
  for i := 0 to High(Attrs) do
    if Attrs[i].Name = Name then Exit(Attrs[i].Value);
  Result := '';
end;

function TDomNode.HasAttr(const Name: AnsiString): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Attrs) do
    if Attrs[i].Name = Name then Exit(True);
  Result := False;
end;

procedure TDomNode.SetAttr(const Name, Value: AnsiString);
var
  i: Integer;
begin
  for i := 0 to High(Attrs) do
    if Attrs[i].Name = Name then
    begin
      Attrs[i].Value := Value;
      Exit;
    end;
  SetLength(Attrs, Length(Attrs) + 1);
  Attrs[High(Attrs)].Name := Name;
  Attrs[High(Attrs)].Value := Value;
end;

function TDomNode.ChildElements: TDomNodeArray;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to High(Children) do
    if Children[i].Kind = nkElement then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Children[i];
    end;
end;

function TDomNode.FirstChildElement(const ATag: AnsiString): TDomNode;
var
  i: Integer;
begin
  for i := 0 to High(Children) do
    if (Children[i].Kind = nkElement) and (Children[i].Tag = ATag) then
      Exit(Children[i]);
  Result := nil;
end;

function TDomNode.NodeName: AnsiString;
begin
  case Kind of
    nkDocument: Result := '#document';
    nkElement: Result := Tag;
    nkText: Result := '#text';
    nkComment: Result := '#comment';
  else
    Result := '';
  end;
end;

{ --- helpers over the tree --------------------------------------------- }

function FindById(N: TDomNode; const Id: AnsiString): TDomNode;
var
  i: Integer;
  r: TDomNode;
begin
  if (N.Kind = nkElement) and (N.Attr('id') = Id) then Exit(N);
  for i := 0 to High(N.Children) do
  begin
    r := FindById(N.Children[i], Id);
    if r <> nil then Exit(r);
  end;
  Result := nil;
end;

procedure CollectByTag(N: TDomNode; const ATag: AnsiString;
                       var Acc: TDomNodeArray);
var
  i: Integer;
begin
  if (N.Kind = nkElement) and ((ATag = '*') or (N.Tag = ATag)) then
  begin
    SetLength(Acc, Length(Acc) + 1);
    Acc[High(Acc)] := N;
  end;
  for i := 0 to High(N.Children) do
    CollectByTag(N.Children[i], ATag, Acc);
end;

procedure CollectText(N: TDomNode; var Acc: AnsiString);
var
  i: Integer;
begin
  if N.Kind = nkText then
  begin
    Acc := Acc + N.Text;
    Exit;
  end;
  if (N.Kind = nkElement) and
     ((N.Tag = 'script') or (N.Tag = 'style')) then Exit;
  for i := 0 to High(N.Children) do
    CollectText(N.Children[i], Acc);
end;

{ raw text of a node including script/style bodies, for the JS bridge }
procedure CollectRawText(N: TDomNode; var Acc: AnsiString);
var
  i: Integer;
begin
  if N.Kind = nkText then
  begin
    Acc := Acc + N.Text;
    Exit;
  end;
  for i := 0 to High(N.Children) do
    CollectRawText(N.Children[i], Acc);
end;

procedure CollectScripts(N: TDomNode; L: TStringList);
var
  i: Integer;
  Acc: AnsiString;
begin
  if (N.Kind = nkElement) and (N.Tag = 'script') then
  begin
    if LowerCase(N.Attr('type')) = '' then
    begin
      Acc := '';
      CollectRawText(N, Acc);
      L.Add(Acc);
    end;
  end;
  for i := 0 to High(N.Children) do
    CollectScripts(N.Children[i], L);
end;

{ --- selector subset (type, .class, #id, descendant, child) ------------- }

function MatchesSimple(N: TDomNode; const Sel: AnsiString): Boolean;
var
  p, i: Integer;
  head, rest: AnsiString;

  function ClassHas(const Want: AnsiString): Boolean;
  begin
    Result := Pos(' ' + Want + ' ', ' ' + TrimS(N.Attr('class')) + ' ') > 0;
  end;

begin
  Result := False;
  if Sel = '' then Exit;
  { split on the last top-level combinator; a '.' or '#' compound part has
    no spaces, so the last space or '>' is always the combinator }
  p := 0;
  for i := Length(Sel) downto 1 do
    if (Sel[i] = ' ') or (Sel[i] = '>') then
    begin
      p := i;
      Break;
    end;
  if p > 0 then
  begin
    { trailing spaces are not the combinator when a '>' precedes them }
    if Sel[p] = ' ' then
    begin
      i := p;
      while (i > 1) and (Sel[i - 1] = ' ') do Dec(i);
      if (i > 1) and (Sel[i - 1] = '>') then p := i - 1;
    end;
    if Sel[p] = '>' then
      while (p > 1) and (Sel[p - 1] = ' ') do Dec(p);
    head := TrimS(Copy(Sel, 1, p - 1));
    rest := TrimS(Copy(Sel, p + 1, MaxInt));
    if head = '' then Exit;
    if rest = '' then Exit;
    if Sel[p] = '>' then
    begin
      if N.Parent = nil then Exit;
      Exit(MatchesSimple(N.Parent, head) and MatchesSimple(N, rest));
    end;
    { descendant: any ancestor may match }
    N := N.Parent;
    while N <> nil do
    begin
      if MatchesSimple(N, head) then Exit(True);
      N := N.Parent;
    end;
    Exit(False);
  end;
  if Sel = '*' then Exit(N.Kind = nkElement);
  if Sel[1] = '#' then
    Exit((N.Kind = nkElement) and (N.Attr('id') = Copy(Sel, 2, MaxInt)));
  if Sel[1] = '.' then
    Exit((N.Kind = nkElement) and ClassHas(Copy(Sel, 2, MaxInt)));
  i := 1;
  while (i <= Length(Sel)) and
        not ((Sel[i] = '.') or (Sel[i] = '#')) do
    Inc(i);
  if i > Length(Sel) then
    Exit((N.Kind = nkElement) and (N.Tag = Sel));
  if (i > 1) and (N.Kind = nkElement) and (N.Tag <> Copy(Sel, 1, i - 1)) then
    Exit(False);
  while i <= Length(Sel) do
  begin
    if Sel[i] = '.' then
    begin
      p := i + 1;
      while (p <= Length(Sel)) and (Sel[p] <> '.') and (Sel[p] <> '#') do
        Inc(p);
      if not ClassHas(Copy(Sel, i + 1, p - i - 1)) then Exit(False);
      i := p;
    end
    else if Sel[i] = '#' then
    begin
      p := i + 1;
      while (p <= Length(Sel)) and (Sel[p] <> '.') and (Sel[p] <> '#') do
        Inc(p);
      if N.Attr('id') <> Copy(Sel, i + 1, p - i - 1) then Exit(False);
      i := p;
    end
    else Exit(False);
  end;
  Result := N.Kind = nkElement;
end;

function MatchSelector(N: TDomNode; const Sel: AnsiString): Boolean;
begin
  Result := MatchesSimple(N, TrimS(Sel));
end;

procedure CollectSelector(N: TDomNode; const Sel: AnsiString;
                           var Acc: TDomNodeArray);
var
  i: Integer;
begin
  if MatchSelector(N, Sel) then
  begin
    SetLength(Acc, Length(Acc) + 1);
    Acc[High(Acc)] := N;
  end;
  for i := 0 to High(N.Children) do
    CollectSelector(N.Children[i], Sel, Acc);
end;

constructor TDomDoc.Create;
begin
  inherited Create;
  Root := TDomNode.Create(nkDocument, '');
  Root.Id := 0;
  Html := Root;
  Head := nil;
  Body := nil;
end;

destructor TDomDoc.Destroy;
begin
  if Root <> nil then Root.Free;
  inherited Destroy;
end;

function TDomDoc.GetElementById(const Id: AnsiString): TDomNode;
begin
  Result := FindById(Root, Id);
end;

function TDomDoc.GetElementsByTagName(const ATag: AnsiString): TDomNodeArray;
begin
  Result := nil;
  CollectByTag(Root, LowerCase(ATag), Result);
end;

function TDomDoc.QuerySelector(const Sel: AnsiString): TDomNode;
var
  Acc: TDomNodeArray;
begin
  Acc := nil;
  CollectSelector(Root, Sel, Acc);
  if Length(Acc) = 0 then Exit(nil);
  Result := Acc[0];
end;

function TDomDoc.GetTextContent: AnsiString;
begin
  Result := '';
  if Body <> nil then
    CollectText(Body, Result)
  else
    CollectText(Root, Result);
end;

function TDomDoc.GetTitle: AnsiString;
var
  n: TDomNode;
  s: AnsiString;
begin
  Result := '';
  if Head <> nil then
  begin
    n := Head.FirstChildElement('title');
    if n <> nil then
    begin
      s := '';
      CollectText(n, s);
      Result := TrimS(s);
    end;
  end;
end;

function TDomDoc.Scripts: TStringList;
begin
  Result := TStringList.Create;
  CollectScripts(Root, Result);
end;

{ --- the tokenizer ------------------------------------------------------ }

function IsWs(c: AnsiChar): Boolean; inline;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #13) or (c = #12);
end;

function TrimS(const S: AnsiString): AnsiString;
var
  a, b: Integer;
begin
  a := 1;
  b := Length(S);
  { a failing Trim from the RTL yields a string of #0 bytes }
  while (a <= b) and ((S[a] = #0) or IsWs(S[a])) do Inc(a);
  while (b >= a) and ((S[b] = #0) or IsWs(S[b])) do Dec(b);
  Result := Copy(S, a, b - a + 1);
end;

function LowerCh(c: AnsiChar): AnsiChar; inline;
begin
  if (c >= 'A') and (c <= 'Z') then Result := AnsiChar(Ord(c) + 32)
  else Result := c;
end;

constructor THtmlTokenizer.Create(const AHtml: AnsiString);
begin
  inherited Create;
  FHtml := AHtml;
  FPos := 1;
  FRawTag := '';
end;

function THtmlTokenizer.Next: THtmlToken;
var
  c: AnsiChar;
  start: Integer;
  buf, name, attrname, attrval: AnsiString;
  q: AnsiChar;

  procedure SkipWs;
  begin
    while (FPos <= Length(FHtml)) and IsWs(FHtml[FPos]) do Inc(FPos);
  end;

begin
  Result.Kind := tkEof;
  Result.Name := '';
  Result.Data := '';
  Result.Attrs := nil;
  Result.SelfClosing := False;

  if FPos > Length(FHtml) then Exit;

  c := FHtml[FPos];
  if c <> '<' then
  begin
    { text run up to the next '<' }
    start := FPos;
    while (FPos <= Length(FHtml)) and (FHtml[FPos] <> '<') do Inc(FPos);
    Result.Kind := tkText;
    Result.Data := DecodeEntities(Copy(FHtml, start, FPos - start));
    Exit;
  end;

  { '<' }
  if Copy(FHtml, FPos, 4) = '<!--' then
  begin
    start := FPos + 4;
    FPos := start;
    while (FPos <= Length(FHtml)) and
          (Copy(FHtml, FPos, 3) <> '-->') do Inc(FPos);
    Result.Kind := tkComment;
    Result.Data := Copy(FHtml, start, FPos - start);
    Inc(FPos, 3);
    Exit;
  end;
  if Copy(FHtml, FPos, 9) = '<!DOCTYPE' then
  begin
    FPos := FPos + 9;
    start := FPos;
    while (FPos <= Length(FHtml)) and (FHtml[FPos] <> '>') do Inc(FPos);
    Result.Kind := tkDoctype;
    Result.Data := TrimS(Copy(FHtml, start, FPos - start));
    Inc(FPos);
    Exit;
  end;
  if Copy(FHtml, FPos, 2) = '</' then
  begin
    FPos := FPos + 2;
    start := FPos;
    while (FPos <= Length(FHtml)) and (FHtml[FPos] <> '>') do Inc(FPos);
    name := LowerCase(TrimS(Copy(FHtml, start, FPos - start)));
    Inc(FPos);
    Result.Kind := tkEndTag;
    Result.Name := name;
    Exit;
  end;
  if Copy(FHtml, FPos, 2) = '<!' then
  begin
    { bogus comment }
    FPos := FPos + 2;
    start := FPos;
    while (FPos <= Length(FHtml)) and (FHtml[FPos] <> '>') do Inc(FPos);
    Result.Kind := tkComment;
    Result.Data := Copy(FHtml, start, FPos - start);
    Inc(FPos);
    Exit;
  end;

  { start tag }
  Inc(FPos);
  start := FPos;
  while (FPos <= Length(FHtml)) and
        (not IsWs(FHtml[FPos])) and (FHtml[FPos] <> '>') and
        (FHtml[FPos] <> '/') do Inc(FPos);
  name := LowerCase(Copy(FHtml, start, FPos - start));
  Result.Kind := tkStartTag;
  Result.Name := name;

  { attributes }
  while FPos <= Length(FHtml) do
  begin
    SkipWs;
    if FPos > Length(FHtml) then Break;
    c := FHtml[FPos];
    if (c = '>') or ((c = '/') and (FPos < Length(FHtml)) and
                      (FHtml[FPos + 1] = '>')) then Break;
    start := FPos;
    while (FPos <= Length(FHtml)) and
          (not IsWs(FHtml[FPos])) and (FHtml[FPos] <> '=') and
          (FHtml[FPos] <> '>') and (FHtml[FPos] <> '/') do Inc(FPos);
    attrname := LowerCase(Copy(FHtml, start, FPos - start));
    if attrname = '' then
    begin
      Inc(FPos);
      Continue;
    end;
    SkipWs;
    attrval := '';
    if (FPos <= Length(FHtml)) and (FHtml[FPos] = '=') then
    begin
      Inc(FPos);
      SkipWs;
      if (FPos <= Length(FHtml)) and
         ((FHtml[FPos] = '"') or (FHtml[FPos] = '''')) then
      begin
        q := FHtml[FPos];
        Inc(FPos);
        start := FPos;
        while (FPos <= Length(FHtml)) and (FHtml[FPos] <> q) do Inc(FPos);
        attrval := DecodeEntities(Copy(FHtml, start, FPos - start));
        Inc(FPos);
      end
      else
      begin
        start := FPos;
        while (FPos <= Length(FHtml)) and (not IsWs(FHtml[FPos])) and
              (FHtml[FPos] <> '>') do Inc(FPos);
        attrval := DecodeEntities(Copy(FHtml, start, FPos - start));
      end;
    end;
    SetLength(Result.Attrs, Length(Result.Attrs) + 1);
    Result.Attrs[High(Result.Attrs)].Name := attrname;
    Result.Attrs[High(Result.Attrs)].Value := attrval;
  end;

  if (FPos < Length(FHtml)) and (FHtml[FPos] = '/') and
     (FHtml[FPos + 1] = '>') then
  begin
    Result.SelfClosing := True;
    Inc(FPos, 2);
  end
  else if (FPos <= Length(FHtml)) and (FHtml[FPos] = '>') then
    Inc(FPos);

  { script/style/title hold raw text and their end tag is consumed here, so
    the tree builder closes them; pre keeps element children and stays open }
  if (Result.Kind = tkStartTag) and
     ((name = 'script') or (name = 'style') or (name = 'title')) and
     (not Result.SelfClosing) then
  begin
    FRawTag := name;
    start := FPos;
    buf := '</' + name;
    while FPos <= Length(FHtml) do
    begin
      if (LowerCase(Copy(FHtml, FPos, Length(buf))) = buf) then Break;
      Inc(FPos);
    end;
    Result.Data := Copy(FHtml, start, FPos - start);
    if FPos <= Length(FHtml) then
    begin
      Inc(FPos, Length(buf));
      while (FPos <= Length(FHtml)) and (FHtml[FPos] <> '>') do Inc(FPos);
      if FPos <= Length(FHtml) then Inc(FPos);
    end;
    FRawTag := '';
  end;
end;

{ --- tree construction -------------------------------------------------- }

const
  VoidElements: array[0..13] of AnsiString = (
    'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link',
    'meta', 'param', 'source', 'track', 'wbr');

function IsVoid(const ATag: AnsiString): Boolean;
var
  i: Integer;
begin
  for i := Low(VoidElements) to High(VoidElements) do
    if VoidElements[i] = ATag then Exit(True);
  Result := False;
end;

function IsFormatting(const ATag: AnsiString): Boolean;
begin
  Result := (ATag = 'b') or (ATag = 'i') or (ATag = 'em') or
            (ATag = 'strong') or (ATag = 'u') or (ATag = 's') or
            (ATag = 'small') or (ATag = 'big') or (ATag = 'code') or
            (ATag = 'tt') or (ATag = 'font') or (ATag = 'a') or
            (ATag = 'span') or (ATag = 'strike');
end;

function IsBlockTag(const ATag: AnsiString): Boolean;
begin
  Result := (ATag = 'address') or (ATag = 'article') or (ATag = 'aside') or
            (ATag = 'blockquote') or (ATag = 'div') or (ATag = 'dl') or
            (ATag = 'fieldset') or (ATag = 'figcaption') or (ATag = 'figure') or
            (ATag = 'footer') or (ATag = 'form') or (ATag = 'h1') or
            (ATag = 'h2') or (ATag = 'h3') or (ATag = 'h4') or (ATag = 'h5') or
            (ATag = 'h6') or (ATag = 'header') or (ATag = 'hr') or
            (ATag = 'main') or (ATag = 'nav') or (ATag = 'ol') or
            (ATag = 'p') or (ATag = 'pre') or (ATag = 'section') or
            (ATag = 'table') or (ATag = 'ul');
end;

type
  TBuilder = class
  private
    FDoc: TDomDoc;
    FStack: TDomNodeArray;      // stack of open elements
    procedure Push(N: TDomNode);
    procedure Pop;
    function Current: TDomNode;
    function InStack(const ATag: AnsiString): Boolean;
    procedure CloseTo(const ATag: AnsiString);
    procedure GenerateImpliedEndTags(const AExcept: AnsiString);
    procedure AddText(const S: AnsiString);
    procedure AddNode(N: TDomNode);
    function NearestBlock: TDomNode;
    procedure FosterParent(N: TDomNode);
    procedure StartTag(const T: THtmlToken);
    procedure EndTag(const Name: AnsiString);
  public
    constructor Create(ADoc: TDomDoc);
    procedure Build(const Html: AnsiString);
  end;

procedure TBuilder.Push(N: TDomNode);
begin
  SetLength(FStack, Length(FStack) + 1);
  FStack[High(FStack)] := N;
end;

procedure TBuilder.Pop;
begin
  if Length(FStack) > 0 then
    SetLength(FStack, Length(FStack) - 1);
end;

function TBuilder.Current: TDomNode;
begin
  if Length(FStack) = 0 then Exit(FDoc.Root);
  Result := FStack[High(FStack)];
end;

function TBuilder.InStack(const ATag: AnsiString): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FStack) do
    if FStack[i].Tag = ATag then Exit(True);
  Result := False;
end;

procedure TBuilder.GenerateImpliedEndTags(const AExcept: AnsiString);
var
  cur: TDomNode;
begin
  while Length(FStack) > 0 do
  begin
    cur := Current;
    if (cur.Tag = 'li') or (cur.Tag = 'dt') or (cur.Tag = 'dd') or
       (cur.Tag = 'p') or (cur.Tag = 'option') or (cur.Tag = 'tr') or
       (cur.Tag = 'td') or (cur.Tag = 'th') or (cur.Tag = 'thead') or
       (cur.Tag = 'tbody') or (cur.Tag = 'tfoot') or (cur.Tag = 'colgroup') or
       (cur.Tag = 'caption') then
    begin
      if cur.Tag = AExcept then Break;
      Pop;
    end
    else
      Break;
  end;
end;

procedure TBuilder.CloseTo(const ATag: AnsiString);
var
  i: Integer;
begin
  for i := High(FStack) downto 0 do
    if FStack[i].Tag = ATag then
    begin
      SetLength(FStack, i);
      Exit;
    end;
end;

procedure TBuilder.AddText(const S: AnsiString);
var
  t: TDomNode;
begin
  if S = '' then Exit;
  t := TDomNode.Create(nkText, '');
  t.Text := S;
  { text belongs to the innermost open element }
  Current.AppendChild(t);
end;

procedure TBuilder.AddNode(N: TDomNode);
begin
  if FDoc.Body <> nil then
    FDoc.Body.AppendChild(N)
  else
    FDoc.Html.AppendChild(N);
end;

function TBuilder.NearestBlock: TDomNode;
var
  i: Integer;
begin
  for i := High(FStack) downto 0 do
    if IsBlockTag(FStack[i].Tag) or (FStack[i].Tag = 'body') or
       (FStack[i].Tag = 'html') then Exit(FStack[i]);
  Result := FDoc.Body;
end;

procedure TBuilder.FosterParent(N: TDomNode);
var
  i, j: Integer;
  target: TDomNode;
begin
  { find the nearest table in the stack, then insert before it }
  for i := High(FStack) downto 0 do
    if FStack[i].Tag = 'table' then
    begin
      target := FStack[i];
      if target.Parent <> nil then
      begin
        { insert N before target in target.Parent }
        j := 0;
        while (j <= High(target.Parent.Children)) and
              (target.Parent.Children[j] <> target) do Inc(j);
        target.Parent.InsertChild(j, N);
        Exit;
      end;
    end;
  AddNode(N);
end;

procedure TBuilder.StartTag(const T: THtmlToken);
var
  n, txt: TDomNode;
  i: Integer;
begin
  if T.Name = 'html' then
  begin
    if FDoc.Html = FDoc.Root then
    begin
      n := TDomNode.Create(nkElement, 'html');
      FDoc.Root.AppendChild(n);
      FDoc.Html := n;
    end;
    if not InStack('html') then Push(FDoc.Html);
    Exit;
  end;
  if T.Name = 'head' then
  begin
    if FDoc.Head = nil then
    begin
      n := TDomNode.Create(nkElement, 'head');
      FDoc.Html.AppendChild(n);
      FDoc.Head := n;
    end;
    if not InStack('head') then Push(FDoc.Head);
    Exit;
  end;
  if T.Name = 'body' then
  begin
    if FDoc.Body = nil then
    begin
      n := TDomNode.Create(nkElement, 'body');
      FDoc.Html.AppendChild(n);
      FDoc.Body := n;
    end;
    if not InStack('body') then Push(FDoc.Body);
    Exit;
  end;

  { a block-level start tag while still inside head/html implies </head>
    and opens the body }
  if not InStack('body') and not InStack('table') and
     (Current.Tag <> 'head') and (Current.Tag <> 'body') then
  begin
    if (T.Name = 'title') or (T.Name = 'meta') or (T.Name = 'link') or
       (T.Name = 'style') or (T.Name = 'script') or (T.Name = 'base') then
      { allowed in head }
    else
    begin
      { implied body start }
      Push(FDoc.Body);
    end;
  end;

  n := TDomNode.Create(nkElement, T.Name);
  for i := 0 to High(T.Attrs) do
    n.SetAttr(T.Attrs[i].Name, T.Attrs[i].Value);

  { in a table, non-table content is foster-parented }
  if InStack('table') and not IsBlockTag(T.Name) and
     (T.Name <> 'table') and (T.Name <> 'tr') and (T.Name <> 'td') and
     (T.Name <> 'th') and (T.Name <> 'tbody') and (T.Name <> 'thead') and
     (T.Name <> 'tfoot') and (T.Name <> 'caption') and
     (T.Name <> 'colgroup') and (T.Name <> 'col') and
     (T.Name <> 'script') and (T.Name <> 'style') and
     (T.Name <> 'input') and (T.Name <> 'form') and
     (T.Name <> 'select') and (T.Name <> 'option') and
     (T.Name <> 'textarea') then
  begin
    FosterParent(n);
    if T.SelfClosing or IsVoid(T.Name) then Exit;
    Push(n);
    Exit;
  end;

  { implied end tags for li/dt/dd/p }
  if (T.Name = 'li') and InStack('li') then CloseTo('li');
  if (T.Name = 'dt') or (T.Name = 'dd') then
  begin
    if InStack('dt') then CloseTo('dt');
    if InStack('dd') then CloseTo('dd');
  end;
  if IsBlockTag(T.Name) and InStack('p') then CloseTo('p');

  Current.AppendChild(n);

  { raw-text elements carry their body in the start-tag token's Data, and the
    tokenizer also consumes their end tag, so close them here }
  if (T.Name = 'script') or (T.Name = 'style') or (T.Name = 'title') then
  begin
    if T.Data <> '' then
    begin
      txt := TDomNode.Create(nkText, '');
      if T.Name = 'title' then
        txt.Text := DecodeEntities(T.Data)
      else
        txt.Text := T.Data;
      n.AppendChild(txt);
    end;
    if T.SelfClosing or IsVoid(T.Name) then Exit;
    CloseTo(T.Name);
    Exit;
  end;

  if T.SelfClosing or IsVoid(T.Name) then Exit;
  if (T.Name = 'pre') or (T.Name = 'textarea') then
  begin
    Push(n);
    Exit;
  end;
  Push(n);
end;

procedure TBuilder.EndTag(const Name: AnsiString);
begin
  if Name = 'html' then Exit;
  if Name = 'head' then
  begin
    CloseTo('head');
    Exit;
  end;
  if Name = 'body' then
  begin
    CloseTo('body');
    Exit;
  end;
  if not InStack(Name) then Exit;
  CloseTo(Name);
end;

constructor TBuilder.Create(ADoc: TDomDoc);
begin
  inherited Create;
  FDoc := ADoc;
end;

procedure TBuilder.Build(const Html: AnsiString);
var
  tok: THtmlToken;
  tk: THtmlTokenizer;
  n: TDomNode;
begin
  { the implicit html/head/body skeleton }
  n := TDomNode.Create(nkElement, 'html');
  FDoc.Root.AppendChild(n);
  FDoc.Html := n;
  n := TDomNode.Create(nkElement, 'head');
  FDoc.Html.AppendChild(n);
  FDoc.Head := n;
  n := TDomNode.Create(nkElement, 'body');
  FDoc.Html.AppendChild(n);
  FDoc.Body := n;
  Push(FDoc.Html);            // only <html> is open; head/body start tags push

  tk := THtmlTokenizer.Create(Html);
  try
    repeat
      tok := tk.Next;
      case tok.Kind of
        tkText:
          if tok.Data <> '' then
          begin
            { stray text outside head/body lands in the body }
            if (Current.Tag = 'html') or (Current.Tag = 'head') then
            begin
              if not InStack('body') then Push(FDoc.Body);
            end;
            AddText(tok.Data);
          end;
        tkStartTag: StartTag(tok);
        tkEndTag: EndTag(tok.Name);
        tkComment:
          begin
            n := TDomNode.Create(nkComment, '');
            n.Text := tok.Data;
            AddNode(n);
          end;
      else
        { tkDoctype, tkEof: nothing }
      end;
    until tok.Kind = tkEof;
  finally
    tk.Free;
  end;
end;

function ParseHtml(const Html: AnsiString): TDomDoc;
var
  b: TBuilder;
  d: TDomDoc;
begin
  d := TDomDoc.Create;
  b := TBuilder.Create(d);
  try
    b.Build(Html);
  finally
    b.Free;
  end;
  Result := d;
end;

function ParseFragment(const Html: AnsiString): TDomNode;
var
  doc: TDomDoc;
begin
  doc := ParseHtml('<body>' + Html + '</body>');
  Result := TDomNode.Create(nkElement, 'body');
  Result.Id := 0;
  if doc.Body <> nil then
    Result.AppendChild(doc.Body);
  { detach from the temporary document without freeing it }
  if Result.Children[0] <> nil then
    Result.Children[0].Parent := Result;
  doc.Html := nil;
  doc.Body := nil;
  doc.Root.RemoveChild(doc.Root.Children[0]);
  doc.Free;
end;

end.
