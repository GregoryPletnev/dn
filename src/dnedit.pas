{ dnedit — MicroEd, the built-in DN editor, as a desktop window.
  A port of the spirit of original/Dos-Navigator/MICROED.PAS:
  F2 save, F7 find, Ctrl-L find next, Ins insert/overwrite, Ctrl-Y delete
  line, Esc close (asks to save when modified). Status shows line:col. }
unit dnedit;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnwin, dnvfs, dnhighlite;

type
  TEditWin = class(TWin)
  public
    Path: AnsiString;
    Lines: TStringList;
    HlRules: THglRules;      // syntax highlighting rules for this file
    HlStates: array of Integer; // comment state before each line
    HlValid: Integer;        // states are computed for lines < HlValid
    CurX, CurY: Integer;        // 0-based column (codepoints) and line
    TopY, LeftX: Integer;
    Modified: Boolean;
    Overwrite: Boolean;
    LastFind: AnsiString;
    SavedTick: QWord;        // 'Saved' notification timestamp
    PutVfs: TVFS;            // non-nil: after saving, put the file here
    PutPath: AnsiString;
    constructor CreateEdit(const APath: AnsiString; ALines: TStringList);
    destructor Destroy; override;
    procedure DrawContent(Focused: Boolean); override;
    function StatusText: AnsiString; override;
    function HandleKey(ch: LongInt): TKeyAction; override;
    function HandleText(const s: AnsiString): TKeyAction; override;
    procedure InsertText(const t: AnsiString);
    procedure HandleClick(mx, my: Integer; bstate: QWord); override;
    function ConfirmClose: Boolean; override;
    function Save: Boolean;
    procedure FindNext(FromNext: Boolean);
  private
    { mark the buffer modified; edits change comment state of every
      following line, so the state cache is cut at the edit point }
    procedure MarkEdit;
    procedure EnsureHlStates(UpTo: Integer);
  end;

function OpenEditor(const Path: AnsiString): TEditWin;

implementation

uses
  SysUtils, ncurses, dnscreen, dndialog, dnoptions;

var
  Cascade: Integer = 0;

constructor TEditWin.CreateEdit(const APath: AnsiString; ALines: TStringList);
var
  rw, rh: Integer;
begin
  rw := (COLS * 3) div 4;
  rh := ((DeskY1 - DeskY0 + 1) * 3) div 4;
  inherited Create(2 + (Cascade mod 4) * 3, DeskY0 + 1 + (Cascade mod 4),
                   rw, rh, ExtractFileName(APath));
  Inc(Cascade);
  Path := APath;
  Lines := ALines;
  if Lines.Count = 0 then
    Lines.Add('');
  CurX := 0; CurY := 0; TopY := 0; LeftX := 0;
  Modified := False;
  Overwrite := False;
  HlRules := HglForFile(ExtractFileName(APath));
  HlValid := 0;
end;

procedure TEditWin.MarkEdit;
begin
  Modified := True;
  if CurY - 1 < HlValid then
    HlValid := CurY - 1;
  if HlValid < 0 then HlValid := 0;
end;

procedure TEditWin.EnsureHlStates(UpTo: Integer);
var
  i: Integer;
begin
  if UpTo > Lines.Count then UpTo := Lines.Count;
  if HlValid > Lines.Count then HlValid := Lines.Count;
  if Length(HlStates) < Lines.Count + 1 then
    SetLength(HlStates, Lines.Count + 1);
  HlStates[0] := -1;
  for i := HlValid to UpTo - 1 do
    HlStates[i + 1] := HglNextState(HlRules, Lines[i], HlStates[i]);
  if UpTo > HlValid then HlValid := UpTo;
end;

destructor TEditWin.Destroy;
begin
  Lines.Free;
  inherited;
end;

function TEditWin.StatusText: AnsiString;
begin
  Result := Format('%d:%d', [CurY + 1, CurX + 1]);
  if Overwrite then Result := Result + '  Ovr';
  if Modified then Result := Result + '  Modified';
  if (SavedTick > 0) and (GetTickCount64 - SavedTick < 2500) then
    Result := Result + '  Saved'
  else
    SavedTick := 0;
end;

procedure TEditWin.DrawContent(Focused: Boolean);
var
  j, cw, chh, scrX, scrY: Integer;
  s: AnsiString;
begin
  cw := W - 2;
  chh := H - 2;
  { keep the cursor in view }
  if CurY < TopY then TopY := CurY;
  if CurY >= TopY + chh then TopY := CurY - chh + 1;
  if CurX < LeftX then LeftX := CurX;
  if CurX >= LeftX + cw then LeftX := CurX - cw + 1;

  if Opt.SyntaxHl and HlRules.Valid then
    EnsureHlStates(TopY + chh);
  for j := 0 to chh - 1 do
  begin
    if (TopY + j < Lines.Count) and Opt.SyntaxHl and HlRules.Valid then
      PutHlLine(Y + 1 + j, X + 1, Lines[TopY + j], LeftX, cw, HlRules, cpViewer,
                HlStates[TopY + j])
    else
    begin
      if TopY + j < Lines.Count then
        s := Utf8Copy(Lines[TopY + j], LeftX + 1, cw)
      else
        s := '';
      PutStr(Y + 1 + j, X + 1, Utf8PadRight(s, cw), cpViewer);
    end;
  end;

  { cursor cell, DN-style inverse }
  if Focused then
  begin
    scrY := Y + 1 + CurY - TopY;
    scrX := X + 1 + CurX - LeftX;
    s := ' ';
    if (CurY < Lines.Count) and (CurX < Utf8Len(Lines[CurY])) then
      s := Utf8Copy(Lines[CurY], CurX + 1, 1);
    PutStr(scrY, scrX, s, cpCursor);
  end;
end;

function TEditWin.Save: Boolean;
var
  err: AnsiString;
begin
  Result := False;
  try
    Lines.SaveToFile(Path);
    Modified := False;
    SavedTick := GetTickCount64;
    Result := True;
  except
    on E: Exception do
      MsgBox('Error', 'Cannot save ' + Path + #10 + E.Message, ['OK']);
  end;
  if Result and (PutVfs <> nil) then
    if not PutVfs.PutFile(Path, PutPath, err) then
    begin
      MsgBox('Error', 'Cannot write back to archive:'#10 + err, ['OK']);
      Result := False;
    end;
end;

function TEditWin.ConfirmClose: Boolean;
begin
  if not Modified then Exit(True);
  case MsgBox('MicroEd', '"' + Title + '" was modified.'#10'Save it?',
              ['Save', 'Discard', 'Cancel']) of
    0: Result := Save;
    1: Result := True;
  else
    Result := False;
  end;
end;

procedure TEditWin.FindNext(FromNext: Boolean);
var
  i, p, start: Integer;
  s: AnsiString;
begin
  if LastFind = '' then Exit;
  { forward search from the cursor position }
  s := Lines[CurY];
  if FromNext then start := Utf8BytePos(s, CurX + 2)
  else start := Utf8BytePos(s, CurX + 1);
  p := Pos(LastFind, Copy(s, start, MaxInt));
  if p > 0 then
  begin
    CurX := Utf8Len(Copy(s, 1, start + p - 2));
    Exit;
  end;
  for i := CurY + 1 to Lines.Count - 1 do
  begin
    p := Pos(LastFind, Lines[i]);
    if p > 0 then
    begin
      CurY := i;
      CurX := Utf8Len(Copy(Lines[i], 1, p - 1));
      Exit;
    end;
  end;
  MsgBox('Find', '"' + LastFind + '" not found.', ['OK']);
end;

function TEditWin.HandleKey(ch: LongInt): TKeyAction;
var
  s, rest: AnsiString;
  q: AnsiString;
begin
  Result := kaConsumed;
  s := Lines[CurY];
  case ch of
    KEY_UP: if CurY > 0 then Dec(CurY);
    KEY_DOWN: if CurY < Lines.Count - 1 then Inc(CurY);
    KEY_LEFT:
      if CurX > 0 then Dec(CurX)
      else if CurY > 0 then
      begin
        Dec(CurY);
        CurX := Utf8Len(Lines[CurY]);
      end;
    KEY_RIGHT:
      if CurX < Utf8Len(s) then Inc(CurX)
      else if CurY < Lines.Count - 1 then
      begin
        Inc(CurY);
        CurX := 0;
      end;
    KEY_PPAGE: begin Dec(CurY, H - 2); if CurY < 0 then CurY := 0; end;
    KEY_NPAGE: begin Inc(CurY, H - 2); if CurY > Lines.Count - 1 then CurY := Lines.Count - 1; end;
    KEY_HOME: CurX := 0;
    KEY_END: CurX := Utf8Len(s);
    KEY_IC: Overwrite := not Overwrite;
    10, 13, KEY_ENTER:
      begin
        rest := Copy(s, Utf8BytePos(s, CurX + 1), MaxInt);
        Lines[CurY] := Copy(s, 1, Utf8BytePos(s, CurX + 1) - 1);
        Lines.Insert(CurY + 1, rest);
        Inc(CurY);
        CurX := 0;
        MarkEdit;
      end;
    KEY_BACKSPACE, 127, 8:
      if CurX > 0 then
      begin
        Delete(s, Utf8BytePos(s, CurX), Utf8CharBytes(s, Utf8BytePos(s, CurX)));
        Lines[CurY] := s;
        Dec(CurX);
        MarkEdit;
      end
      else if CurY > 0 then
      begin
        CurX := Utf8Len(Lines[CurY - 1]);
        Lines[CurY - 1] := Lines[CurY - 1] + s;
        Lines.Delete(CurY);
        Dec(CurY);
        MarkEdit;
      end;
    KEY_DC:
      if CurX < Utf8Len(s) then
      begin
        Delete(s, Utf8BytePos(s, CurX + 1), Utf8CharBytes(s, Utf8BytePos(s, CurX + 1)));
        Lines[CurY] := s;
        MarkEdit;
      end
      else if CurY < Lines.Count - 1 then
      begin
        Lines[CurY] := s + Lines[CurY + 1];
        Lines.Delete(CurY + 1);
        MarkEdit;
      end;
    25: { Ctrl-Y: delete line }
      begin
        if Lines.Count > 1 then
          Lines.Delete(CurY)
        else
          Lines[0] := '';
        if CurY > Lines.Count - 1 then CurY := Lines.Count - 1;
        CurX := 0;
        MarkEdit;
      end;
    9: { Tab: four spaces }
      begin
        Insert('    ', s, Utf8BytePos(s, CurX + 1));
        Lines[CurY] := s;
        Inc(CurX, 4);
        MarkEdit;
      end;
    KEY_F0 + 2: Save;
    KEY_F0 + 7:
      begin
        q := LastFind;
        if InputBox('Find', 'Search for:', q) and (q <> '') then
        begin
          LastFind := q;
          FindNext(False);
        end;
      end;
    12: FindNext(True);   // Ctrl-L
    27, KEY_F0 + 3, KEY_F0 + 10: Exit(kaClose);  // Esc / F3 / F10 close
  else
    if (ch >= 32) and (ch < 127) then
      InsertText(Chr(ch))
    else
      Exit(kaPass);
  end;
  if CurX > Utf8Len(Lines[CurY]) then CurX := Utf8Len(Lines[CurY]);
end;

procedure TEditWin.InsertText(const t: AnsiString);
var
  s: AnsiString;
  bp: Integer;
begin
  s := Lines[CurY];
  bp := Utf8BytePos(s, CurX + 1);
  if Overwrite and (CurX < Utf8Len(s)) then
    Delete(s, bp, Utf8CharBytes(s, bp));
  Insert(t, s, bp);
  Lines[CurY] := s;
  Inc(CurX, Utf8Len(t));
  MarkEdit;
end;

function TEditWin.HandleText(const s: AnsiString): TKeyAction;
begin
  InsertText(s);
  Result := kaConsumed;
end;

procedure TEditWin.HandleClick(mx, my: Integer; bstate: QWord);
var
  ny, nx: Integer;
begin
  if (bstate and mbtnWheelUp) <> 0 then
  begin
    Dec(CurY, 3);
    if CurY < 0 then CurY := 0;
  end
  else if (bstate and mbtnWheelDown) <> 0 then
  begin
    Inc(CurY, 3);
    if CurY > Lines.Count - 1 then CurY := Lines.Count - 1;
  end
  else if (bstate and (mbtn1Pressed or mbtn1Clicked or mbtn1Double)) <> 0 then
  begin
    ny := TopY + (my - Y - 1);
    nx := LeftX + (mx - X - 1);
    if (ny >= 0) and (ny < Lines.Count) then
    begin
      CurY := ny;
      CurX := nx;
      if CurX > Utf8Len(Lines[CurY]) then CurX := Utf8Len(Lines[CurY]);
    end;
  end;
  if CurX > Utf8Len(Lines[CurY]) then CurX := Utf8Len(Lines[CurY]);
end;

function OpenEditor(const Path: AnsiString): TEditWin;
var
  L: TStringList;
begin
  Result := nil;
  L := TStringList.Create;
  try
    if FileExists(Path) then
      L.LoadFromFile(Path);
  except
    on E: Exception do
    begin
      L.Free;
      MsgBox('Error', E.Message, ['OK']);
      Exit;
    end;
  end;
  Result := TEditWin.CreateEdit(Path, L);
  WinAdd(Result);
end;

end.
