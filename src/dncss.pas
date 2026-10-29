{ dncss — a CSS subset for the text browser (BROWSER.md).
  Pure logic: no ncurses, no terminal, fully unit-testable.

  The cascade computes a computed style per DOM node from three origins:
  the user-agent stylesheet (TCssDefaults), the author stylesheets in
  <style> and <link>, and inline style="" attributes. Specificity and
  source order decide ties; !important wins. Selectors are the supported
  subset: type, .class, #id, *, descendant (space) and child (>), plus the
  comma list. Pseudo-classes, pseudo-elements, attribute selectors and
  :nth-child are parsed and ignored, so a page with them still styles its
  remaining rules.

  The computed style keeps only the properties the text layout uses. flex,
  grid, animations, transforms and transitions are computed away: a `display:
  flex` becomes `block`. }
unit dncss;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnhtml;

type
  TDisplay = (dpNone, dpBlock, dpInline, dpInlineBlock, dpListItem,
               dpTable, dpTableRow, dpTableCell, dpTableRowGroup, dpCaption);

  TCssStyle = record
    Display: TDisplay;
    FontWeight: Integer;      // 400 normal, 700 bold
    FontStyle: Boolean;       // italic
    Underline: Boolean;
    Align: AnsiString;        // '', 'left', 'center', 'right'
    Color: AnsiString;        // '' = inherit
    BgColor: AnsiString;      // '' = none
    MarginTop, MarginRight, MarginBottom, MarginLeft: Integer;
    PaddingTop, PaddingRight, PaddingBottom, PaddingLeft: Integer;
    Width, Height: Integer;    // 0 = auto
    ListStyle: AnsiString;    // '', 'disc', 'circle', 'square', 'decimal', ...
    WhiteSpace: AnsiString;   // '', 'pre', 'nowrap'
    Hidden: Boolean;          // display:none on this node or an ancestor
  end;

  { one parsed declaration with its selector and specificity }
  TCssRule = record
    Selector: AnsiString;
    Specificity: Integer;
    Important: Boolean;
    Prop: AnsiString;
    Value: AnsiString;
    Order: Integer;           // source order, for the tie-break
  end;
  TCssRules = array of TCssRule;

  TCssSheet = class
  private
    FRules: TCssRules;
    FOrder: Integer;
  public
    procedure Parse(const Css: AnsiString);
    procedure AddRules(const Css: AnsiString);
    function Count: Integer;
    function Get(Index: Integer): TCssRule;
    { the winner for a node: the highest specificity, then !important,
      then the last source order }
    function Winner(N: TDomNode; const Prop: AnsiString;
                    out Value: AnsiString): Boolean;
  end;

  TStyleMap = class
  private
    FNodes: array of TDomNode;
    FStyles: array of TCssStyle;
  public
    procedure SetStyle(N: TDomNode; const S: TCssStyle);
    function StyleOf(N: TDomNode): TCssStyle;
    function Count: Integer;
  end;

{ --- stylesheet collection -------------------------------------------- }

{ Collect author stylesheets from a document: <style> bodies, plus any
  external sheets the caller already fetched for <link> elements. Inline
  style="" attributes are applied by the cascade directly. }
function CollectSheets(Doc: TDomDoc): TCssSheet;
{ The user-agent stylesheet as a fresh sheet (never mutated). }
function UserAgentSheet: TCssSheet;

{ --- cascade ----------------------------------------------------------- }

{ Compute the style of every element in the document. }
function ComputeStyles(Doc: TDomDoc; Author: TCssSheet): TStyleMap;

{ --- helpers (exported for tests) -------------------------------------- }

{ Specificity of a simple/compound selector: (id, class, type) packed. }
function Specificity(const Sel: AnsiString): Integer;
{ Split a selector list on top-level commas. }
procedure SplitSelectorList(const Sel: AnsiString; L: TStringList);
{ Parse a length: '12px' -> 12, '2em' -> 32 (16 px per em), '50%' -> 0. }
function ParseLength(const S: AnsiString): Integer;
{ Parse a CSS color: #rgb, #rrggbb, a named color, or rgb(...). }
function ParseColor(const S: AnsiString): AnsiString;
function DisplayName(const S: AnsiString): TDisplay;

implementation

uses
  SysUtils;

const
  EmPx = 16;

{ --- tokenizer helpers ------------------------------------------------- }

function IsWsC(c: AnsiChar): Boolean; inline;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #13) or (c = #12);
end;

function TrimC(const S: AnsiString): AnsiString;
var
  a, b: Integer;
begin
  a := 1;
  b := Length(S);
  while (a <= b) and IsWsC(S[a]) do Inc(a);
  while (b >= a) and IsWsC(S[b]) do Dec(b);
  Result := Copy(S, a, b - a + 1);
end;

function Lower(const S: AnsiString): AnsiString;
begin
  Result := LowerCase(S);
end;

{ strip comments and collapse whitespace (CSS Syntax preprocessing) }
function Preprocess(const S: AnsiString): AnsiString;
var
  i: Integer;
  c: AnsiChar;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = '/') and (i < Length(S)) and (S[i + 1] = '*') then
    begin
      Inc(i, 2);
      while (i <= Length(S)) and
            not ((S[i] = '*') and (i < Length(S)) and (S[i + 1] = '/')) do
        Inc(i);
      Inc(i, 2);
      Continue;
    end;
    c := S[i];
    if IsWsC(c) then
    begin
      Result := Result + ' ';
      while (i <= Length(S)) and IsWsC(S[i]) do Inc(i);
      Continue;
    end;
    Result := Result + c;
    Inc(i);
  end;
end;

{ --- specificity ------------------------------------------------------- }

function Specificity(const Sel: AnsiString): Integer;
var
  i, ids, classes, types: Integer;
  c: AnsiChar;
begin
  ids := 0;
  classes := 0;
  types := 0;
  i := 1;
  while i <= Length(Sel) do
  begin
    c := Sel[i];
    if c = '#' then
    begin
      Inc(ids);
      Inc(i);
      while (i <= Length(Sel)) and (Sel[i] <> ' ') and (Sel[i] <> '>') and
            (Sel[i] <> '.') and (Sel[i] <> '#') and (Sel[i] <> ':') and
            (Sel[i] <> '[') do Inc(i);
    end
    else if c = '.' then
    begin
      Inc(classes);
      Inc(i);
      while (i <= Length(Sel)) and (Sel[i] <> ' ') and (Sel[i] <> '>') and
            (Sel[i] <> '.') and (Sel[i] <> '#') and (Sel[i] <> ':') and
            (Sel[i] <> '[') do Inc(i);
    end
    else if (c = ':') or (c = '[') then
    begin
      { pseudo-class / attribute: parsed and ignored, no specificity }
      Inc(i);
      while (i <= Length(Sel)) and (Sel[i] <> ' ') and (Sel[i] <> '>') and
            (Sel[i] <> '.') and (Sel[i] <> '#') do Inc(i);
    end
    else if (c = ' ') or (c = '>') then
      Inc(i)
    else
    begin
      Inc(types);
      while (i <= Length(Sel)) and (Sel[i] <> ' ') and (Sel[i] <> '>') and
            (Sel[i] <> '.') and (Sel[i] <> '#') and (Sel[i] <> ':') and
            (Sel[i] <> '[') do Inc(i);
    end;
  end;
  Result := ids * 10000 + classes * 100 + types;
end;

procedure SplitSelectorList(const Sel: AnsiString; L: TStringList);
var
  i, start, depth: Integer;
begin
  L.Clear;
  start := 1;
  depth := 0;
  for i := 1 to Length(Sel) do
  begin
    if Sel[i] = '(' then Inc(depth)
    else if Sel[i] = ')' then Dec(depth)
    else if (Sel[i] = ',') and (depth = 0) then
    begin
      L.Add(TrimC(Copy(Sel, start, i - start)));
      start := i + 1;
    end;
  end;
  if start <= Length(Sel) then
    L.Add(TrimC(Copy(Sel, start, MaxInt)));
end;

{ --- lengths and colors ------------------------------------------------- }

function ParseLength(const S: AnsiString): Integer;
var
  v: Double;
  num: AnsiString;
  i: Integer;
  c: AnsiChar;
begin
  num := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c >= '0') and (c <= '9') or (c = '.') or (c = '-') or (c = '+') then
      num := num + c
    else
      Break;
  end;
  v := StrToFloatDef(num, 0);
  { the unit is the tail after the number }
  if Pos('em', Lower(S)) > 0 then Exit(Round(v * EmPx));
  if Pos('rem', Lower(S)) > 0 then Exit(Round(v * EmPx));
  if Pos('%', S) > 0 then Exit(0);   // percentages resolve at layout time
  if Pos('pt', Lower(S)) > 0 then Exit(Round(v * 4 / 3));
  Result := Round(v);                 // px and unitless
end;

const
  NamedColors: array[0..15] of record
    Name: AnsiString;
    Rgb: AnsiString;
  end = (
    (Name: 'black';   Rgb: '#000000'),
    (Name: 'silver';  Rgb: '#c0c0c0'),
    (Name: 'gray';    Rgb: '#808080'),
    (Name: 'white';   Rgb: '#ffffff'),
    (Name: 'maroon';  Rgb: '#800000'),
    (Name: 'red';     Rgb: '#ff0000'),
    (Name: 'purple';  Rgb: '#800080'),
    (Name: 'fuchsia'; Rgb: '#ff00ff'),
    (Name: 'green';   Rgb: '#008000'),
    (Name: 'lime';    Rgb: '#00ff00'),
    (Name: 'olive';   Rgb: '#808000'),
    (Name: 'yellow';  Rgb: '#ffff00'),
    (Name: 'navy';    Rgb: '#000080'),
    (Name: 'blue';    Rgb: '#0000ff'),
    (Name: 'teal';    Rgb: '#008080'),
    (Name: 'aqua';    Rgb: '#00ffff')
  );

function ParseColor(const S: AnsiString): AnsiString;
var
  v, t: AnsiString;
  i: Integer;
  r, g, b: Integer;
  function H2(const X: AnsiString): Integer;
  var
    k: Integer;
  begin
    Result := 0;
    for k := 1 to Length(X) do
      case X[k] of
        '0'..'9': Result := Result * 16 + (Ord(X[k]) - Ord('0'));
        'a'..'f': Result := Result * 16 + (Ord(X[k]) - Ord('a') + 10);
        'A'..'F': Result := Result * 16 + (Ord(X[k]) - Ord('A') + 10);
      else
        Exit(-1);
      end;
  end;
begin
  v := Lower(TrimC(S));
  if v = '' then Exit('');
  if v = 'transparent' then Exit('');
  if v = 'inherit' then Exit('');
  if v = 'currentcolor' then Exit('currentcolor');
  if v[1] = '#' then
  begin
    t := Copy(v, 2, MaxInt);
    if Length(t) = 3 then
      Exit('#' + Copy(t, 1, 1) + Copy(t, 1, 1) + Copy(t, 2, 1) + Copy(t, 2, 1) +
           Copy(t, 3, 1) + Copy(t, 3, 1));
    if Length(t) = 6 then Exit('#' + t);
    Exit('');
  end;
  if Copy(v, 1, 4) = 'rgb(' then
  begin
    t := Copy(v, 5, MaxInt);
    i := Pos(')', t);
    if i > 0 then t := Copy(t, 1, i - 1);
    i := Pos(',', t);
    if i = 0 then Exit('');
    r := StrToIntDef(TrimC(Copy(t, 1, i - 1)), -1);
    t := Copy(t, i + 1, MaxInt);
    i := Pos(',', t);
    if i = 0 then Exit('');
    g := StrToIntDef(TrimC(Copy(t, 1, i - 1)), -1);
    b := StrToIntDef(TrimC(Copy(t, i + 1, MaxInt)), -1);
    if (r < 0) or (g < 0) or (b < 0) then Exit('');
    Exit('#' + IntToHex(r, 2) + IntToHex(g, 2) + IntToHex(b, 2));
  end;
  for i := Low(NamedColors) to High(NamedColors) do
    if NamedColors[i].Name = v then Exit(NamedColors[i].Rgb);
  Result := '';
end;

function DisplayName(const S: AnsiString): TDisplay;
var
  v: AnsiString;
begin
  v := Lower(TrimC(S));
  if v = 'none' then Result := dpNone
  else if v = 'block' then Result := dpBlock
  else if v = 'inline' then Result := dpInline
  else if v = 'inline-block' then Result := dpInlineBlock
  else if v = 'list-item' then Result := dpListItem
  else if v = 'table' then Result := dpTable
  else if v = 'table-row' then Result := dpTableRow
  else if v = 'table-cell' then Result := dpTableCell
  else if (v = 'table-row-group') or (v = 'table-header-group') or
          (v = 'table-footer-group') then Result := dpTableRowGroup
  else if (v = 'table-caption') then Result := dpCaption
  else if (v = 'flex') or (v = 'inline-flex') or (v = 'grid') or
          (v = 'inline-grid') then Result := dpBlock
  else if v = 'inline-block' then Result := dpInlineBlock
  else Result := dpInline;
end;

{ --- the sheet --------------------------------------------------------- }

procedure TCssSheet.Parse(const Css: AnsiString);
begin
  FRules := nil;
  FOrder := 0;
  AddRules(Css);
end;

procedure TCssSheet.AddRules(const Css: AnsiString);
var
  s: AnsiString;
  i, n: Integer;
  prelude, block, rest: AnsiString;
  parts, decls, sels: TStringList;
  k, p: Integer;
  prop, val: AnsiString;
  sel: AnsiString;
  r: TCssRule;
  inMedia: Boolean;
  imp: Boolean;

  procedure AddDecl(const ASel: AnsiString; ASpec: Integer;
                    const AImportant: Boolean; const AProp, AVal: AnsiString);
  begin
    SetLength(FRules, Length(FRules) + 1);
    r := FRules[High(FRules)];
    r.Selector := ASel;
    r.Specificity := ASpec;
    r.Important := AImportant;
    r.Prop := Lower(TrimC(AProp));
    r.Value := TrimC(AVal);
    r.Order := FOrder;
    Inc(FOrder);
    FRules[High(FRules)] := r;
  end;

  { top-level segments: text between closing braces of consecutive rule sets,
    quoted strings preserved }
  procedure SplitSegments(const S: AnsiString; L: TStringList);
  var
    i, start: Integer;
    q: AnsiChar;
  begin
    q := #0;
    start := 1;
    for i := 1 to Length(S) do
    begin
      if q <> #0 then
      begin
        if S[i] = q then q := #0;
        Continue;
      end;
      if (S[i] = '"') or (S[i] = '''') then q := S[i]
      else if S[i] = '}' then
      begin
        L.Add(Copy(S, start, i - start));
        start := i + 1;
      end;
    end;
    if start <= Length(S) then L.Add(Copy(S, start, MaxInt));
  end;

  { declarations separated by ';' at brace depth 0, so a nested @media block
    is not chopped into pseudo-declarations }
  procedure SplitDecls(const S: AnsiString; L: TStringList);
  var
    i, depth, start: Integer;
  begin
    depth := 0;
    start := 1;
    for i := 1 to Length(S) do
      case S[i] of
        '{': Inc(depth);
        '}': Dec(depth);
        ';':
          if depth = 0 then
          begin
            L.Add(Copy(S, start, i - start));
            start := i + 1;
          end;
      end;
    if start <= Length(S) then L.Add(Copy(S, start, MaxInt));
  end;

  { a statement-terminated at-rule such as '@import "x.css";' precedes real
    rule sets inside one segment; drop that statement and re-parse the rest }
  function DropLeadingAtRule(const S: AnsiString): AnsiString;
  var
    i, j: Integer;
    q: AnsiChar;
  begin
    Result := '';
    if Copy(Lower(TrimC(S)), 1, 1) <> '@' then Exit;
    q := #0;
    j := 0;
    for i := 1 to Length(S) do
    begin
      if q <> #0 then
      begin
        if S[i] = q then q := #0;
        Continue;
      end;
      if (S[i] = '"') or (S[i] = '''') then q := S[i]
      else if S[i] = '{' then Exit
      else if S[i] = ';' then
      begin
        j := i;
        Break;
      end;
    end;
    if j = 0 then Exit;
    Result := TrimC(Copy(S, j + 1, MaxInt));
  end;

begin
  s := Preprocess(Css);
  parts := TStringList.Create;
  try
    SplitSegments(s, parts);
    for i := 0 to parts.Count - 1 do
    begin
      n := Pos('{', parts[i]);
      if n = 0 then Continue;
      prelude := TrimC(Copy(parts[i], 1, n - 1));
      block := Copy(parts[i], n + 1, MaxInt);
      if prelude = '' then Continue;
      inMedia := False;
      if (Copy(Lower(prelude), 1, 6) = '@media') then
      begin
        if (Pos('screen', Lower(prelude)) = 0) and
           (Pos('all', Lower(prelude)) = 0) then Continue;
        { strip the @media prefix }
        n := Pos('{', prelude);   // not present; prelude is the condition
        prelude := TrimC(Copy(prelude, 7, MaxInt));
        inMedia := True;
      end;
      if (Copy(Lower(prelude), 1, 1) = '@') and (not inMedia) then
      begin
        rest := DropLeadingAtRule(parts[i]);
        if rest <> '' then AddRules(rest);
        Continue;
      end;
      if inMedia then
      begin
        { inside @media the block is a nested rule set }
        decls := TStringList.Create;
        try
          decls.Delimiter := '}';
          decls.StrictDelimiter := True;
          decls.DelimitedText := block;
          for k := 0 to decls.Count - 1 do
          begin
            n := Pos('{', decls[k]);
            if n = 0 then Continue;
            AddRules(TrimC(Copy(decls[k], 1, n - 1)) + '{' +
                     Copy(decls[k], n + 1, MaxInt));
          end;
        finally
          decls.Free;
        end;
        Continue;
      end;

      { split the prelude on commas into selectors }
      sels := TStringList.Create;
      try
        SplitSelectorList(prelude, sels);
        { parse declarations }
        { declarations split on ';' only, so a nested block survives }
        decls := TStringList.Create;
        try
          SplitDecls(block, decls);
          for k := 0 to sels.Count - 1 do
          begin
            sel := sels[k];
            if sel = '' then Continue;
            for p := 0 to decls.Count - 1 do
            begin
              n := Pos(':', decls[p]);
              if n = 0 then Continue;
              prop := Copy(decls[p], 1, n - 1);
              val := TrimC(Copy(decls[p], n + 1, MaxInt));
              if TrimC(prop) = '' then Continue;
              imp := Pos('!important', Lower(val)) > 0;
              AddDecl(sel, Specificity(sel), imp, prop, val);
            end;
          end;
        finally
          decls.Free;
        end;
      finally
        sels.Free;
      end;
    end;
  finally
    parts.Free;
  end;
end;

function TCssSheet.Count: Integer;
begin
  Result := Length(FRules);
end;

function TCssSheet.Get(Index: Integer): TCssRule;
begin
  if (Index < 0) or (Index > High(FRules)) then
  begin
    Result.Prop := '';
    Exit;
  end;
  Result := FRules[Index];
end;

function TCssSheet.Winner(N: TDomNode; const Prop: AnsiString;
                          out Value: AnsiString): Boolean;
var
  i, b: Integer;
  bestSpec, bestOrder: Integer;
  bestImp: Boolean;
  found: Boolean;
begin
  Value := '';
  found := False;
  bestSpec := -1;
  bestOrder := -1;
  bestImp := False;
  for i := 0 to High(FRules) do
  begin
    if FRules[i].Prop <> Prop then Continue;
    if not MatchSelector(N, FRules[i].Selector) then Continue;
    if (not found) or
       (FRules[i].Important and not bestImp) or
       (FRules[i].Important = bestImp) and
       ((FRules[i].Specificity > bestSpec) or
        ((FRules[i].Specificity = bestSpec) and
         (FRules[i].Order > bestOrder))) then
    begin
      Value := FRules[i].Value;
      bestSpec := FRules[i].Specificity;
      bestOrder := FRules[i].Order;
      bestImp := FRules[i].Important;
      found := True;
    end;
  end;
  Result := found;
  if found then
  begin
    b := Pos('!', Value);
    if b > 0 then Value := TrimC(Copy(Value, 1, b - 1));
  end;
end;

{ --- user-agent stylesheet ---------------------------------------------- }

const
  UaCss =
    'html, body { display: block; margin: 0; padding: 0 } ' +
    'head, script, style, meta, link, title, base { display: none } ' +
    'div, p, section, article, aside, header, footer, nav, main, figure, ' +
    'figcaption, blockquote, address, dl, fieldset, form { display: block; ' +
    'margin: 0 0 1em 0 } ' +
    'h1 { display: block; font-weight: bold; margin: 1em 0 } ' +
    'h2 { display: block; font-weight: bold; margin: 1em 0 } ' +
    'h3 { display: block; font-weight: bold; margin: 1em 0 } ' +
    'h4 { display: block; font-weight: bold; margin: 1em 0 } ' +
    'h5 { display: block; font-weight: bold; margin: 1em 0 } ' +
    'h6 { display: block; font-weight: bold; margin: 1em 0 } ' +
    'ul, ol { display: block; margin: 1em 0; padding: 0 0 0 2em } ' +
    'li { display: list-item } ' +
    'pre { display: block; white-space: pre; margin: 1em 0 } ' +
    'hr { display: block; margin: 1em 0 } ' +
    'table { display: table; margin: 1em 0 } ' +
    'tr { display: table-row } ' +
    'td, th { display: table-cell; padding: 0 1em 0 0 } ' +
    'th { font-weight: bold } ' +
    'b, strong { font-weight: bold } ' +
    'i, em, cite, var { font-style: italic } ' +
    'u, ins { text-decoration: underline } ' +
    's, strike, del { text-decoration: line-through } ' +
    'code, kbd, samp, tt, pre { font-style: normal } ' +
    'a { display: inline; text-decoration: underline } ' +
    'br { display: inline } ' +
    'center { display: block; text-align: center } ' +
    'blockquote { margin: 1em 2em } ' +
    'small { font-size: 0.8em } ' +
    'big { font-size: 1.2em }';

var
  UaSheet: TCssSheet = nil;

function UserAgentSheet: TCssSheet;
begin
  if UaSheet = nil then
  begin
    UaSheet := TCssSheet.Create;
    UaSheet.Parse(UaCss);
  end;
  Result := UaSheet;
end;

function CollectSheets(Doc: TDomDoc): TCssSheet;
var
  L: TDomNodeArray;
  i: Integer;
  s: AnsiString;
  n: TDomNode;
begin
  Result := TCssSheet.Create;
  { author <style> blocks, in document order }
  L := Doc.GetElementsByTagName('style');
  for i := 0 to High(L) do
  begin
    s := '';
    if Length(L[i].Children) > 0 then
      s := L[i].Children[0].Text;
    if s <> '' then
      Result.AddRules(s);
  end;
  { link[rel=stylesheet] bodies the caller fetched are stored as text children
    of the link element under the attribute data-dn-css }
  L := Doc.GetElementsByTagName('link');
  for i := 0 to High(L) do
  begin
    n := L[i];
    s := n.Attr('data-dn-css');
    if s <> '' then
      Result.AddRules(s);
  end;
end;

{ --- cascade ------------------------------------------------------------ }

procedure TStyleMap.SetStyle(N: TDomNode; const S: TCssStyle);
var
  i: Integer;
begin
  for i := 0 to High(FNodes) do
    if FNodes[i] = N then
    begin
      FStyles[i] := S;
      Exit;
    end;
  SetLength(FNodes, Length(FNodes) + 1);
  SetLength(FStyles, Length(FStyles) + 1);
  FNodes[High(FNodes)] := N;
  FStyles[High(FStyles)] := S;
end;

function TStyleMap.StyleOf(N: TDomNode): TCssStyle;
var
  i: Integer;
begin
  for i := 0 to High(FNodes) do
    if FNodes[i] = N then Exit(FStyles[i]);
  { default: an element with no computed style is inline }
  FillChar(Result, SizeOf(Result), 0);
  Result.Display := dpInline;
  Result.FontWeight := 400;
  Result.WhiteSpace := '';
end;

function TStyleMap.Count: Integer;
begin
  Result := Length(FNodes);
end;

function ApplyProp(var S: TCssStyle; const Prop, Value: AnsiString): Boolean;
var
  v: AnsiString;
begin
  Result := True;
  v := Lower(TrimC(Value));
  if Prop = 'display' then S.Display := DisplayName(v)
  else if Prop = 'font-weight' then
  begin
    if (v = 'bold') or (v = 'bolder') or (StrToIntDef(v, 400) >= 600) then
      S.FontWeight := 700
    else if v = 'normal' then S.FontWeight := 400
    else S.FontWeight := StrToIntDef(v, 400);
  end
  else if Prop = 'font-style' then
    S.FontStyle := (v = 'italic') or (v = 'oblique')
  else if Prop = 'text-decoration' then
    S.Underline := Pos('underline', v) > 0
  else if Prop = 'text-align' then
  begin
    if (v = 'left') or (v = 'center') or (v = 'right') then S.Align := v;
  end
  else if Prop = 'color' then
  begin
    if v = 'currentcolor' then S.Color := ''
    else S.Color := ParseColor(v);
  end
  else if Prop = 'background-color' then S.BgColor := ParseColor(v)
  else if Prop = 'background' then
  begin
    if S.BgColor = '' then S.BgColor := ParseColor(v);
  end
  else if Prop = 'margin' then
  begin
    S.MarginTop := ParseLength(v);
    S.MarginRight := S.MarginTop;
    S.MarginBottom := S.MarginTop;
    S.MarginLeft := S.MarginTop;
  end
  else if Prop = 'margin-top' then S.MarginTop := ParseLength(v)
  else if Prop = 'margin-right' then S.MarginRight := ParseLength(v)
  else if Prop = 'margin-bottom' then S.MarginBottom := ParseLength(v)
  else if Prop = 'margin-left' then S.MarginLeft := ParseLength(v)
  else if Prop = 'padding' then
  begin
    S.PaddingTop := ParseLength(v);
    S.PaddingRight := S.PaddingTop;
    S.PaddingBottom := S.PaddingTop;
    S.PaddingLeft := S.PaddingTop;
  end
  else if Prop = 'padding-top' then S.PaddingTop := ParseLength(v)
  else if Prop = 'padding-right' then S.PaddingRight := ParseLength(v)
  else if Prop = 'padding-bottom' then S.PaddingBottom := ParseLength(v)
  else if Prop = 'padding-left' then S.PaddingLeft := ParseLength(v)
  else if Prop = 'width' then S.Width := ParseLength(v)
  else if Prop = 'height' then S.Height := ParseLength(v)
  else if Prop = 'list-style' then S.ListStyle := v
  else if Prop = 'list-style-type' then S.ListStyle := v
  else if Prop = 'white-space' then S.WhiteSpace := v
  else
    Result := False;   // unknown property: ignored
end;

function ComputeStyles(Doc: TDomDoc; Author: TCssSheet): TStyleMap;
var
  L: TDomNodeArray;
  i: Integer;
  n: TDomNode;
  s, ua: TCssStyle;
  props: array[0..21] of AnsiString;
  j: Integer;
  val: AnsiString;
  inline: AnsiString;
  parentStyle: TCssStyle;
  decls: TStringList;
  n2: Integer;
  prop: AnsiString;

  procedure ApplyInline(var St: TCssStyle);
  var
    q: Integer;
  begin
    if inline = '' then Exit;
    decls.Delimiter := ';';
    decls.StrictDelimiter := True;
    decls.DelimitedText := inline;
    for q := 0 to decls.Count - 1 do
    begin
      n2 := Pos(':', decls[q]);
      if n2 = 0 then Continue;
      prop := Lower(TrimC(Copy(decls[q], 1, n2 - 1)));
      if prop = '' then Continue;
      ApplyProp(St, prop, Copy(decls[q], n2 + 1, MaxInt));
    end;
  end;

begin
  Result := TStyleMap.Create;
  FillChar(s, SizeOf(s), 0);
  FillChar(ua, SizeOf(ua), 0);
  s.Display := dpInline;
  s.FontWeight := 400;
  s.WhiteSpace := '';
  props[0] := 'display'; props[1] := 'font-weight'; props[2] := 'font-style';
  props[3] := 'text-decoration'; props[4] := 'text-align';
  props[5] := 'color'; props[6] := 'background-color';
  props[7] := 'margin-top'; props[8] := 'margin-right';
  props[9] := 'margin-bottom'; props[10] := 'margin-left';
  props[11] := 'padding-top'; props[12] := 'padding-right';
  props[13] := 'padding-bottom'; props[14] := 'padding-left';
  props[15] := 'width'; props[16] := 'list-style-type';
  props[17] := 'margin'; props[18] := 'padding';
  props[19] := 'white-space'; props[20] := 'list-style';
  props[21] := 'background';

  decls := TStringList.Create;
  try
    L := Doc.GetElementsByTagName('*');
    { GetElementsByTagName('*') returns every element }
    for i := 0 to High(L) do
    begin
      n := L[i];
      { start from the parent's computed style for inheritance }
      if n.Parent <> nil then
        parentStyle := Result.StyleOf(n.Parent)
      else
        parentStyle := s;
      FillChar(s, SizeOf(s), 0);
      s.Display := dpInline;
      s.FontWeight := parentStyle.FontWeight;
      s.FontStyle := parentStyle.FontStyle;
      s.Underline := parentStyle.Underline;
      s.Align := '';
      s.Color := parentStyle.Color;
      s.BgColor := '';
      s.ListStyle := parentStyle.ListStyle;
      s.WhiteSpace := parentStyle.WhiteSpace;
      s.MarginTop := 0; s.MarginRight := 0;
      s.MarginBottom := 0; s.MarginLeft := 0;
      s.PaddingTop := 0; s.PaddingRight := 0;
      s.PaddingBottom := 0; s.PaddingLeft := 0;
      s.Width := 0; s.Height := 0;

      { user-agent first }
      for j := Low(props) to High(props) do
        if UserAgentSheet.Winner(n, props[j], val) then
          ApplyProp(s, props[j], val);
      { then author }
      if Author <> nil then
        for j := Low(props) to High(props) do
          if Author.Winner(n, props[j], val) then
            ApplyProp(s, props[j], val);
      { then inline }
      inline := n.Attr('style');
      ApplyInline(s);

      { display:none anywhere hides the subtree }
      if s.Display = dpNone then s.Hidden := True
      else s.Hidden := parentStyle.Hidden;
      if s.Hidden then s.Display := dpNone;

      Result.SetStyle(n, s);
    end;
  finally
    decls.Free;
  end;
end;

end.
