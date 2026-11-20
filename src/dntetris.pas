{ dntetris — the Dos Navigator Tetris, reborn on ncurses.
  The original DN shipped TETRIS.PAS as a built-in tool; this is a fresh
  implementation of the same game for the terminal.

  The game is an ordinary desktop window (TTetrisWin): it can be dragged
  by its title, raised, and left in the background. Gravity runs from
  Tick, which the main loop calls every pass; a game pauses itself when
  it loses the focus and resumes with P.

  Set DN_TETRIS_SEQ (letters IOTSZJL, used cyclically) for a deterministic
  piece sequence — the test suite relies on it. }
unit dntetris;

{$mode objfpc}{$H+}

interface

uses
  dnwin;

const
  FW = 10;                       // field width in cells
  InfoW = 12;                    // info column inside the window
  { outer window width: frame, field, separator, gap, info, frame }
  TetrisW = 1 + FW * 2 + 1 + 1 + InfoW + 1;
  { main-loop timeout while a game runs: short enough for smooth gravity
    at the fastest level (100 ms) }
  TetrisTickMs = 50;

type
  TTetrisWin = class(TWin)
  private
    FieldH: Integer;
    Field: array[0..21, 0..FW - 1] of Integer;   // 0 = empty, else piece+1
    CurP, CurRot, CurX, CurY: Integer;
    NextP: Integer;
    Seq: AnsiString;
    SeqPos: Integer;
    LastDrop: QWord;
    function Collides(p, rot, px, py: Integer): Boolean;
    function TakePiece: Integer;
    procedure SpawnPiece;
    function DropInterval: Integer;
    procedure LockPiece;
    function TryMove(dx, dy: Integer): Boolean;
    procedure TryRotate;
    procedure StepDown;
    procedure HardDrop;
  public
    Score, TotalLines, Level: Integer;
    GameOver: Boolean;
    Paused: Boolean;
    constructor CreateGame;
    procedure NewGame;
    procedure ClampToDesk; override;
    procedure DrawContent(Focused: Boolean); override;
    function StatusText: AnsiString; override;
    function HandleKey(ch: LongInt): TKeyAction; override;
    { gravity; a game without the focus pauses itself }
    procedure Tick(Focused: Boolean);
    { True while the game wants fast ticks (running, not paused) }
    function Running: Boolean;
  end;

{ The open game window, or a new one when there is none (one game at a
  time, like the original). nil when the screen is too small. }
function OpenTetris: TTetrisWin;

implementation

uses
  SysUtils, ncurses, dnscreen;

const
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
  MinFieldH = 10;

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

{ --- game logic ---------------------------------------------------------- }

function TTetrisWin.Collides(p, rot, px, py: Integer): Boolean;
var
  cx, cy, fx, fy: Integer;
begin
  for cy := 0 to 3 do
    for cx := 0 to 3 do
      if Cell(p, rot, cx, cy) then
      begin
        fx := px + cx;
        fy := py + cy;
        if (fx < 0) or (fx >= FW) or (fy >= FieldH) then Exit(True);
        if (fy >= 0) and (Field[fy][fx] > 0) then Exit(True);
      end;
  Result := False;
end;

function TTetrisWin.TakePiece: Integer;
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

procedure TTetrisWin.SpawnPiece;
begin
  CurP := NextP;
  NextP := TakePiece;
  CurRot := 0;
  CurX := 3;
  CurY := 0;
  if Collides(CurP, CurRot, CurX, CurY) then
    GameOver := True;
end;

function TTetrisWin.DropInterval: Integer;
begin
  Result := 500 - Level * 50;
  if Result < 100 then Result := 100;
end;

procedure TTetrisWin.LockPiece;
var
  cx, cy, fy, cleared: Integer;
  full: Boolean;
begin
  for cy := 0 to 3 do
    for cx := 0 to 3 do
      if Cell(CurP, CurRot, cx, cy) and (CurY + cy >= 0) then
        Field[CurY + cy][CurX + cx] := CurP + 1;
  { clear full lines }
  cleared := 0;
  for fy := FieldH - 1 downto 0 do
  begin
    full := True;
    for cx := 0 to FW - 1 do
      if Field[fy][cx] = 0 then
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

function TTetrisWin.TryMove(dx, dy: Integer): Boolean;
begin
  Result := not Collides(CurP, CurRot, CurX + dx, CurY + dy);
  if Result then
  begin
    Inc(CurX, dx);
    Inc(CurY, dy);
  end;
end;

procedure TTetrisWin.TryRotate;
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

procedure TTetrisWin.StepDown;
begin
  if not TryMove(0, 1) then
    LockPiece;
  LastDrop := GetTickCount64;
end;

procedure TTetrisWin.HardDrop;
begin
  while TryMove(0, 1) do ;
  LockPiece;
  LastDrop := GetTickCount64;
end;

{ --- window -------------------------------------------------------------- }

constructor TTetrisWin.CreateGame;
var
  dh: Integer;
begin
  { the field is as tall as the desktop allows, up to the classic 20 }
  dh := DeskY1 - DeskY0 + 1;
  FieldH := dh - 2;
  if FieldH > 20 then FieldH := 20;
  dh := FieldH + 2;
  inherited Create((COLS - TetrisW) div 2 + 1,
                   DeskY0 + (DeskY1 - DeskY0 + 1 - dh) div 2,
                   TetrisW, dh, 'TETRIS');
  Seq := GetEnvironmentVariable('DN_TETRIS_SEQ');
  if Seq = '' then Randomize;
  NewGame;
end;

procedure TTetrisWin.NewGame;
begin
  FillChar(Field, SizeOf(Field), 0);
  Score := 0;
  TotalLines := 0;
  Level := 0;
  GameOver := False;
  Paused := False;
  SeqPos := 0;
  NextP := TakePiece;
  SpawnPiece;
  LastDrop := GetTickCount64;
end;

procedure TTetrisWin.ClampToDesk;
begin
  { the field has a fixed size: never shrink below it (zoom may grow the
    frame; the game stays centered inside) }
  if W < TetrisW then W := TetrisW;
  if H < FieldH + 2 then H := FieldH + 2;
  inherited ClampToDesk;
end;

function TTetrisWin.Running: Boolean;
begin
  Result := not GameOver and not Paused;
end;

procedure TTetrisWin.Tick(Focused: Boolean);
begin
  if not Running then Exit;
  if not Focused then
  begin
    Paused := True;        // left in the background: wait for the player
    Exit;
  end;
  if GetTickCount64 - LastDrop >= QWord(DropInterval) then
    StepDown;
end;

function TTetrisWin.StatusText: AnsiString;
begin
  if GameOver then Result := 'N new game  Q quit'
  else if Paused then Result := 'Paused: P resume'
  else Result := '';
end;

function TTetrisWin.HandleKey(ch: LongInt): TKeyAction;
begin
  Result := kaConsumed;
  case ch of
    Ord('q'), Ord('Q'), 27: Exit(kaClose);
    Ord('n'), Ord('N'):
      if GameOver then NewGame;
    Ord('p'), Ord('P'):
      if not GameOver then
      begin
        Paused := not Paused;
        LastDrop := GetTickCount64;   // resume with a full interval
      end;
  else
    if GameOver then
    begin
      if ch in [10, 13] then Exit(kaClose);
      Exit(kaPass);
    end;
    if Paused then
    begin
      { any game key resumes a paused game, so it never feels stuck }
      case ch of
        KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, Ord(' '):
          begin
            Paused := False;
            LastDrop := GetTickCount64;
          end;
      else
        Exit(kaPass);
      end;
    end;
    case ch of
      KEY_LEFT:  TryMove(-1, 0);
      KEY_RIGHT: TryMove(1, 0);
      KEY_UP:    TryRotate;
      KEY_DOWN:  StepDown;
      Ord(' '):  HardDrop;
    else
      Result := kaPass;   // F-keys and the rest go to the desktop
    end;
  end;
end;

procedure TTetrisWin.DrawContent(Focused: Boolean);
var
  cx, cy, ix, fx0, fy0, i: Integer;
  pair: Integer;

  procedure Info(row: Integer; const s: AnsiString);
  begin
    if row < FieldH then
      PutStr(fy0 + row, ix, PadRight(s, InfoW), cpFrame, True);
  end;

begin
  for i := 0 to 6 do
    init_pair(cpPiece0 + i, COLOR_BLACK, PieceColors[i]);
  init_pair(cpFieldBg,  COLOR_WHITE, COLOR_BLACK);
  init_pair(cpGameOver, COLOR_WHITE, COLOR_RED);

  { game area centered in the interior (a zoomed frame is larger) }
  fx0 := X + 1 + (W - TetrisW) div 2;
  fy0 := Y + 1 + (H - FieldH - 2) div 2;
  ix := fx0 + FW * 2 + 2;

  for cy := 0 to FieldH - 1 do
  begin
    for cx := 0 to FW - 1 do
    begin
      pair := cpFieldBg;
      if Field[cy][cx] > 0 then pair := cpPiece0 + Field[cy][cx] - 1;
      PutStr(fy0 + cy, fx0 + cx * 2, '  ', pair);
    end;
    PutStr(fy0 + cy, fx0 + FW * 2, bxColV, cpFrame, True);
    { blank the whole info area so nothing shows through }
    PutStr(fy0 + cy, fx0 + FW * 2 + 1, StringOfChar(' ', InfoW + 1), cpFrame);
  end;

  { current piece }
  if not GameOver then
    for cy := 0 to 3 do
      for cx := 0 to 3 do
        if Cell(CurP, CurRot, cx, cy) and (CurY + cy >= 0) then
          PutStr(fy0 + CurY + cy, fx0 + (CurX + cx) * 2, '  ', cpPiece0 + CurP);

  { info column }
  Info(0, 'Next:');
  for cy := 0 to 1 do
    for cx := 0 to 3 do
      if BaseCell(NextP, cx, cy) then
        PutStr(fy0 + 1 + cy, ix + cx * 2, '  ', cpPiece0 + NextP)
      else
        PutStr(fy0 + 1 + cy, ix + cx * 2, '  ', cpFrame);
  Info(4, 'Score: ' + IntToStr(Score));
  Info(5, 'Lines: ' + IntToStr(TotalLines));
  Info(6, 'Level: ' + IntToStr(Level));
  Info(8,  #226#134#144#226#134#146' move');    // ←→
  Info(9,  #226#134#145' rotate');              // ↑
  Info(10, 'Space drop');
  Info(11, 'P pause');
  Info(12, 'Q quit');

  if GameOver then
    PutStr(fy0 + FieldH div 2, fx0 + FW - 6, ' GAME  OVER ', cpGameOver, True)
  else if Paused then
    PutStr(fy0 + FieldH div 2, fx0 + FW - 5, '  PAUSED  ', cpGameOver, True);
end;

function OpenTetris: TTetrisWin;
var
  i: Integer;
begin
  for i := 0 to WinCount - 1 do
    if Wins[i] is TTetrisWin then
    begin
      Result := TTetrisWin(Wins[i]);
      WinRaise(Result);
      Exit;
    end;
  Result := nil;
  if (DeskY1 - DeskY0 + 1 < MinFieldH + 2) or (COLS < TetrisW) then Exit;
  Result := TTetrisWin.CreateGame;
  WinAdd(Result);
end;

end.
