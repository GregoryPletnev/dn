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
  { editor/viewer syntax highlighting (dnhighlite hh* classes) }
  cpSynNumber  = 18;
  cpSynString  = 19;
  cpSynComment = 20;
  cpSynSymbol  = 21;
  cpSynKw1     = 22;
  cpSynKw2     = 23;
  { more interface elements of the DN palette (40..51; 30..37 are the
    savers', 20..28 Tetris', 64.. the browser's) }
  cpFrameInact = 40; // inactive panel frame
  cpTitlePas   = 41; // inactive panel title (path)
  cpColTitle   = 42; // panel column titles
  cpInfo       = 43; // info line at the bottom of a panel
  cpClock      = 44; // clock in the menu bar
  cpDialog     = 45; // dialog text and background
  cpDlgFrame   = 46; // dialog frame
  cpDlgList    = 47; // list rows in a dialog
  cpDlgSel     = 48; // focused list row in a dialog
  cpDlgBtnSel  = 49; // focused dialog button
  cpEditor     = 50; // editor text
  cpCmdPrompt  = 51; // command line prompt (the path)

  { Mouse button masks for NCURSES_MOUSE_VERSION = 2 (5 bits per button,
    mask = m shl ((btn-1)*5)). The FPC binding's BUTTON* constants use the
    v1 6-bit layout and do NOT match libncurses 6 — do not use them. }
  mbtn1Released  = $1;
  mbtn1Pressed   = $2;
  mbtn1Clicked   = $4;
  mbtn1Double    = $8;
  mbtn1Triple    = $10;
  mbtn2Released  = $20;
  mbtn2Pressed   = $40;
  mbtn2Clicked   = $80;
  mbtn2Double    = $100;
  mbtn2Triple    = $200;
  mbtn3Released  = $400;
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
{ hand the terminal to a shell or a program (Ctrl-O, a command line run)
  and take it back: besides endwin these switch the xterm mouse modes off
  and on again, or the terminal keeps sending mouse reports instead of
  selecting text }
procedure ScrSuspend;
procedure ScrResume;
{ ncurses getch/timeout, plus gpm mouse on the Linux console (dngpm).
  Units list dnscreen after ncurses, so these take precedence. }
function getch: LongInt;
procedure timeout(delay: LongInt);
{ the delay the last timeout() set: ms, -1 = blocking }
function CurrentTimeout: LongInt;
{ Mouse shims. The FPC ncurses binding's mmask_t/MEVENT are built for
  64-bit masks, but the ncurses on this machine uses 32-bit ones: the ABI
  mismatch makes ncurses' own mouse support silently drop every report
  (getch returns the raw ESC, never KEY_MOUSE). We therefore enable SGR
  mouse (1006) ourselves and parse the reports here. Units list dnscreen
  after ncurses, so these take precedence over the binding. }
function getmouse(event: PMEVENT): LongInt;
function ungetmouse(event: PMEVENT): LongInt;
procedure MouseEnqueue(x, y: Integer; bstate: LongWord);
{ bstate of the last report PopMouse handed out (0 when none); the release
  half of a click carries mbtn1Released }
function LastMouseState: LongWord;
{ True when the event just handed out is a button release. Dialogs act on
  the press and drop this event instead of reading another key. }
function MouseIsRelease: Boolean;
{ drop every queued report and the hand-out one }
procedure MouseFlush;
{ True while the queue holds an unclaimed report }
function MousePending: Boolean;


type
  { a Dos Navigator 1.51 palette: the 228 TV attributes of TApplication
    (CColor layout) and the VGA DAC (6-bit RGB) it was designed with }
  TDnPalette = record
    Id: AnsiString;
    Name: AnsiString;
    Attr: array[1..228] of Byte;
    Dac: array[0..15, 0..2] of Byte;
  end;

{$I dnpalettes.inc}

const
  { the DN attribute index behind each of our pairs: the chain the original
    views use (CDoubleWindow -> CPanel, CMenuView, CGrayDialog, ...) }
  PairDnIndex: array[0..19] of record Pair, Index: Integer; end = (
    (Pair: cpFrame;      Index: 81),   // CDoubleWindow 2: active frame
    (Pair: cpFrameInact; Index: 80),   // CDoubleWindow 1: passive frame
    (Pair: cpFile;       Index: 85),   // CPanel 1: normal text
    (Pair: cpSelected;   Index: 87),   // CPanel 3: selected text
    (Pair: cpCursor;     Index: 88),   // CPanel 4: normal cursor
    (Pair: cpSelCursor;  Index: 89),   // CPanel 5: selected cursor
    (Pair: cpColTitle;   Index: 165),  // CPanel 6: column titles
    (Pair: cpDir;        Index: 172),  // CPanel 7: highlight, directories
    (Pair: cpTitleAct;   Index: 90),   // CTopView 1: active
    (Pair: cpTitlePas;   Index: 91),   // CTopView 2: passive
    (Pair: cpInfo;       Index: 119),  // CInfoView 1
    (Pair: cpClock;      Index: 1),    // TClockView: the app's entry 1
    (Pair: cpMenuBar;    Index: 2),    // CMenuView / CStatusLine normal
    (Pair: cpFKeyNum;    Index: 4),    //   shortcut (the F-key numbers)
    (Pair: cpMenuSel;    Index: 5),    //   selected
    (Pair: cpDialog;     Index: 37),   // CGrayDialog 6: static text
    (Pair: cpDlgFrame;   Index: 33),   // CGrayDialog 2: active frame
    (Pair: cpDlgBtnSel;  Index: 43),   // CGrayDialog 12: selected button
    (Pair: cpInput;      Index: 50),   // CGrayDialog 19: input line
    (Pair: cpViewer;     Index: 117)   // CViewWindow 6: viewer text
  );
  PairDnIndex2: array[0..2] of record Pair, Index: Integer; end = (
    (Pair: cpDlgList;    Index: 57),   // CGrayDialog 26: list normal
    (Pair: cpDlgSel;     Index: 58),   // CGrayDialog 27: list focused
    (Pair: cpEditor;     Index: 76)    // CUniWindow 13: editor text
  );

function DnPaletteIndex(const Id: AnsiString): Integer;
{ the DN attribute byte a pair shows in palette Pal (for tests/preview) }
function DnPairAttr(Pal, Pair: Integer): Byte;
{ the terminal color for VGA color c of palette Pal: an ANSI index (0..15)
  for the standard VGA colors, the nearest xterm-256 color for a color the
  palette re-programs, c and 7 on an 8-color terminal }
function DnTermColor(Pal, c, Colors: Integer): Integer;
{ re-init the color pairs to DnPalettes[Pal]; ScrInit applies 0, dn.pas
  re-applies the configured one }
procedure ApplyPalette(Pal: Integer);
{ the terminal color of the viewer background in the current palette }
function ViewerBg: Integer;
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
{ s cut or padded to exactly w screen columns (wide characters count 2) }
function Utf8PadRight(const s: AnsiString; w: Integer): AnsiString;
function Utf8PadLeft(const s: AnsiString; w: Integer): AnsiString;
{ screen columns of a codepoint: 0 combining, 2 wide (CJK, emoji), else 1 }
function Utf8CpWidth(Cp: LongWord): Integer;
{ screen columns of a string }
function Utf8Width(const s: AnsiString): Integer;
{ columns startCol.. startCol+cols-1 of s, padded with spaces to cols }
function Utf8ClipCols(const s: AnsiString; startCol, cols: Integer): AnsiString;
{ malformed UTF-8, control and C1 characters replaced with '·' (tab and
  line breaks kept): safe to send to the terminal }
function Utf8Sanitize(const s: AnsiString): AnsiString;

implementation

uses
  dngpm;

var
  PanelBG: LongInt = COLOR_BLUE;   // panel background of the active scheme
  InputDelay: LongInt = -1;        // last timeout(): ms, -1 = blocking
  { parsed mouse events waiting for getmouse; small ring, a burst of
    clicks never exceeds it }
  MouseQ: array[0..63] of MEVENT;
  MouseHead, MouseTail: Integer;
  { bytes the sequence decoder read but did not consume (a lone ESC or an
    Alt-letter): getch hands them out before touching the terminal again.
    ungetch cannot be used for this: ncurses does not reassemble a
    sequence pushed back into its buffer, it returns the bytes one by one. }
  PushQ: AnsiString;

function c_setlocale(category: LongInt; locale: PChar): PChar;
  cdecl; external 'c' name 'setlocale';

const
  { LC_CTYPE differs per libc: 0 on glibc, 2 on Darwin (where 0 is LC_ALL).
    ncurses only needs character type classification to be UTF-8 before
    initscr. }
  LC_CTYPE_C = {$ifdef darwin} 2 {$else} 0 {$endif};

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
  { An env var promising UTF-8 is not enough: over SSH the client forwards
    locales the host may never have generated, and setlocale fails — the
    process stays in "C" and ncurses renders box-drawing bytes as ~U/~P. }
  if IsUtf8Locale(loc) and (c_setlocale(LC_CTYPE_C, '') <> nil) then
    Exit;

  { Debian ships C.UTF-8 by default. macOS does not have it, so keep
    en_US.UTF-8 as a fallback for direct local runs. Pass the names straight
    to setlocale instead of exporting LC_ALL: env changes would leak into
    every shell and tool DN spawns. }
  if c_setlocale(LC_CTYPE_C, 'C.UTF-8') = nil then
    c_setlocale(LC_CTYPE_C, 'en_US.UTF-8');
end;

const
  { the standard VGA DAC (DRIVERS.PAS VGA_Default) }
  VgaStd: array[0..15, 0..2] of Byte = (
    (0, 0, 0), (0, 0, 42), (0, 42, 0), (0, 42, 42), (42, 0, 0), (42, 0, 42),
    (42, 21, 0), (42, 42, 42), (21, 21, 21), (21, 21, 63), (21, 63, 21),
    (21, 63, 63), (63, 21, 21), (63, 21, 63), (63, 63, 21), (63, 63, 63));
  { VGA color order (blue first) to ANSI order (red first) }
  VgaToAnsi: array[0..7] of Integer = (0, 4, 2, 6, 1, 5, 3, 7);

const
  PalettePairs = [cpFrame..cpViewer, cpFrameInact..cpCmdPrompt];

var
  { pairs whose foreground needs A_BOLD to be bright (8-color terminals) }
  PairBold: array[0..255] of Boolean;
  SynBG: LongInt = COLOR_BLUE;

function DnPaletteIndex(const Id: AnsiString): Integer;
var
  i: Integer;
begin
  for i := 0 to DnPalCount - 1 do
    if DnPalettes[i].Id = Id then Exit(i);
  Result := -1;
end;

function DnPairAttr(Pal, Pair: Integer): Byte;
var
  i: Integer;
begin
  Result := $07;
  if Pair = cpCmdLine then Exit($07);        // TCommandLine.Draw: fixed
  if Pair = cpCmdPrompt then Exit($0F);
  if (Pal < 0) or (Pal >= DnPalCount) then Pal := 0;
  for i := 0 to High(PairDnIndex) do
    if PairDnIndex[i].Pair = Pair then
      Exit(DnPalettes[Pal].Attr[PairDnIndex[i].Index]);
  for i := 0 to High(PairDnIndex2) do
    if PairDnIndex2[i].Pair = Pair then
      Exit(DnPalettes[Pal].Attr[PairDnIndex2[i].Index]);
end;

function Nearest256(r, g, b: Integer): Integer;
const
  Steps: array[0..5] of Integer = (0, 95, 135, 175, 215, 255);
var
  i, best, d, bd, v, ri, gi, bi: Integer;

  function Step(x: Integer): Integer;
  var
    k: Integer;
  begin
    Result := 0;
    for k := 1 to 5 do
      if Abs(Steps[k] - x) < Abs(Steps[Result] - x) then Result := k;
  end;

begin
  ri := Step(r); gi := Step(g); bi := Step(b);
  best := 16 + 36 * ri + 6 * gi + bi;
  bd := Sqr(Steps[ri] - r) + Sqr(Steps[gi] - g) + Sqr(Steps[bi] - b);
  for i := 0 to 23 do                       // the gray ramp 232..255
  begin
    v := 8 + 10 * i;
    d := Sqr(v - r) + Sqr(v - g) + Sqr(v - b);
    if d < bd then
    begin
      bd := d;
      best := 232 + i;
    end;
  end;
  Result := best;
end;

function DnTermColor(Pal, c, Colors: Integer): Integer;
var
  custom: Boolean;
  k: Integer;
begin
  c := c and 15;
  custom := False;
  for k := 0 to 2 do
    if DnPalettes[Pal].Dac[c, k] <> VgaStd[c, k] then custom := True;
  if custom and (Colors >= 256) then
    Result := Nearest256(DnPalettes[Pal].Dac[c, 0] * 255 div 63,
                         DnPalettes[Pal].Dac[c, 1] * 255 div 63,
                         DnPalettes[Pal].Dac[c, 2] * 255 div 63)
  else if Colors >= 16 then
    Result := VgaToAnsi[c and 7] + 8 * (c shr 3)
  else
    Result := VgaToAnsi[c and 7];
end;

procedure SetDnPair(Pal, Pair: Integer; Attr: Byte);
var
  fg, bg: Integer;
begin
  fg := DnTermColor(Pal, Attr and 15, COLORS);
  bg := DnTermColor(Pal, Attr shr 4, COLORS);
  PairBold[Pair] := (COLORS < 16) and (Attr and 8 <> 0);
  init_pair(Pair, fg, bg);
end;

procedure SetHlPair(idx, fg: Integer);
begin
  if (idx < 1) or (idx > 4) then Exit;
  if (fg < 1) or (fg > 7) then fg := COLOR_WHITE;
  init_pair(cpHl1 + idx - 1, fg, PanelBG);
end;

function ViewerBg: Integer;
begin
  Result := SynBG;
end;

procedure ApplyPalette(Pal: Integer);
var
  i: Integer;
  mono: Boolean;
begin
  if (Pal < 0) or (Pal >= DnPalCount) then Pal := 0;
  FillChar(PairBold, SizeOf(PairBold), 0);
  for i := 0 to High(PairDnIndex) do
    SetDnPair(Pal, PairDnIndex[i].Pair, DnPairAttr(Pal, PairDnIndex[i].Pair));
  for i := 0 to High(PairDnIndex2) do
    SetDnPair(Pal, PairDnIndex2[i].Pair, DnPairAttr(Pal, PairDnIndex2[i].Pair));
  SetDnPair(Pal, cpCmdLine, DnPairAttr(Pal, cpCmdLine));
  SetDnPair(Pal, cpCmdPrompt, DnPairAttr(Pal, cpCmdPrompt));
  { user highlight groups and syntax classes keep their own foregrounds
    on the panel / viewer background of the palette }
  PanelBG := DnTermColor(Pal, DnPairAttr(Pal, cpFile) shr 4, COLORS);
  SynBG := DnTermColor(Pal, DnPairAttr(Pal, cpViewer) shr 4, COLORS);
  mono := (DnPalettes[Pal].Id = 'bw') or (DnPalettes[Pal].Id = 'vgabw') or
          (DnPalettes[Pal].Id = 'mono');
  if mono then
  begin
    { only bold-at-draw distinguishes the classes }
    for i := cpSynNumber to cpSynKw2 do
      init_pair(i, DnTermColor(Pal, DnPairAttr(Pal, cpViewer) and 7, COLORS), SynBG);
  end
  else
  begin
    init_pair(cpSynNumber,  COLOR_GREEN,  SynBG);
    init_pair(cpSynString,  COLOR_CYAN,   SynBG);
    init_pair(cpSynComment, COLOR_BLACK,  SynBG);
    init_pair(cpSynSymbol,  COLOR_YELLOW, SynBG);
    init_pair(cpSynKw1,     COLOR_WHITE,  SynBG);
    init_pair(cpSynKw2,     COLOR_YELLOW, SynBG);
  end;
end;

procedure MouseReportsOn;
begin
  Write(#27'[?1000h'#27'[?1002h'#27'[?1006h');
  Flush(Output);
end;

procedure MouseReportsOff;
begin
  Write(#27'[?1006l'#27'[?1002l'#27'[?1000l');
  Flush(Output);
end;

procedure ScrInit;
begin
  EnsureUtf8Locale;
  GpmPreInit;
  initscr;
  { raw, not cbreak: keeps ^Y (macOS DSUSP), ^S/^Q, ^C as ordinary input
    instead of terminal control — an editor needs them as keystrokes }
  raw;
  noecho;
  { keypad OFF: ncurses cannot decode the key sequences on this build (the
    FPC binding's chtype is wider than the linked ncurses'), so getch returns
    raw bytes and dnscreen decodes every sequence itself in DecodeSeq }
  keypad(stdscr, False);
  curs_set(0);
  start_color;
  ApplyPalette(0);
  { Do NOT call ncurses' mousemask: the FPC binding's mmask_t is 64-bit
    while the linked ncurses uses 32-bit masks, so the call misaligns
    ncurses' internal mouse state and every report is dropped. We enable the
    terminal modes ourselves and parse the reports in getch instead. }
  { Enable SGR mouse (1006) for exact coordinates, button-motion (1002) for
    drag events. Must go out AFTER ncurses' refresh, or ncurses' own
    mouse-enable string would overwrite these modes. }
  refresh;
  MouseReportsOn;
  GpmInit;
end;

procedure ScrDone;
begin
  GpmDone;
  MouseReportsOff;
  endwin;
end;

procedure ScrSuspend;
begin
  def_prog_mode;
  GpmSuspend;
  endwin;
  MouseReportsOff;       // after endwin: nothing of ncurses' follows it
end;

procedure ScrResume;
begin
  reset_prog_mode;
  GpmResume;
  refresh;
  MouseReportsOn;        // after refresh, as in ScrInit
end;

function CurrentTimeout: LongInt;
begin
  Result := InputDelay;
end;

procedure timeout(delay: LongInt);
begin
  InputDelay := delay;
  ncurses.timeout(delay);
end;

{ --- SGR mouse parsing (xterm 1006) -------------------------------- }

procedure MouseEnqueue(x, y: Integer; bstate: LongWord);
begin
  FillChar(MouseQ[MouseHead], SizeOf(MEVENT), 0);
  MouseQ[MouseHead].x := x;
  MouseQ[MouseHead].y := y;
  MouseQ[MouseHead].bstate := bstate;
  MouseHead := (MouseHead + 1) and 63;
end;

function MousePending: Boolean;
begin
  Result := MouseHead <> MouseTail;
end;

{ the last event PopMouse handed out: its bstate is mbtn1Released when it
  is the release half of a click. Callers that treat a press as the click
  drop this report instead of acting on it a second time. }
{ hand out one queued event. getch calls this when it returns KEY_MOUSE so
  the event is already off the queue: a caller that ignores the mouse (Tetris,
  the screen saver) does not wedge the queue and its next getch still returns
  real keys. getmouse reads the event back. }
var
  MouseCurrent: MEVENT;
  MouseHasCurrent: Boolean;

function LastMouseState: LongWord;
begin
  if MouseHasCurrent then Result := MouseCurrent.bstate else Result := 0;
end;

function MouseIsRelease: Boolean;
begin
  Result := (LastMouseState and (mbtn1Released or mbtn2Released or
                                 mbtn3Released)) <> 0;
end;

{ drop every queued report and the hand-out one: after a dialog picked a
  row, the release of that click must not reach the next input }
procedure MouseFlush;
begin
  MouseHasCurrent := False;
  MouseHead := MouseTail;
end;

function PopMouse: Boolean;
begin
  if not MousePending then Exit(False);
  MouseCurrent := MouseQ[MouseTail];
  MouseTail := (MouseTail + 1) and 63;
  MouseHasCurrent := True;
  Result := True;
end;

function getmouse(event: PMEVENT): LongInt;
begin
  if event = nil then Exit(ERR);
  if not MouseHasCurrent then
    if not PopMouse then Exit(ERR);
  event^ := MouseCurrent;
  MouseHasCurrent := False;
  Result := OK;
end;

function ungetmouse(event: PMEVENT): LongInt;
begin
  if event = nil then Exit(ERR);
  MouseTail := (MouseTail - 1) and 63;
  MouseQ[MouseTail] := event^;
  Result := OK;
end;

{ read one byte from ncurses with a short timeout: a sequence's bytes arrive
  together, a lone ESC has no follow-up }
function ReadRawByte: Integer;
var
  c: LongInt;
begin
  ncurses.timeout(30);
  c := ncurses.getch;
  ncurses.timeout(InputDelay);
  if c = ERR then Result := -1 else Result := c and $FF;
end;

{ --- escape-sequence decoder -----------------------------------------
  ncurses cannot decode key sequences on this build: the FPC binding's chtype
  and mmask_t are wider than the linked ncurses' ones, so keypad matching and
  mousemask both fail and getch returns raw bytes (ESC O F for End, ESC [ <
  for the SGR mouse). keypad is therefore OFF (ScrInit) and every sequence is
  decoded here: function keys, arrows, Home/End/PgUp/PgDn/Ins/Del and the SGR
  mouse reports. Anything unrecognized comes back as ESC with its bytes queued
  in PushQ, so a lone ESC and an Alt-letter still reach the caller. }

type
  TKeySeq = record
    Seq: AnsiString;
    Key: LongInt;
  end;

const
  { xterm sequences in both CSI (\E[..) and SS3 (\EO..) forms }
  KeySeqs: array[0..30] of TKeySeq = (
    (Seq: 'OA'; Key: KEY_UP),
    (Seq: 'OB'; Key: KEY_DOWN),
    (Seq: 'OC'; Key: KEY_RIGHT),
    (Seq: 'OD'; Key: KEY_LEFT),
    (Seq: '[A'; Key: KEY_UP),
    (Seq: '[B'; Key: KEY_DOWN),
    (Seq: '[C'; Key: KEY_RIGHT),
    (Seq: '[D'; Key: KEY_LEFT),
    (Seq: 'OH'; Key: KEY_HOME),
    (Seq: '[H'; Key: KEY_HOME),
    (Seq: '[1~'; Key: KEY_HOME),
    (Seq: '[7~'; Key: KEY_HOME),
    (Seq: 'OF'; Key: KEY_END),
    (Seq: '[F'; Key: KEY_END),
    (Seq: '[4~'; Key: KEY_END),
    (Seq: '[8~'; Key: KEY_END),
    (Seq: '[5~'; Key: KEY_PPAGE),
    (Seq: '[6~'; Key: KEY_NPAGE),
    (Seq: '[2~'; Key: KEY_IC),
    (Seq: '[3~'; Key: KEY_DC),
    (Seq: '[1;2D'; Key: KEY_SLEFT),
    (Seq: '[1;2C'; Key: KEY_SRIGHT),
    (Seq: '[1;2A'; Key: KEY_SR),
    (Seq: '[1;2B'; Key: KEY_SF),
    (Seq: '[15;5~'; Key: KEY_F0 + 29),   // Ctrl-F5: move/resize a window
    (Seq: '[18;3~'; Key: KEY_F0 + 7 + 1000),  // Alt-F7: find file
    (Seq: '[19;3~'; Key: KEY_F0 + 8 + 1000),  // Alt-F8: stop playback
    (Seq: 'OP'; Key: KEY_F0 + 1),
    (Seq: 'OQ'; Key: KEY_F0 + 2),
    (Seq: 'OR'; Key: KEY_F0 + 3),
    (Seq: 'OS'; Key: KEY_F0 + 4)
  );

{ F5..F12: CSI \E[<n>~ with n = 15,17,18,19,20,21,23,24 }
function FKeyNum(n: Integer; out Key: LongInt): Boolean;
begin
  case n of
    15: Key := KEY_F0 + 5;
    17: Key := KEY_F0 + 6;
    18: Key := KEY_F0 + 7;
    19: Key := KEY_F0 + 8;
    20: Key := KEY_F0 + 9;
    21: Key := KEY_F0 + 10;
    23: Key := KEY_F0 + 11;
    24: Key := KEY_F0 + 12;
  else
    Exit(False);
  end;
  Result := True;
end;

{ decode a sequence that begins after an ESC. Returns KEY_MOUSE for an SGR
  report, the matching KEY_* for a known key, or 27 with the bytes queued in
  PushQ when nothing matches. Called only after getch returned 27. }
function DecodeSeq: LongInt;
var
  buf: AnsiString;
  c, i, n: Integer;
  b, x, y: Integer;
  nb, btn: Integer;
  bstate: LongWord;
  press: Boolean;
  nums: array[0..2] of Integer;
  cur: Integer;

  function Next: Integer;
  begin
    Result := ReadRawByte;
    if Result >= 0 then buf := buf + Chr(Result);
  end;

  procedure QueueBytes;
  begin
    PushQ := PushQ + buf;
  end;

  procedure PutNum;
  begin
    if cur <= 2 then nums[cur] := nb;
    Inc(cur);
    nb := 0;
  end;

  function LastByte: Char;
  begin
    Result := buf[Length(buf)];
  end;

begin
  Result := 27;
  buf := '';
  if Next < 0 then
  begin
    QueueBytes;                      // lone ESC: give it straight back
    Exit;
  end;
  if not (LastByte in ['[', 'O']) then
  begin
    QueueBytes;                      // Alt-letter and the like
    Exit;
  end;
  { SGR mouse report: ESC [ < b ; x ; y M|m }
  if LastByte = '[' then
  begin
    if Next = Ord('<') then
    begin
      cur := 0; nb := 0;
      press := True;
      while True do
      begin
        if Next < 0 then
        begin
          QueueBytes;
          Exit;
        end;
        c := Ord(LastByte);
        if (c >= Ord('0')) and (c <= Ord('9')) then
          nb := nb * 10 + (c - Ord('0'))
        else if c = Ord(';') then
          PutNum
        else if (c = Ord('M')) or (c = Ord('m')) then
        begin
          PutNum;
          press := c = Ord('M');
          Break;
        end
        else
        begin
          QueueBytes;
          Exit;
        end;
      end;
      if cur < 3 then
      begin
        QueueBytes;
        Exit;
      end;
      b := nums[0];
      x := nums[1] - 1;
      y := nums[2] - 1;
      if x < 0 then x := 0;
      if y < 0 then y := 0;
      if x >= COLS then x := COLS - 1;
      if y >= LINES then y := LINES - 1;
      btn := b and 3;
      if (b and 64) <> 0 then
      begin
        { wheel: 64 = up, 65 = down }
        if btn = 0 then bstate := mbtnWheelUp
        else bstate := mbtnWheelDown;
      end
      else if (b and 32) <> 0 then
        bstate := mMousePosition        // motion with a button held
      else if press then
        case btn of
          0: bstate := mbtn1Pressed;
          1: bstate := mbtn2Pressed;
          2: bstate := mbtn3Pressed;
        else
          bstate := 0;
        end
      else
        case btn of
          0: bstate := mbtn1Released;
          1: bstate := mbtn2Released;
          2: bstate := mbtn3Released;
        else
          bstate := 0;
        end;
      MouseEnqueue(x, y, bstate);
      Exit(KEY_MOUSE);
    end
    else
      { not a mouse report: keep the '[' and the byte just read, and go on
        collecting a key sequence }
      ;
  end;
  { collect up to a final byte: '~', or a letter for CSI/SS3 — but 'O'
    alone is the SS3 introducer, not a final byte, so keep reading }
  while (Length(buf) < 8) and
        ((Length(buf) = 1) or
         ((LastByte <> '~') and not ((LastByte >= 'A') and (LastByte <= 'Z')))) do
    if Next < 0 then
    begin
      QueueBytes;
      Exit;
    end;
  for i := 0 to High(KeySeqs) do
    if KeySeqs[i].Seq = buf then Exit(KeySeqs[i].Key);
  { CSI <n>~ : F5..F12, n is everything between '[' and '~' and must
    be plain digits (a modifier like "15;5" is a different key, already in
    the table) }
  if (Length(buf) >= 3) and (LastByte = '~') and (buf[2] >= '1') and
     (buf[2] <= '2') and (Pos(';', buf) = 0) then
  begin
    n := StrToIntDef(Copy(buf, 2, Length(buf) - 2), -1);
    if FKeyNum(n, Result) then Exit;
  end;
  QueueBytes;
  Result := 27;
end;

function getch: LongInt;
var
  deadline, now: QWord;
  wait: LongInt;

  function OneKey: LongInt;
  begin
    if PushQ <> '' then
    begin
      Result := Ord(PushQ[1]);
      Delete(PushQ, 1, 1);
      Exit;
    end;
    Result := ncurses.getch;
    if Result = 27 then
      Result := DecodeSeq;
  end;

begin
  if PopMouse then Exit(KEY_MOUSE);
  if not GpmActive then
    Exit(OneKey);
  { poll ncurses (which also flushes screen updates), then sleep on the
    keyboard and the gpm socket together }
  if InputDelay > 0 then
    deadline := GetTickCount64 + QWord(InputDelay)
  else
    deadline := GetTickCount64;
  ncurses.timeout(0);
  try
    repeat
      Result := OneKey;
      if Result <> ERR then Exit;
      GpmShowPointer;
      if InputDelay < 0 then
        wait := -1
      else
      begin
        now := GetTickCount64;
        if now >= deadline then Exit(ERR);
        wait := deadline - now;
      end;
      GpmWait(wait);
    until False;
  finally
    ncurses.timeout(InputDelay);
  end;
end;

procedure PutStr(y, x: Integer; const s: AnsiString; pair: Integer; bold: Boolean);
var
  attr: LongInt;
begin
  attr := COLOR_PAIR(pair);
  { a palette pair carries its own brightness; only highlight and syntax
    pairs (and windows' private pairs) take the caller's bold }
  if PairBold[pair and 255] or
     (bold and not (pair in PalettePairs)) then
    attr := attr or A_BOLD;
  attrset(attr);
  mvaddstr(y, x, PChar(s));
end;

procedure FillRow(y, x, w: Integer; pair: Integer);
var
  i: Integer;
begin
  if PairBold[pair and 255] then attrset(COLOR_PAIR(pair) or A_BOLD)
  else attrset(COLOR_PAIR(pair));
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

{ --- display width ------------------------------------------------------ }

{ decode one codepoint at s[i]; False (Len = 1) for a malformed sequence }
function Utf8Decode(const s: AnsiString; i: Integer; out Cp: LongWord;
                    out Len: Integer): Boolean;
var
  b: Byte;
  k: Integer;
  minCp: LongWord;
begin
  Result := False;
  Len := 1;
  Cp := Ord(s[i]);
  b := Ord(s[i]);
  if b < $80 then Exit(True);
  if (b and $E0) = $C0 then begin Len := 2; Cp := b and $1F; minCp := $80; end
  else if (b and $F0) = $E0 then begin Len := 3; Cp := b and $0F; minCp := $800; end
  else if (b and $F8) = $F0 then begin Len := 4; Cp := b and $07; minCp := $10000; end
  else begin Len := 1; Exit; end;
  if i + Len - 1 > Length(s) then begin Len := 1; Exit; end;
  for k := 1 to Len - 1 do
  begin
    b := Ord(s[i + k]);
    if (b and $C0) <> $80 then begin Len := 1; Exit; end;
    Cp := (Cp shl 6) or (b and $3F);
  end;
  if (Cp < minCp) or (Cp > $10FFFF) or ((Cp >= $D800) and (Cp <= $DFFF)) then
  begin
    Len := 1;
    Exit;
  end;
  Result := True;
end;

function Utf8CpWidth(Cp: LongWord): Integer;
begin
  { combining marks and zero-width characters take no column }
  if ((Cp >= $0300) and (Cp <= $036F)) or ((Cp >= $1AB0) and (Cp <= $1AFF)) or
     ((Cp >= $1DC0) and (Cp <= $1DFF)) or ((Cp >= $20D0) and (Cp <= $20FF)) or
     ((Cp >= $FE20) and (Cp <= $FE2F)) or ((Cp >= $200B) and (Cp <= $200F)) or
     (Cp = $FEFF) then
    Exit(0);
  { East Asian wide and fullwidth, and the emoji blocks: two columns }
  if ((Cp >= $1100) and (Cp <= $115F)) or ((Cp >= $2E80) and (Cp <= $303E)) or
     ((Cp >= $3041) and (Cp <= $33FF)) or ((Cp >= $3400) and (Cp <= $4DBF)) or
     ((Cp >= $4E00) and (Cp <= $9FFF)) or ((Cp >= $A000) and (Cp <= $A4CF)) or
     ((Cp >= $AC00) and (Cp <= $D7A3)) or ((Cp >= $F900) and (Cp <= $FAFF)) or
     ((Cp >= $FE30) and (Cp <= $FE4F)) or ((Cp >= $FF00) and (Cp <= $FF60)) or
     ((Cp >= $FFE0) and (Cp <= $FFE6)) or ((Cp >= $1F300) and (Cp <= $1F64F)) or
     ((Cp >= $1F900) and (Cp <= $1F9FF)) or ((Cp >= $20000) and (Cp <= $3FFFD)) then
    Exit(2);
  Result := 1;
end;

function Utf8Sanitize(const s: AnsiString): AnsiString;
var
  i, len: Integer;
  cp: LongWord;
begin
  Result := '';
  i := 1;
  while i <= Length(s) do
  begin
    if not Utf8Decode(s, i, cp, len) then
      Result := Result + '·'
    else if (cp < 32) and (cp <> 9) and (cp <> 10) and (cp <> 13) then
      Result := Result + '·'
    else if (cp = $7F) or ((cp >= $80) and (cp <= $9F)) then
      Result := Result + '·'                 // C1 controls: terminal commands
    else
      Result := Result + Copy(s, i, len);
    Inc(i, len);
  end;
end;

function Utf8Width(const s: AnsiString): Integer;
var
  i, len: Integer;
  cp: LongWord;
begin
  Result := 0;
  i := 1;
  while i <= Length(s) do
  begin
    if Utf8Decode(s, i, cp, len) then Inc(Result, Utf8CpWidth(cp))
    else Inc(Result);
    Inc(i, len);
  end;
end;

function Utf8ClipCols(const s: AnsiString; startCol, cols: Integer): AnsiString;
var
  i, len, w, col: Integer;
  cp: LongWord;
begin
  Result := '';
  col := 0;                  // columns placed so far
  i := 1;
  { skip startCol columns; a wide char cut in half leaves a space }
  while (i <= Length(s)) and (startCol > 0) do
  begin
    if Utf8Decode(s, i, cp, len) then w := Utf8CpWidth(cp) else w := 1;
    Inc(i, len);
    Dec(startCol, w);
    if startCol < 0 then
    begin
      Result := ' ';
      col := 1;
      startCol := 0;
    end;
  end;
  while (i <= Length(s)) and (col < cols) do
  begin
    if Utf8Decode(s, i, cp, len) then w := Utf8CpWidth(cp) else w := 1;
    if col + w > cols then Break;
    Result := Result + Copy(s, i, len);
    Inc(col, w);
    Inc(i, len);
  end;
  if col < cols then Result := Result + StringOfChar(' ', cols - col);
end;

function Utf8PadRight(const s: AnsiString; w: Integer): AnsiString;
begin
  if w <= 0 then Exit('');
  Result := Utf8ClipCols(s, 0, w);
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
