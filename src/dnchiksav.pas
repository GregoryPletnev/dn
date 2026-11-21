{ dnchiksav — pure-logic port of the CHIK.SS text-mode screen saver.

  Reverse-engineered from ssavers_raw/CHIK.SS (RIT ssavers.zip, 1995);
  tools/re/chik_analysis.md holds the listing map. The walk below no
  longer follows tools/re/chik_emu.py: that model erased a strip
  cellsX x rowsY (20x5 at 80x25) from the box corner, not the box.

  The original draws no sprite art: it blanks a 4x5 cell box (4x6 at
  80x43) of the color text screen and walks the blank box along
  straight lines. Erased text never returns — the 0x04B2 restore loop
  is unreachable in the binary — so the visible sprite is a walking
  hole. The boot wipe blanks the box one row per frame while the
  rolled first-move delay counts down; then the box rests FW frames
  per cell and slides one cell, cellsX (or rowsY) slides per leg. At
  the leg end a new direction rolls (PRD(4)&3, rerolled at the walls).
  The port stops the slide at the screen edge, where the original
  walks out and resets (documented deviation).

  No terminal I/O here: Init primes the position, Step advances one
  frame, the Grid accessors expose the erased screen. Random rolls
  are value mod Bound (helper 0x05E2) through the Roll hook. }
unit dnchiksav;

{$mode objfpc}{$H+}

interface

type
  { source of random rolls: returns a value in 0..Bound-1 }
  TChikRoll = function(Bound: Integer): Integer of object;

  TChikPhase = (
    chpBoot,      { boot frame: roll and prime the position }
    chpWipe,      { countdown frames: one box row erased per frame }
    chpWalk       { erasing lattice cells along the current leg }
  );

  TChikSaver = class
  private
    FCols, FRows: Integer;    // text size (BIOS 40:044Ah, 40:0484h+1)
    FW, FH: Integer;          // box size in cells (4x5, or 4x6 at 80x43)
    FCellsX: Integer;         // cols div FW: box positions per row
    FRowsY: Integer;          // rows div FH: box positions per column
    FCount: Integer;          // walk counter, ticks per row pass
    FFirst: Integer;          // the rolled first-move delay (read-only)
    FGrid: array of Word;     // the text screen, CGA attribute words
    FBoxX, FBoxY: Integer;    // box corner in cells (bp-0x06/-0x07)
    FPos: Integer;            // box origin in words (bp-0x1A)
    FDx, FDy: Integer;        // walk direction (bp-0x2E/-0x30)
    FX, FY: Integer;          // strip loops (bp-0x04 byte, bp-0x14)
    FState: TChikPhase;
    FRoll: TChikRoll;
    function Prnd(Bound: Integer): Integer;
    procedure ChooseDir;
    function InScreen(P: Integer): Boolean;
    procedure EraseBox;
    procedure WalkFrame;
  public
    constructor Create(ACols, ARows: Integer);
    { primes the position and the boot wipe; ARoll may be nil
      (then the rolls return 0) }
    procedure Init(ARoll: TChikRoll);
    { paint the starting screen; nil restores the blank default }
    procedure SetScreen(AGrid: PWord);
    { one frame of the original }
    procedure Step;
    { the rolled first erase length, in frames }
    function FirstDelay: Integer;
    function Cell(X, Y: Integer): Word;        // grid word at cell
    function Dirty(X, Y: Integer): Boolean;    // cell blanked, repaint
    property Cols: Integer read FCols;
    property Rows: Integer read FRows;
    property BoxW: Integer read FW;
    property BoxH: Integer read FH;
    property BoxX: Integer read FBoxX;         // box corner column
    property BoxY: Integer read FBoxY;         // box corner row
    property DirX: Integer read FDx;
    property DirY: Integer read FDy;
    property Phase: TChikPhase read FState;
    property WalksLeft: Integer read FCount;
    property StripX: Integer read FX;
    property StripY: Integer read FY;
  end;

const
  ChikW = 4;               // default box width in cells
  ChikH = 5;               // default box height in cells
  ChikSnapWords = 125;     // usable words of the 0xFD0 scratch buffer
  ChikFramesPerTick = 6;   // ~113 fps retrace loop / 18.2 Hz tick

implementation

{ TChikSaver }

constructor TChikSaver.Create(ACols, ARows: Integer);
begin
  inherited Create;
  FCols := ACols;
  FRows := ARows;
  FW := ChikW;
  FH := ChikH;
  if (ACols = 80) and (ARows = 43) then FH := 6; // the 80x43 special case
  FCellsX := FCols div FW;
  FRowsY := FRows div FH;
  SetLength(FGrid, FCols * FRows);
  FillChar(FGrid[0], Length(FGrid) * SizeOf(Word), 0);
end;

function TChikSaver.Prnd(Bound: Integer): Integer;
begin
  if Bound <= 0 then Exit(0);
  Result := 0;
  if Assigned(FRoll) then Result := FRoll(Bound);
  if (Result < 0) or (Result >= Bound) then Result := 0;
end;

procedure TChikSaver.Init(ARoll: TChikRoll);
begin
  FRoll := ARoll;
  FState := chpBoot;
  FCount := 0;
  FFirst := 0;
  FX := 0;
  FY := 0;
  FDx := 0;
  FDy := 0;
  { original 0x01F3..0x0250 (the boot frame): rolled first-move delay
    (walk byte) and random lattice cell for the box origin; Step runs
    the boot wipe row and the first countdown tick }
  FCount := Prnd(20);
  FFirst := FCount;
  FBoxX := Prnd(FCellsX) * FW;
  FBoxY := Prnd(FRowsY) * FH;
  FPos := 2 * (FBoxY * FCols + FBoxX);
end;

procedure TChikSaver.SetScreen(AGrid: PWord);
var
  i: Integer;
begin
  if AGrid = nil then
    FillChar(FGrid[0], Length(FGrid) * SizeOf(Word), 0)
  else
    for i := 0 to Length(FGrid) - 1 do
      FGrid[i] := AGrid[i];
end;

{ original 0x02FB..0x03C2: roll a direction the wall rules allow,
  then count the sweeps of the axis; re-anchor winOff from the box
  cell (the 0x03C4 block runs every choose frame) }
procedure TChikSaver.ChooseDir;
var
  D, Tries: Integer;
begin
  D := -1;
  for Tries := 1 to 8 do
  begin
    D := Prnd(4) and 3;
    case D of
      { a direction is refused when the box already touches that wall }
      0: if FBoxX >= FCols - FW then D := -1;   { east }
      1: if FBoxY >= FRows - FH then D := -1;   { south }
      2: if FBoxX <= 0 then D := -1;            { west }
      3: if FBoxY <= 0 then D := -1;            { north }
    end;
    if D >= 0 then Break;
  end;
  if D < 0 then
  begin
    { original 0x034F re-rolls until the clock offers another second;
      the port takes the first inward direction and moves on }
    if FBoxX < FCols - FW then D := 0
    else if FBoxY < FRows - FH then D := 1
    else if FBoxX > 0 then D := 2
    else D := 3;
  end;
  case D of
    0: begin FCount := FCellsX; FDx := 1;  FDy := 0; end;
    1: begin FCount := FRowsY;  FDx := 0;  FDy := 1; end;
    2: begin FCount := FCellsX; FDx := -1; FDy := 0; end;
    3: begin FCount := FRowsY;  FDx := 0;  FDy := -1; end;
  end;
  FPos := 2 * (FBoxY * FCols + FBoxX);
  FX := 0;
  FY := 0;
  FState := chpWalk;
end;

function TChikSaver.InScreen(P: Integer): Boolean;
var
  bx, by: Integer;
begin
  bx := (P div 2) mod FCols;
  by := (P div 2) div FCols;
  Result := (bx >= 0) and (bx + FW <= FCols)
    and (by >= 0) and (by + FH <= FRows);
end;

{ blank the whole FW x FH box at its current corner }
procedure TChikSaver.EraseBox;
var
  x, y, cx, cy: Integer;
begin
  for y := 0 to FH - 1 do
    for x := 0 to FW - 1 do
    begin
      cx := FBoxX + x;
      cy := FBoxY + y;
      if (cx >= 0) and (cx < FCols) and (cy >= 0) and (cy < FRows) then
        FGrid[cy * FCols + cx] := 0;
    end;
end;

{ one walk frame: the box stays FW frames on a cell, then slides one cell
  along the leg and blanks what it covers. The leg ends after FCount
  slides or at the screen edge; the next walk frame rolls a new leg. }
procedure TChikSaver.WalkFrame;
var
  nxt: Integer;
begin
  if FCount = 0 then ChooseDir;
  EraseBox;
  Inc(FX);
  if FX >= FW then
  begin
    FX := 0;
    Dec(FCount);
    nxt := FPos + 2 * FDx + 2 * FCols * FDy;
    if (FCount <= 0) or (not InScreen(nxt)) then
      FCount := 0
    else
    begin
      FPos := nxt;
      Inc(FBoxX, FDx);
      Inc(FBoxY, FDy);
      EraseBox;
    end;
  end;
end;

procedure TChikSaver.Step;
var
  p, row: Integer;
begin
  case FState of
    chpBoot, chpWipe:
      begin
        { the boot wipe: blank one box row per frame while the rolled
          first-move delay counts down; at zero the first leg starts on
          the same frame }
        if FY < FH then
        begin
          row := FBoxY + FY;
          if (row >= 0) and (row < FRows) then
            for p := 0 to FW - 1 do
              if FBoxX + p < FCols then
                FGrid[row * FCols + FBoxX + p] := 0;
          Inc(FY);
        end;
        FState := chpWipe;
        Dec(FCount);
        if FCount > 0 then Exit;
        FCount := 0;
        FY := 0;
        FState := chpWalk;
        WalkFrame;
      end;

    chpWalk:
      WalkFrame;
  end;
end;

function TChikSaver.FirstDelay: Integer;
begin
  Result := FFirst;
end;

function TChikSaver.Cell(X, Y: Integer): Word;
begin
  Result := 0;
  if (X >= 0) and (X < FCols) and (Y >= 0) and (Y < FRows) then
    Result := FGrid[Y * FCols + X];
end;

function TChikSaver.Dirty(X, Y: Integer): Boolean;
begin
  Result := Cell(X, Y) = 0;
end;

end.
