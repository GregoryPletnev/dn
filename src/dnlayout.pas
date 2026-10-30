{ dnlayout — the text layout engine for the browser (BROWSER.md).
  Pure logic: no ncurses, no terminal, fully unit-testable.

  The engine walks a DOM tree with computed styles and produces a flat
  list of display lines. Each line is a list of runs; a run is a string
  with a style and an optional link. Layout is a pure function of the DOM,
  the styles and the viewport width, so it is tested without a terminal.

  Layout is block and inline flow only. Tables become fixed text grids;
  lists get markers; <pre> is verbatim; images become [alt] placeholders.
  flex, grid, animations and transforms are computed away by the cascade
  and never reach here. }
unit dnlayout;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnhtml, dncss;

type
  TLayoutRun = record
    Text: AnsiString;
    Bold: Boolean;
    Italic: Boolean;
    Underline: Boolean;
    Color: AnsiString;
    BgColor: AnsiString;
    Link: AnsiString;        // href for a link run, '' otherwise
    Image: AnsiString;       // alt text for an image run, '' otherwise
    Break: Boolean;          // a <br> hard break marker
  end;
  TLayoutRuns = array of TLayoutRun;

  TLayoutLine = record
    Runs: TLayoutRuns;
    Indent: Integer;         // left indent in columns
    Align: AnsiString;       // '', 'left', 'center', 'right'
    Pre: Boolean;            // verbatim: no wrapping
    IsRule: Boolean;         // an <hr> line
    Marker: AnsiString;      // '', '*', '1.', ... (list marker)
    Blank: Boolean;          // a blank separator line
    Heading: Integer;        // 0 = body, 1..6 for h1..h6
  end;
  TLayoutLines = array of TLayoutLine;

  TLayout = class
  private
    FLines: TLayoutLines;
    FCols: Integer;
  public
    constructor Create(Acols: Integer);
    procedure EnsureLine;
    procedure AddBlank;
    procedure AppendLine(const L: TLayoutLine);
    procedure SetLastIndent(AIndent: Integer);
    procedure SetLastMarker(const AMarker: AnsiString);
    procedure SetLastAlign(const AAlign: AnsiString);
    procedure SetLastPre(APre: Boolean);
    procedure SetLastRule(ARule: Boolean);
    procedure SetLastHeading(AHeading: Integer);
    procedure SetLastRuns(const ARuns: TLayoutRuns);
    procedure AppendRun(const ARun: TLayoutRun);
    function Count: Integer;
    function Get(Index: Integer): TLayoutLine;
    property Cols: Integer read FCols;
  end;

{ Lay out a whole document into display lines. Cols is the viewport width. }
function LayoutDocument(Doc: TDomDoc; Styles: TStyleMap;
                        Cols: Integer): TLayout;

{ A run's visible width in columns (UTF-8 aware). }
function RunWidth(const R: TLayoutRun): Integer;
function LineWidth(const L: TLayoutLine): Integer;
{ The plain text of a line, markers and indents included. }
function LineText(const L: TLayoutLine): AnsiString;

{ --- helpers (exported for tests) -------------------------------------- }

function IsBlockDisplay(D: TDisplay): Boolean;
function IsListTag(const T: AnsiString): Boolean;
function IsHeading(const T: AnsiString): Boolean;
function HeadingLevel(const T: AnsiString): Integer;
function ListMarker(const N: TDomNode; Index: Integer): AnsiString;
function CollapseWs(const S: AnsiString): AnsiString;

implementation

uses
  SysUtils, dnscreen;

{ --- helpers ----------------------------------------------------------- }

function IsSpaceChar(c: AnsiChar): Boolean; inline;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #13);
end;

function CollapseWs(const S: AnsiString): AnsiString;
var
  i: Integer;
  lastWs: Boolean;
begin
  Result := '';
  lastWs := False;
  for i := 1 to Length(S) do
  begin
    if IsSpaceChar(S[i]) then
    begin
      if not lastWs then Result := Result + ' ';
      lastWs := True;
    end
    else
    begin
      Result := Result + S[i];
      lastWs := False;
    end;
  end;
end;

function IsBlockDisplay(D: TDisplay): Boolean;
begin
  Result := (D = dpBlock) or (D = dpListItem) or (D = dpTable) or
            (D = dpTableRow) or (D = dpTableCell) or
            (D = dpTableRowGroup) or (D = dpCaption);
end;

function IsListTag(const T: AnsiString): Boolean;
begin
  Result := (T = 'ul') or (T = 'ol') or (T = 'menu') or (T = 'dir');
end;

function IsHeading(const T: AnsiString): Boolean;
begin
  Result := (T = 'h1') or (T = 'h2') or (T = 'h3') or (T = 'h4') or
            (T = 'h5') or (T = 'h6');
end;

function HeadingLevel(const T: AnsiString): Integer;
begin
  if (Length(T) = 2) and (T[1] = 'h') and (T[2] >= '1') and (T[2] <= '6') then
    Result := Ord(T[2]) - Ord('0')
  else
    Result := 0;
end;

function ListMarker(const N: TDomNode; Index: Integer): AnsiString;
var
  s: AnsiString;
begin
  if N.Tag = 'ol' then
    Exit(IntToStr(Index) + '. ');
  if N.Tag = 'menu' then
    Exit('- ');
  s := N.Attr('style');
  if Pos('circle', s) > 0 then Exit('o ');
  if Pos('square', s) > 0 then Exit('# ');
  Result := '* ';
end;

{ --- TLayout ----------------------------------------------------------- }

constructor TLayout.Create(Acols: Integer);
begin
  inherited Create;
  FCols := Acols;
  if FCols < 8 then FCols := 8;
  FLines := nil;
end;

procedure TLayout.EnsureLine;
begin
  if Length(FLines) = 0 then
    SetLength(FLines, 1);
end;

procedure TLayout.AddBlank;
begin
  SetLength(FLines, Length(FLines) + 1);
  FillChar(FLines[High(FLines)], SizeOf(TLayoutLine), 0);
  FLines[High(FLines)].Blank := True;
end;

procedure TLayout.AppendLine(const L: TLayoutLine);
begin
  SetLength(FLines, Length(FLines) + 1);
  FLines[High(FLines)] := L;
end;

procedure TLayout.SetLastIndent(AIndent: Integer);
begin
  EnsureLine;
  FLines[High(FLines)].Indent := AIndent;
end;

procedure TLayout.SetLastMarker(const AMarker: AnsiString);
begin
  EnsureLine;
  FLines[High(FLines)].Marker := AMarker;
end;

procedure TLayout.SetLastAlign(const AAlign: AnsiString);
begin
  EnsureLine;
  FLines[High(FLines)].Align := AAlign;
end;

procedure TLayout.SetLastPre(APre: Boolean);
begin
  EnsureLine;
  FLines[High(FLines)].Pre := APre;
end;

procedure TLayout.SetLastRule(ARule: Boolean);
begin
  EnsureLine;
  FLines[High(FLines)].IsRule := ARule;
end;

procedure TLayout.SetLastHeading(AHeading: Integer);
begin
  EnsureLine;
  FLines[High(FLines)].Heading := AHeading;
end;

procedure TLayout.SetLastRuns(const ARuns: TLayoutRuns);
begin
  EnsureLine;
  FLines[High(FLines)].Runs := ARuns;
end;

{ append a run to the current (last) line }
procedure TLayout.AppendRun(const ARun: TLayoutRun);
begin
  EnsureLine;
  SetLength(FLines[High(FLines)].Runs,
            Length(FLines[High(FLines)].Runs) + 1);
  FLines[High(FLines)].Runs[High(FLines[High(FLines)].Runs)] := ARun;
end;

function TLayout.Count: Integer;
begin
  Result := Length(FLines);
end;

function TLayout.Get(Index: Integer): TLayoutLine;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (Index >= 0) and (Index <= High(FLines)) then
    Result := FLines[Index];
end;

function RunWidth(const R: TLayoutRun): Integer;
begin
  Result := Utf8Len(R.Text);
end;

function LineWidth(const L: TLayoutLine): Integer;
var
  i: Integer;
begin
  Result := L.Indent + Utf8Len(L.Marker);
  if L.Runs <> nil then
    for i := 0 to High(L.Runs) do
      Result := Result + RunWidth(L.Runs[i]);
end;

function LineText(const L: TLayoutLine): AnsiString;
var
  i: Integer;
begin
  Result := StringOfChar(' ', L.Indent) + L.Marker;
  if L.Runs <> nil then
    for i := 0 to High(L.Runs) do
      Result := Result + L.Runs[i].Text;
end;

{ build a run; a break run has empty text and Break = True }
function MakeRun(const Text: AnsiString; const St: TCssStyle;
                 const Link, Image: AnsiString; ABreak: Boolean): TLayoutRun;
begin
  Result.Text := Text;
  Result.Bold := St.FontWeight >= 600;
  Result.Italic := St.FontStyle;
  Result.Underline := St.Underline;
  Result.Color := St.Color;
  Result.BgColor := St.BgColor;
  Result.Link := Link;
  Result.Image := Image;
  Result.Break := ABreak;
end;

procedure AddRun(var Runs: TLayoutRuns; const Text: AnsiString;
                  const St: TCssStyle; const Link, Image: AnsiString;
                  ABreak: Boolean);
begin
  if (Text = '') and not ABreak then
    Exit;
  SetLength(Runs, Length(Runs) + 1);
  Runs[High(Runs)] := MakeRun(Text, St, Link, Image, ABreak);
end;

{ --- inline collection -------------------------------------------------- }

procedure CollectInline(N: TDomNode; Styles: TStyleMap;
                        var Runs: TLayoutRuns; const Link: AnsiString);
var
  i: Integer;
  st: TCssStyle;
  child: TDomNode;
  href, alt, s: AnsiString;
begin
  for i := 0 to High(N.Children) do
  begin
    child := N.Children[i];
    if child.Kind = nkText then
    begin
      st := Styles.StyleOf(N);
      if N.Tag = 'pre' then
        s := child.Text
      else
        s := CollapseWs(child.Text);
      if s <> '' then
        AddRun(Runs, s, st, Link, '', False);
    end
    else if child.Kind = nkElement then
    begin
      st := Styles.StyleOf(child);
      if st.Display = dpNone then
        Continue;
      if IsBlockDisplay(st.Display) then
        Continue;
      if child.Tag = 'br' then
      begin
        AddRun(Runs, '', st, Link, '', True);
        Continue;
      end;
      if child.Tag = 'img' then
      begin
        alt := child.Attr('alt');
        if alt = '' then alt := 'img';
        AddRun(Runs, '[' + alt + ']', st, Link, alt, False);
        Continue;
      end;
      if child.Tag = 'a' then
      begin
        href := child.Attr('href');
        if href = '' then href := Link;
      end
      else
        href := Link;
      CollectInline(child, Styles, Runs, href);
    end;
  end;
end;

procedure LayoutNode(N: TDomNode; Styles: TStyleMap; var L: TLayout;
                     Indent, Avail: Integer); forward;
procedure LayoutListItem(N: TDomNode; Styles: TStyleMap; var L: TLayout;
                         Indent, Avail: Integer;
                         const Marker: AnsiString); forward;
procedure LayoutTable(N: TDomNode; Styles: TStyleMap; var L: TLayout;
                      Indent, Avail: Integer); forward;
procedure LayoutPre(N: TDomNode; Styles: TStyleMap; var L: TLayout;
                    Indent: Integer); forward;

{ --- table collection --------------------------------------------------- }

procedure CollectRows(N: TDomNode; var Acc: TDomNodeArray);
var
  i: Integer;
  ch: TDomNode;
begin
  for i := 0 to High(N.Children) do
  begin
    ch := N.Children[i];
    if ch.Kind <> nkElement then
      Continue;
    if ch.Tag = 'tr' then
    begin
      SetLength(Acc, Length(Acc) + 1);
      Acc[High(Acc)] := ch;
    end
    else if (ch.Tag = 'thead') or (ch.Tag = 'tbody') or (ch.Tag = 'tfoot') then
      CollectRows(ch, Acc);
  end;
end;

procedure CollectCells(N: TDomNode; var Acc: TDomNodeArray);
var
  i: Integer;
  ch: TDomNode;
begin
  for i := 0 to High(N.Children) do
  begin
    ch := N.Children[i];
    if ch.Kind <> nkElement then
      Continue;
    if (ch.Tag = 'td') or (ch.Tag = 'th') then
    begin
      SetLength(Acc, Length(Acc) + 1);
      Acc[High(Acc)] := ch;
    end;
  end;
end;

procedure CollectCellText(N: TDomNode; var S: AnsiString);
var
  i: Integer;
begin
  if N.Kind = nkText then
  begin
    S := S + N.Text;
    Exit;
  end;
  if (N.Kind = nkElement) and ((N.Tag = 'script') or (N.Tag = 'style')) then
    Exit;
  for i := 0 to High(N.Children) do
    CollectCellText(N.Children[i], S);
end;

procedure CollectRawText(N: TDomNode; var S: AnsiString);
var
  i: Integer;
begin
  if N.Kind = nkText then
  begin
    S := S + N.Text;
    Exit;
  end;
  for i := 0 to High(N.Children) do
    CollectRawText(N.Children[i], S);
end;

{ --- block flow -------------------------------------------------------- }

procedure EmitLine(L: TLayout; const Rs: TLayoutRuns; const AIndent: Integer;
                    const AAlign: AnsiString; const APre, ARule: Boolean;
                    const AMarker: AnsiString; const AHeading: Integer);
var
  ln: TLayoutLine;
  k: Integer;
begin
  FillChar(ln, SizeOf(ln), 0);
  { deep-copy the runs so later additions to the caller's array do not
    mutate this line through the shared dynamic-array reference }
  SetLength(ln.Runs, Length(Rs));
  for k := 0 to High(Rs) do
    ln.Runs[k] := Rs[k];
  ln.Indent := AIndent;
  ln.Align := AAlign;
  ln.Pre := APre;
  ln.IsRule := ARule;
  ln.Marker := AMarker;
  ln.Heading := AHeading;
  L.AppendLine(ln);
end;

procedure LayoutTable(N: TDomNode; Styles: TStyleMap; var L: TLayout;
                      Indent, Avail: Integer);
var
  rows, cells: TDomNodeArray;
  r, c, w, ncols: Integer;
  rowRuns: TLayoutRuns;
  colW: array of Integer;
  s: AnsiString;
  st: TCssStyle;
begin
  rows := nil;
  CollectRows(N, rows);
  ncols := 0;
  for r := 0 to High(rows) do
  begin
    cells := nil;
    CollectCells(rows[r], cells);
    if Length(cells) > ncols then
      ncols := Length(cells);
  end;
  if ncols = 0 then
    Exit;
  SetLength(colW, ncols);
  for c := 0 to ncols - 1 do
    colW[c] := 0;

  for r := 0 to High(rows) do
  begin
    cells := nil;
    CollectCells(rows[r], cells);
    for c := 0 to High(cells) do
    begin
      s := '';
      CollectCellText(cells[c], s);
      s := CollapseWs(s);
      w := Utf8Len(s);
      if w > colW[c] then
        colW[c] := w;
    end;
  end;

  for r := 0 to High(rows) do
  begin
    cells := nil;
    CollectCells(rows[r], cells);
    rowRuns := nil;
    for c := 0 to High(cells) do
    begin
      st := Styles.StyleOf(cells[c]);
      s := '';
      CollectCellText(cells[c], s);
      s := CollapseWs(s);
      w := colW[c] + 2;
      if Utf8Len(s) > w then
        s := Utf8Copy(s, 1, w);
      s := Utf8PadRight(s, w);
      AddRun(rowRuns, s, st, '', '', False);
    end;
    EmitLine(L, rowRuns, Indent, '', False, False, '', 0);
  end;
end;

procedure LayoutPre(N: TDomNode; Styles: TStyleMap; var L: TLayout;
                     Indent: Integer);
var
  s: AnsiString;
  i, a, b: Integer;
  st: TCssStyle;
begin
  st := Styles.StyleOf(N);
  s := '';
  CollectRawText(N, s);
  a := 1;
  for i := 1 to Length(s) + 1 do
    if (i > Length(s)) or (s[i] = #10) then
    begin
      b := i - 1;
      EmitLine(L, nil, Indent, '', True, False, '', 0);
      if b >= a then
        L.AppendRun(MakeRun(Copy(s, a, b - a + 1), st, '', '', False));
      a := i + 1;
    end;
end;

procedure LayoutListItem(N: TDomNode; Styles: TStyleMap; var L: TLayout;
                          Indent, Avail: Integer; const Marker: AnsiString);
var
  i: Integer;
  child: TDomNode;
  runs: TLayoutRuns;
  s: AnsiString;
  st: TCssStyle;
  emitted: Boolean;
begin
  st := Styles.StyleOf(N);
  runs := nil;
  emitted := False;
  for i := 0 to High(N.Children) do
  begin
    child := N.Children[i];
    if child.Kind = nkText then
    begin
      s := CollapseWs(child.Text);
      if s <> '' then
        AddRun(runs, s, st, '', '', False);
    end
    else if child.Kind = nkElement then
    begin
      if IsBlockDisplay(Styles.StyleOf(child).Display) then
      begin
        { flush the marker with the inline content so far, then recurse }
        EmitLine(L, runs, Indent, '', False, False, Marker, 0);
        runs := nil;
        emitted := True;
        LayoutNode(child, Styles, L, Indent + 2, Avail);
      end
      else
        CollectInline(child, Styles, runs, '');
    end;
  end;
  { emit the pending line with the marker; if a block child already flushed
    it, the marker goes on the next line only when there is content }
  if runs <> nil then
    EmitLine(L, runs, Indent, '', False, False, Marker, 0)
  else if not emitted then
    EmitLine(L, nil, Indent, '', False, False, Marker, 0);
end;

procedure LayoutNode(N: TDomNode; Styles: TStyleMap; var L: TLayout;
                     Indent, Avail: Integer);
var
  i: Integer;
  st: TCssStyle;
  child: TDomNode;
  runs: TLayoutRuns;
  marker: AnsiString;
  listIdx: Integer;
  s: AnsiString;
  href: AnsiString;
begin
  if N = nil then
    Exit;
  st := Styles.StyleOf(N);
  if st.Display = dpNone then
    Exit;

  if N.Tag = 'hr' then
  begin
    EmitLine(L, nil, Indent, '', False, True, '', 0);
    Exit;
  end;

  if not IsBlockDisplay(st.Display) then
  begin
    { an inline element at the top level }
    runs := nil;
    CollectInline(N, Styles, runs, '');
    if runs <> nil then
      EmitLine(L, runs, Indent, '', False, False, '', 0);
    Exit;
  end;

  { vertical top margin as blank lines (16 px per line) }
  for i := 1 to st.MarginTop div 16 do
    L.AddBlank;

  if IsListTag(N.Tag) then
  begin
    listIdx := 0;
    for i := 0 to High(N.Children) do
    begin
      child := N.Children[i];
      if (child.Kind <> nkElement) or (child.Tag <> 'li') then
        Continue;
      if Styles.StyleOf(child).Display = dpNone then
        Continue;
      Inc(listIdx);
      marker := ListMarker(N, listIdx);
      LayoutListItem(child, Styles, L, Indent + 2, Avail, marker);
    end;
  end
  else if N.Tag = 'table' then
    LayoutTable(N, Styles, L, Indent, Avail)
  else if N.Tag = 'pre' then
    LayoutPre(N, Styles, L, Indent)
  else
  begin
    { a block container: accumulate inline content into a pending line,
      flush it when a block child starts, then recurse into that child }
    runs := nil;
    for i := 0 to High(N.Children) do
    begin
      child := N.Children[i];
      if child.Kind = nkText then
      begin
        s := CollapseWs(child.Text);
        if s <> '' then
          AddRun(runs, s, st, '', '', False);
      end
      else if child.Kind = nkElement then
      begin
        if Styles.StyleOf(child).Display = dpNone then
          Continue;
        if IsBlockDisplay(Styles.StyleOf(child).Display) then
        begin
          if runs <> nil then
          begin
            EmitLine(L, runs, Indent, st.Align, False, False, '', 0);
            runs := nil;
          end;
          LayoutNode(child, Styles, L, Indent, Avail);
        end
        else
        begin
          if child.Tag = 'a' then href := child.Attr('href')
          else href := '';
          CollectInline(child, Styles, runs, href);
        end;
      end;
    end;
    if runs <> nil then
      EmitLine(L, runs, Indent + st.PaddingLeft div 8, st.Align, False,
                False, '', HeadingLevel(N.Tag));
  end;

  { vertical bottom margin as blank lines }
  for i := 1 to st.MarginBottom div 16 do
    L.AddBlank;
end;

function LayoutDocument(Doc: TDomDoc; Styles: TStyleMap;
                         Cols: Integer): TLayout;
var
  root: TDomNode;
begin
  Result := TLayout.Create(Cols);
  if Doc = nil then
    Exit;
  root := Doc.Body;
  if root = nil then
    root := Doc.Root;
  LayoutNode(root, Styles, Result, 0, Cols);
end;

end.
