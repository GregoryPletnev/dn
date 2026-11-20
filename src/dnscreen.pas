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
{ Mouse shims. The FPC ncurses binding's mmask_t/MEVENT are built for
  64-bit masks, but the ncurses on this machine uses 32-bit ones: the ABI
  mismatch makes ncurses' own mouse support silently drop every report
  (getch returns the raw ESC, never KEY_MOUSE). We therefore enable SGR
  mouse (1006) ourselves and parse the reports here. Units list dnscreen
  after ncurses, so these take precedence over the binding. }
function getmouse(event: PMEVENT): LongInt;
function ungetmouse(event: PMEVENT): LongInt;
procedure MouseEnqueue(x, y: Integer; bstate: LongWord);
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

procedure SetHlPair(idx, fg: Integer);
begin
  if (idx < 1) or (idx > 4) then Exit;
  if (fg < 1) or (fg > 7) then fg := COLOR_WHITE;
  init_pair(cpHl1 + idx - 1, fg, PanelBG);
end;

procedure ApplyPalette(Scheme: Integer);
var
  synBG: LongInt;
begin
  if Scheme = 0 then PanelBG := COLOR_BLUE else PanelBG := COLOR_BLACK;
  { syntax pairs follow the viewer background; the draw code adds bold
    for comments (dark gray) and keywords }
  if Scheme = 0 then synBG := COLOR_BLUE else synBG := COLOR_BLACK;
  if Scheme = 2 then
  begin
    { monochrome: only bold-at-draw distinguishes the classes }
    init_pair(cpSynNumber,  COLOR_WHITE, synBG);
    init_pair(cpSynString,  COLOR_WHITE, synBG);
    init_pair(cpSynComment, COLOR_WHITE, synBG);
    init_pair(cpSynSymbol,  COLOR_WHITE, synBG);
    init_pair(cpSynKw1,     COLOR_WHITE, synBG);
    init_pair(cpSynKw2,     COLOR_WHITE, synBG);
  end
  else
  begin
    init_pair(cpSynNumber,  COLOR_GREEN,  synBG);
    init_pair(cpSynString,  COLOR_CYAN,   synBG);
    init_pair(cpSynComment, COLOR_BLACK,  synBG);
    init_pair(cpSynSymbol,  COLOR_YELLOW, synBG);
    init_pair(cpSynKw1,     COLOR_WHITE,  synBG);
    init_pair(cpSynKw2,     COLOR_YELLOW, synBG);
  end;
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

{ hand out one queued event. getch calls this when it returns KEY_MOUSE so
  the event is already off the queue: a caller that ignores the mouse (Tetris,
  the screen saver) does not wedge the queue and its next getch still returns
  real keys. getmouse reads the event back. }
var
  MouseCurrent: MEVENT;
  MouseHasCurrent: Boolean;

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
  KeySeqs: array[0..29] of TKeySeq = (
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
