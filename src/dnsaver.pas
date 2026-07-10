{ dnsaver — idle screen savers, a port of original/dnossp/idlers.pas:
  the flying star field (TStarSkySaver), the bouncing clock
  (TClockSaver) and a blank screen. RunSaver takes over the terminal
  and animates until a key or mouse press arrives; that waking event
  is consumed, exactly like the original TSSaver.Execute. }
unit dnsaver;

{$mode objfpc}{$H+}

interface

const
  svStarSky = 0;
  svClock   = 1;
  svBlank   = 2;

{ seconds of inactivity before the saver starts; 0 = disabled.
  DN_SAVER_SECONDS overrides the configured minutes (for tests/preview). }
function SaverIdleLimit: Integer;
procedure RunSaver(Kind: Integer);

implementation

uses
  SysUtils, ncurses, dnscreen, dnoptions;

const
  { pairs 30..37: COLOR_* foreground on black, private to the saver }
  cpSaverBase = 30;

  { star appearance by distance ring from the center (original StarChars:
    CP437 #32 #250 #249 #7 #4 #15) }
  StarChars: array[0..5] of AnsiString = (' ', '·', '∙', '•', '♦', '☼');
  Mult = 256;                       // fixed-point multiplier (StarSkyMult)

type
  TStar = record
    X, Y, DX, DY: Integer;          // position/velocity, fixed-point
    Speed, Stat, Stage: Integer;
    Bright: Boolean;
    NextMs: QWord;                  // next movement deadline
  end;

function SaverIdleLimit: Integer;
var
  s: AnsiString;
  n: Integer;
begin
  s := GetEnvironmentVariable('DN_SAVER_SECONDS');
  n := StrToIntDef(s, 0);
  if n > 0 then Exit(n);
  if Opt.SaverDelay <= 0 then Exit(0);
  Result := Opt.SaverDelay * 60;
end;

procedure InitSaverPairs;
var
  c: Integer;
begin
  for c := 1 to 7 do
    init_pair(cpSaverBase + c, c, COLOR_BLACK);
end;

procedure PutSaver(y, x: Integer; const s: AnsiString; color: Integer; bold: Boolean);
var
  attr: LongInt;
begin
  attr := COLOR_PAIR(cpSaverBase + color);
  if bold then attr := attr or A_BOLD;
  attrset(attr);
  mvaddstr(y, x, PChar(s));
end;

{ ---------------- star sky (port of TStarSkySaver) ---------------- }

procedure StarInit(var st: TStar; now: QWord);
var
  a, r: Integer;
begin
  { only 1 in 4 respawns immediately: the sky fills up gradually }
  if Random(4) <> 3 then Exit;
  st.Speed := COLS div 44 + Random(3);
  a := Random(360);
  st.DX := Round(Mult * cos((2 * PI * a) / 360));
  st.DY := Round(Mult * sin((2 * PI * a) / 360));
  r := (1 + Random(2)) * (1 + 131 div COLS);
  st.X := (COLS div 2) * Mult + st.DX * st.Speed div r;
  st.Y := (LINES div 2) * Mult + st.DY * st.Speed div r;
  st.Bright := Random(5) = 4;
  st.Stat := 0;
  st.Stage := 10;
  st.NextMs := now;
end;

{ distance ring 1..5 from the screen center (the original MMM) }
function StarRing(x, y: Integer): Integer;
var
  dx, dy: Integer;
begin
  dx := 8 * Abs(x div Mult - COLS div 2) div COLS + 1;
  dy := 8 * Abs(y div Mult - LINES div 2) div LINES + 1;
  if dx < dy then Result := dy else Result := dx;
  if Result > High(StarChars) then Result := High(StarChars);
end;

procedure RunStarSky;
var
  stars: array of TStar;
  n, i, k, delay, px, py: Integer;
  now: QWord;
  ch: LongInt;
  mev: MEVENT;
begin
  Randomize;
  n := 2 * COLS - 64;
  if n < 16 then n := 16;
  if n > 512 then n := 512;
  SetLength(stars, n);
  FillChar(stars[0], n * SizeOf(TStar), 0);
  delay := (131 div COLS) * 2;

  timeout(40);
  repeat
    now := GetTickCount64;
    { tall terminals animate the full set, wide ones half (original K) }
    if LINES * 2 > COLS then k := 1 else k := 2;
    for i := 0 to n div k - 1 do
      with stars[i] do
        if now >= NextMs then
        begin
          Inc(X, (DX * Stage) div 12);
          Inc(Y, (DY * Stage) div 12);
          Inc(Stage);
          Stat := StarRing(X, Y);
          px := X div Mult;
          py := Y div Mult;
          if (px < 0) or (px >= COLS) or (py < 0) or (py >= LINES) or
             ((DX = 0) and (DY = 0)) then
            StarInit(stars[i], now)
          else
            NextMs := now + QWord((delay + Speed) * 10);
        end;

    erase;
    for i := 0 to n - 1 do
      with stars[i] do
        if (DX <> 0) or (DY <> 0) then
        begin
          px := X div Mult;
          py := Y div Mult;
          if (px >= 0) and (px < COLS) and (py >= 0) and (py < LINES) then
            PutSaver(py, px, StarChars[Stat], 7, Bright);
        end;
    refresh;

    ch := getch;
    if ch = KEY_MOUSE then
    begin
      getmouse(@mev);
      Break;
    end;
    if ch = KEY_RESIZE then
    begin
      n := 2 * COLS - 64;
      if n < 16 then n := 16;
      if n > 512 then n := 512;
      SetLength(stars, n);
      FillChar(stars[0], n * SizeOf(TStar), 0);
      ch := ERR;
    end;
  until ch <> ERR;
end;

{ ---------------- bouncing clock (port of TClockSaver) ------------ }

procedure RunClock;
var
  x, y, dx, dy, ddy, clr: Integer;
  lastSec: Integer;
  h, m, s, ms: Word;
  ch: LongInt;
  mev: MEVENT;
  t: AnsiString;
begin
  Randomize;
  x := COLS div 2 - 3;
  y := LINES div 2;
  dx := 1 - Random(3);
  dy := 1 - Random(3);
  ddy := 3 + Random(10);
  clr := 1;                          // walks 1..6 like the original 9..14
  lastSec := -1;

  timeout(200);
  repeat
    DecodeTime(Now, h, m, s, ms);
    if s <> lastSec then
    begin
      lastSec := s;
      Inc(x, dx);
      Inc(y, dy);
      if x < 0 then x := 0;
      if x > COLS - 6 then x := COLS - 6;
      if y < 0 then y := 0;
      if y > LINES - 1 then y := LINES - 1;
      Dec(ddy);
      if ddy <= 0 then
      begin
        dx := 1 - Random(3);
        dy := 1 - Random(3);
        ddy := 3 + Random(10);
        Inc(clr);
        if clr > 6 then clr := 1;
      end;
    end;
    erase;
    t := Format('%.2d:%.2d', [h, m]);
    { blink the colon: hide it on odd seconds (the original used the
      hardware blink attribute, unreliable in terminals) }
    if Odd(s) then t[3] := ' ';
    PutSaver(y, x, t, clr, True);
    refresh;

    ch := getch;
    if ch = KEY_MOUSE then
    begin
      getmouse(@mev);
      Break;
    end;
    if ch = KEY_RESIZE then
    begin
      if x > COLS - 6 then x := COLS - 6;
      if y > LINES - 1 then y := LINES - 1;
      ch := ERR;
    end;
  until ch <> ERR;
end;

{ ---------------- blank screen ------------------------------------ }

procedure RunBlank;
var
  ch: LongInt;
  mev: MEVENT;
begin
  timeout(500);
  repeat
    erase;
    refresh;
    ch := getch;
    if ch = KEY_MOUSE then
    begin
      getmouse(@mev);
      Break;
    end;
    if ch = KEY_RESIZE then ch := ERR;
  until ch <> ERR;
end;

procedure RunSaver(Kind: Integer);
begin
  InitSaverPairs;
  curs_set(0);
  case Kind of
    svClock: RunClock;
    svBlank: RunBlank;
  else
    RunStarSky;
  end;
  { back to the main loop contract: 1s tick, full repaint }
  timeout(1000);
  erase;
  redrawwin(stdscr);
end;

end.
