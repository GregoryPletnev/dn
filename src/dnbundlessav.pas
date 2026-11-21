{ dnbundlessav — port of BUNDLES.SS (RIT ssavers.zip, 1995).

  The original is a 16-bit DOS .COM saver on VGA mode 12h (640x480x4bpp).
  It keeps NumBundles moving line segments (default 2), each a ring of
  NumLines records [x0,y0,x1,y1] (default 5), and walks them through a
  wall-bounce, weaving colored bundles. Address-level evidence for every
  constant below is in tools/re/bundles_analysis.md; the bit-exact
  reference is the Python emulator tools/re/bundles_oracle.py.

  What the binary actually does (re-verified by disassembly, correcting the
  first-pass notes):
    * The plotter (0x3598) writes VGA GC register 8 (bit set/reset), NOT the
      4-bit pixel. Each segment plots ONE color plane: color c (1..15) maps
      to plane (c-1) AND 3. Draw mode (GC index 8, byte = color) ORs bit
      (x AND 7) into byte (x shr 3) + (y shr 1)*80. So the picture is four
      640x300 monochrome bit-planes, not a nibble buffer.
    * The frame loop (0x3765) per bundle advances the ring head, then runs
      the line routine twice: once in erase mode (0x37C6: GC index 8 = NOT
      mask, write mode 3 XOR -> clears exactly that segment's pixels) and
      once in draw mode (0x37E2: OR it back). The steady picture is the OR
      of the NumLines newest segments of every bundle.
    * The line routine (0x3456) is a normalized forward Bresenham; it fills
      verticals (0x34EA). Endpoints swap when dx<0 (0x347F-0x349D).
    * The advance (0x3868) walks the four coordinates A.X (mask F), A.Y
      (mask 7), B.X (mask 7), B.Y (mask F) and bounces at walls 0x27F (x)
      and 0x1DF (y). A bounce re-rolls the velocity as ((RNG AND mask) SHL
      1), minimum 5, negated at the far wall, and fires the chase gate.
    * The chase (0x3426) steps the shared DAC color 1..15 every third bounce.
    * RNG (0x38E0) walks a 997-word table at 0x2FC3, index 0x1DC, seeded at
      tick init from (BIOS jiffies AND 3FE) (0x372E).
    * The y coordinate lives in half-row units 0..479; the plotter only acts
      on even y (the bounds byte address (y shr 1)*80), so odd-y pixels are
      invisible. The composite grid is plane space: cell (px,py), px 0..639,
      py 0..299.

  The terminal paints the live trail records straight into cell space,
  each in its own palette color (the planes keep only (color-1) AND 3, and
  one-pixel lines would fall between cell samples); y spans the used plane
  rows 0..239. BundlesDisplayValue keeps the 320x100 decimation for tests. }
unit dnbundlessav;

{$mode objfpc}{$H+}

interface

const
  BnGridW = 640;                   // plane columns (grid = plane space)
  BnGridH = 300;                   // plane rows (0x9600 = 80 * 300)
  BnPlaneRowBytes = 80;            // 640 px / 8
  BnPlaneBytes = 80 * 300;         // 9600, the original bounds check
  BnMaxBundles = 64;               // static ring capacity
  BnMaxLines = 64;                 // static trail ring capacity

  { The 320x100 display rect is a decimation of the 640x300 grid: display
    cell (dx,dy) shows grid[dy*3, dx*2]. The paint maps it into any rect. }
  BnDispW = 320;
  BnDispH = 100;

  { color pairs 52..59, shared with the other DOS savers: every preview
    frame and every run re-inits them. They stay clear of the dnscreen
    interface pairs 40..51 (ApplyPalette is not re-run after a preview
    frame) and below 64, the pair limit of TERM=screen and linux. }
  cpBundlesBase = 52;

type
  TBnPlane = array[0..BnPlaneBytes - 1] of Byte;
  TBnPlanes = array[0..3] of TBnPlane;

  TBnPoint = record
    X: Integer;                    // plane units, 0..639
    Y: Integer;                    // half-row units, 0..479 (wall 0x1DF)
  end;

  TBnSeg = record                  // trail record, orig 8 bytes at 0x1E2
    A, B: TBnPoint;
    C: Byte;                       // color the record was drawn with
  end;

  TBnSegRing = array[0..BnMaxLines - 1] of TBnSeg;

  { the full simulation state, one record so the caller owns it; mirrors
    the dndossav.TWaveSim pattern. Pure logic: no hardware, no terminal. }
  TBundlesSim = record
    Planes: TBnPlanes;             // four monochrome bit-planes
    Trail: array[0..BnMaxBundles - 1] of TBnSegRing;
    Head: array[0..BnMaxBundles - 1] of Integer;       // newest record
    Vel: array[0..BnMaxBundles - 1, 0..3] of SmallInt; // orig [0x131C]
    ColorArr: array[0..BnMaxBundles - 1] of Byte;      // orig [0x1646]
    ChaseArr: array[0..BnMaxBundles - 1] of Byte;      // orig [0x1710]
    RngIdx: Integer;               // orig [0x1DC]
    RngVal: Word;                  // orig [0x1E0]
    NumLines: Integer;             // orig [0x17DA]
    NumBundles: Integer;           // orig [0x17DE]
    Init: Boolean;
  end;

{ Seed the simulation and draw the first frame (the original draws a frame
  inside tick init at 0x3745). Lines = trail records per bundle, Bundles =
  ray count, zero falls back to the shipped defaults 5 and 2. RngSeed is the
  tick-init seed (original: BIOS jiffies AND 3FE). Deterministic for a given
  RngSeed. }
procedure BundlesInit(var S: TBundlesSim; Lines, Bundles: Integer;
  RngSeed: Word);

{ One drawn frame: per bundle erase-old / advance / draw-new, exactly the
  0x3765 loop. After it, S holds the picture the screen shows. }
procedure BundlesStep(var S: TBundlesSim);

{ The shared chase color pushed to DAC index 0 after the last step: 1..15,
  stepping on every third bounce event (orig [0x33EC]). }
function BundlesColor(var S: TBundlesSim): Byte;

{ palette-8 value (0..15) of the composite grid cell (px,py): the lowest
  color with a set bit across the planes, matching the draw order. }
function BundlesPixel(const S: TBundlesSim; px, py: Integer): Integer;

{ the 320x100 display value of cell (dx,dy) = the grid's top-left pixel }
function BundlesDisplayValue(const S: TBundlesSim; dx, dy: Integer): Integer;

{ --- terminal layer (pairs 52..59, shared with the DOS savers) ---------- }

{ init the color pairs 52..59; idempotent, run before every frame }
procedure InitBundlesPairs;

{ paint one frame of S into the terminal rectangle
  (py,px)-(py+ph-1,px+pw-1); only paints cells, never erases or refreshes,
  so a dialog can draw a live preview inside its own box. Mirrors
  dndossav.PaintDosSaverRect. }
procedure PaintBundlesRect(const S: TBundlesSim; py, px, ph, pw: Integer);

{ the terminal entry: paints the running saver and returns on the first key
  or mouse event. Mirrors dndossav.RunDosSaver. }
procedure RunBundlesSaver;

implementation

uses
  SysUtils, ncurses, dnscreen;

const
  BnWallX = $27F;                  // orig CMP at 0x381A
  BnWallY = $1DF;                  // orig CMP at 0x384C (479 half-rows)
  BnRngCount = 997;                // orig wrap CMP 3E6h at 0x38E5
  DfltLines = 5;                   // orig forced defaults (see analysis)
  DfltBundles = 2;

{$i bundles_rng.inc}

var
  ChaseColor: Byte;                // orig [0x33EC]
  ChaseStep: Byte;                 // orig [0x33EE]

{ orig 0x38E0 }
function RngNext(var S: TBundlesSim): Word;
begin
  Inc(S.RngIdx);
  if S.RngIdx >= BnRngCount then S.RngIdx := 0;
  S.RngVal := BundlesRng[S.RngIdx];
  Result := S.RngVal;
end;

{ orig 0x3426 }
procedure ChaseTick;
begin
  Inc(ChaseStep);
  if ChaseStep >= 3 then
  begin
    ChaseStep := 0;
    ChaseColor := (ChaseColor + 1) and $0F;
    if ChaseColor = 0 then Inc(ChaseColor);
  end;
end;

{ orig 0x3804 (X) / 0x3836 (Y). At either wall: fire the chase gate, re-roll
  the velocity from the last RNG word as ((RNG AND mask) SHL 1), minimum 5,
  negated at the far wall, and clamp the position. The bounce call reuses
  [0x1E0] without a fresh draw, exactly like the original. }
function BounceAxis(var S: TBundlesSim; var Pos: Integer; Vel: SmallInt;
  Mask: Word; MaxPos: Integer): SmallInt;
var
  V: SmallInt;
begin
  if Pos < 0 then
  begin
    ChaseTick;
    V := SmallInt((S.RngVal and Mask) shl 1);
    if V = 0 then V := 5;
    Pos := 0;
    Result := V;
  end
  else if Pos > MaxPos then
  begin
    ChaseTick;
    V := SmallInt((S.RngVal and Mask) shl 1);
    if V = 0 then V := 5;
    Pos := MaxPos;
    Result := -V;
  end
  else
    Result := Vel;
end;

{ orig 0x3598/0x35B1 plot: plane (color-1) AND 3, byte (x shr 3)+(y shr 1)*80
  must be < 0x9600; only even y hits a row. SetMode selects GC set (OR) or
  the XOR-with-NOT erase. }
procedure PlotPixel(var S: TBundlesSim; X, Y, Color: Integer; SetMode: Boolean);
var
  off, bit: Integer;
  P: ^TBnPlane;
begin
  if (X < 0) or (X >= BnGridW) then Exit;
  if Odd(Y) then Exit;
  if (Y < 0) or (Y > $1DF) then Exit;
  off := (X shr 3) + (Y shr 1) * BnPlaneRowBytes;
  if off >= BnPlaneBytes then Exit;
  bit := 1 shl (X and 7);
  P := @S.Planes[(Color - 1) and 3];
  if SetMode then
    P^[off] := P^[off] or bit
  else
    P^[off] := P^[off] xor bit;    // XOR with the NOT mask clears the bit
end;

{ orig 0x3456: normalized Bresenham, swap when dx<0, single forward walk;
  verticals take the fill branch. SetMode picks OR-draw or XOR-erase. }
procedure DrawSeg(var S: TBundlesSim; X0, Y0, X1, Y1, Color: Integer;
  SetMode: Boolean);
var
  dx, dy, err, t, ystep: Integer;
begin
  if X0 > X1 then
  begin
    t := X0; X0 := X1; X1 := t;
    t := Y0; Y0 := Y1; Y1 := t;
  end;
  dx := X1 - X0;
  dy := Y1 - Y0;
  if dx = 0 then
  begin
    if dy < 0 then
    begin
      dy := -dy;
      t := Y0; Y0 := Y1; Y1 := t;
    end;
    while Y0 <= Y1 do
    begin
      PlotPixel(S, X0, Y0, Color, SetMode);
      Inc(Y0);
    end;
    Exit;
  end;
  ystep := 1;
  if dy < 0 then
  begin
    dy := -dy;
    ystep := -1;
  end;
  if dy <= dx then
  begin
    err := 2 * dy - dx;
    while True do
    begin
      PlotPixel(S, X0, Y0, Color, SetMode);
      if X0 = X1 then Break;
      if err < 0 then
        Inc(err, 2 * dy)
      else
      begin
        Inc(err, 2 * (dy - dx));
        Inc(Y0, ystep);
      end;
      Inc(X0);
    end;
  end
  else
  begin
    err := 2 * dx - dy;
    while True do
    begin
      PlotPixel(S, X0, Y0, Color, SetMode);
      if Y0 = Y1 then Break;
      if err < 0 then
        Inc(err, 2 * dx)
      else
      begin
        Inc(err, 2 * (dx - dy));
        Inc(X0);
      end;
      Inc(Y0, ystep);
    end;
  end;
end;

function BundlesPixel(const S: TBundlesSim; px, py: Integer): Integer;
var
  by, bit, c: Integer;
begin
  if (px < 0) or (px >= BnGridW) or (py < 0) or (py >= BnGridH) then
    Exit(0);
  by := py * BnPlaneRowBytes + (px shr 3);
  bit := 1 shl (px and 7);
  for c := 1 to 15 do
    if (S.Planes[(c - 1) and 3][by] and bit) <> 0 then
      Exit(c);
  Result := 0;
end;

function BundlesDisplayValue(const S: TBundlesSim; dx, dy: Integer): Integer;
begin
  if (dx < 0) or (dx >= BnDispW) or (dy < 0) or (dy >= BnDispH) then
    Exit(0);
  Result := BundlesPixel(S, dx * 2, dy * 3);
end;

procedure BundlesInit(var S: TBundlesSim; Lines, Bundles: Integer;
  RngSeed: Word);
var
  b, j, y, k: Integer;
  r: Word;
  Masks: array[0..3] of Word;
begin
  if (Lines <= 0) or (Lines > BnMaxLines) then Lines := DfltLines;
  if (Bundles <= 0) or (Bundles > BnMaxBundles) then Bundles := DfltBundles;
  S.NumLines := Lines;
  S.NumBundles := Bundles;

  for k := 0 to 3 do FillChar(S.Planes[k], SizeOf(TBnPlane), 0);

  S.RngIdx := RngSeed and $3FE;    // orig 0x372E
  S.RngVal := BundlesRng[S.RngIdx];
  ChaseColor := 1;
  ChaseStep := 0;

  { initial segments: 4 RNG draws per bundle (orig 0x3651); y is drawn in
    half-plane units and folded below 0x1E0 }
  for b := 0 to S.NumBundles - 1 do
  begin
    r := RngNext(S);
    S.Trail[b, 0].A.X := ((r and $FF) * 5) shr 1;          // 0..637
    r := RngNext(S);
    y := (r and $FF) * 2;
    if y >= $1E0 then Dec(y, $27);                         // 0..479
    S.Trail[b, 0].A.Y := y;
    r := RngNext(S);
    S.Trail[b, 0].B.X := ((r and $FF) * 5) shr 1;
    r := RngNext(S);
    y := (r and $FF) * 2;
    if y >= $1E0 then Dec(y, $28);
    S.Trail[b, 0].B.Y := y;
  end;

  { velocities: one RNG word per component, masks F/7/7/F, descending bundle
    order (orig 0x369D); d = lo AND mask, minimum 1, negated when bit0 of the
    high byte is set }
  Masks[0] := $F; Masks[1] := 7; Masks[2] := 7; Masks[3] := $F;
  for b := S.NumBundles - 1 downto 0 do
    for j := 0 to 3 do
    begin
      r := RngNext(S);
      if (r shr 8) and 1 <> 0 then
        S.Vel[b, j] := SmallInt(-((r and Masks[j]) or
          Integer((r and Masks[j]) = 0)))
      else
        S.Vel[b, j] := SmallInt((r and Masks[j]) or
          Integer((r and Masks[j]) = 0));
    end;

  { colors: retry until (RNG AND $F) nonzero, descending (orig 0x36BF) }
  for b := S.NumBundles - 1 downto 0 do
  begin
    repeat
      r := RngNext(S);
    until (r and $F) <> 0;
    S.ColorArr[b] := r and $F;
  end;

  for b := 0 to S.NumBundles - 1 do
  begin
    S.Head[b] := 0;
    S.ChaseArr[b] := 0;
    S.Trail[b, 0].C := S.ColorArr[b];
    for j := 1 to S.NumLines - 1 do
      S.Trail[b, j] := S.Trail[b, 0];
  end;

  { tick-init draw (orig 0x3745): OR each bundle's single segment once }
  for b := 0 to S.NumBundles - 1 do
    DrawSeg(S, S.Trail[b, 0].A.X, S.Trail[b, 0].A.Y,
            S.Trail[b, 0].B.X, S.Trail[b, 0].B.Y, S.ColorArr[b], True);

  S.Init := True;
end;

procedure BundlesStep(var S: TBundlesSim);
var
  b, nxt, c: Integer;
  Seg: TBnSeg;
begin
  for b := 0 to S.NumBundles - 1 do
  begin
    { per-bundle chase state, orig load/store of 0x1646 / 0x1710 }
    ChaseColor := S.ColorArr[b] and $0F;
    if ChaseColor = 0 then ChaseColor := 1;
    ChaseStep := S.ChaseArr[b];

    nxt := S.Head[b] + 1;
    if nxt >= S.NumLines then nxt := 0;

    { advance one segment, orig 0x3868: A.X (mask F), A.Y (7), B.X (7),
      B.Y (mask F) }
    Seg := S.Trail[b, S.Head[b]];
    Inc(Seg.A.X, S.Vel[b, 0]);
    S.Vel[b, 0] := BounceAxis(S, Seg.A.X, S.Vel[b, 0], $F, BnWallX);
    Inc(Seg.A.Y, S.Vel[b, 1]);
    S.Vel[b, 1] := BounceAxis(S, Seg.A.Y, S.Vel[b, 1], 7, BnWallY);
    Inc(Seg.B.X, S.Vel[b, 2]);
    S.Vel[b, 2] := BounceAxis(S, Seg.B.X, S.Vel[b, 2], 7, BnWallX);
    Inc(Seg.B.Y, S.Vel[b, 3]);
    S.Vel[b, 3] := BounceAxis(S, Seg.B.Y, S.Vel[b, 3], $F, BnWallY);

    c := ChaseColor;
    Seg.C := c;
    { the new head replaces the oldest record of the ring: that record
      leaves the picture (the original XOR-erases it, 0x37C6) }
    S.Trail[b, nxt] := Seg;
    S.Head[b] := nxt;

    S.ColorArr[b] := ChaseColor;
    S.ChaseArr[b] := ChaseStep;
  end;
  { rebuild the planes from the live trail records: erasing a segment in
    place would also cut the pixels it shares with its neighbours }
  for b := 0 to 3 do FillChar(S.Planes[b], SizeOf(TBnPlane), 0);
  for b := 0 to S.NumBundles - 1 do
    for nxt := 0 to S.NumLines - 1 do
      with S.Trail[b, nxt] do
        DrawSeg(S, A.X, A.Y, B.X, B.Y, C, True);
end;

function BundlesColor(var S: TBundlesSim): Byte;
begin
  Result := S.ColorArr[S.NumBundles - 1];
end;

{ ---------------------------------------------------------------- terminal }

procedure InitBundlesPairs;
var
  c: Integer;
begin
  for c := 1 to 8 do
    init_pair(cpBundlesBase + c - 1, (c - 1) mod 8, COLOR_BLACK);
end;

{ palette value 0..15 -> a readable terminal color pair }
function BundlesCellColor(v: Integer): Integer;
begin
  case v of
    0:      Result := 0;
    1, 2:   Result := 1;   // red
    3, 4:   Result := 2;   // green
    5, 6:   Result := 3;   // yellow
    7, 8:   Result := 4;   // blue
    9, 10:  Result := 5;   // magenta
    11, 12: Result := 6;   // cyan
    13:     Result := 7;   // white
    14:     Result := 1;   // red4 (bright)
  else      Result := 7;   // white4 (bright)
  end;
end;

{ paint the live trail records straight into cell space, each in its own
  palette color: the bit-planes keep only (color-1) AND 3, and a one-pixel
  line of the 640x240 picture would fall between cell samples }
procedure PaintBundlesRect(const S: TBundlesSim; py, px, ph, pw: Integer);
const
  UsedRows = (BnWallY + 1) div 2;  // y is in half-rows: plane rows 0..239
var
  cells: array of Byte;
  x, y, b, j, c, n, k, x0, y0, x1, y1: Integer;
begin
  if (ph <= 0) or (pw <= 0) then Exit;
  SetLength(cells, ph * pw);
  for b := 0 to S.NumBundles - 1 do
    for j := 0 to S.NumLines - 1 do
      with S.Trail[b, j] do
      begin
        x0 := A.X * pw div BnGridW;  y0 := (A.Y div 2) * ph div UsedRows;
        x1 := B.X * pw div BnGridW;  y1 := (B.Y div 2) * ph div UsedRows;
        n := Abs(x1 - x0);
        if Abs(y1 - y0) > n then n := Abs(y1 - y0);
        for k := 0 to n do
        begin
          if n = 0 then begin x := x0; y := y0; end
          else
          begin
            x := x0 + Round((x1 - x0) * k / n);
            y := y0 + Round((y1 - y0) * k / n);
          end;
          if (x >= 0) and (x < pw) and (y >= 0) and (y < ph) then
            cells[y * pw + x] := C;
        end;
      end;
  for y := 0 to ph - 1 do
    for x := 0 to pw - 1 do
    begin
      c := BundlesCellColor(cells[y * pw + x]);
      if c = 0 then
      begin
        attrset(COLOR_PAIR(cpBundlesBase + 7));
        mvaddstr(py + y, px + x, ' ');
      end
      else
      begin
        if cells[y * pw + x] >= 8 then
          attrset(COLOR_PAIR(cpBundlesBase + c) or A_BOLD)
        else
          attrset(COLOR_PAIR(cpBundlesBase + c));
        mvaddstr(py + y, px + x, '█');
      end;
    end;
end;

procedure RunBundlesSaver;
var
  S: TBundlesSim;
  ch: LongInt;
  mev: MEVENT;
begin
  InitBundlesPairs;
  curs_set(0);
  BundlesInit(S, 0, 0, GetTickCount64 and $3FE);
  timeout(40);
  repeat
    BundlesStep(S);
    erase;
    PaintBundlesRect(S, 0, 0, LINES - 1, COLS);
    attrset(COLOR_PAIR(cpBundlesBase + 7));
    mvaddstr(LINES - 1, 0, 'Dos Navigator bundles port — any key returns');
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

end.
