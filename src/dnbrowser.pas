{ dnbrowser — the text browser window (BROWSER.md).

  TBrowserWin renders an HTML document into the TWin cell grid: the fetch
  goes through dnhttp (curl) for http(s), through the file loader for
  file:// and bare paths, and through dnhtml -> dncss -> dnlayout for
  parsing, styling and line layout. The window owns scroll position, the
  link cursor, page history, and the status line.

  Keys: Tab / Shift-Tab move the link cursor (Shift arrows too), Enter
  follows, Backspace goes back in history, Ctrl-F forward, 'g' opens a URL
  prompt, Ctrl-R reloads, the scroll keys move the window, 'q' / Esc close.
  Ctrl-C aborts a fetch or cancels the URL prompt instead of closing.
  Clicking a link follows it; the wheel scrolls.

  JS: dnjs.TBrowserJs is the bridge and runs fully synchronously, but its
  external engine has no wall-clock kill, so a script that hangs would hang
  the UI. The bridge is therefore NOT wired in here; enabling it is the
  work plan's step 9 (BROWSER.md). When DN_JS_CMD is set, the status line
  says "js: not wired" — an honest note, not faked support. }
unit dnbrowser;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnwin, dnlayout;

type
  TBrowserLink = record
    Url: AnsiString;
    Text: AnsiString;
    Row: Integer;    // document row
    Col: Integer;    // first column
    Len: Integer;    // columns
  end;
  TBrowserLinks = array of TBrowserLink;

  TScreenRun = record
    Text: AnsiString;
    Bold, Italic, Underline: Boolean;
    Color, BgColor: AnsiString;
    Link: AnsiString;
    Col: Integer;
  end;
  TScreenLine = record
    Runs: array of TScreenRun;
    Indent: Integer;
    Marker: AnsiString;
    Align: AnsiString;
    Pre: Boolean;
    IsRule: Boolean;
  end;
  TScreenLines = array of TScreenLine;

  TBrowserWin = class(TWin)
  public
    Url: AnsiString;             // current page URL
    Top: Integer;                // first visible document row
    LinkAt: Integer;             // link cursor index, -1 = none
    Loaded: Boolean;
    Loading: Boolean;
    ErrMsg: AnsiString;          // last fetch error
    LayoutCols: Integer;         // width the current layout used
    Screen: TScreenLines;        // wrapped screen rows, owned by nil check
    Links: TBrowserLinks;
    History: TStringList;        // owned, visited URLs
    HistPos: Integer;            // index into History
    RawHtml: AnsiString;         // last fetched body
    Fg0, Bg0: Integer;           // default text color of the palette
    PairOf: array[0..7, 0..7] of Integer;  // color-pair cache, 0 = none
    PairNext: Integer;
    constructor CreateBrowser(const AUrl: AnsiString);
    destructor Destroy; override;
    procedure DrawContent(Focused: Boolean); override;
    function StatusText: AnsiString; override;
    function HandleKey(ch: LongInt): TKeyAction; override;
    procedure HandleClick(mx, my: Integer; bstate: QWord); override;
    { navigation }
    procedure Reload;
    procedure GotoUrl(const AUrl: AnsiString);
    procedure GoBack;
    procedure GoForward;
  private
    FAbort: Boolean;             // Ctrl-C pressed before/during a load
    procedure FetchAndRender(const AUrl: AnsiString);
    procedure RenderHtml(const Html: AnsiString);
    procedure Rebuild;
    procedure ClampLink;
    procedure ScrollToShowLink;
    function CellPair(Fore, Back: Integer): Integer;
  end;

{ Opens the browser on AUrl and returns the window (already on the desktop).
  Accepts http(s)://, file:// and bare local paths; '' opens about:blank. }
function OpenBrowser(const AUrl: AnsiString): TBrowserWin;

{ True when S looks like a URL the browser can open (the dn.pas command-line
  and dn.ext @browse entries use this). }
function LooksLikeUrl(const S: AnsiString): Boolean;

implementation

uses
  SysUtils, ncurses, dnscreen, dndialog, dnoptions,
  dnhtml, dncss, dnhttp, dnjs;

const
  BlankUrl = 'about:blank';
  MaxBody = 8 * 1024 * 1024;

var
  Cascade: Integer = 0;
  JsProbe: TBrowserJs = nil;

function HasJsEngine: Boolean;
begin
  if JsProbe = nil then JsProbe := TBrowserJs.Create;
  Result := JsProbe.ResolveEngine <> '';
end;

function LooksLikeUrl(const S: AnsiString): Boolean;
var
  sc: AnsiString;
begin
  sc := LowerCase(UrlScheme(S));
  Result := (sc = 'http') or (sc = 'https') or (sc = 'file');
end;

{ --- fetch ------------------------------------------------------------- }

function ReadLocalFile(const Path: AnsiString; out Body: AnsiString): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  Body := '';
  try
    fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if fs.Size > MaxBody then Exit;
      SetLength(Body, fs.Size);
      if Length(Body) > 0 then
        fs.ReadBuffer(Body[1], Length(Body));
    finally
      fs.Free;
    end;
    Result := True;
  except
    Body := '';
  end;
end;

{ A bare local path: relative to the current directory, then absolute.
  True only for an existing readable file. }
function ReadLocalPath(const S: AnsiString; out Body: AnsiString): Boolean;
var
  p: AnsiString;
begin
  Result := False;
  Body := '';
  if (S = '') or (Length(S) > 4096) then Exit;
  p := S;
  if (p[1] <> '/') and FileExists(p) then
  begin
    Result := ReadLocalFile(p, Body);
    if Result then Exit;
  end;
  if p[1] <> '/' then
  begin
    p := GetCurrentDir + '/' + p;
    if FileExists(p) then
      Result := ReadLocalFile(p, Body);
  end;
end;

function ReadFileUrl(const U: TUrl; out Body: AnsiString): Boolean;
var
  p: AnsiString;
begin
  Body := '';
  p := FileUrlToPath(U);
  if (p <> '') and (p[1] <> '/') then
    p := GetCurrentDir + '/' + p;
  Result := ReadLocalFile(p, Body);
end;

{ Load the page body for AUrl. http(s) goes through THttpClient (curl);
  everything else is the file loader. On False, Err explains why. }
function LoadPage(const AUrl: AnsiString; out Body, Err: AnsiString): Boolean;
var
  u: TUrl;
  client: THttpClient;
  r: THttpResult;
begin
  Result := False;
  Body := '';
  Err := '';
  if (AUrl = '') or (AUrl = BlankUrl) then
  begin
    Result := True;   // an empty page
    Exit;
  end;
  u := UrlParse(AUrl);
  if u.Valid and (u.Scheme = 'file') then
  begin
    if not ReadFileUrl(u, Body) then
      Err := 'cannot read ' + FileUrlToPath(u)
    else
      Result := True;
    Exit;
  end;
  if u.Valid and ((u.Scheme = 'http') or (u.Scheme = 'https')) then
  begin
    { the curl child is not interruptible from here (THttpClient blocks in
      fpSystem and exposes no pid), so Ctrl-C during a fetch is reported as
      queued and applies to the next reload; the fetch itself finishes. }
    client := THttpClient.Create;
    try
      if not client.Get(AUrl, r) then
      begin
        Err := r.Err;
        if Err = '' then Err := 'fetch failed';
      end
      else
      begin
        Body := r.Body;
        Result := True;
      end;
    finally
      client.Free;
    end;
    Exit;
  end;
  { no scheme: try it as a local path, as the dn.ext @browse verb relies on }
  if ReadLocalPath(AUrl, Body) then
    Result := True
  else
    Err := 'cannot open ' + AUrl;
end;

{ map a laid-out TLayout into scrollable screen rows. dnlayout emits one
  line per block element and does not wrap, so a long line is split on the
  viewport width here; Pre and IsRule lines pass through untouched. }
procedure SplitRunsToWidth(Src: TLayout; Cols: Integer; out Outp: TScreenLines);
var
  li, ri, ci: Integer;
  ln: TLayoutLine;
  r: TLayoutRun;
  sl: TScreenLine;
  sr: TScreenRun;
  cx, avail: Integer;
  left, part: AnsiString;
  w, cut: Integer;

  procedure NewRow;
  begin
    Inc(ci);
    SetLength(Outp, ci);
    Outp[ci - 1] := sl;
    SetLength(Outp[ci - 1].Runs, 0);
    cx := sl.Indent + Length(sl.Marker);
  end;

  procedure AddRun(const Txt: AnsiString);
  var
    n: Integer;
  begin
    n := Length(Outp[ci - 1].Runs);
    SetLength(Outp[ci - 1].Runs, n + 1);
    Outp[ci - 1].Runs[n].Text := Txt;
    Outp[ci - 1].Runs[n].Bold := r.Bold;
    Outp[ci - 1].Runs[n].Italic := r.Italic;
    Outp[ci - 1].Runs[n].Underline := r.Underline;
    Outp[ci - 1].Runs[n].Color := r.Color;
    Outp[ci - 1].Runs[n].BgColor := r.BgColor;
    Outp[ci - 1].Runs[n].Link := r.Link;
    Outp[ci - 1].Runs[n].Col := cx;
    Inc(cx, Utf8Len(Txt));
  end;

begin
  Outp := nil;
  ci := 0;
  cx := 0;
  for li := 0 to Src.Count - 1 do
  begin
    ln := Src.Get(li);
    FillChar(sl, SizeOf(sl), 0);
    sl.Indent := ln.Indent;
    sl.Marker := ln.Marker;
    sl.Align := ln.Align;
    sl.Pre := ln.Pre;
    sl.IsRule := ln.IsRule;
    NewRow;
    if (ln.Runs = nil) or ln.IsRule then Continue;
    for ri := 0 to High(ln.Runs) do
    begin
      r := ln.Runs[ri];
      if r.Break then
      begin
        NewRow;
        Continue;
      end;
      if sl.Pre then
      begin
        AddRun(r.Text);
        Continue;
      end;
      left := r.Text;
      while left <> '' do
      begin
        avail := Cols - cx;
        if avail <= 0 then
        begin
          NewRow;
          Continue;
        end;
        w := Utf8Len(left);
        if w <= avail then
        begin
          AddRun(left);
          left := '';
        end
        else
        begin
          cut := avail;
          part := Utf8Copy(left, 1, cut);
          if Pos(' ', part) > 0 then
            cut := LastDelimiter(' ', part);
          if cut <= 0 then cut := avail;
          part := TrimRight(Utf8Copy(left, 1, cut));
          if part = '' then
          begin
            left := Copy(left, 2, MaxInt);   // drop a leading space
            Continue;
          end;
          AddRun(part);
          left := Copy(left, Utf8BytePos(left, Utf8Len(part) + 1), MaxInt);
          if (left <> '') and (left[1] = ' ') then left := Copy(left, 2, MaxInt);
          if left <> '' then NewRow;
        end;
      end;
    end;
  end;
end;

{ --- window ------------------------------------------------------------- }

constructor TBrowserWin.CreateBrowser(const AUrl: AnsiString);
var
  rw, rh, i, j: Integer;
begin
  rw := COLS - 4;
  if rw < 40 then rw := COLS;
  rh := DeskY1 - DeskY0 + 1;
  inherited Create(2 + (Cascade mod 4) * 2, DeskY0, rw, rh, 'Browser');
  Inc(Cascade);
  Url := AUrl;
  if Url = '' then Url := BlankUrl;
  Top := 0;
  LinkAt := 0;
  Loaded := False;
  Loading := False;
  ErrMsg := '';
  LayoutCols := 0;
  Screen := nil;
  Links := nil;
  History := TStringList.Create;
  HistPos := -1;
  RawHtml := '';
  FAbort := False;
  { the default text color of the palette, for runs without a color }
  Fg0 := COLOR_WHITE;
  if Opt.Palette = 0 then Bg0 := COLOR_BLUE else Bg0 := COLOR_BLACK;
  for i := 0 to High(PairOf) do
    for j := 0 to High(PairOf[0]) do
      PairOf[i, j] := 0;
  PairNext := 16;
  FetchAndRender(Url);
end;

destructor TBrowserWin.Destroy;
begin
  Screen := nil;
  History.Free;
  inherited;
end;

{ on-demand color-pair cache, like TERMINAL.md §3: fg on bg, bounded to the
  8x8 base colors, ids above the fixed dnscreen pairs }
function TBrowserWin.CellPair(Fore, Back: Integer): Integer;
begin
  if (Fore < 0) or (Fore > 7) then Fore := Fg0;
  if (Back < 0) or (Back > 7) then Back := Bg0;
  Result := PairOf[Fore, Back];
  if Result <> 0 then Exit;
  if PairNext > 255 then Exit(cpViewer);   // pair ids exhausted: fall back
  PairOf[Fore, Back] := PairNext;
  init_pair(PairNext, Fore, Back);
  Result := PairNext;
  Inc(PairNext);
end;

procedure TBrowserWin.FetchAndRender(const AUrl: AnsiString);
var
  body, err: AnsiString;
begin
  Loading := True;
  ErrMsg := '';
  if LoadPage(AUrl, body, err) then
  begin
    RawHtml := body;
    RenderHtml(body);
  end
  else
  begin
    ErrMsg := err;
    Screen := nil;
    Links := nil;
  end;
  Loaded := True;
  Loading := False;
  FAbort := False;
end;

procedure TBrowserWin.RenderHtml(const Html: AnsiString);
var
  doc: TDomDoc;
  sheet: TCssSheet;
  styles: TStyleMap;
  lay: TLayout;
begin
  doc := ParseHtml(Html);
  try
    sheet := CollectSheets(doc);
    try
      styles := ComputeStyles(doc, sheet);
      try
        lay := LayoutDocument(doc, styles, W - 2);
        try
          SplitRunsToWidth(lay, W - 2, Screen);
        finally
          lay.Free;
        end;
        LayoutCols := W - 2;
      finally
        styles.Free;
      end;
    finally
      sheet.Free;
    end;
  finally
    doc.Free;
  end;
  Rebuild;
end;

{ --- link map ----------------------------------------------------------- }

procedure AddLink(var Ls: TBrowserLinks; const Url, Text: AnsiString;
                  Row, Col, Len: Integer);
var
  i: Integer;
begin
  if (Url = '') or (Len <= 0) then Exit;
  for i := 0 to High(Ls) do
    if (Ls[i].Url = Url) and (Ls[i].Row = Row) then Exit;
  SetLength(Ls, Length(Ls) + 1);
  Ls[High(Ls)].Url := Url;
  Ls[High(Ls)].Text := Text;
  Ls[High(Ls)].Row := Row;
  Ls[High(Ls)].Col := Col;
  Ls[High(Ls)].Len := Len;
end;

{ walk the laid-out lines once, recording where each link is drawn }
procedure TBrowserWin.Rebuild;
var
  li, ri, len: Integer;
begin
  Links := nil;
  for li := 0 to High(Screen) do
    for ri := 0 to High(Screen[li].Runs) do
    begin
      len := Utf8Len(Screen[li].Runs[ri].Text);
      if (Screen[li].Runs[ri].Link <> '') and (len > 0) then
        AddLink(Links, Screen[li].Runs[ri].Link, Screen[li].Runs[ri].Text,
                li, Screen[li].Runs[ri].Col, len);
    end;
  ClampLink;
end;

procedure TBrowserWin.ClampLink;
begin
  if Length(Links) = 0 then
    LinkAt := -1
  else if LinkAt < 0 then
    LinkAt := 0
  else if LinkAt > High(Links) then
    LinkAt := High(Links);
end;

{ scroll so the link cursor is visible }
procedure TBrowserWin.ScrollToShowLink;
var
  ph: Integer;
begin
  if (LinkAt < 0) or (LinkAt > High(Links)) then Exit;
  ph := H - 2;
  if Links[LinkAt].Row < Top then
    Top := Links[LinkAt].Row
  else if Links[LinkAt].Row >= Top + ph then
    Top := Links[LinkAt].Row - ph + 1;
  if Top < 0 then Top := 0;
end;

{ --- drawing ------------------------------------------------------------ }
{ map a CSS color to an ncurses color number; False = keep the default }
function CssColorToNc(const C: AnsiString; out Nc: Integer): Boolean;
var
  s: AnsiString;
  rr, gg, bb: Integer;

  function Hex2(const H: AnsiString): Integer;
  begin
    Result := StrToIntDef('$' + H, -1);
  end;

  function Nearest(rr, gg, bb: Integer): Integer;
  const
    Rgb: array[0..7, 0..2] of Integer = (
      (  0,  0,  0), (205,  0,  0), (  0,205,  0), (205,205,  0),
      (  0,  0,238), (238,  0,238), (  0,238,238), (238,238,238));
  var
    i, d, dr, dg, db, best: Integer;
  begin
    best := 0;
    d := -1;
    for i := 0 to 7 do
    begin
      dr := rr - Rgb[i, 0];
      dg := gg - Rgb[i, 1];
      db := bb - Rgb[i, 2];
      dr := dr * dr + dg * dg + db * db;
      if (d < 0) or (dr < d) then
      begin
        d := dr;
        best := i;
      end;
    end;
    Result := best;
  end;

begin
  Result := False;
  Nc := -1;
  s := Trim(LowerCase(C));
  if s = '' then Exit;
  if s = 'black'   then begin Nc := 0; Exit(True); end;
  if s = 'maroon'  then begin Nc := 1; Exit(True); end;
  if s = 'red'     then begin Nc := 1; Exit(True); end;
  if s = 'green'   then begin Nc := 2; Exit(True); end;
  if s = 'olive'   then begin Nc := 3; Exit(True); end;
  if s = 'yellow'  then begin Nc := 3; Exit(True); end;
  if s = 'navy'    then begin Nc := 4; Exit(True); end;
  if s = 'blue'     then begin Nc := 4; Exit(True); end;
  if s = 'purple'  then begin Nc := 5; Exit(True); end;
  if s = 'fuchsia' then begin Nc := 5; Exit(True); end;
  if s = 'magenta' then begin Nc := 5; Exit(True); end;
  if (s = 'gray') or (s = 'grey') or (s = 'silver') then
    begin Nc := 6; Exit(True); end;
  if s = 'white'   then begin Nc := 7; Exit(True); end;
  if (Length(s) = 7) and (s[1] = '#') then
  begin
    rr := Hex2(Copy(s, 2, 2));
    gg := Hex2(Copy(s, 4, 2));
    bb := Hex2(Copy(s, 6, 2));
  end
  else if (Length(s) = 4) and (s[1] = '#') then
  begin
    rr := Hex2(Copy(s, 2, 1) + Copy(s, 2, 1));
    gg := Hex2(Copy(s, 3, 1) + Copy(s, 3, 1));
    bb := Hex2(Copy(s, 4, 1) + Copy(s, 4, 1));
  end
  else
    Exit;
  if (rr < 0) or (gg < 0) or (bb < 0) then Exit;
  Nc := Nearest(rr, gg, bb);
  Result := True;
end;


procedure TBrowserWin.DrawContent(Focused: Boolean);
var
  cw, ph, j, li, ri, cx, sel: Integer;
  s: AnsiString;

  procedure PutRun(const Str: AnsiString; Bold, Under: Boolean;
                   RunFg, RunBg: AnsiString);
  var
    attr: LongInt;
    f2, b2: Integer;
  begin
    if Str = '' then Exit;
    f2 := Fg0;
    b2 := Bg0;
    if CssColorToNc(RunFg, f2) then { mapped } else f2 := Fg0;
    if CssColorToNc(RunBg, b2) then { mapped } else b2 := Bg0;
    attr := COLOR_PAIR(CellPair(f2, b2));
    if Bold then attr := attr or A_BOLD;
    if Under then attr := attr or A_UNDERLINE;
    attrset(attr);
    mvaddstr(Y + 1 + j, X + 1 + cx, PChar(Str));
  end;

begin
  cw := W - 2;
  ph := H - 2;
  if cw < 1 then Exit;
  s := '';
  cx := 0;

  { relayout when the window width changed }
  if (Length(Screen) > 0) and (LayoutCols <> cw) and (RawHtml <> '') then
    RenderHtml(RawHtml);

  if Length(Screen) = 0 then
  begin
    if Loading then
      s := 'loading ' + Url
    else if ErrMsg <> '' then
      s := 'error: ' + ErrMsg
    else if Url = BlankUrl then
      s := 'about:blank'
    else
      s := 'empty page';
    for j := 0 to ph - 1 do
      PutStr(Y + 1 + j, X + 1, Utf8PadRight('', cw), cpViewer);
    PutStr(Y + 1, X + 1, Utf8PadRight(Utf8Copy(s, 1, cw), cw), cpViewer);
    Exit;
  end;

  if Top > Length(Screen) - ph then Top := Length(Screen) - ph;
  if Top < 0 then Top := 0;
  sel := -1;
  if (LinkAt >= 0) and (LinkAt <= High(Links)) then
    sel := LinkAt;

  for j := 0 to ph - 1 do
  begin
    li := Top + j;
    PutStr(Y + 1 + j, X + 1, Utf8PadRight('', cw), cpViewer);
    if li >= Length(Screen) then Continue;
    if Screen[li].IsRule then
    begin
      PutStr(Y + 1 + j, X + 1, Rep('─', cw), cpViewer);
      Continue;
    end;
    cx := Screen[li].Indent;
    if Screen[li].Marker <> '' then
    begin
      PutRun(Screen[li].Marker, False, False, '', '');
      Inc(cx, Length(Screen[li].Marker));
    end;
    for ri := 0 to High(Screen[li].Runs) do
    begin
      if cx >= cw then Break;
      s := Screen[li].Runs[ri].Text;
      if Utf8Len(s) > cw - cx then s := Utf8Copy(s, 1, cw - cx);
      PutRun(s, Screen[li].Runs[ri].Bold,
             Screen[li].Runs[ri].Underline or
               (Screen[li].Runs[ri].Link <> ''),
             Screen[li].Runs[ri].Color, Screen[li].Runs[ri].BgColor);
      Inc(cx, Utf8Len(s));
    end;
    { the link cursor: an inverted block over the link's first cell }
    if (sel >= 0) and (Links[sel].Row = li) then
    begin
      attrset(COLOR_PAIR(CellPair(Bg0, Fg0)));
      mvaddstr(Y + 1 + j, X + 1 + Links[sel].Col, '#');
    end;
  end;
end;

function TBrowserWin.StatusText: AnsiString;
var
  pct, n: Integer;
  t: AnsiString;
begin
  if Length(Links) > 0 then n := LinkAt + 1 else n := 0;
  if Length(Screen) > 0 then
  begin
    pct := ((Top + H - 2) * 100) div Length(Screen);
    if pct > 100 then pct := 100;
    if pct < 0 then pct := 0;
  end
  else
    pct := 100;
  t := Url;
  if Loading then
    t := t + '  loading...'
  else if ErrMsg <> '' then
    t := t + '  ' + ErrMsg;
  if HasJsEngine then
    t := t + '  js: not wired';
  Result := Format('%s  [%d%%]  link %d/%d', [t, pct, n, Length(Links)]);
end;

{ --- navigation --------------------------------------------------------- }

procedure TBrowserWin.GotoUrl(const AUrl: AnsiString);
begin
  if AUrl = '' then Exit;
  Url := AUrl;
  if (HistPos < 0) or (History[HistPos] <> AUrl) then
  begin
    while History.Count > HistPos + 1 do
      History.Delete(History.Count - 1);
    History.Add(AUrl);
    HistPos := History.Count - 1;
  end;
  Top := 0;
  LinkAt := 0;
  FetchAndRender(AUrl);
end;

procedure TBrowserWin.GoBack;
begin
  if HistPos > 0 then
  begin
    Dec(HistPos);
    Url := History[HistPos];
    Top := 0;
    LinkAt := 0;
    FetchAndRender(Url);
  end;
end;

procedure TBrowserWin.GoForward;
begin
  if (HistPos >= 0) and (HistPos < History.Count - 1) then
  begin
    Inc(HistPos);
    Url := History[HistPos];
    Top := 0;
    LinkAt := 0;
    FetchAndRender(Url);
  end;
end;

procedure TBrowserWin.Reload;
begin
  Top := 0;
  LinkAt := 0;
  FetchAndRender(Url);
end;

function TBrowserWin.HandleKey(ch: LongInt): TKeyAction;
var
  ph: Integer;
  u: AnsiString;

  procedure NextLink;
  begin
    if Length(Links) = 0 then Exit;
    if LinkAt >= High(Links) then LinkAt := 0 else Inc(LinkAt);
    ScrollToShowLink;
  end;

  procedure PrevLink;
  begin
    if Length(Links) = 0 then Exit;
    if LinkAt <= 0 then LinkAt := Length(Links) - 1 else Dec(LinkAt);
    ScrollToShowLink;
  end;

begin
  Result := kaConsumed;
  ph := H - 2;
  case ch of
    KEY_UP: Dec(Top);
    KEY_DOWN: Inc(Top);
    KEY_PPAGE: Dec(Top, ph);
    KEY_NPAGE: Inc(Top, ph);
    KEY_HOME: Top := 0;
    KEY_END: Top := Length(Screen);
    9: NextLink;                       { Tab }
    25: PrevLink;                      { Shift-Tab }
    KEY_SF: NextLink;                  { Shift-Down }
    KEY_SR: PrevLink;                  { Shift-Up }
    10, 13, KEY_ENTER:
      if (LinkAt >= 0) and (LinkAt <= High(Links)) then
        GotoUrl(UrlResolve(Url, Links[LinkAt].Url));
    KEY_BACKSPACE, 127, 8: GoBack;
    6: GoForward;                      { Ctrl-F }
    18: Reload;                        { Ctrl-R }
    Ord('g'), Ord('G'):
      begin
        if FAbort then
        begin
          FAbort := False;
          ErrMsg := '';
          Exit;
        end;
        u := Url;
        if InputBox('Go to URL', 'URL:', u) and (Trim(u) <> '') then
          GotoUrl(Trim(u));
      end;
    3:                                 { Ctrl-C: abort, never close }
      begin
        FAbort := True;
        ErrMsg := 'aborted (Ctrl-R retries)';
      end;
    27, Ord('q'), Ord('Q'), KEY_F0 + 3, KEY_F0 + 10:
      Exit(kaClose);
  else
    Exit(kaPass);
  end;
  if Top > Length(Screen) - ph then Top := Length(Screen) - ph;
  if Top < 0 then Top := 0;
end;

procedure TBrowserWin.HandleClick(mx, my: Integer; bstate: QWord);
var
  i, row: Integer;
begin
  if (bstate and mbtnWheelUp) <> 0 then Dec(Top, 3);
  if (bstate and mbtnWheelDown) <> 0 then Inc(Top, 3);
  if (bstate and (mbtn1Pressed or mbtn1Clicked or mbtn1Double)) <> 0 then
  begin
    row := my - (Y + 1);
    if row >= 0 then
      for i := 0 to High(Links) do
        if (Links[i].Row = Top + row) and
           (mx >= X + 1 + Links[i].Col) and
           (mx < X + 1 + Links[i].Col + Links[i].Len) then
        begin
          LinkAt := i;
          GotoUrl(UrlResolve(Url, Links[i].Url));
          Exit;
        end;
  end;
  if Top > Length(Screen) - (H - 2) then Top := Length(Screen) - (H - 2);
  if Top < 0 then Top := 0;
end;

function OpenBrowser(const AUrl: AnsiString): TBrowserWin;
begin
  Result := TBrowserWin.CreateBrowser(AUrl);
  WinAdd(Result);
end;

end.
