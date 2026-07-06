{ dnview — file/text viewer as a desktop window (F3, F1 help). }
unit dnview;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnwin;

type
  TViewWin = class(TWin)
  public
    Content: TStringList;      // owned
    Top, Ofs: Integer;
    constructor CreateView(const ATitle: AnsiString; AContent: TStringList);
    destructor Destroy; override;
    procedure DrawContent(Focused: Boolean); override;
    function StatusText: AnsiString; override;
    function HandleKey(ch: LongInt): TKeyAction; override;
    procedure HandleClick(mx, my: Integer; bstate: QWord); override;
  end;

{ Returns the created window (already added to the desktop), nil on error. }
function OpenViewer(const Path: AnsiString): TViewWin;
function OpenTextView(const ATitle: AnsiString; L: TStringList): TViewWin;

implementation

uses
  SysUtils, ncurses, dnscreen, dndialog;

var
  Cascade: Integer = 0;

function NextRect(out rx, ry, rw, rh: Integer): Boolean;
begin
  rw := (COLS * 3) div 4;
  rh := ((DeskY1 - DeskY0 + 1) * 3) div 4;
  rx := 2 + (Cascade mod 4) * 3;
  ry := DeskY0 + 1 + (Cascade mod 4);
  Inc(Cascade);
  Result := True;
end;

{ Make a line safe to draw: expand tabs (8-col stops), replace control
  bytes and broken UTF-8 with '·'. ncurses would otherwise render tabs
  and ^X control pairs wider than we counted and spill over the frame. }
function SanitizeLine(const src: AnsiString): AnsiString;
var
  i, k, n, col: Integer;
  b: Byte;
  ok: Boolean;
begin
  Result := '';
  col := 0;
  i := 1;
  while i <= Length(src) do
  begin
    b := Ord(src[i]);
    if b = 9 then
    begin
      n := 8 - (col mod 8);
      Result := Result + StringOfChar(' ', n);
      Inc(col, n);
      Inc(i);
    end
    else if (b < 32) or (b = 127) then
    begin
      Result := Result + '·';
      Inc(col);
      Inc(i);
    end
    else if b < 128 then
    begin
      Result := Result + src[i];
      Inc(col);
      Inc(i);
    end
    else
    begin
      { multi-byte UTF-8: copy only complete, valid sequences }
      n := 0;
      if (b and $E0) = $C0 then n := 1
      else if (b and $F0) = $E0 then n := 2
      else if (b and $F8) = $F0 then n := 3;
      ok := (n > 0) and (i + n <= Length(src));
      if ok then
        for k := 1 to n do
          if (Ord(src[i + k]) and $C0) <> $80 then ok := False;
      if ok then
      begin
        Result := Result + Copy(src, i, n + 1);
        Inc(col);
        Inc(i, n + 1);
      end
      else
      begin
        Result := Result + '·';
        Inc(col);
        Inc(i);
      end;
    end;
  end;
end;

constructor TViewWin.CreateView(const ATitle: AnsiString; AContent: TStringList);
var
  rx, ry, rw, rh: Integer;
  i: Integer;
begin
  NextRect(rx, ry, rw, rh);
  inherited Create(rx, ry, rw, rh, ATitle);
  Content := AContent;
  for i := 0 to Content.Count - 1 do
    Content[i] := SanitizeLine(Content[i]);
  Top := 0;
  Ofs := 0;
end;

destructor TViewWin.Destroy;
begin
  Content.Free;
  inherited;
end;

function TViewWin.StatusText: AnsiString;
var
  pct: Integer;
begin
  if Content.Count > 0 then
    pct := ((Top + H - 2) * 100) div Content.Count
  else
    pct := 100;
  if pct > 100 then pct := 100;
  Result := Format('%d lines  %d%%', [Content.Count, pct]);
end;

procedure TViewWin.DrawContent(Focused: Boolean);
var
  j, cw: Integer;
  s: AnsiString;
begin
  cw := W - 2;
  for j := 0 to H - 3 do
  begin
    if Top + j < Content.Count then
      s := Utf8Copy(Content[Top + j], Ofs + 1, cw)
    else
      s := '';
    PutStr(Y + 1 + j, X + 1, Utf8PadRight(s, cw), cpViewer);
  end;
end;

procedure Clamp(var Top: Integer; var Ofs: Integer; cnt, ph: Integer);
begin
  if Top > cnt - ph then Top := cnt - ph;
  if Top < 0 then Top := 0;
  if Ofs < 0 then Ofs := 0;
end;

function TViewWin.HandleKey(ch: LongInt): TKeyAction;
var
  ph: Integer;
begin
  Result := kaConsumed;
  ph := H - 2;
  case ch of
    KEY_UP: Dec(Top);
    KEY_DOWN: Inc(Top);
    KEY_PPAGE: Dec(Top, ph);
    KEY_NPAGE: Inc(Top, ph);
    KEY_HOME: begin Top := 0; Ofs := 0; end;
    KEY_END: Top := Content.Count;
    KEY_LEFT: Dec(Ofs, 10);
    KEY_RIGHT: Inc(Ofs, 10);
    27, Ord('q'), Ord('Q'), KEY_F0 + 3, KEY_F0 + 10: Exit(kaClose);
  else
    Exit(kaPass);
  end;
  Clamp(Top, Ofs, Content.Count, ph);
end;

procedure TViewWin.HandleClick(mx, my: Integer; bstate: QWord);
begin
  if (bstate and mbtnWheelUp) <> 0 then Dec(Top, 3);
  if (bstate and mbtnWheelDown) <> 0 then Inc(Top, 3);
  Clamp(Top, Ofs, Content.Count, H - 2);
end;

function OpenTextView(const ATitle: AnsiString; L: TStringList): TViewWin;
begin
  Result := TViewWin.CreateView(ATitle, L);
  WinAdd(Result);
end;

function OpenViewer(const Path: AnsiString): TViewWin;
const
  MaxSize = 5 * 1024 * 1024;
var
  L: TStringList;
  fs: TFileStream;
  buf: AnsiString;
  i: Integer;
begin
  Result := nil;
  L := TStringList.Create;
  try
    fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(buf, fs.Size);
      if fs.Size > MaxSize then SetLength(buf, MaxSize);
      if Length(buf) > 0 then
        fs.ReadBuffer(buf[1], Length(buf));
    finally
      fs.Free;
    end;
  except
    on E: Exception do
    begin
      L.Free;
      MsgBox('Error', E.Message, ['OK']);
      Exit;
    end;
  end;
  for i := 1 to Length(buf) do
    if (buf[i] < #32) and (buf[i] <> #10) and (buf[i] <> #13) and (buf[i] <> #9) then
      buf[i] := '.';
  L.Text := StringReplace(buf, #9, '        ', [rfReplaceAll]);
  Result := OpenTextView(ExtractFileName(Path) + ' — ' + Path, L);
end;

end.
