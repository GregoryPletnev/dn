{ dnwin — the DN multi-window desktop layer.
  Windows float above the panels: double-line frame when focused, single
  when not, [■] close icon top-left, [↕] zoom icon top-right (the original
  used [*] and [|]). F5 zoom, F6 cycle focus, Ctrl-F5 move/resize mode
  (arrows move, shift-arrows resize), Esc/F10 close. }
unit dnwin;

{$mode objfpc}{$H+}

interface

type
  TKeyAction = (kaPass, kaConsumed, kaClose);

  TWin = class
  public
    X, Y, W, H: Integer;          // outer rect, frame included
    Title: AnsiString;
    Zoomed: Boolean;
    SX, SY, SW, SH: Integer;      // saved rect for unzoom
    constructor Create(AX, AY, AW, AH: Integer; const ATitle: AnsiString);
    procedure Draw(Focused: Boolean);
    procedure DrawContent(Focused: Boolean); virtual; abstract;
    { status text shown in the bottom frame line, '' = none }
    function StatusText: AnsiString; virtual;
    function HandleKey(ch: LongInt): TKeyAction; virtual;
    { multi-byte (UTF-8) text input; default ignores it }
    function HandleText(const s: AnsiString): TKeyAction; virtual;
    procedure HandleClick(mx, my: Integer; bstate: QWord); virtual;
    { called before closing; False cancels (e.g. unsaved changes) }
    function ConfirmClose: Boolean; virtual;
    procedure ZoomToggle;
    procedure ClampToDesk;
    function Inside(mx, my: Integer): Boolean;
    function OnCloseIcon(mx, my: Integer): Boolean;
    function OnZoomIcon(mx, my: Integer): Boolean;
  end;

const
  MinW = 24;
  MinH = 5;

var
  Wins: array of TWin;
  { desktop area (set by the main program every frame) }
  DeskY0: Integer = 1;
  DeskY1: Integer = 20;

procedure WinAdd(w: TWin);
procedure WinClose(w: TWin);           // no ConfirmClose here
function WinTop: TWin;
procedure WinRaise(w: TWin);
function WinAt(mx, my: Integer): TWin; // topmost window under the point
procedure WinDrawAll(Focused: TWin);
function WinCount: Integer;

implementation

uses
  SysUtils, ncurses, dnscreen;

constructor TWin.Create(AX, AY, AW, AH: Integer; const ATitle: AnsiString);
begin
  X := AX; Y := AY; W := AW; H := AH;
  Title := ATitle;
  Zoomed := False;
  ClampToDesk;
end;

function TWin.StatusText: AnsiString;
begin
  Result := '';
end;

function TWin.HandleKey(ch: LongInt): TKeyAction;
begin
  Result := kaPass;
end;

function TWin.HandleText(const s: AnsiString): TKeyAction;
begin
  Result := kaPass;
end;

procedure TWin.HandleClick(mx, my: Integer; bstate: QWord);
begin
end;

function TWin.ConfirmClose: Boolean;
begin
  Result := True;
end;

procedure TWin.ClampToDesk;
begin
  if W < MinW then W := MinW;
  if H < MinH then H := MinH;
  if W > COLS then W := COLS;
  if H > DeskY1 - DeskY0 + 1 then H := DeskY1 - DeskY0 + 1;
  if X < 0 then X := 0;
  if Y < DeskY0 then Y := DeskY0;
  if X + W > COLS then X := COLS - W;
  if Y + H - 1 > DeskY1 then Y := DeskY1 - H + 1;
  if Y < DeskY0 then Y := DeskY0;
end;

procedure TWin.ZoomToggle;
begin
  if Zoomed then
  begin
    X := SX; Y := SY; W := SW; H := SH;
    Zoomed := False;
  end
  else
  begin
    SX := X; SY := Y; SW := W; SH := H;
    X := 0; Y := DeskY0;
    W := COLS; H := DeskY1 - DeskY0 + 1;
    Zoomed := True;
  end;
  ClampToDesk;
end;

function TWin.Inside(mx, my: Integer): Boolean;
begin
  Result := (mx >= X) and (mx < X + W) and (my >= Y) and (my < Y + H);
end;

function TWin.OnCloseIcon(mx, my: Integer): Boolean;
begin
  Result := (my = Y) and (mx >= X + 2) and (mx <= X + 4);
end;

function TWin.OnZoomIcon(mx, my: Integer): Boolean;
begin
  Result := (my = Y) and (mx >= X + W - 5) and (mx <= X + W - 3);
end;

procedure TWin.Draw(Focused: Boolean);
var
  i: Integer;
  tl, tr, bl, br, hh, vv: AnsiString;
  t, st: AnsiString;
begin
  if Focused then
  begin
    tl := bxTL; tr := bxTR; bl := bxBL; br := bxBR; hh := bxH; vv := bxV;
  end
  else
  begin
    tl := bxSTL; tr := bxSTR; bl := bxSBL; br := bxSBR; hh := bxSepH; vv := bxColV;
  end;
  PutStr(Y, X, tl + Rep(hh, W - 2) + tr, cpFrame, Focused);
  for i := 1 to H - 2 do
  begin
    PutStr(Y + i, X, vv, cpFrame, Focused);
    PutStr(Y + i, X + 1, StringOfChar(' ', W - 2), cpViewer);
    PutStr(Y + i, X + W - 1, vv, cpFrame, Focused);
  end;
  PutStr(Y + H - 1, X, bl + Rep(hh, W - 2) + br, cpFrame, Focused);

  { icons and title }
  PutStr(Y, X + 2, '[■]', cpFrame, Focused);
  PutStr(Y, X + W - 5, '[↕]', cpFrame, Focused);
  t := ' ' + Title + ' ';
  if Length(t) > W - 12 then
    t := ' …' + Copy(Title, Length(Title) - (W - 16), W - 15) + ' ';
  if Focused then
    PutStr(Y, X + (W - Length(t)) div 2, t, cpTitleAct)
  else
    PutStr(Y, X + (W - Length(t)) div 2, t, cpFrame);

  st := StatusText;
  if st <> '' then
  begin
    if Length(st) > W - 6 then st := Copy(st, 1, W - 6);
    PutStr(Y + H - 1, X + 2, ' ' + st + ' ', cpFrame, Focused);
  end;

  DrawContent(Focused);
end;

{ --- manager ------------------------------------------------------------ }

function WinCount: Integer;
begin
  Result := Length(Wins);
end;

procedure WinAdd(w: TWin);
begin
  SetLength(Wins, Length(Wins) + 1);
  Wins[High(Wins)] := w;
end;

procedure WinClose(w: TWin);
var
  i, j: Integer;
begin
  for i := 0 to High(Wins) do
    if Wins[i] = w then
    begin
      for j := i to High(Wins) - 1 do
        Wins[j] := Wins[j + 1];
      SetLength(Wins, Length(Wins) - 1);
      w.Free;
      Exit;
    end;
end;

function WinTop: TWin;
begin
  if Length(Wins) > 0 then
    Result := Wins[High(Wins)]
  else
    Result := nil;
end;

procedure WinRaise(w: TWin);
var
  i, j: Integer;
begin
  for i := 0 to High(Wins) do
    if Wins[i] = w then
    begin
      for j := i to High(Wins) - 1 do
        Wins[j] := Wins[j + 1];
      Wins[High(Wins)] := w;
      Exit;
    end;
end;

function WinAt(mx, my: Integer): TWin;
var
  i: Integer;
begin
  for i := High(Wins) downto 0 do
    if Wins[i].Inside(mx, my) then
      Exit(Wins[i]);
  Result := nil;
end;

procedure WinDrawAll(Focused: TWin);
var
  i: Integer;
begin
  for i := 0 to High(Wins) do
  begin
    Wins[i].ClampToDesk;
    Wins[i].Draw(Wins[i] = Focused);
  end;
end;

end.
