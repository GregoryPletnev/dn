{ dnascopesav — native port of the ASCOPE.SS oscilloscope saver from the RIT
  Labs ssavers.zip pack (Dos Navigator II, 1995).

  ASCOPE.SS is a Microsoft C program (1988 MS C runtime + Microsoft 8087
  floating-point emulation library) that draws an oscilloscope Lissajous
  figure into VGA mode 13h (320x200) and ramps the DAC palette. See
  tools/re/ascopesS_analysis.md for the toolchain identification and the
  fidelity note.

  The original's transcendental path is the closed Microsoft 8087 emulator,
  whose polynomial constants are not present as floats in the image, so we
  cannot certify frame-exact output against it from the static binary alone.
  Instead this unit models the visible structure with a deterministic
  integer core:

    - a 256-entry sine table, peak 16000, built with Sin at unit start,
    - two integer oscillators with fixed phase steps (a 3:2 Lissajous ratio)
      and a one-step Y phase drift per frame, so the figure turns,
    - integer pixel mapping (sine peak 16000, scaled by >>14 onto the canvas),
    - a phosphor model: each sample adds glow, each frame decays every cell.

  The model runs on a 320x100 canvas and exposes AscopeInit/AscopeStep for the
  logic layer plus AscopePaint for the terminal rectangle. It no longer
  matches tools/re/ascope_emu.py (that model retraced one static figure with
  a broken sine table); the unit tests pin the current model. }
unit dnascopesav;

{$mode objfpc}{$H+}

interface

const
  { logical canvas of the ported scope }
  AscopeW = 320;
  AscopeH = 100;

  { pairs 53..59: a green scope phosphor ramp, shared with the other DOS
    savers (each re-inits them before it paints); clear of the dnscreen
    interface pairs 40..51 and below the 64-pair limit of TERM=screen }
  cpScopeBase = 52;

type
  TAscopeSim = record
    Buf: array[0..AscopeW*AscopeH-1] of Byte;
    Px, Py: Integer;        { oscillator phases, 0..255 }
    Dpx, Dpy: Integer;      { fixed phase steps per sample }
    Pal: Integer;           { palette ramp phase }
    Frame: Integer;
  end;

{ reset the simulation to its initial state }
procedure AscopeInit(var S: TAscopeSim);

{ set the Lissajous frequency ratio (per-sample phase steps) for tests }
procedure AscopeSetRatio(var S: TAscopeSim; Dpx, Dpy: Integer);

{ advance one frame of the scope onto S.Buf }
procedure AscopeStep(var S: TAscopeSim);

{ sum of all canvas bytes, for tests and diagnostics }
function AscopeChecksum(const S: TAscopeSim): LongInt;

{ FNV-1a over the whole canvas buffer (row-major), for the unit tests }
function AscopeFnv(const S: TAscopeSim): Cardinal;

{ init the scope color pairs 53..59; idempotent }
procedure InitScopePairs;

{ paint one frame into the terminal rectangle (py,px)-(py+ph-1,px+pw-1);
  paints cells only, never erases or refreshes }
procedure AscopePaint(const S: TAscopeSim; py, px, ph, pw: Integer);

implementation

uses
  ncurses, dnscreen;

{ sine table, peak 16000 (the >>14 scale onto the half-extent), built
  once at unit start. The old hand-typed table was not a sine: 0.53 at 45
  degrees and a lone 16000 spike at the peak. }
var
  AscopeSine: array[0..255] of SmallInt;

procedure BuildSine;
var
  i: Integer;
begin
  for i := 0 to 255 do
    AscopeSine[i] := Round(16000 * Sin(2 * Pi * i / 256));
end;

const
  ScopeSamples = 256;   { samples drawn per frame (one full X turn) }
  ScopeGain    = 96;    { per-sample phosphor glow }
  ScopeDecay   = 40;    { per-frame phosphor decay: a ~3 frame afterglow }

procedure AscopeInit(var S: TAscopeSim);
begin
  FillChar(S.Buf[0], SizeOf(S.Buf), 0);
  S.Px := 0; S.Py := 0;
  S.Dpx := 3; S.Dpy := 2;   { 3:2 Lissajous frequency ratio }
  S.Pal := 0;
  S.Frame := 0;
end;

procedure AscopeSetRatio(var S: TAscopeSim; Dpx, Dpy: Integer);
begin
  S.Dpx := Dpx;
  S.Dpy := Dpy;
end;

procedure AscopeStep(var S: TAscopeSim);
var
  i, cx, cy, ax, ay, sx, sy, pxc, pyc, idx, v, n: Integer;
begin
  Inc(S.Frame);
  { phosphor decay: every cell loses ScopeDecay steps }
  for i := 0 to High(S.Buf) do
    if S.Buf[i] <> 0 then
    begin
      if S.Buf[i] <= ScopeDecay then S.Buf[i] := 0
      else Dec(S.Buf[i], ScopeDecay);
    end;
  cx := AscopeW div 2;
  cy := AscopeH div 2;
  ax := cx - 1;
  ay := cy - 1;
  for n := 1 to ScopeSamples do
  begin
    sx := AscopeSine[S.Px and $FF];
    sy := AscopeSine[S.Py and $FF];
    { sine peak 16000 scaled by >>14 onto the half-extent }
    pxc := cx + ((sx * ax) shr 14);
    pyc := cy + ((sy * ay) shr 14);
    if (pxc >= 0) and (pxc < AscopeW) and (pyc >= 0) and (pyc < AscopeH) then
    begin
      idx := pyc * AscopeW + pxc;
      v := S.Buf[idx] + ScopeGain;
      if v > 255 then v := 255;
      S.Buf[idx] := Byte(v);
    end;
    S.Px := (S.Px + S.Dpx) and $FF;
    S.Py := (S.Py + S.Dpy) and $FF;
  end;
  { one frame is exactly one closed turn (256 * 3 and 256 * 2 are multiples
    of 256), so without a drift every frame retraces the same figure: slip
    the Y phase one step per frame and the Lissajous figure turns }
  S.Py := (S.Py + 1) and $FF;
  S.Pal := (S.Pal + 1) and $FF;
end;

function AscopeChecksum(const S: TAscopeSim): LongInt;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(S.Buf) do Inc(Result, S.Buf[i]);
end;

function AscopeFnv(const S: TAscopeSim): Cardinal;
var
  i: Integer;
begin
  Result := $811C9DC5;
  for i := 0 to High(S.Buf) do
  begin
    Result := Result xor Cardinal(S.Buf[i]);
    Result := Result * $01000193;
  end;
end;

{ ---------------------------------------------------------------- terminal }

const
  ScopeRamp: array[0..7] of AnsiString =
    (' ', '.', ':', '-', '=', '+', '*', '#');

procedure InitScopePairs;
begin
  { green phosphor ramp on black; brightness comes from A_BOLD at paint time }
  init_pair(cpScopeBase + 1, COLOR_GREEN, COLOR_BLACK);
  init_pair(cpScopeBase + 2, COLOR_GREEN, COLOR_BLACK);
  init_pair(cpScopeBase + 3, COLOR_GREEN, COLOR_BLACK);
  init_pair(cpScopeBase + 4, COLOR_GREEN, COLOR_BLACK);
  init_pair(cpScopeBase + 5, COLOR_GREEN, COLOR_BLACK);
  init_pair(cpScopeBase + 6, COLOR_GREEN, COLOR_BLACK);
  init_pair(cpScopeBase + 7, COLOR_GREEN, COLOR_BLACK);
end;

function CellColor(v: Byte): Integer;
begin
  if v < 2 then Result := 1
  else if v < 8 then Result := 2
  else if v < 24 then Result := 3
  else if v < 64 then Result := 4
  else if v < 128 then Result := 5
  else Result := 6;
end;

procedure AscopePaint(const S: TAscopeSim; py, px, ph, pw: Integer);
var
  x, y, ri, c, x0, x1, y0, y1, sx, sy: Integer;
  v: Byte;
begin
  if (ph <= 0) or (pw <= 0) then Exit;
  for y := 0 to ph - 1 do
  begin
    y0 := (y * AscopeH) div ph;
    y1 := ((y + 1) * AscopeH) div ph;
    if y1 <= y0 then y1 := y0 + 1;
    for x := 0 to pw - 1 do
    begin
      x0 := (x * AscopeW) div pw;
      x1 := ((x + 1) * AscopeW) div pw;
      if x1 <= x0 then x1 := x0 + 1;
      { the brightest sample under the cell: the trace is one pixel wide
        and would fall between point samples }
      v := 0;
      for sy := y0 to y1 - 1 do
        for sx := x0 to x1 - 1 do
          if S.Buf[sy * AscopeW + sx] > v then v := S.Buf[sy * AscopeW + sx];
      if v <> 0 then
      begin
        ri := 1 + (Integer(v) * 7) div 256;
        if ri > 7 then ri := 7;
        c := CellColor(v);
        if v >= 96 then
          attrset(COLOR_PAIR(cpScopeBase + c) or A_BOLD)
        else
          attrset(COLOR_PAIR(cpScopeBase + c));
        mvaddstr(py + y, px + x, PChar(string(ScopeRamp[ri])));
      end
      else
      begin
        attrset(COLOR_PAIR(cpScopeBase + 1));
        mvaddstr(py + y, px + x, ' ');
      end;
    end;
  end;
end;

initialization
  BuildSine;

end.
