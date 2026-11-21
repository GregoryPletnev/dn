{ dnsaver — idle screen savers, a port of original/dnossp/idlers.pas:
  the flying star field (TStarSkySaver), the bouncing clock
  (TClockSaver) and a blank screen. RunSaver takes over the terminal
  and animates until a key or mouse press arrives; that waking event
  is consumed, exactly like the original TSSaver.Execute.
  The svDos* kinds run the native ports of the RIT Labs ssavers.zip
  pack (unit dndossav). }
unit dnsaver;

{$mode objfpc}{$H+}

interface

const
  svOff     = -1;   { no saver (used by the picker preview) }
  svStarSky = 0;
  svClock   = 1;
  svBlank   = 2;
  svWater   = 3;   { AZ_WATER.SS wave ripples }
  svFire    = 4;   { AZ_FIRE.SS burning plasma }
  svColines = 5;   { COLINES.SS palette chase }
  svBundles = 6;   { BUNDLES.SS bouncing line bundles }
  svChik    = 7;   { CHIK.SS walking blank box (dnchiksav) }
  svAscope  = 8;   { ASCOPE.SS oscilloscope Lissajous (unit dnascopesav) }

{ seconds of inactivity before the saver starts; 0 = disabled.
  DN_SAVER_SECONDS overrides the configured minutes (for tests/preview). }
function SaverIdleLimit: Integer;
procedure RunSaver(Kind: Integer);

{ draw one live frame of saver Kind into the rectangle (py,px)-(ph,pw)
  cells; the caller owns the box and the refresh. Kind is a sv* constant,
  svOff or below draws a dim "disabled" hint. Preview state persists
  between calls, so repeated calls animate the saver in the picker. }
procedure SaverPreviewDraw(Kind, py, px, ph, pw: Integer);

implementation

uses
  SysUtils, ncurses, dnscreen, dnoptions, dndossav, dnbundlessav, dnchiksav,
  dnascopesav;

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
  { the CHIK field uses a dim gray (base color 8) on black }
  init_pair(cpSaverBase + 8, 8, COLOR_BLACK);
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

{ ---------------- CHIK.SS walking blank box -------------------------- }

{ second of the day, the DOS clock byte the original rolls through
  helper 0x05E2 (value mod Bound) }
type
  TChikClock = object
    function Roll(Bound: Integer): Integer;
  end;

function TChikClock.Roll(Bound: Integer): Integer;
var
  h, m, s, ms: Word;
begin
  if Bound <= 0 then Exit(0);
  DecodeTime(Now, h, m, s, ms);
  Result := (h * 3600 + m * 60 + s) mod Bound;
end;

procedure RunChik;
var
  S: TChikSaver;
  clk: TChikClock;
  dirty: array of Boolean;
  fill: array of Word;
  ch: LongInt;
  mev: MEVENT;
  now, next: QWord;
  x, y: Integer;
begin
  S := TChikSaver.Create(COLS, LINES);
  try
    SetLength(dirty, COLS * LINES);
    for x := 0 to High(dirty) do dirty[x] := True;
    { the original walks a hole through the text screen it finds: the DN
      screen stays as it is, the grid only tracks which cells are still
      live (0x0720, space + attribute); erased cells are painted blank }
    SetLength(fill, S.Rows * S.Cols);
    for x := 0 to High(fill) do fill[x] := $0720;
    S.SetScreen(@fill[0]);
    S.Init(@clk.Roll);
    for x := 0 to High(dirty) do dirty[x] := False;
    timeout(ChikFramesPerTick * 1000 div 182);
    next := GetTickCount64;
    repeat
      now := GetTickCount64;
      if now >= next then
      begin
        Inc(next, ChikFramesPerTick * 1000 div 182);
        S.Step;
        for y := 0 to S.Rows - 1 do
          for x := 0 to S.Cols - 1 do
          begin
            if S.Dirty(x, y) and not dirty[y * COLS + x] then
            begin
              dirty[y * COLS + x] := True;
              PutSaver(y, x, ' ', 7, False);   { the hole: blank on black }
            end;
          end;
        refresh;
      end;
      ch := getch;
      if ch = KEY_MOUSE then
      begin
        getmouse(@mev);
        Break;
      end;
      if ch = KEY_RESIZE then ch := ERR;
    until ch <> ERR;
  finally
    S.Free;
  end;
end;

{ --- preview state for the saver picker ---------------------------- }

var
  PvKind: Integer = -2;             // -2: not initialized
  PvWave: dndossav.TWaveSim;
  PvBundlesReady: Boolean = False;
  PvBundles: dnbundlessav.TBundlesSim;
  PvChik: TChikSaver = nil;
  PvChikClk: TChikClock;
  PvChikFill: array of Word;
  PvScope: TAscopeSim;
  PvTick: QWord = 0;
  PvClockX, PvClockY, PvClockDX, PvClockDY, PvClockDdy, PvClockClr: Integer;

procedure PvReset(Kind: Integer);
var
  i: Integer;
begin
  PvKind := Kind;
  PvTick := 0;
  PvClockX := 4; PvClockY := 2;
  PvClockDX := 1; PvClockDY := 1; PvClockDdy := 6; PvClockClr := 1;
  case Kind of
    svWater:
      begin
        dndossav.WaveInit(PvWave, dndossav.dssWater, 320, 100);
        { the water fill is uniform until ripples spread; warm the sim up
          so the preview shows a developed interference pattern }
        for i := 1 to 40 do dndossav.WaveStep(PvWave, dndossav.dssWater);
      end;
    svFire:
      begin
        dndossav.WaveInit(PvWave, dndossav.dssFire, 320, 100);
        for i := 1 to 40 do dndossav.WaveStep(PvWave, dndossav.dssFire);
      end;
    svColines: dndossav.WaveInit(PvWave, dndossav.dssColines, 320, 100);
    svBundles:
      begin
        dnbundlessav.BundlesInit(PvBundles, 0, 0, 0);
        { the bundles weave their trail over the first frames; warm up so
          the preview shows a developed pattern, not a single segment }
        for i := 1 to 60 do dnbundlessav.BundlesStep(PvBundles);
        PvBundlesReady := True;
      end;
    svChik:
      begin
        if PvChik = nil then
        begin
          PvChik := TChikSaver.Create(80, 25);
          SetLength(PvChikFill, 25 * 80);
          for i := 0 to High(PvChikFill) do PvChikFill[i] := $0720;
          PvChik.SetScreen(@PvChikFill[0]);
          PvChik.Init(@PvChikClk.Roll);
          PvChik.Step;
        end;
        PvChik.Step;
      end;
    svAscope:
      begin
        AscopeInit(PvScope);
        { warm up so the picker preview already shows the traced figure }
        for i := 1 to 10 do AscopeStep(PvScope);
      end;
  end;
end;

{ a fixed pseudo-random star pattern, stable across repaints }
function PvStar(x, y: Integer): Boolean;
begin
  Result := ((x * 7 + y * 13) mod 11) = 0;
end;

procedure SaverPreviewDraw(Kind, py, px, ph, pw: Integer);
var
  x, y, c, phase, i: Integer;
  pvNow: QWord;
  t: AnsiString;
  h, m, s, ms: Word;
begin
  if (ph <= 0) or (pw <= 0) then Exit;
  if Kind <> PvKind then PvReset(Kind);

  { the saver pairs 30..38 and dndossav's 53..59 must be ready }
  InitSaverPairs;
  dndossav.InitSdosPairs;

  case Kind of
    svOff:
      begin
        for y := 0 to ph - 1 do
          for x := 0 to pw - 1 do
            PutSaver(py + y, px + x, ' ', 7, False);
        PutSaver(py + ph div 2, px, Utf8PadRight(' saver off ', pw), 7, True);
      end;
    svStarSky:
      for y := 0 to ph - 1 do
        for x := 0 to pw - 1 do
          if PvStar(x, y) then
          begin
            i := 1 + ((x * 3 + y) mod 4);
            PutSaver(py + y, px + x, StarChars[i], 7, (x + y) mod 5 = 0);
          end
          else
            PutSaver(py + y, px + x, ' ', 7, False);
    svClock:
      begin
        pvNow := GetTickCount64;
        if pvNow - PvTick >= 200 then
        begin
          PvTick := pvNow;
          Inc(PvClockX, PvClockDX);
          Inc(PvClockY, PvClockDY);
          if (PvClockX < 0) or (PvClockX > pw - 5) then
          begin
            PvClockDX := -PvClockDX; Inc(PvClockX, 2 * PvClockDX);
          end;
          if (PvClockY < 0) or (PvClockY > ph - 1) then
          begin
            PvClockDY := -PvClockDY; Inc(PvClockY, 2 * PvClockDY);
          end;
          Dec(PvClockDdy);
          if PvClockDdy <= 0 then
          begin
            PvClockDX := 1 - Random(3);
            PvClockDY := 1 - Random(3);
            PvClockDdy := 3 + Random(10);
            Inc(PvClockClr);
            if PvClockClr > 6 then PvClockClr := 1;
          end;
        end;
        for y := 0 to ph - 1 do
          for x := 0 to pw - 1 do
            PutSaver(py + y, px + x, ' ', 7, False);
        DecodeTime(Now, h, m, s, ms);
        t := Format('%.2d:%.2d', [h, m]);
        if Odd(s) then t[3] := ' ';
        if PvClockX > pw - 5 then PvClockX := pw - 5;
        if PvClockY > ph - 1 then PvClockY := ph - 1;
        PutSaver(py + PvClockY, px + PvClockX, t, PvClockClr, True);
      end;
    svBlank:
      for y := 0 to ph - 1 do
        for x := 0 to pw - 1 do
          PutSaver(py + y, px + x, ' ', 7, False);
    svWater, svFire, svColines:
      begin
        dndossav.WaveStep(PvWave, Kind - svWater);
        dndossav.PaintDosSaverRect(PvWave, Kind - svWater, py, px, ph, pw);
      end;
    svBundles:
      begin
        dnbundlessav.InitBundlesPairs;
        dnbundlessav.BundlesStep(PvBundles);
        dnbundlessav.PaintBundlesRect(PvBundles, py, px, ph, pw);
      end;
    svChik:
      begin
        if PvChik = nil then
        begin
          PvChik := TChikSaver.Create(80, 25);
          SetLength(PvChikFill, 25 * 80);
          for x := 0 to High(PvChikFill) do PvChikFill[x] := $0720;
          PvChik.SetScreen(@PvChikFill[0]);
          PvChik.Init(@PvChikClk.Roll);
          PvChik.Step;
        end;
        PvChik.Step;
        { the erased window shows as a blank gap in a field of text dots }
        for y := 0 to ph - 1 do
          for x := 0 to pw - 1 do
            if (y < PvChik.Rows) and (x < PvChik.Cols) and
               (PvChik.Cell(x, y) = 0) then
              PutSaver(py + y, px + x, ' ', 7, False)
            else
              PutSaver(py + y, px + x, '.', 7, False);
      end;
    svAscope:
      begin
        InitScopePairs;
        AscopeStep(PvScope);
        AscopePaint(PvScope, py, px, ph, pw);
      end;
  end;
end;

{ run the ASCOPE scope full-screen until a key or mouse event }
procedure RunScope;
var
  S: TAscopeSim;
  ch: LongInt;
  mev: MEVENT;
begin
  InitScopePairs;
  curs_set(0);
  AscopeInit(S);
  timeout(40);
  repeat
    AscopeStep(S);
    erase;
    AscopePaint(S, 0, 0, LINES - 1, COLS);
    refresh;
    ch := ncurses.getch;
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
  if Kind = svChik then
  begin
    InitSaverPairs;
    curs_set(0);
    RunChik;
    timeout(1000);
    erase;
    redrawwin(stdscr);
    Exit;
  end;
  if Kind = svBundles then
  begin
    InitSaverPairs;
    dnbundlessav.RunBundlesSaver;
    { back to the main loop contract: 1s tick, full repaint }
    timeout(1000);
    erase;
    redrawwin(stdscr);
    Exit;
  end;
  if Kind = svAscope then
  begin
    InitSaverPairs;
    RunScope;
    timeout(1000);
    erase;
    redrawwin(stdscr);
    Exit;
  end;
  if Kind in [svWater..svColines] then
  begin
    InitSaverPairs;
    RunDosSaver(Kind - svWater);
    { back to the main loop contract: 1s tick, full repaint }
    timeout(1000);
    erase;
    redrawwin(stdscr);
    Exit;
  end;
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
