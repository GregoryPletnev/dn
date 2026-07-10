{ dnscreen — ncurses setup and the classic Dos Navigator palette. }
unit dnscreen;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ncurses;

const
  { color pair ids }
  cpFrame     = 1;  // panel frame: white on blue
  cpFile      = 2;  // normal file: cyan on blue
  cpDir       = 3;  // directory: bright white on blue
  cpCursor    = 4;  // cursor bar: black on cyan
  cpMenuBar   = 5;  // top menu / fkey labels: black on cyan
  cpFKeyNum   = 6;  // fkey numbers: white on black
  cpCmdLine   = 7;  // command line: light gray on black
  cpSelected  = 8;  // selected file: yellow on blue
  cpSelCursor = 9;  // selected file under cursor: yellow on cyan
  cpTitleAct  = 10; // active panel title: black on cyan
  cpMenuSel   = 11; // selected menu item / focused button: black on green
  cpInput     = 12; // dialog input line: white on blue
  cpViewer    = 13; // viewer text: white on blue
  cpHl1       = 14; // file-highlight groups 1..4: user fg on panel bg
  cpHl2       = 15;
  cpHl3       = 16;
  cpHl4       = 17;

  { Mouse button masks for NCURSES_MOUSE_VERSION = 2 (5 bits per button,
    mask = m shl ((btn-1)*5)). The FPC binding's BUTTON* constants use the
    v1 6-bit layout and do NOT match libncurses 6 — do not use them. }
  mbtn1Released  = $1;
  mbtn1Pressed   = $2;
  mbtn1Clicked   = $4;
  mbtn1Double    = $8;
  mbtn1Triple    = $10;
  mbtn3Pressed   = $800;
  mbtn3Clicked   = $1000;
  mbtn3Double    = $2000;
  mbtn3Triple    = $4000;
  mbtnWheelUp    = $10000;    // BUTTON4_PRESSED
  mbtnWheelDown  = $200000;   // BUTTON5_PRESSED
  mMousePosition = $10000000; // REPORT_MOUSE_POSITION (drag motion events)
  mAllMouseEvents = $1FFFFFFF;

  { double / single line box drawing (UTF-8) }
  bxTL = '╔'; bxTR = '╗'; bxBL = '╚'; bxBR = '╝';
  bxH  = '═'; bxV  = '║';
  bxSepL = '╟'; bxSepR = '╢'; bxSepH = '─';
  bxColV = '│'; bxColT = '╤'; bxColB = '┴';
  bxSTL = '┌'; bxSTR = '┐'; bxSBL = '└'; bxSBR = '┘';

var
  { modal widgets (menu, dialogs, viewer) call this to repaint what's
    underneath them; the main program assigns it }
  RedrawBase: procedure = nil;

procedure ScrInit;
procedure ScrDone;
{ re-init the color pairs to one of the schemes (dnoptions pal* constants);
  ScrInit applies scheme 0, dn.pas re-applies the configured one }
procedure ApplyPalette(Scheme: Integer);
{ set highlight pair cpHl<idx> (idx 1..4) to fg on the current panel bg;
  call after ApplyPalette (which resets the bg) }
procedure SetHlPair(idx, fg: Integer);
procedure PutStr(y, x: Integer; const s: AnsiString; pair: Integer; bold: Boolean = False);
procedure FillRow(y, x, w: Integer; pair: Integer);
function PadLeft(const s: AnsiString; w: Integer): AnsiString;
function PadRight(const s: AnsiString; w: Integer): AnsiString;
function Rep(const s: AnsiString; n: Integer): AnsiString;

{ UTF-8 helpers: display width = codepoints (CJK double-width not handled) }
function Utf8CharBytes(const s: AnsiString; bytePos: Integer): Integer;
function Utf8Len(const s: AnsiString): Integer;
{ 1-based byte position of the cpIndex-th codepoint (cpIndex 1-based) }
function Utf8BytePos(const s: AnsiString; cpIndex: Integer): Integer;
function Utf8Copy(const s: AnsiString; cpStart, cpCount: Integer): AnsiString;
function Utf8PadRight(const s: AnsiString; w: Integer): AnsiString;
function Utf8PadLeft(const s: AnsiString; w: Integer): AnsiString;

implementation

var
  PanelBG: LongInt = COLOR_BLUE;   // panel background of the active scheme

function c_setenv(name, value: PChar; overwrite: LongInt): LongInt;
  cdecl; external 'c' name 'setenv';
function c_setlocale(category: LongInt; locale: PChar): PChar;
  cdecl; external 'c' name 'setlocale';

const
  { LC_CTYPE is 0 on glibc and Darwin; ncurses only needs character type
    classification to be UTF-8 before initscr. }
  LC_CTYPE_C = 0;

function IsUtf8Locale(const s: AnsiString): Boolean;
var
  u: AnsiString;
begin
  u := UpperCase(s);
  Result := (Pos('UTF-8', u) > 0) or (Pos('UTF8', u) > 0);
end;

procedure EnsureUtf8Locale;
var
  loc: AnsiString;
begin
  loc := GetEnvironmentVariable('LC_ALL');
  if loc = '' then loc := GetEnvironmentVariable('LC_CTYPE');
  if loc = '' then loc := GetEnvironmentVariable('LANG');
  if IsUtf8Locale(loc) then
  begin
    c_setlocale(LC_CTYPE_C, '');
    Exit;
  end;

  { Debian ships C.UTF-8 by default. macOS does not always have it, so keep
    en_US.UTF-8 as a fallback for direct local runs. LC_ALL has priority over
    LC_CTYPE, so set both before initscr; otherwise ncurses renders box-drawing
    bytes as ~U/~P. }
  c_setenv('LC_ALL', 'C.UTF-8', 1);
  c_setenv('LC_CTYPE', 'C.UTF-8', 1);
  if c_setlocale(LC_CTYPE_C, '') = nil then
  begin
    c_setenv('LC_ALL', 'en_US.UTF-8', 1);
    c_setenv('LC_CTYPE', 'en_US.UTF-8', 1);
    c_setlocale(LC_CTYPE_C, '');
  end;
end;

procedure SetHlPair(idx, fg: Integer);
begin
  if (idx < 1) or (idx > 4) then Exit;
  if (fg < 1) or (fg > 7) then fg := COLOR_WHITE;
  init_pair(cpHl1 + idx - 1, fg, PanelBG);
end;

procedure ApplyPalette(Scheme: Integer);
begin
  if Scheme = 0 then PanelBG := COLOR_BLUE else PanelBG := COLOR_BLACK;
  case Scheme of
    1: begin  { dark: black background }
      init_pair(cpFrame,     COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpFile,      COLOR_CYAN,   COLOR_BLACK);
      init_pair(cpDir,       COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpCursor,    COLOR_BLACK,  COLOR_CYAN);
      init_pair(cpMenuBar,   COLOR_BLACK,  COLOR_CYAN);
      init_pair(cpFKeyNum,   COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpCmdLine,   COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpSelected,  COLOR_YELLOW, COLOR_BLACK);
      init_pair(cpSelCursor, COLOR_YELLOW, COLOR_CYAN);
      init_pair(cpTitleAct,  COLOR_BLACK,  COLOR_CYAN);
      init_pair(cpMenuSel,   COLOR_BLACK,  COLOR_GREEN);
      init_pair(cpInput,     COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpViewer,    COLOR_WHITE,  COLOR_BLACK);
    end;
    2: begin  { black & white }
      init_pair(cpFrame,     COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpFile,      COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpDir,       COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpCursor,    COLOR_BLACK,  COLOR_WHITE);
      init_pair(cpMenuBar,   COLOR_BLACK,  COLOR_WHITE);
      init_pair(cpFKeyNum,   COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpCmdLine,   COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpSelected,  COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpSelCursor, COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpTitleAct,  COLOR_BLACK,  COLOR_WHITE);
      init_pair(cpMenuSel,   COLOR_WHITE,  COLOR_BLACK);
      init_pair(cpInput,     COLOR_BLACK,  COLOR_WHITE);
      init_pair(cpViewer,    COLOR_WHITE,  COLOR_BLACK);
    end;
  else      { classic DN blue }
    init_pair(cpFrame,     COLOR_WHITE,  COLOR_BLUE);
    init_pair(cpFile,      COLOR_CYAN,   COLOR_BLUE);
    init_pair(cpDir,       COLOR_WHITE,  COLOR_BLUE);
    init_pair(cpCursor,    COLOR_BLACK,  COLOR_CYAN);
    init_pair(cpMenuBar,   COLOR_BLACK,  COLOR_CYAN);
    init_pair(cpFKeyNum,   COLOR_WHITE,  COLOR_BLACK);
    init_pair(cpCmdLine,   COLOR_WHITE,  COLOR_BLACK);
    init_pair(cpSelected,  COLOR_YELLOW, COLOR_BLUE);
    init_pair(cpSelCursor, COLOR_YELLOW, COLOR_CYAN);
    init_pair(cpTitleAct,  COLOR_BLACK,  COLOR_CYAN);
    init_pair(cpMenuSel,   COLOR_BLACK,  COLOR_GREEN);
    init_pair(cpInput,     COLOR_WHITE,  COLOR_BLUE);
    init_pair(cpViewer,    COLOR_WHITE,  COLOR_BLUE);
  end;
end;

procedure ScrInit;
begin
  EnsureUtf8Locale;
  initscr;
  { raw, not cbreak: keeps ^Y (macOS DSUSP), ^S/^Q, ^C as ordinary input
    instead of terminal control — an editor needs them as keystrokes }
  raw;
  noecho;
  keypad(stdscr, True);
  curs_set(0);
  start_color;
  ApplyPalette(0);
  mousemask(mAllMouseEvents, nil);
  { Raw press/release only: ncurses' click/double-click synthesis is
    timing-dependent and can swallow press events (a second quick click
    may arrive as a lone RELEASED). We act on presses and detect double
    clicks ourselves. }
  mouseinterval(0);
  { Button-motion tracking (xterm 1002): terminals send drag events.
    Must go out AFTER ncurses' own mouse-enable string (flushed by
    refresh), or its "?1000h" would downgrade tracking to clicks-only. }
  refresh;
  Write(#27'[?1002h');
  Flush(Output);
end;

procedure ScrDone;
begin
  Write(#27'[?1002l');
  Flush(Output);
  endwin;
end;

procedure PutStr(y, x: Integer; const s: AnsiString; pair: Integer; bold: Boolean);
var
  attr: LongInt;
begin
  attr := COLOR_PAIR(pair);
  if bold then
    attr := attr or A_BOLD;
  attrset(attr);
  mvaddstr(y, x, PChar(s));
end;

procedure FillRow(y, x, w: Integer; pair: Integer);
var
  i: Integer;
begin
  attrset(COLOR_PAIR(pair));
  for i := 0 to w - 1 do
    mvaddstr(y, x + i, ' ');
end;

function Rep(const s: AnsiString; n: Integer): AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to n do
    Result := Result + s;
end;

function Utf8CharBytes(const s: AnsiString; bytePos: Integer): Integer;
var
  b: Byte;
begin
  if (bytePos < 1) or (bytePos > Length(s)) then Exit(1);
  b := Ord(s[bytePos]);
  if b < $80 then Result := 1
  else if (b and $E0) = $C0 then Result := 2
  else if (b and $F0) = $E0 then Result := 3
  else if (b and $F8) = $F0 then Result := 4
  else Result := 1;   // stray continuation byte: treat as one cell
  if bytePos + Result - 1 > Length(s) then
    Result := Length(s) - bytePos + 1;
end;

function Utf8Len(const s: AnsiString): Integer;
var
  i: Integer;
begin
  Result := 0;
  i := 1;
  while i <= Length(s) do
  begin
    Inc(i, Utf8CharBytes(s, i));
    Inc(Result);
  end;
end;

function Utf8BytePos(const s: AnsiString; cpIndex: Integer): Integer;
var
  cp: Integer;
begin
  Result := 1;
  cp := 1;
  while (cp < cpIndex) and (Result <= Length(s)) do
  begin
    Inc(Result, Utf8CharBytes(s, Result));
    Inc(cp);
  end;
end;

function Utf8Copy(const s: AnsiString; cpStart, cpCount: Integer): AnsiString;
var
  b0, b1, n: Integer;
begin
  b0 := Utf8BytePos(s, cpStart);
  b1 := b0;
  n := 0;
  while (n < cpCount) and (b1 <= Length(s)) do
  begin
    Inc(b1, Utf8CharBytes(s, b1));
    Inc(n);
  end;
  Result := Copy(s, b0, b1 - b0);
end;

function Utf8PadRight(const s: AnsiString; w: Integer): AnsiString;
var
  l: Integer;
begin
  l := Utf8Len(s);
  if l >= w then
    Result := Utf8Copy(s, 1, w)
  else
    Result := s + StringOfChar(' ', w - l);
end;

function Utf8PadLeft(const s: AnsiString; w: Integer): AnsiString;
var
  l: Integer;
begin
  l := Utf8Len(s);
  if l >= w then
    Result := Utf8Copy(s, 1, w)
  else
    Result := StringOfChar(' ', w - l) + s;
end;

function PadLeft(const s: AnsiString; w: Integer): AnsiString;
begin
  if Length(s) >= w then
    Result := Copy(s, 1, w)
  else
    Result := StringOfChar(' ', w - Length(s)) + s;
end;

function PadRight(const s: AnsiString; w: Integer): AnsiString;
begin
  if Length(s) >= w then
    Result := Copy(s, 1, w)
  else
    Result := s + StringOfChar(' ', w - Length(s));
end;

end.
