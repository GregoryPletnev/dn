{ dntetris — the Dos Navigator Tetris, reborn on ncurses.
  The original DN shipped TETRIS.PAS as a built-in tool; this is a fresh
  implementation of the same game for the terminal.

  Set DN_TETRIS_SEQ (letters IOTSZJL, used cyclically) for a deterministic
  piece sequence — the test suite relies on it. }
unit dntetris;

{$mode objfpc}{$H+}

interface

procedure RunTetris;

implementation

uses
  SysUtils, ncurses, dnscreen;

const
  FW = 10;                       // field width in cells
  PieceLetters = 'IOTSZJL';
  { base shapes: rows 0..1 of a 4x4 box }
  ShapeStr: array[0..6, 0..1] of string[4] = (
    ('....', 'XXXX'),   // I
    ('.XX.', '.XX.'),   // O
    ('.X..', 'XXX.'),   // T
    ('.XX.', 'XX..'),   // S
    ('XX..', '.XX.'),   // Z
    ('X...', 'XXX.'),   // J
    ('..X.', 'XXX.')    // L
  );
  cpPiece0   = 20;               // pairs 20..26: piece colors (as background)
  cpFieldBg  = 27;
  cpGameOver = 28;
  PieceColors: array[0..6] of SmallInt =
    (COLOR_CYAN, COLOR_YELLOW, COLOR_MAGENTA, COLOR_GREEN,
     COLOR_RED, COLOR_BLUE, COLOR_WHITE);
  InfoW = 12;                    // info column inside the window

var
  FieldH: Integer;
  Field: array[0..21, 0..FW - 1] of Integer;   // 0 = empty, else piece+1
  CurP, CurRot, CurX, CurY: Integer;
  NextP: Integer;
  Score, TotalLines, Level: Integer;
  Seq: AnsiString;
  SeqPos: Integer;
  fy0, fx0: Integer;             // screen cell of field's top-left
  GameOver: Boolean;

function BaseCell(p, x, y: Integer): Boolean;
begin
  Result := (y >= 0) and (y <= 1) and (x >= 0) and (x <= 3) and
            (ShapeStr[p][y][x + 1] = 'X');
end;

function Cell(p, rot, x, y: Integer): Boolean;
var
  i, t: Integer;
begin
  for i := 1 to rot and 3 do
  begin
    t := x;
    x := y;
    y := 3 - t;
  end;
  Result := BaseCell(p, x, y);
end;

function Collides(p, rot, px, py: Integer): Boolean;
var
  x, y, fx, fy: Integer;
begin
  for y := 0 to 3 do
    for x := 0 to 3 do
      if Cell(p, rot, x, y) then
      begin
        fx := px + x;
        fy := py + y;
        if (fx < 0) or (fx >= FW) or (fy >= FieldH) then Exit(True);
        if (fy >= 0) and (Field[fy][fx] > 0) then Exit(True);
      end;
  Result := False;
end;

function TakePiece: Integer;
begin
  if Seq <> '' then
  begin
    Result := Pos(Seq[SeqPos mod Length(Seq) + 1], PieceLetters) - 1;
    if Result < 0 then Result := 0;
    Inc(SeqPos);
  end
  else
    Result := Random(7);
end;

procedure SpawnPiece;
begin
  CurP := NextP;
  NextP := TakePiece;
  CurRot := 0;
  CurX := 3;
  CurY := 0;
  if Collides(CurP, CurRot, CurX, CurY) then
    GameOver := True;
end;

function DropInterval: Integer;
begin
  Result := 500 - Level * 50;
  if Result < 100 then Result := 100;
end;

procedure LockPiece;
var
  x, y, fy, cleared: Integer;
  full: Boolean;
begin
  for y := 0 to 3 do
    for x := 0 to 3 do
      if Cell(CurP, CurRot, x, y) and (CurY + y >= 0) then
        Field[CurY + y][CurX + x] := CurP + 1;
  { clear full lines }
  cleared := 0;
  for fy := FieldH - 1 downto 0 do
  begin
    full := True;
    for x := 0 to FW - 1 do
      if Field[fy][x] = 0 then
      begin
        full := False;
        Break;
      end;
    if full then Inc(cleared)
    else if cleared > 0 then
      System.Move(Field[fy], Field[fy + cleared], SizeOf(Field[fy]));
  end;
  for fy := 0 to cleared - 1 do
    FillChar(Field[fy], SizeOf(Field[fy]), 0);
  if cleared > 0 then
  begin
    case cleared of
      1: Inc(Score, 100 * (Level + 1));
      2: Inc(Score, 300 * (Level + 1));
      3: Inc(Score, 500 * (Level + 1));
    else Inc(Score, 800 * (Level + 1));
    end;
    Inc(TotalLines, cleared);
    Level := TotalLines div 10;
  end;
  SpawnPiece;
end;

function TryMove(dx, dy: Integer): Boolean;
begin
  Result := not Collides(CurP, CurRot, CurX + dx, CurY + dy);
  if Result then
  begin
    Inc(CurX, dx);
    Inc(CurY, dy);
  end;
end;

procedure TryRotate;
const
  kicks: array[0..4] of Integer = (0, -1, 1, -2, 2);
var
  nr, i: Integer;
begin
  nr := (CurRot + 1) and 3;
  for i := 0 to High(kicks) do
    if not Collides(CurP, nr, CurX + kicks[i], CurY) then
    begin
      CurRot := nr;
      Inc(CurX, kicks[i]);
      Exit;
    end;
end;

procedure StepDown;
begin
  if not TryMove(0, 1) then
    LockPiece;
end;

procedure HardDrop;
begin
  while TryMove(0, 1) do ;
  LockPiece;
end;

procedure DrawGame;
var
  x, y, ix: Integer;
  pair: Integer;
  title: AnsiString;

  procedure Info(row: Integer; const s: AnsiString);
  begin
    PutStr(fy0 + row, ix, PadRight(s, InfoW), cpFrame, True);
  end;

begin
  ix := fx0 + FW * 2 + 2;
  { window frame; interior = field + separator + info column }
  title := ' TETRIS ';
  PutStr(fy0 - 1, fx0 - 1,
    bxTL + Rep(bxH, FW * 2 + 2 + InfoW) + bxTR, cpFrame, True);
  PutStr(fy0 - 1, fx0 + (FW * 2 - Length(title)) div 2, title, cpTitleAct);
  for y := 0 to FieldH - 1 do
  begin
    PutStr(fy0 + y, fx0 - 1, bxV, cpFrame, True);
    for x := 0 to FW - 1 do
    begin
      pair := cpFieldBg;
      if Field[y][x] > 0 then pair := cpPiece0 + Field[y][x] - 1;
      PutStr(fy0 + y, fx0 + x * 2, '  ', pair);
    end;
    PutStr(fy0 + y, fx0 + FW * 2, bxColV, cpFrame, True);
    { blank the whole info area so nothing shows through from the panels }
    PutStr(fy0 + y, fx0 + FW * 2 + 1, StringOfChar(' ', InfoW + 1), cpFrame);
    PutStr(fy0 + y, fx0 + FW * 2 + 2 + InfoW, bxV, cpFrame, True);
  end;
  PutStr(fy0 + FieldH, fx0 - 1,
    bxBL + Rep(bxH, FW * 2 + 2 + InfoW) + bxBR, cpFrame, True);

  { current piece }
  if not GameOver then
    for y := 0 to 3 do
      for x := 0 to 3 do
        if Cell(CurP, CurRot, x, y) and (CurY + y >= 0) then
          PutStr(fy0 + CurY + y, fx0 + (CurX + x) * 2, '  ', cpPiece0 + CurP);

  { info column }
  Info(0, 'Next:');
  for y := 0 to 1 do
    for x := 0 to 3 do
      if BaseCell(NextP, x, y) then
        PutStr(fy0 + 1 + y, ix + x * 2, '  ', cpPiece0 + NextP)
      else
        PutStr(fy0 + 1 + y, ix + x * 2, '  ', cpFrame);
  Info(4, 'Score: ' + IntToStr(Score));
  Info(5, 'Lines: ' + IntToStr(TotalLines));
  Info(6, 'Level: ' + IntToStr(Level));
  if FieldH >= 13 then
  begin
    Info(8,  #226#134#144#226#134#146' move');    // ←→
    Info(9,  #226#134#145' rotate');              // ↑
    Info(10, 'Space drop');
    Info(11, 'Q quit');
  end;

  if GameOver then
    PutStr(fy0 + FieldH div 2, fx0 + FW - 6, ' GAME  OVER ', cpGameOver, True);
  refresh;
end;

procedure RunTetris;
var
  i, ch: LongInt;
begin
  if (LINES < 14) or (COLS < 42) then Exit;

  for i := 0 to 6 do
    init_pair(cpPiece0 + i, COLOR_BLACK, PieceColors[i]);
  init_pair(cpFieldBg,  COLOR_WHITE, COLOR_BLACK);
  init_pair(cpGameOver, COLOR_WHITE, COLOR_RED);

  FieldH := LINES - 4;
  if FieldH > 20 then FieldH := 20;
  fy0 := (LINES - FieldH) div 2;
  fx0 := (COLS - (FW * 2 + 2 + InfoW)) div 2 + 1;

  FillChar(Field, SizeOf(Field), 0);
  Score := 0;
  TotalLines := 0;
  Level := 0;
  GameOver := False;
  Seq := GetEnvironmentVariable('DN_TETRIS_SEQ');
  SeqPos := 0;
  if Seq = '' then Randomize;
  NextP := TakePiece;
  SpawnPiece;

  repeat
    timeout(DropInterval);
    DrawGame;
    ch := getch;
    if GameOver then
    begin
      case ch of
        Ord('q'), Ord('Q'), 27, 10, 13: Break;
      end;
      Continue;
    end;
    case ch of
      KEY_LEFT:  TryMove(-1, 0);
      KEY_RIGHT: TryMove(1, 0);
      KEY_UP:    TryRotate;
      KEY_DOWN:  StepDown;
      Ord(' '):  HardDrop;
      Ord('q'), Ord('Q'), 27: Break;
      ERR:       StepDown;      // gravity tick
    end;
  until False;

  timeout(1000);
end;

end.
