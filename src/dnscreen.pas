{ dnscreen — ncurses setup and the classic Dos Navigator palette. }
unit dnscreen;

{$mode objfpc}{$H+}

interface

uses
  ncurses;

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

  { Mouse button masks for NCURSES_MOUSE_VERSION = 2 (5 bits per button,
    mask = m shl ((btn-1)*5)). The FPC binding's BUTTON* constants use the
    v1 6-bit layout and do NOT match libncurses 6 — do not use them. }
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
  mAllMouseEvents = $0FFFFFFF;

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

procedure ScrInit;
begin
  initscr;
  { raw, not cbreak: keeps ^Y (macOS DSUSP), ^S/^Q, ^C as ordinary input
    instead of terminal control — an editor needs them as keystrokes }
  raw;
  noecho;
  keypad(stdscr, True);
  curs_set(0);
  start_color;
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
  mousemask(mAllMouseEvents, nil);
  { Raw press/release only: ncurses' click/double-click synthesis is
    timing-dependent and can swallow press events (a second quick click
    may arrive as a lone RELEASED). We act on presses and detect double
    clicks ourselves. }
  mouseinterval(0);
end;

procedure ScrDone;
begin
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
