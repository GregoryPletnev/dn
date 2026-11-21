{ dndossav — native ports of the 16-bit DOS .SS screen savers from the RIT
  Labs ssavers.zip pack (Dos Navigator II, 1995).

  Sources of truth: the TASM sources shipped in SOURCE/ (AZ_WATER.ASM,
  AZ_FIRE.ASM) plus a bit-exact 32-bit register replay of the @@waveLine
  loops, validated in tools/re/water_seed.py and ground-truth vectors in
  tests/unittests.pas (TestDosSavers).

  AZ_WATER (AZ_WATER.ASM lines 33-92):
  - Seeding: two 320x100 byte buffers are filled with $08; 2000 drops land
    at (cx mod 31360)+320 with value ch and 3, from the DEAD/FACE LCG with
    the exact 8-bit CF chain (dx ends $9054, cx ends $561A).
  - waveLine walks destination offsets 320..31679 (rows 1..98, every x).
    Three rolling 32-bit windows over Cur (rows y-1, y, y+1); each shrd
    pushes the next byte to the TOP, so after the shift bl=A[k-3],
    bh=A[k-2]. The stored byte is
      ah = (A[k-4]+C[k-4]+D[k-4] + A[k-3]+D[k-3] + A[k-2]+C[k-2]+D[k-2])
      out = ((ah shr 3) + 1{D[k] bit1 clear}) and $FF
    The prologue windows read the four bytes before each row start, so the
    carry-in bytes wrap across rows; only bl is forced 0 (A[k-4] at k=0).
    Reads past the 32000-byte image end (last D-stream loads) see 0.
  AZ_FIRE (AZ_FIRE.ASM lines 35-86):
  - waveLine writes offsets 1..31360: row0 x=1..319, rows 1..98 every x,
    row 99 x=0. With Y[k]=Cur[row y, x-1], Z[k]=Cur[row y+1, x-1] (the asm
    window offsets), T = Z[k]+Y[k-1]+Y[k-2]+Z[k-2]; the ror ax,2 keeps
    sum bits 16..17 in ah bits 6..7, outside the stored byte, so
      out = (T shr 2) and $FF, minus 1 iff nonzero and Y[k-1] odd.
  - MakeSeed runs after waveLine, at offset 31361 (row 99 x=1), writing
    row 99 x=1..319 plus one spill byte past the image. bx and al persist
    across frames; the frame-top 'mov bl,0' zeroes only bl. dx comes from
    randSeed and is stored back each frame:
      bx += $05EDA; bx ^= dx; dx += $E34A; dl := bh; t := dh+bl;
      dh := t; cf := carry; dl += al + cf; bx += dx; rol bx,3;
      al := bl and $7F.
  - The screen shows only rows 2..97 (the asm refresh window).

  The terminal averages the 320x100 bytes under each cell and maps them
  onto a shade ramp: fire in red-yellow-white, water in blue-cyan.
  Exit follows the original CheckChanges: any key or mouse move ends it. }
unit dndossav;

{$mode objfpc}{$H+}

interface

const
  dssWater  = 0;   { AZ_WATER.SS: 320x100 wave-interference ripples }
  dssFire   = 1;   { AZ_FIRE.SS: 320x100 burning-rand plasma }
  dssColines= 2;   { COLINES.SS: EGA/VGA palette-rotating color lines }

  { color pairs of the DOS savers: 52..59, shared by dndossav, dnbundlessav
    and dnascopesav (each re-inits them before it paints). They must not
    overlap the dnscreen interface pairs 40..51 (cpDialog, cpDlgFrame, ...),
    because ApplyPalette is not called after a preview frame, and stay
    below 64, the pair limit of TERM=screen and linux. }
  cpSdosBase = 52;

type
  TWaveSim = record
    W, H: Integer;
    Cur, Next: array of Byte;     { two W*H buffers, ping-pong }
    Dx, Dy: Word;                 { DEAD/FACE LCG state (water seeding) }
    Seed: Word;                   { randSeed }
    SdBx: Word;                   { MakeSeed bx, persists across frames }
    SdAl: Byte;                   { al carry into MakeSeed }
    Init: Boolean;
    PalPhase: Integer;
  end;

{ the exact MakeSeed bottom-row PRNG, exposed for tests }
procedure FireSeed(var S: TWaveSim);
procedure WaveInit(var S: TWaveSim; Kind, W, H: Integer);
procedure WaveStep(var S: TWaveSim; Kind: Integer);
procedure SdReset(var S: TWaveSim);

{ init the private saver color pairs 53..59; idempotent, so a caller can
  call it before a preview without disturbing the running saver }
procedure InitSdosPairs;

{ render one frame of the saver buffer into the terminal rectangle
  (py,px)-(py+ph-1,px+pw-1); it only paints cells, never erases or
  refreshes, so a dialog can draw a live preview inside its own box }
procedure PaintDosSaverRect(var S: TWaveSim; Kind, py, px, ph, pw: Integer);

{ the terminal entry: paints the running saver and returns on the first
  key or mouse event; Kind is a dss* constant }
procedure RunDosSaver(Kind: Integer);

implementation

uses
  SysUtils, ncurses, dnscreen;

{ byte at flat offset off of Cur; bytes outside the image read 0, matching
  the uninitialized segment bytes the DOS original happened to hit }
function OffGet(const S: TWaveSim; off: Integer): Byte;
begin
  if (off < 0) or (off >= Length(S.Cur)) then Exit(0);
  Result := S.Cur[off];
end;

{ --- DEAD/FACE seeding LCG, exact 8-bit carries (AZ_WATER lines 33-55) }

procedure WaterDrop(var Dx, Cx: Word; out Idx: Word; out Val: Byte);
var
  dl, dh, cl, ch, s, t: Integer;
  cf: Integer;
begin
  Dx := Word((Dx shl 3) or (Dx shr 13));            { rol dx,3 }
  dl := Dx and $FF; dh := Dx shr 8;
  s := dl + dh;                                      { add dl,dh }
  Dx := Word((Dx and $FF00) or (s and $FF));
  cf := s shr 8;
  dl := Dx and $FF;                                  { dl = dl+dh (low) }
  ch := Cx shr 8;
  s := ch + dl + cf;                                 { adc ch,dl (updated dl) }
  ch := s and $FF; cf := s shr 8;
  cl := (Cx and $FF) xor dh;                         { xor cl,dh: CF=0 }
  Cx := Word((ch shl 8) or cl);                      { xor writes cl into cx }
  t := Cx - Dx;                                      { sub cx,dx }
  cf := Ord(t < 0);
  t := t and $FFFF;
  s := (t shr 8) + dl + cf;                          { adc ch,dl }
  ch := s and $FF;
  Cx := Word((t and $00FF) or (ch shl 8));
  Idx := Word(Cx mod (320 * 98));
  Val := Byte(ch and 3);
end;

procedure WaveInit(var S: TWaveSim; Kind, W, H: Integer);
var
  i, n, k: Integer;
  dx_, cx_, idx_: Word;
  v_: Byte;
begin
  S.W := W; S.H := H;
  n := W * H;
  SetLength(S.Cur, n);
  SetLength(S.Next, n);
  S.PalPhase := 0;
  SdReset(S);
  case Kind of
    dssWater:
      begin
        for i := 0 to n - 1 do S.Cur[i] := 8;
        dx_ := $DEAD; cx_ := $FACE;
        for k := 1 to 2000 do
        begin
          WaterDrop(dx_, cx_, idx_, v_);
          S.Cur[idx_ + W] := v_;
        end;
        S.Dx := dx_; S.Dy := cx_;
      end;
  else
    FillChar(S.Cur[0], n, 0);
  end;
  FillChar(S.Next[0], n, 0);
  S.Init := True;
end;

{ MakeSeed fills the seed line at flat offsets 31361..31680 (row 98
  x=1..319, row 99 x=0) into Cur, exactly like the asm: 'add dx,$E34A'
  first, then 'mov dl,bh' (dh = the new dx high byte), 'add dh,bl',
  'adc dl,al', 'add bx,dx', 'rol bx,3', al := bl and $7F.
  bx and al persist across frames; the frame-top 'mov bl,0' clears bl. }
procedure FireSeed(var S: TWaveSim);
var
  bx, dx: Word;
  al, bh, bl, dl, dh: Byte;
  sm, cf: Integer;
  x, di: Integer;
begin
  bx := Word(S.SdBx and $FF00);       { frame-top 'mov bl,0' }
  dx := S.Seed;
  al := S.SdAl;
  di := S.W * (S.H - 2) + 1;
  for x := 0 to S.W - 1 do
  begin
    bx := Word(bx + $05EDA);
    bx := bx xor dx;
    dx := Word(dx + $E34A);
    dh := dx shr 8;
    bh := bx shr 8;
    dl := bh;                         { mov dl,bh }
    bl := bx and $FF;
    sm := dh + bl;                    { add dh,bl }
    dh := Byte(sm and $FF); cf := sm shr 8;
    dl := Byte(dl + al + cf);         { adc dl,al }
    dx := Word((dh shl 8) or dl);
    bx := Word(bx + dx);
    bx := Word((bx shl 3) or (bx shr 13));   { rol bx,3 }
    al := Byte((bx and $FF) and $7F);
    S.Cur[di + x] := al;
  end;
  S.Seed := dx;
  S.SdBx := bx;
  S.SdAl := al;
end;

{ waveLine: destination offsets W..W*99 (rows 1..98, every x). Three
  rolling windows over Cur; the prologue windows read the four bytes
  before each row start, so carry-in bytes wrap across rows. }
procedure WaveStepWater(var S: TWaveSim);
var
  y, x, w: Integer;
  k, a4, c4, d4, a3, d3, a2, c2, d2: Integer;
  dk: Byte;
  ah: Integer;
begin
  w := S.W;
  System.Move(S.Cur[0], S.Next[0], Length(S.Cur));   { dests keep old bytes }
  for y := 1 to S.H - 2 do
    for x := 0 to w - 1 do
    begin
      k := (y - 1) * w + x;
      a4 := OffGet(S, k - 1);   if k = 0 then a4 := 0;   { mov bl,0 }
      c4 := OffGet(S, w + k - 1);
      d4 := OffGet(S, 2 * w + k - 1);
      a3 := OffGet(S, k);
      d3 := OffGet(S, 2 * w + k);
      a2 := OffGet(S, k + 1);
      c2 := OffGet(S, w + k + 1);
      d2 := OffGet(S, 2 * w + k + 1);
      dk := OffGet(S, 2 * w + k + 3);
      ah := (a4 + c4 + d4 + a3 + d3 + a2 + c2 + d2) and $FF;
      if (dk and 2) = 0 then Inc(ah, 8);
      S.Next[y * w + x] := Byte(ah shr 3);
    end;
  System.Move(S.Next[0], S.Cur[0], Length(S.Cur));
end;

{ fire waveLine: destination offsets 1..31360 (row0 x>=1, rows 1..98 all
  x, row99 x=0). T = Z[k]+Y[k-1]+Y[k-2]+Z[k-2] over the row windows;
  bits 16..17 of T never reach the stored byte (they land in ah bits 6..7,
  cleared by the test/sub chain). }
{ MakeSeed seeds the line at flat offsets 31361..31680 (row 98 x=1..319,
  row 99 x=0) into the buffer, then waveLine overwrites the whole image
  in place, exactly like the asm single-frame pass over Wave1. }
{ waveLine: the literal rolling windows over the seeded image. ecx covers
  the row at W+k (window bytes cur[W-1+i], shifted in from cur[323+k]) and
  edx the row at 2W+k; after each shift ecx[0]=cur[W+k], ecx[1]=cur[W+1+k],
  edx[1]=cur[2W+1+k], and al = cur[2W+3+k] enters the sum as the new byte.
  Dests run 1..31360; the seed line (31361..31680) survives as the wave
  tail. Reads past the image return 0 (EXT = 0, like the DOS segment). }
procedure WaveStepFire(var S: TWaveSim);
var
  w, k, si, di: Integer;
  cl, ch, dh, al: Byte;
  ecx0, ecx1, ecx2, ecx3: Byte;
  edx0, edx1, edx2, edx3: Byte;
  t: Integer;
  ax: Integer;
  p: Byte;
begin
  w := S.W;
  FireSeed(S);
  System.Move(S.Cur[0], S.Next[0], Length(S.Cur));
  ecx0 := OffGet(S, w - 1); ecx1 := OffGet(S, w);
  ecx2 := OffGet(S, w + 1); ecx3 := OffGet(S, w + 2);
  edx0 := OffGet(S, 2 * w - 1); edx1 := OffGet(S, 2 * w);
  edx2 := OffGet(S, 2 * w + 1); edx3 := OffGet(S, 2 * w + 2);
  si := w + 3;
  for k := 0 to w * (S.H - 2) - 1 do
  begin
    al := OffGet(S, si);
    ecx0 := ecx1; ecx1 := ecx2; ecx2 := ecx3; ecx3 := al;
    al := OffGet(S, si + w);
    edx0 := edx1; edx1 := edx2; edx2 := edx3; edx3 := al;
    Inc(si);
    cl := ecx0; ch := ecx1; dh := edx1;
    { the third shrd-loaded operand al = the byte just shifted into edx }
    t := (al + cl + ch + dh) and $FFFF;
    ax := ((t shr 2) or (t shl 14)) and $FFFF;
    p := Byte(ax and $FF);
    if (p <> 0) and ((cl and 1) <> 0) then Dec(p);
    di := 1 + k;
    S.Next[di] := p;
  end;
  System.Move(S.Next[0], S.Cur[0], Length(S.Cur));
  S.SdAl := S.Cur[w * (S.H - 2)];      { AL = the last waveLine byte }
end;

{ COLINES: three RGB anchors drift 0..255, bounce at the bounds, fade
  toward the current value; 408 palette slots chase one step per frame
  against the retrace. }

procedure WaveStepColines(var S: TWaveSim);
begin
  S.PalPhase := (S.PalPhase + 1) mod 408;
end;

procedure SdReset(var S: TWaveSim);
begin
  S.Seed := 0;      { randSeed is uninitialized RAM in the DOS original; }
  S.SdBx := 0;      { zero is the documented, reproducible choice. }
  S.SdAl := 0;
end;

procedure WaveStep(var S: TWaveSim; Kind: Integer);
begin
  case Kind of
    dssWater:   WaveStepWater(S);
    dssFire:    WaveStepFire(S);
    dssColines: WaveStepColines(S);
  end;
end;

{ ---------------------------------------------------------------- terminal }

const
  { shade ramp, 0 = empty .. 8 = hottest / brightest }
  ShadeRamp: array[0..8] of AnsiString =
    (' ', '░', '░', '▒', '▒', '▓', '▓', '█', '█');
  { ncurses color per ramp level; bold marks the bright half }
  FireColor: array[0..8] of SmallInt =
    (COLOR_BLACK, COLOR_RED, COLOR_RED, COLOR_RED, COLOR_YELLOW,
     COLOR_YELLOW, COLOR_YELLOW, COLOR_WHITE, COLOR_WHITE);
  FireBold: array[0..8] of Boolean =
    (False, False, False, True, False, True, True, False, True);
  { a dim blue sea, like the original black-to-(0,20,32) ramp }
  WaterColor: array[0..8] of SmallInt =
    (COLOR_BLUE, COLOR_BLUE, COLOR_BLUE, COLOR_BLUE, COLOR_BLUE,
     COLOR_CYAN, COLOR_CYAN, COLOR_CYAN, COLOR_CYAN);
  WaterBold: array[0..8] of Boolean =
    (False, False, False, True, True, False, False, True, True);

procedure InitSdosPairs;
var
  c: Integer;
begin
  for c := 1 to 7 do
    init_pair(cpSdosBase + c, c, COLOR_BLACK);
end;

procedure SetLevelAttr(Kind, lv: Integer);
var
  c: Integer;
  b: Boolean;
begin
  if Kind = dssWater then
  begin
    c := WaterColor[lv]; b := WaterBold[lv];
  end
  else
  begin
    c := FireColor[lv]; b := FireBold[lv];
  end;
  if c = COLOR_BLACK then c := COLOR_WHITE;   { pair 52 is not set: blank }
  if b then attrset(COLOR_PAIR(cpSdosBase + c) or A_BOLD)
  else attrset(COLOR_PAIR(cpSdosBase + c));
end;

{ map the saver bytes onto the 0..8 shade ramp. Fire averages the bytes
  under each terminal cell (about 0..48 in practice), so the flames do not
  alias into noise; water samples one pixel per cell, see below. }
procedure PaintDosSaverRect(var S: TWaveSim; Kind, py, px, ph, pw: Integer);
var
  x, y, c, phase, lv, x0, x1, y0, y1, sx, sy, n, lo, hi: Integer;
  sum: LongInt;
  avg: array of Integer;     { cell average x16 }
begin
  if (ph <= 0) or (pw <= 0) then Exit;
  if Kind = dssColines then
  begin
    phase := S.PalPhase;
    for y := 0 to ph - 1 do
      for x := 0 to pw - 1 do
      begin
        c := ((x + y * 3 + phase) shr 2) mod 8;
        if c = 0 then c := 7;
        attrset(COLOR_PAIR(cpSdosBase + c));
        mvaddstr(py + y, px + x, '▓');
      end;
    Exit;
  end;
  if Length(S.Cur) < S.W * S.H then Exit;
  SetLength(avg, ph * pw);
  { water: the range of the sampled pixels; the field starts in the
    8..13 band and brightens over minutes up to the original's 0..31
    blue ramp, so the ramp is stretched over what the frame holds }
  lo := 255; hi := 0;
  if Kind = dssWater then
    for y := 0 to ph - 1 do
      for x := 0 to pw - 1 do
      begin
        c := S.Cur[((y * S.H) div ph) * S.W + (x * S.W) div pw];
        if c < lo then lo := c;
        if c > hi then hi := c;
      end;
  for y := 0 to ph - 1 do
  begin
    y0 := (y * S.H) div ph;
    y1 := ((y + 1) * S.H) div ph;
    if y1 <= y0 then y1 := y0 + 1;
    if y1 > S.H then y1 := S.H;
    for x := 0 to pw - 1 do
    begin
      x0 := (x * S.W) div pw;
      x1 := ((x + 1) * S.W) div pw;
      if x1 <= x0 then x1 := x0 + 1;
      if x1 > S.W then x1 := S.W;
      sum := 0; n := 0;
      for sy := y0 to y1 - 1 do
        for sx := x0 to x1 - 1 do
        begin
          Inc(sum, S.Cur[sy * S.W + sx]);
          Inc(n);
        end;
      if n = 0 then n := 1;
      c := (sum * 16) div n;
      avg[y * pw + x] := c;
    end;
  end;
  for y := 0 to ph - 1 do
    for x := 0 to pw - 1 do
    begin
      c := avg[y * pw + x];
      if Kind = dssWater then
      begin
        { water: one source pixel per cell. The field lives as a
          per-pixel shimmer (the original shows it through a black to
          (0,20,32) blue ramp); a block average would freeze it }
        sx := (x * S.W) div pw;
        sy := (y * S.H) div ph;
        if hi > lo then
          lv := (Integer(S.Cur[sy * S.W + sx]) - lo) * 8 div (hi - lo)
        else
          lv := 0;
      end
      else
        lv := c * 8 div (48 * 16);           { fire: 0..48 -> 0..8 }
      if lv < 0 then lv := 0;
      if lv > 8 then lv := 8;
      SetLevelAttr(Kind, lv);
      mvaddstr(py + y, px + x, PChar(string(ShadeRamp[lv])));
    end;
end;

procedure PaintWave(var S: TWaveSim; Kind: Integer);
begin
  erase;
  PaintDosSaverRect(S, Kind, 0, 0, LINES - 1, COLS);
  attrset(COLOR_PAIR(cpSdosBase + 7));
  mvaddstr(LINES - 1, 0, PChar('Dos Navigator saver port — any key returns'));
  refresh;
end;

procedure PaintColines(var S: TWaveSim);
begin
  erase;
  PaintDosSaverRect(S, dssColines, 0, 0, LINES - 1, COLS);
  attrset(COLOR_PAIR(cpSdosBase + 7));
  mvaddstr(LINES - 1, 0, PChar('COLINES palette chase — any key returns'));
  refresh;
end;

procedure RunDosSaver(Kind: Integer);
var
  S: TWaveSim;
  ch: LongInt;
  i: Integer;
  mev: MEVENT;
begin
  InitSdosPairs;
  curs_set(0);
  WaveInit(S, Kind, 320, 100);
  { the wave savers start from a uniform fill; run a few frames so the
    first painted screen already shows a developed pattern }
  if Kind <> dssColines then
    for i := 1 to 40 do WaveStep(S, Kind);
  timeout(40);
  repeat
    WaveStep(S, Kind);
    if Kind = dssColines then PaintColines(S) else PaintWave(S, Kind);
    ch := ncurses.getch;
    if ch = KEY_MOUSE then
    begin
      getmouse(@mev);
      Break;
    end;
    if ch = KEY_RESIZE then ch := ERR;
  until ch <> ERR;
  timeout(1000);
  erase;
  redrawwin(stdscr);
end;

end.
