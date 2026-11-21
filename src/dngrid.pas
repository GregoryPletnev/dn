{ dngrid — a desktop window that shows a query result as a grid.

  The header row stays on top; arrows move the cell cursor, the view
  scrolls by rows and by whole columns; Home/End jump to the first/last
  column, Ctrl-Home/Ctrl-End (or g/G) to the first/last row. Enter shows
  the full value of the cell (long text, newlines). Esc/F10 close. A
  result without columns (INSERT, DDL) shows its message instead. }
unit dngrid;

{$mode objfpc}{$H+}

interface

uses
  dnwin, dndb;

type
  TGridWin = class(TWin)
  public
    Res: TDbResult;
    Info: AnsiString;           // shown in the status line, e.g. the query time
    ColW: array of Integer;
    CurRow, CurCol, TopRow, LeftCol: Integer;
    constructor CreateGrid(AX, AY, AW, AH: Integer; const ATitle: AnsiString);
    procedure SetResult(const ARes: TDbResult; const AInfo: AnsiString);
    procedure DrawContent(Focused: Boolean); override;
    function StatusText: AnsiString; override;
    function HandleKey(ch: LongInt): TKeyAction; override;
    procedure HandleClick(mx, my: Integer; bstate: QWord); override;
    function ScrollInfo(out Pos, Total, Page: Integer): Boolean; override;
    procedure ScrollTo(NewPos: Integer); override;
  end;

{ a grid window centred on the desktop }
function OpenGrid(const Title: AnsiString; const R: TDbResult;
                  const Info: AnsiString): TGridWin;

{ a cell for one screen line: control characters shown as symbols }
function CellText(const S: AnsiString): AnsiString;

implementation

uses
  SysUtils, ncurses, dnscreen, dndialog;

const
  MinColW = 3;
  MaxColW = 40;
  SampleRows = 500;            // column widths come from the first rows

function CellText(const S: AnsiString): AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      #10: Result := Result + '↵';
      #13: ;
      #9: Result := Result + ' ';
      #0..#8, #11, #12, #14..#31: Result := Result + '·';
    else
      Result := Result + S[i];
    end;
end;

constructor TGridWin.CreateGrid(AX, AY, AW, AH: Integer; const ATitle: AnsiString);
begin
  inherited Create(AX, AY, AW, AH, ATitle);
  Info := '';
end;

procedure TGridWin.SetResult(const ARes: TDbResult; const AInfo: AnsiString);
var
  ci, ri, n, cw: Integer;
begin
  Res := ARes;
  Info := AInfo;
  CurRow := 0; CurCol := 0; TopRow := 0; LeftCol := 0;
  SetLength(ColW, Length(Res.Columns));
  for ci := 0 to High(Res.Columns) do
  begin
    cw := Utf8Width(CellText(Res.Columns[ci]));
    n := Length(Res.Rows);
    if n > SampleRows then n := SampleRows;
    for ri := 0 to n - 1 do
      if (ci <= High(Res.Rows[ri])) and
         (Utf8Width(CellText(Res.Rows[ri][ci])) > cw) then
        cw := Utf8Width(CellText(Res.Rows[ri][ci]));
    if cw < MinColW then cw := MinColW;
    if cw > MaxColW then cw := MaxColW;
    ColW[ci] := cw;
  end;
end;

function Cell(const R: TDbResult; Row, Col: Integer): AnsiString;
begin
  if (Row < Length(R.Rows)) and (Col <= High(R.Rows[Row])) then
    Result := R.Rows[Row][Col]
  else
    Result := '';
end;

function Fit(const S: AnsiString; W: Integer): AnsiString;
var
  t: AnsiString;
begin
  t := CellText(S);
  if Utf8Width(t) > W then
    Result := Utf8PadRight(t, W - 1) + '…'
  else
    Result := Utf8PadRight(t, W);
end;

procedure TGridWin.DrawContent(Focused: Boolean);
var
  x0, y0, iw, ih, rows, ci, ri, cx, cw, pair: Integer;
  msg: AnsiString;
begin
  x0 := X + 1;
  y0 := Y + 1;
  iw := W - 2;
  ih := H - 2;
  if Length(Res.Columns) = 0 then
  begin
    msg := Res.Message;
    if msg = '' then msg := 'no result';
    PutStr(y0 + ih div 2, x0 + 2, Copy(msg, 1, iw - 4), cpViewer, True);
    Exit;
  end;
  rows := ih - 1;                    // the header takes one line
  if CurRow < TopRow then TopRow := CurRow;
  if CurRow >= TopRow + rows then TopRow := CurRow - rows + 1;
  { keep the current column on screen: scroll whole columns }
  if CurCol < LeftCol then LeftCol := CurCol;
  repeat
    cx := 0;
    for ci := LeftCol to CurCol do Inc(cx, ColW[ci] + 1);
    if (cx <= iw) or (LeftCol >= CurCol) then Break;
    Inc(LeftCol);
  until False;

  { header }
  cx := x0;
  ci := LeftCol;
  while (ci <= High(Res.Columns)) and (cx < x0 + iw) do
  begin
    cw := ColW[ci];
    if cx + cw > x0 + iw then cw := x0 + iw - cx;
    PutStr(y0, cx, Fit(Res.Columns[ci], cw), cpTitleAct);
    Inc(cx, cw);
    if cx < x0 + iw then
    begin
      PutStr(y0, cx, '│', cpTitleAct);
      Inc(cx);
    end;
    Inc(ci);
  end;
  if cx < x0 + iw then PutStr(y0, cx, StringOfChar(' ', x0 + iw - cx), cpTitleAct);

  { rows }
  for ri := 0 to rows - 1 do
  begin
    if TopRow + ri >= Length(Res.Rows) then Break;
    cx := x0;
    ci := LeftCol;
    while (ci <= High(Res.Columns)) and (cx < x0 + iw) do
    begin
      cw := ColW[ci];
      if cx + cw > x0 + iw then cw := x0 + iw - cx;
      pair := cpViewer;
      if TopRow + ri = CurRow then
      begin
        pair := cpCursor;
        if (ci = CurCol) and Focused then pair := cpMenuSel;
      end;
      PutStr(y0 + 1 + ri, cx, Fit(Cell(Res, TopRow + ri, ci), cw), pair);
      Inc(cx, cw);
      if cx < x0 + iw then
      begin
        PutStr(y0 + 1 + ri, cx, '│', cpFrame);
        Inc(cx);
      end;
      Inc(ci);
    end;
  end;
end;

function TGridWin.StatusText: AnsiString;
var
  n: AnsiString;
begin
  if Length(Res.Columns) = 0 then Exit(Info);
  n := IntToStr(Length(Res.Rows));
  if Res.Truncated then n := n + '+';
  Result := Format('row %d/%s  col %d/%d', [CurRow + 1, n, CurCol + 1,
                                            Length(Res.Columns)]);
  if Info <> '' then Result := Result + '  ' + Info;
end;

function TGridWin.HandleKey(ch: LongInt): TKeyAction;
var
  page: Integer;
  v: AnsiString;
begin
  Result := kaConsumed;
  page := H - 3;
  if page < 1 then page := 1;
  case ch of
    27, KEY_F0 + 10, Ord('q'): Exit(kaClose);
    KEY_UP: if CurRow > 0 then Dec(CurRow);
    KEY_DOWN: if CurRow < Length(Res.Rows) - 1 then Inc(CurRow);
    KEY_PPAGE: begin Dec(CurRow, page); if CurRow < 0 then CurRow := 0; end;
    KEY_NPAGE:
      begin
        Inc(CurRow, page);
        if CurRow > Length(Res.Rows) - 1 then CurRow := Length(Res.Rows) - 1;
        if CurRow < 0 then CurRow := 0;
      end;
    KEY_LEFT: if CurCol > 0 then Dec(CurCol);
    KEY_RIGHT, 9: if CurCol < Length(Res.Columns) - 1 then Inc(CurCol);
    KEY_HOME: CurCol := 0;
    KEY_END: if Length(Res.Columns) > 0 then CurCol := Length(Res.Columns) - 1;
    Ord('g'): CurRow := 0;
    Ord('G'): if Length(Res.Rows) > 0 then CurRow := Length(Res.Rows) - 1;
    10, 13, KEY_ENTER:
      if (Length(Res.Columns) > 0) and (Length(Res.Rows) > 0) then
      begin
        v := Cell(Res, CurRow, CurCol);
        if v = '' then v := '(empty)';
        MsgBox(Res.Columns[CurCol], v, ['OK']);
      end;
  else
    Result := kaPass;
  end;
end;

function TGridWin.ScrollInfo(out Pos, Total, Page: Integer): Boolean;
begin
  Pos := TopRow;
  Total := Length(Res.Rows);
  Page := H - 3;                 // the header takes a line
  Result := Length(Res.Columns) > 0;
end;

procedure TGridWin.ScrollTo(NewPos: Integer);
begin
  TopRow := NewPos;
  if TopRow > Length(Res.Rows) - (H - 3) then TopRow := Length(Res.Rows) - (H - 3);
  if TopRow < 0 then TopRow := 0;
  if CurRow < TopRow then CurRow := TopRow;
  if CurRow > TopRow + H - 4 then CurRow := TopRow + H - 4;
end;

procedure TGridWin.HandleClick(mx, my: Integer; bstate: QWord);
var
  ci, cx: Integer;
begin
  { the wheel scrolls the rows wherever the pointer is; it is not a click }
  if (bstate and (mbtnWheelUp or mbtnWheelDown)) <> 0 then
  begin
    if (bstate and mbtnWheelUp) <> 0 then ScrollTo(TopRow - 3)
    else ScrollTo(TopRow + 3);
    Exit;
  end;
  if (my <= Y + 1) or (my >= Y + H - 1) or (Length(Res.Columns) = 0) then Exit;
  if TopRow + (my - Y - 2) < Length(Res.Rows) then
    CurRow := TopRow + (my - Y - 2);
  cx := X + 1;
  for ci := LeftCol to High(Res.Columns) do
  begin
    if mx < cx + ColW[ci] + 1 then
    begin
      CurCol := ci;
      Break;
    end;
    Inc(cx, ColW[ci] + 1);
  end;
end;

function OpenGrid(const Title: AnsiString; const R: TDbResult;
                  const Info: AnsiString): TGridWin;
var
  w, h: Integer;
begin
  w := COLS - 4;
  h := DeskY1 - DeskY0 - 1;
  Result := TGridWin.CreateGrid(2, DeskY0 + 1, w, h, Title);
  Result.SetResult(R, Info);
  WinAdd(Result);
end;

end.
