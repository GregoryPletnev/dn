{ dndialog — modal DN-style dialogs: message box, input box, text viewer.
  All are ncurses-modal loops that repaint the screen via RedrawBase. }
unit dndialog;

{$mode objfpc}{$H+}

interface

uses
  Classes;

{ Returns pressed button index, or -1 on Esc. Message lines split by #10. }
function MsgBox(const Title, Msg: AnsiString;
                const Buttons: array of AnsiString): Integer;

{ Line-input dialog. Returns True on OK; Value holds the edited text. }
function InputBox(const Title, Prompt: AnsiString;
                  var Value: AnsiString): Boolean;

implementation

uses
  SysUtils, ncurses, dnscreen;

procedure Base;
begin
  if Assigned(RedrawBase) then RedrawBase();
end;

procedure SplitMsg(const Msg: AnsiString; L: TStringList);
begin
  L.Text := Msg;
end;

procedure DrawBox(y, x, h, w: Integer; const Title: AnsiString);
var
  i: Integer;
begin
  PutStr(y, x, bxSTL + Rep(bxSepH, w - 2) + bxSTR, cpMenuBar);
  for i := 1 to h - 2 do
  begin
    PutStr(y + i, x, bxColV, cpMenuBar);
    PutStr(y + i, x + 1, StringOfChar(' ', w - 2), cpMenuBar);
    PutStr(y + i, x + w - 1, bxColV, cpMenuBar);
  end;
  PutStr(y + h - 1, x, bxSBL + Rep(bxSepH, w - 2) + bxSBR, cpMenuBar);
  if Title <> '' then
    PutStr(y, x + (w - Length(Title) - 2) div 2, ' ' + Title + ' ', cpMenuBar);
end;

function MsgBox(const Title, Msg: AnsiString;
                const Buttons: array of AnsiString): Integer;
var
  L: TStringList;
  w, h, y, x, i, focus, bw, bx, by, ch: Integer;
  btnX: array of Integer;
  me: MEVENT;

  procedure Draw;
  var
    j, cx: Integer;
    cap: AnsiString;
  begin
    Base;
    DrawBox(y, x, h, w, Title);
    for j := 0 to L.Count - 1 do
      PutStr(y + 1 + j, x + 2, L[j], cpMenuBar);
    cx := bx;
    SetLength(btnX, Length(Buttons));
    for j := 0 to High(Buttons) do
    begin
      cap := '[ ' + Buttons[j] + ' ]';
      btnX[j] := cx;
      if j = focus then
        PutStr(by, cx, cap, cpMenuSel)
      else
        PutStr(by, cx, cap, cpMenuBar);
      cx := cx + Length(cap) + 2;
    end;
    refresh;
  end;

var
  j: Integer;
begin
  Result := -1;
  L := TStringList.Create;
  try
    SplitMsg(Msg, L);
    w := 20;
    for i := 0 to L.Count - 1 do
      if Length(L[i]) + 4 > w then w := Length(L[i]) + 4;
    bw := 0;
    for i := 0 to High(Buttons) do
      bw := bw + Length(Buttons[i]) + 6;
    if bw + 2 > w then w := bw + 2;
    if w > COLS - 4 then w := COLS - 4;
    h := L.Count + 4;
    y := (LINES - h) div 2;
    x := (COLS - w) div 2;
    by := y + h - 2;
    bx := x + (w - bw + 2) div 2;
    focus := 0;

    repeat
      Draw;
      ch := getch;
      case ch of
        ERR: ;
        9, KEY_RIGHT: focus := (focus + 1) mod Length(Buttons);
        KEY_LEFT: focus := (focus + Length(Buttons) - 1) mod Length(Buttons);
        10, 13, KEY_ENTER: Exit(focus);
        27: Exit(-1);
        KEY_MOUSE:
          if getmouse(@me) = OK then
            if ((me.bstate and (mbtn1Clicked or mbtn1Pressed or mbtn1Double)) <> 0)
               and (me.y = by) then
              for j := 0 to High(Buttons) do
                if (me.x >= btnX[j]) and (me.x < btnX[j] + Length(Buttons[j]) + 4) then
                  Exit(j);
      else
        for j := 0 to High(Buttons) do
          if (Buttons[j] <> '') and
             (UpCase(Chr(ch and $FF)) = UpCase(Buttons[j][1])) then
            Exit(j);
      end;
    until False;
  finally
    L.Free;
  end;
end;

function InputBox(const Title, Prompt: AnsiString;
                  var Value: AnsiString): Boolean;
var
  w, h, y, x, fw, caret, ofs, ch, focus, n: Integer;
  u: AnsiString;
  me: MEVENT;
  okX, cancelX, by: Integer;

  procedure Draw;
  var
    vis: AnsiString;
  begin
    Base;
    DrawBox(y, x, h, w, Title);
    PutStr(y + 1, x + 2, Prompt, cpMenuBar);
    if caret < ofs then ofs := caret;
    if caret - ofs >= fw then ofs := caret - fw + 1;
    vis := Utf8PadRight(Utf8Copy(Value, ofs + 1, fw), fw);
    PutStr(y + 2, x + 2, vis, cpInput);
    if focus = 0 then  // visible caret cell
      PutStr(y + 2, x + 2 + caret - ofs,
             Utf8Copy(vis + ' ', caret - ofs + 1, 1), cpFKeyNum);
    if focus = 1 then PutStr(by, okX, '[ OK ]', cpMenuSel)
    else PutStr(by, okX, '[ OK ]', cpMenuBar);
    if focus = 2 then PutStr(by, cancelX, '[ Cancel ]', cpMenuSel)
    else PutStr(by, cancelX, '[ Cancel ]', cpMenuBar);
    refresh;
  end;

begin
  Result := False;
  w := 50;
  if w > COLS - 4 then w := COLS - 4;
  fw := w - 4;
  h := 6;
  y := (LINES - h) div 2;
  x := (COLS - w) div 2;
  by := y + 4;
  okX := x + w div 2 - 10;
  cancelX := x + w div 2 - 1;
  caret := Utf8Len(Value);
  ofs := 0;
  focus := 0;

  repeat
    Draw;
    ch := getch;
    case ch of
      ERR: ;
      10, 13, KEY_ENTER:
        Exit(focus <> 2);
      27: Exit(False);
      9: focus := (focus + 1) mod 3;
      KEY_MOUSE:
        if getmouse(@me) = OK then
          if (me.bstate and (mbtn1Clicked or mbtn1Pressed or mbtn1Double)) <> 0 then
          begin
            if (me.y = by) and (me.x >= okX) and (me.x < okX + 6) then Exit(True);
            if (me.y = by) and (me.x >= cancelX) and (me.x < cancelX + 10) then Exit(False);
            if (me.y = y + 2) and (me.x >= x + 2) and (me.x < x + 2 + fw) then
            begin
              focus := 0;
              caret := ofs + me.x - (x + 2);
              if caret > Utf8Len(Value) then caret := Utf8Len(Value);
            end;
          end;
      KEY_LEFT: if (focus = 0) and (caret > 0) then Dec(caret);
      KEY_RIGHT: if (focus = 0) and (caret < Utf8Len(Value)) then Inc(caret);
      KEY_HOME: caret := 0;
      KEY_END: caret := Utf8Len(Value);
      KEY_BACKSPACE, 127, 8:
        if (focus = 0) and (caret > 0) then
        begin
          Delete(Value, Utf8BytePos(Value, caret),
                 Utf8CharBytes(Value, Utf8BytePos(Value, caret)));
          Dec(caret);
        end;
      KEY_DC:
        if (focus = 0) and (caret < Utf8Len(Value)) then
          Delete(Value, Utf8BytePos(Value, caret + 1),
                 Utf8CharBytes(Value, Utf8BytePos(Value, caret + 1)));
    else
      if (focus = 0) and (ch >= 32) and (ch < 127) then
      begin
        Insert(Chr(ch), Value, Utf8BytePos(Value, caret + 1));
        Inc(caret);
      end
      else if (focus = 0) and (ch >= $C2) and (ch <= $F4) then
      begin
        { assemble a UTF-8 character (continuation bytes are queued) }
        u := Chr(ch);
        if (ch and $E0) = $C0 then n := 1
        else if (ch and $F0) = $E0 then n := 2
        else n := 3;
        timeout(50);
        while n > 0 do
        begin
          ch := getch;
          if (ch < $80) or (ch > $BF) then Break;
          u := u + Chr(ch);
          Dec(n);
        end;
        timeout(1000);
        Insert(u, Value, Utf8BytePos(Value, caret + 1));
        Inc(caret);
      end;
    end;
  until False;
end;

end.
