{ dndialog — modal DN-style dialogs: message box, input box, text viewer.
  All are ncurses-modal loops that repaint the screen via RedrawBase. }
unit dndialog;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnoptions, dnvfs;

{ Returns pressed button index, or -1 on Esc. Message lines split by #10. }
function MsgBox(const Title, Msg: AnsiString;
                const Buttons: array of AnsiString): Integer;

{ Line-input dialog. Returns True on OK; Value holds the edited text. }
function InputBox(const Title, Prompt: AnsiString;
                  var Value: AnsiString): Boolean;

{ InputBox that shows '*' for every character typed (passwords) }
function PasswordBox(const Title, Prompt: AnsiString;
                     var Value: AnsiString): Boolean;

{ Checkbox-list dialog ("[X] item" rows). Space or mouse toggles, Enter/OK
  accepts, Esc/Cancel leaves Flags untouched. Returns True on accept. }
function CheckListDialog(const Title: AnsiString;
                         const Items: array of AnsiString;
                         var Flags: array of Boolean): Boolean;

{ Highlight-groups editor: one row per group ("Color    masks").
  Space cycles the color, Enter edits the masks, Tab reaches OK/Cancel.
  Returns True on accept (Groups updated), False leaves Groups untouched. }
function HighlightDialog(var Groups: THlGroups): Boolean;

{ Modal list picker: arrows/digits/letters navigate, Enter picks, Esc
  cancels. Returns the chosen index or -1. A digit jumps to item 1..9;
  a letter jumps to the next item starting with it. }
function ListDialog(const Title: AnsiString; Items: TStrings;
                    StartCur: Integer = 0): Integer;

{ A list with action keys: arrows/mouse move the cursor, a key from Keys
  (10 = Enter, a double click is Enter) ends the dialog with Result True,
  Key set and Cur on the row; Esc returns False. Works on an empty list
  too (Cur = 0, for keys like Ins). Hint is shown under the rows. }
function KeyListDialog(const Title, Hint: AnsiString; Items: TStrings;
                       const Keys: array of LongInt; var Cur: Integer;
                       out Key: LongInt): Boolean;

type
  TFormKind = (fkText, fkChoice, fkCheck);
  TFormField = record
    Caption: AnsiString;
    Kind: TFormKind;
    Value: AnsiString;           // fkText
    Options: array of AnsiString; // fkChoice
    Index: Integer;              // fkChoice: the chosen option
    Checked: Boolean;            // fkCheck
    { fkChoice with Levels (one per option, 0 = top): a drop-down tree that
      Enter/Space/a click opens; Left/Right still step through the options }
    Levels: array of Integer;
  end;

{ A drop-down tree under (AY, AX), AW wide: Labels with their depth in
  Levels (an item followed by deeper ones is a branch). Up/Down move,
  Right/+ unfold, Left/- fold (on a child: fold its parent), Enter/Space
  pick, a letter jumps, Esc cancels. The branch holding Index starts
  unfolded. Returns True with Index set on a pick. }
function TreeDropDown(AY, AX, AW: Integer; const Labels: array of AnsiString;
                      const Levels: array of Integer; var Index: Integer): Boolean;

{ A form of several fields. Tab/Down and Shift-Tab/Up move between the
  fields and the buttons; a choice cycles with Left/Right/Space, a check
  box toggles with Space; typing edits a text field (Backspace, Ctrl-U
  clears). Enter accepts (on Cancel: cancels), Esc cancels. }
function FormDialog(const Title: AnsiString; var Fields: array of TFormField): Boolean;

{ Draw a message box and return at once (no key wait): the screen shows
  it while the caller does blocking work; the next redraw removes it. }
procedure InfoBox(const Title, Msg: AnsiString);

type
  { refills Items while a live list is open; True when they changed }
  TListRefresh = function(Items: TStrings): Boolean;

  { draws one preview frame into the inner rectangle (py,px,ph,pw) of a
    preview pane; called with the focused row Cur and every tick/repaint }
  TListPreview = procedure(Cur: Integer; py, px, ph, pw: Integer);

{ ListDialog whose items change while it is open: OnRefresh runs every
  TickMs and after each key. MinW keeps the box from jumping as rows come
  and go. The cursor stays on the same row index. When OnPreview is set,
  a preview pane PreviewW wide opens to the right of the list and OnPreview
  paints the focused row into it. When FootLabel is set, a numeric field
  with that label is drawn under the list; Tab moves the focus between the
  list and the field, digits edit it, and the result returns in FootValue
  (no nested dialog). }
function LiveListDialog(const Title: AnsiString; Items: TStrings;
                        OnRefresh: TListRefresh; TickMs, MinW: Integer;
                        StartCur: Integer = 0;
                        OnPreview: TListPreview = nil;
                        PreviewW: Integer = 0;
                        const FootLabel: AnsiString = '';
                        FootValue: PInteger = nil): Integer;

{ the progress box RunCapture shows for a slow external command: install
  with RunBusyHook := @BusyBox once the screen is up }
procedure BusyBox(const Busy: TRunBusy; var Cancel: Boolean);
{ the next BusyBox repaints the whole screen first (after a dialog drew
  over it) }
procedure BusyBoxRedraw;

implementation

uses
  SysUtils, Math, ncurses, dnscreen;

var
  InputMasked: Boolean = False;     // PasswordBox around InputBox
  BusyNeedsBase: Boolean = False;   // BusyBox repaints the screen first
  BusyLines: Integer = -1;          // the size BusyBox last drew at
  BusyCols: Integer = -1;

procedure Base;
begin
  if Assigned(RedrawBase) then RedrawBase();
end;

procedure SplitMsg(const Msg: AnsiString; L: TStringList);
begin
  L.Text := Msg;
end;

{ break every line wider than Cols: at the last space when there is one
  in the second half, else hard }
procedure WrapLines(L: TStringList; Cols: Integer);
var
  i, cut, k: Integer;
  s: AnsiString;
begin
  if Cols < 8 then Exit;
  i := 0;
  while i < L.Count do
  begin
    s := L[i];
    if Utf8Width(s) > Cols then
    begin
      cut := Cols;
      for k := Cols downto Cols div 2 do
        if Utf8Copy(s, k, 1) = ' ' then
        begin
          cut := k;
          Break;
        end;
      L[i] := TrimRight(Utf8Copy(s, 1, cut));
      L.Insert(i + 1, TrimLeft(Utf8Copy(s, cut + 1, MaxInt)));
    end;
    Inc(i);
  end;
end;

procedure DrawBox(y, x, h, w: Integer; const Title: AnsiString);
var
  i: Integer;
begin
  PutStr(y, x, bxSTL + Rep(bxSepH, w - 2) + bxSTR, cpDlgFrame);
  for i := 1 to h - 2 do
  begin
    PutStr(y + i, x, bxColV, cpDlgFrame);
    PutStr(y + i, x + 1, StringOfChar(' ', w - 2), cpDialog);
    PutStr(y + i, x + w - 1, bxColV, cpDlgFrame);
  end;
  PutStr(y + h - 1, x, bxSBL + Rep(bxSepH, w - 2) + bxSBR, cpDlgFrame);
  if Title <> '' then
    PutStr(y, x + (w - Length(Title) - 2) div 2, ' ' + Title + ' ', cpDlgFrame);
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
      PutStr(y + 1 + j, x + 2, L[j], cpDialog);
    cx := bx;
    SetLength(btnX, Length(Buttons));
    for j := 0 to High(Buttons) do
    begin
      cap := '[ ' + Buttons[j] + ' ]';
      btnX[j] := cx;
      if j = focus then
        PutStr(by, cx, cap, cpDlgBtnSel)
      else
        PutStr(by, cx, cap, cpDialog);
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
    WrapLines(L, w - 4);
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
          if (getmouse(@me) = OK) and not MouseIsRelease then
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

function CheckListDialog(const Title: AnsiString;
                         const Items: array of AnsiString;
                         var Flags: array of Boolean): Boolean;
var
  w, h, y, x, i, cur, focus, ch, by, okX, cancelX: Integer;
  tmp: array of Boolean;
  me: MEVENT;

  procedure Draw;
  var
    j, pair: Integer;
    mark: AnsiString;
  begin
    Base;
    DrawBox(y, x, h, w, Title);
    for j := 0 to High(Items) do
    begin
      if tmp[j] then mark := '[X] ' else mark := '[ ] ';
      if (focus = 0) and (j = cur) then pair := cpDlgSel else pair := cpDlgList;
      PutStr(y + 1 + j, x + 2, PadRight(mark + Items[j], w - 4), pair);
    end;
    if focus = 1 then PutStr(by, okX, '[ OK ]', cpDlgBtnSel)
    else PutStr(by, okX, '[ OK ]', cpDialog);
    if focus = 2 then PutStr(by, cancelX, '[ Cancel ]', cpDlgBtnSel)
    else PutStr(by, cancelX, '[ Cancel ]', cpDialog);
    refresh;
  end;

  procedure Accept;
  var
    j: Integer;
  begin
    for j := 0 to High(Flags) do
      Flags[j] := tmp[j];
  end;

begin
  Result := False;
  SetLength(tmp, Length(Flags));
  for i := 0 to High(Flags) do
    tmp[i] := Flags[i];
  w := 34;
  for i := 0 to High(Items) do
    if Length(Items[i]) + 8 > w then w := Length(Items[i]) + 8;
  if w > COLS - 4 then w := COLS - 4;
  h := Length(Items) + 4;
  y := (LINES - h) div 2;
  x := (COLS - w) div 2;
  by := y + h - 2;
  okX := x + w div 2 - 10;
  cancelX := x + w div 2 - 1;
  cur := 0;
  focus := 0;

  repeat
    Draw;
    ch := getch;
    case ch of
      ERR: ;
      10, 13, KEY_ENTER:
        begin
          if focus = 2 then Exit(False);
          Accept;
          Exit(True);
        end;
      27: Exit(False);
      9: focus := (focus + 1) mod 3;
      KEY_UP:
        if focus = 0 then cur := (cur + High(Items)) mod Length(Items)
        else focus := 0;
      KEY_DOWN:
        if focus = 0 then cur := (cur + 1) mod Length(Items);
      32:
        if focus = 0 then tmp[cur] := not tmp[cur];
      KEY_MOUSE:
        if getmouse(@me) = OK then
          if (me.bstate and (mbtn1Clicked or mbtn1Pressed or mbtn1Double)) <> 0 then
          begin
            if (me.y = by) and (me.x >= okX) and (me.x < okX + 6) then
            begin
              Accept;
              Exit(True);
            end;
            if (me.y = by) and (me.x >= cancelX) and (me.x < cancelX + 10) then
              Exit(False);
            if (me.y >= y + 1) and (me.y <= y + Length(Items)) and
               (me.x >= x + 2) and (me.x < x + w - 2) then
            begin
              focus := 0;
              cur := me.y - (y + 1);
              tmp[cur] := not tmp[cur];
            end;
          end;
    end;
  until False;
end;

function HighlightDialog(var Groups: THlGroups): Boolean;
var
  w, h, y, x, i, cur, focus, ch, by, okX, cancelX: Integer;
  tmp: THlGroups;
  m: AnsiString;
  me: MEVENT;

  procedure Draw;
  var
    j, pair: Integer;
    row: AnsiString;
  begin
    Base;
    DrawBox(y, x, h, w, 'Highlight groups');
    for j := 1 to HlGroupCount do
    begin
      if (focus = 0) and (j - 1 = cur) then pair := cpDlgSel else pair := cpDlgList;
      row := PadRight(HlColorNames[tmp[j].Color], 9) + tmp[j].Mask;
      PutStr(y + j, x + 2, PadRight(row, w - 4), pair);
    end;
    PutStr(y + HlGroupCount + 1, x + 2,
           PadRight(' Space = color, Enter = edit masks', w - 4), cpDialog);
    if focus = 1 then PutStr(by, okX, '[ OK ]', cpDlgBtnSel)
    else PutStr(by, okX, '[ OK ]', cpDialog);
    if focus = 2 then PutStr(by, cancelX, '[ Cancel ]', cpDlgBtnSel)
    else PutStr(by, cancelX, '[ Cancel ]', cpDialog);
    refresh;
  end;

  procedure CycleColor(j: Integer);
  begin
    tmp[j].Color := tmp[j].Color mod 7 + 1;
  end;

begin
  Result := False;
  tmp := Groups;
  w := 56;
  if w > COLS - 4 then w := COLS - 4;
  h := HlGroupCount + 5;    // rows + hint + buttons + borders
  y := (LINES - h) div 2;
  x := (COLS - w) div 2;
  by := y + h - 2;
  okX := x + w div 2 - 10;
  cancelX := x + w div 2 - 1;
  cur := 0;
  focus := 0;

  repeat
    Draw;
    ch := getch;
    case ch of
      ERR: ;
      10, 13, KEY_ENTER:
        case focus of
          0: begin
               m := tmp[cur + 1].Mask;
               if InputBox('Masks for ' + HlColorNames[tmp[cur + 1].Color],
                           'File masks (empty = off):', m) then
                 tmp[cur + 1].Mask := Trim(m);
             end;
          1: begin
               Groups := tmp;
               Exit(True);
             end;
          2: Exit(False);
        end;
      27: Exit(False);
      9: focus := (focus + 1) mod 3;
      KEY_UP:
        if focus = 0 then cur := (cur + HlGroupCount - 1) mod HlGroupCount
        else focus := 0;
      KEY_DOWN:
        if focus = 0 then cur := (cur + 1) mod HlGroupCount;
      32:
        if focus = 0 then CycleColor(cur + 1);
      KEY_MOUSE:
        if getmouse(@me) = OK then
          if (me.bstate and (mbtn1Clicked or mbtn1Pressed or mbtn1Double)) <> 0 then
          begin
            if (me.y = by) and (me.x >= okX) and (me.x < okX + 6) then
            begin
              Groups := tmp;
              Exit(True);
            end;
            if (me.y = by) and (me.x >= cancelX) and (me.x < cancelX + 10) then
              Exit(False);
            if (me.y >= y + 1) and (me.y <= y + HlGroupCount) and
               (me.x >= x + 2) and (me.x < x + w - 2) then
            begin
              focus := 0;
              cur := me.y - (y + 1);
              CycleColor(cur + 1);   // click = cycle the row's color
            end;
          end;
    end;
  until False;
end;

function LiveListDialog(const Title: AnsiString; Items: TStrings;
                        OnRefresh: TListRefresh; TickMs, MinW: Integer;
                        StartCur: Integer; OnPreview: TListPreview;
                        PreviewW: Integer; const FootLabel: AnsiString;
                        FootValue: PInteger): Integer;
var
  w, h, y, x, cur, top, ch, rows: Integer;
  listW, pvW, pvX, pvY, pvH, pvInnerW: Integer;
  footRow, footVal, footFocus, footEdit, fw, cx, k: Integer;
  footText: AnsiString;
  footBtns: array[0..1] of AnsiString;
  me: MEVENT;

  function HasFoot: Boolean;
  begin
    Result := (FootLabel <> '') and (FootValue <> nil);
  end;

  function FootCell: AnsiString;
  begin
    Result := FootLabel + ' ' + footText;
  end;

  procedure Draw;
  var
    j, idx, pair, fx, kk: Integer;
    s: AnsiString;
  begin
    Base;
    DrawBox(y, x, h, w, Title);
    for j := 0 to rows - 1 do
    begin
      idx := top + j;
      if idx >= Items.Count then
      begin
        PutStr(y + 1 + j, x + 2, StringOfChar(' ', listW - 4), cpDlgList);
        Continue;
      end;
      if (idx = cur) and (footFocus = 0) then pair := cpDlgSel
      else pair := cpDlgList;
      PutStr(y + 1 + j, x + 2, Utf8PadRight(' ' + Items[idx] + ' ', listW - 4), pair);
    end;
    if Assigned(OnPreview) and (pvW > 0) then
    begin
      DrawBox(pvY, pvX, pvH, pvW, '');
      OnPreview(cur, pvY + 1, pvX + 1, pvH - 2, pvInnerW);
    end;
    if HasFoot then
    begin
      { the numeric field looks like an input: label, then an underlined
        value box with a visible caret cell }
      PutStr(footRow, x + 2, Utf8PadRight(' ' + FootLabel, listW - 4),
             cpDialog);
      fx := x + 2 + Utf8Width(FootLabel) + 2;
      fw := listW - 4 - (Utf8Width(FootLabel) + 2);
      if fw < 4 then fw := 4;
      if footFocus = 1 then pair := cpDlgSel else pair := cpInput;
      PutStr(footRow, fx, Utf8PadRight(' ' + footText, fw), pair);
      if footFocus = 1 then
        PutStr(footRow, fx + 1 + footEdit, ' ', cpCursor);
      { the dialog buttons: [ OK ] [ Cancel ] }
      cx := x + 2;
      for kk := 0 to High(footBtns) do
      begin
        if footFocus = 2 + kk then pair := cpDlgBtnSel else pair := cpDialog;
        PutStr(footRow + 1, cx, '[ ' + footBtns[kk] + ' ]', pair);
        Inc(cx, Length(footBtns[kk]) + 6);
      end;
    end;
    refresh;
  end;

  procedure Layout;
  var
    j: Integer;
  begin
    listW := MinW;
    if listW < 24 then listW := 24;
    for j := 0 to Items.Count - 1 do
      if Utf8Len(Items[j]) + 6 > listW then listW := Utf8Len(Items[j]) + 6;
    { the field row needs room for the label, a value and the cursor }
    if HasFoot and (Utf8Width(FootLabel) + 12 > listW) then
      listW := Utf8Width(FootLabel) + 12;
    if listW > COLS - 4 then listW := COLS - 4;
    rows := Items.Count;
    if rows > LINES - 9 then rows := LINES - 9;
    if rows < 1 then rows := 1;
    h := rows + 2;
    if HasFoot then Inc(h, 2);         // the field row and the button row
    pvW := 0;
    pvH := 0;
    if Assigned(OnPreview) then
    begin
      { the preview pane needs real room: it takes PreviewW columns, but
        shrinks to whatever is left beside the list, and is dropped only
        when fewer than 16 columns remain }
      pvW := PreviewW;
      if pvW < 20 then pvW := 20;
      if listW + pvW + 3 > COLS - 4 then
        pvW := COLS - 4 - listW - 3;
      if pvW < 16 then pvW := 0;
    end;
    if pvW > 0 then
    begin
      w := listW + pvW + 3;
      pvH := h - 2;
      if HasFoot then Dec(pvH, 2);     // the field and button rows sit under
      if pvH > 12 then pvH := 12;
      if pvH < 4 then pvH := 4;
      if pvH + 2 > h then h := pvH + 2;
      if HasFoot and (h < rows + 4) then h := rows + 4;
      pvX := x + listW + 2;
      pvY := y + 1;
      pvInnerW := pvW - 2;
    end
    else
      w := listW;
    if w > COLS - 4 then w := COLS - 4;
    y := (LINES - h) div 2;
    x := (COLS - w) div 2;
    if pvW > 0 then
    begin
      pvX := x + listW + 2;
      pvY := y + 1;
    end;
    footRow := y + h - 3;
    if cur >= Items.Count then cur := Items.Count - 1;
    if cur < 0 then cur := 0;
  end;

  procedure Jump(c: Char);
  var
    j, idx: Integer;
  begin
    for j := 1 to Items.Count do
    begin
      idx := (cur + j) mod Items.Count;
      if (Items[idx] <> '') and (UpCase(Items[idx][1]) = UpCase(c)) then
      begin
        cur := idx;
        Exit;
      end;
    end;
  end;

begin
  Result := -1;
  if Items.Count = 0 then Exit;
  cur := StartCur;
  if (cur < 0) or (cur >= Items.Count) then cur := 0;
  top := 0;
  footFocus := 0;
  footEdit := 0;
  footBtns[0] := 'OK';
  footBtns[1] := 'Cancel';
  if HasFoot then
  begin
    footVal := FootValue^;
    if footVal < 0 then footVal := 0;
    footText := IntToStr(footVal);
  end;
  { the tick drives both a live list and a live preview: without a timeout
    a preview-only dialog would repaint only on a key }
  if Assigned(OnRefresh) or Assigned(OnPreview) then timeout(TickMs);

  repeat
    { refresh before drawing, never between a draw and its key: Enter
      picks the row the user saw }
    if Assigned(OnRefresh) then
    begin
      OnRefresh(Items);
      timeout(TickMs);      // a nested dialog may have changed it
    end;
    if Items.Count = 0 then Exit(-1);
    Layout;
    if cur < top then top := cur;
    if cur >= top + rows then top := cur - rows + 1;
    if top > Items.Count - rows then top := Items.Count - rows;
    if top < 0 then top := 0;
    Draw;
    ch := getch;
    { a mouse click is handled the same at any focus: on the field it
      focuses and edits, on a button it accepts or cancels }
    if (ch = KEY_MOUSE) and (getmouse(@me) = OK) and
       ((me.bstate and (mbtn1Clicked or mbtn1Pressed or mbtn1Double)) <> 0) then
    begin
      { a click on a list row selects it (and picks it without a preview) }
      if (me.y >= y + 1) and (me.y < y + 1 + rows) and
         (me.x >= x) and (me.x < x + listW) and
         (top + me.y - (y + 1) < Items.Count) then
      begin
        cur := top + me.y - (y + 1);
        footFocus := 0;
        if (me.bstate and mbtn1Double) <> 0 then Exit(cur);
        if Assigned(OnPreview) then
        begin
          Layout;
          if cur < top then top := cur;
          if cur >= top + rows then top := cur - rows + 1;
          Draw;
          Continue;
        end;
        Exit(cur);
      end
      else if HasFoot and (me.y = footRow) and
              (me.x >= x + 2) and (me.x < x + listW - 2) then
      begin
        footFocus := 1;
        footEdit := Length(footText);
      end
      else if (Assigned(OnPreview)) and (pvW > 0) and
              (me.y >= pvY) and (me.y < pvY + pvH) and
              (me.x >= pvX) and (me.x < pvX + pvW) then
        { a click in the preview pane: keep the dialog open }
      else if HasFoot and (me.y = footRow + 1) then
      begin
        cx := x + 2;
        for k := 0 to High(footBtns) do
        begin
          if (me.x >= cx) and (me.x < cx + Length(footBtns[k]) + 4) then
          begin
            if k = 0 then
            begin
              footVal := StrToIntDef(footText, footVal);
              FootValue^ := footVal;
              Exit(cur);
            end
            else
              Exit(-1);
          end;
          Inc(cx, Length(footBtns[k]) + 6);
        end;
        Exit(-1);
      end;
      Continue;
    end;
    if HasFoot and (footFocus = 1) then
    begin
      case ch of
        ERR: ;
        10, 13, KEY_ENTER:
          begin
            footVal := StrToIntDef(footText, footVal);
            FootValue^ := footVal;
            Exit(cur);
          end;
        27: Exit(-1);
        9: footFocus := 2;              // Tab: to the buttons
        8, 127, KEY_BACKSPACE:
          begin
            if footText <> '' then
              Delete(footText, Length(footText), 1);
            if footText = '' then footText := '0';
            footEdit := Length(footText);
          end;
        KEY_LEFT: if footEdit > 0 then Dec(footEdit);
        KEY_RIGHT: if footEdit < Length(footText) then Inc(footEdit);
      else
        if (ch >= Ord('0')) and (ch <= Ord('9')) then
        begin
          if (Length(footText) < 4) and not ((footText = '0') and (ch = Ord('0'))) then
          begin
            if footText = '0' then footText := '';
            footText := footText + Chr(ch);
          end;
          footEdit := Length(footText);
        end;
      end;
      Continue;
    end;
    if HasFoot and (footFocus >= 2) then
    begin
      case ch of
        9, KEY_RIGHT, KEY_LEFT:        // Tab / arrows cycle the buttons
          footFocus := 2 + ((footFocus - 2 + 1) mod Length(footBtns));
        10, 13, KEY_ENTER, 32:
          if footFocus = 2 then
          begin
            footVal := StrToIntDef(footText, footVal);
            FootValue^ := footVal;
            Exit(cur);
          end
          else
            Exit(-1);
        27: Exit(-1);
      end;
      Continue;
    end;
    case ch of
      ERR: ;
      10, 13, KEY_ENTER: Exit(cur);
      27: Exit(-1);
      9:
        if HasFoot then
        begin
          footFocus := 1;
          footEdit := Length(footText);
        end;
      KEY_UP: cur := (cur + Items.Count - 1) mod Items.Count;
      KEY_DOWN: cur := (cur + 1) mod Items.Count;
      KEY_HOME: cur := 0;
      KEY_END: cur := Items.Count - 1;
      KEY_MOUSE: ;   { handled above, before the focus branches }
    else
      if (ch >= Ord('1')) and (ch <= Ord('9')) and
         (ch - Ord('1') < Items.Count) then
        Exit(ch - Ord('1'))
      else if ((ch >= Ord('a')) and (ch <= Ord('z'))) or
              ((ch >= Ord('A')) and (ch <= Ord('Z'))) then
        Jump(Chr(ch));
    end;
  until False;
end;

{ --- progress box for external commands (dnvfs.RunBusyHook) ------------ }

procedure BusyBoxRedraw;
begin
  BusyNeedsBase := True;
end;

procedure BusyBox(const Busy: TRunBusy; var Cancel: Boolean);
const
  W = 56;
  Seg = 8;                     // the moving block of an unknown-length bar
var
  y, x, bw, fill, pos, i, ch, saved: Integer;
  bar, info, secs: AnsiString;
begin
  { keys first: Esc cancels, a resize means the screen under the box is
    gone; every other key is dropped while the command runs }
  saved := CurrentTimeout;
  timeout(0);
  repeat
    ch := getch;
    if ch = 27 then Cancel := True;
    if ch = KEY_RESIZE then BusyNeedsBase := True;
  until ch = ERR;
  timeout(saved);
  if (LINES <> BusyLines) or (COLS <> BusyCols) then BusyNeedsBase := True;
  if BusyNeedsBase then
  begin
    Base;                      // the whole screen again, at the new size
    BusyNeedsBase := False;
    BusyLines := LINES;
    BusyCols := COLS;
  end;
  y := (LINES - 5) div 2;
  x := (COLS - W) div 2;
  if x < 0 then x := 0;
  DrawBox(y, x, 5, W, Busy.Title);
  PutStr(y + 1, x + 2, Utf8PadRight(' ' + Busy.Detail, W - 4), cpDialog);

  bw := W - 6;
  if Busy.Percent >= 0 then
  begin
    fill := (bw * Busy.Percent) div 100;
    if fill > bw then fill := bw;
    bar := Rep('█', fill) + Rep('░', bw - fill);
  end
  else
  begin
    { no percentage: a block sweeps back and forth, one cell per tick }
    pos := (Busy.ElapsedMs div RunBusyTickMs) mod (2 * (bw - Seg));
    if pos > bw - Seg then pos := 2 * (bw - Seg) - pos;
    bar := '';
    for i := 0 to bw - 1 do
      if (i >= pos) and (i < pos + Seg) then bar := bar + '█'
      else bar := bar + '░';
  end;
  PutStr(y + 2, x + 3, bar, cpDialog);

  secs := IntToStr(Busy.ElapsedMs div 1000) + ' s';
  info := '';
  if Busy.Percent >= 0 then
    info := IntToStr(Busy.Percent) + '%  ';
  if Busy.CountWhat <> '' then
    info := info + IntToStr(Busy.Lines) + ' ' + Busy.CountWhat + '  ';
  info := info + secs;
  PutStr(y + 3, x + 2, Utf8PadRight(' ' + info, W - 4 - 12) +
         Utf8PadRight('Esc cancel', 12), cpDialog);
  refresh;
end;

function KeyListDialog(const Title, Hint: AnsiString; Items: TStrings;
                       const Keys: array of LongInt; var Cur: Integer;
                       out Key: LongInt): Boolean;
var
  w, h, y, x, i, top, ch, rows: Integer;
  me: MEVENT;

  procedure Draw;
  var
    j, idx, pair: Integer;
    s: AnsiString;
  begin
    Base;
    DrawBox(y, x, h, w, Title);
    for j := 0 to rows - 1 do
    begin
      idx := top + j;
      if idx < Items.Count then s := ' ' + Items[idx] + ' ' else s := '';
      if (idx = Cur) and (Items.Count > 0) then pair := cpDlgSel
      else pair := cpDlgList;
      PutStr(y + 1 + j, x + 2, Utf8PadRight(s, w - 4), pair);
    end;
    PutStr(y + h - 2, x + 2, Utf8PadRight(' ' + Hint, w - 4), cpDialog);
    refresh;
  end;

  function IsActionKey(k: LongInt): Boolean;
  var
    j: Integer;
  begin
    for j := 0 to High(Keys) do
      if Keys[j] = k then Exit(True);
    Result := False;
  end;

begin
  Result := False;
  Key := 0;
  w := Utf8Width(Hint) + 6;
  if w < 50 then w := 50;
  for i := 0 to Items.Count - 1 do
    if Utf8Width(Items[i]) + 6 > w then w := Utf8Width(Items[i]) + 6;
  if w > COLS - 4 then w := COLS - 4;
  rows := Items.Count;
  if rows < 1 then rows := 1;
  if rows > LINES - 8 then rows := LINES - 8;
  h := rows + 3;                      // the hint line under the rows
  y := (LINES - h) div 2;
  x := (COLS - w) div 2;
  if Cur >= Items.Count then Cur := Items.Count - 1;
  if Cur < 0 then Cur := 0;
  top := 0;
  repeat
    if Cur < top then top := Cur;
    if Cur >= top + rows then top := Cur - rows + 1;
    Draw;
    ch := getch;
    case ch of
      ERR: ;
      27: Exit(False);
      KEY_UP: if Cur > 0 then Dec(Cur);
      KEY_DOWN: if Cur < Items.Count - 1 then Inc(Cur);
      KEY_HOME: Cur := 0;
      KEY_END: Cur := Items.Count - 1;
      KEY_PPAGE: begin Dec(Cur, rows); if Cur < 0 then Cur := 0; end;
      KEY_NPAGE:
        begin
          Inc(Cur, rows);
          if Cur > Items.Count - 1 then Cur := Items.Count - 1;
        end;
      KEY_MOUSE:
        if (getmouse(@me) = OK) and
           ((me.bstate and (mbtn1Clicked or mbtn1Pressed or mbtn1Double)) <> 0) then
        begin
          if (me.y >= y + 1) and (me.y < y + 1 + rows) and
             (top + me.y - (y + 1) < Items.Count) then
          begin
            Cur := top + me.y - (y + 1);
            if (me.bstate and mbtn1Double) <> 0 then
            begin
              Key := 10;
              Exit(True);
            end;
          end
          else if not ((me.x >= x) and (me.x < x + w) and (me.y >= y) and
                       (me.y < y + h)) then
            Exit(False);
        end;
    else
      begin
        if (ch = 13) or (ch = KEY_ENTER) then ch := 10;
        if IsActionKey(ch) then
        begin
          Key := ch;
          Exit(True);
        end;
      end;
    end;
  until False;
end;

function TreeDropDown(AY, AX, AW: Integer; const Labels: array of AnsiString;
                      const Levels: array of Integer; var Index: Integer): Boolean;
var
  open: array of Boolean;        // per item: a parent row that shows its children
  vis: array of Integer;         // the visible rows -> item index
  cur, top, rows, h, y, x, w, ch, i, k, maxRows: Integer;
  below: Boolean;
  me: MEVENT;

  function HasKids(i2: Integer): Boolean;
  begin
    Result := (i2 < High(Labels)) and (Levels[i2 + 1] > Levels[i2]);
  end;

  function ParentOf(i2: Integer): Integer;
  begin
    Result := i2 - 1;
    while (Result >= 0) and (Levels[Result] >= Levels[i2]) do Dec(Result);
  end;

  procedure Rebuild;
  var
    j, hide: Integer;
  begin
    SetLength(vis, 0);
    hide := MaxInt;                  // children deeper than this are folded
    for j := 0 to High(Labels) do
    begin
      if Levels[j] > hide then Continue;
      hide := MaxInt;
      SetLength(vis, Length(vis) + 1);
      vis[High(vis)] := j;
      if HasKids(j) and not open[j] then hide := Levels[j];
    end;
  end;

  function VisPos(item: Integer): Integer;
  var
    j: Integer;
  begin
    for j := 0 to High(vis) do
      if vis[j] = item then Exit(j);
    Result := 0;
  end;

  procedure Draw;
  var
    j, it, pair: Integer;
    s, mark: AnsiString;
  begin
    DrawBox(y, x, h, w, '');
    for j := 0 to rows - 1 do
    begin
      if top + j > High(vis) then
      begin
        PutStr(y + 1 + j, x + 1, StringOfChar(' ', w - 2), cpDlgList);
        Continue;
      end;
      it := vis[top + j];
      if HasKids(it) then
      begin
        if open[it] then mark := '▾ ' else mark := '▸ ';
      end
      else
        mark := '  ';
      s := StringOfChar(' ', Levels[it] * 2) + mark + Labels[it];
      if top + j = cur then pair := cpDlgSel else pair := cpDlgList;
      PutStr(y + 1 + j, x + 1, Utf8PadRight(s, w - 2), pair);
    end;
    refresh;
  end;

  procedure Fit;
  var
    want: Integer;
  begin
    want := Length(vis);
    if want > maxRows then want := maxRows;
    if want > rows then rows := want;        // grow, never shrink
    h := rows + 2;
    if below then y := AY else y := AY - 1 - h;
    if y < 0 then y := 0;
  end;

  procedure Jump(c: Char);
  var
    j, it: Integer;
  begin
    for j := 1 to Length(vis) do
    begin
      it := vis[(cur + j) mod Length(vis)];
      if (Labels[it] <> '') and (UpCase(Labels[it][1]) = UpCase(c)) then
      begin
        cur := (cur + j) mod Length(vis);
        Exit;
      end;
    end;
  end;

begin
  Result := False;
  if Length(Labels) = 0 then Exit;
  SetLength(open, Length(Labels));
  { open the branch that holds the current choice }
  for i := 0 to High(open) do open[i] := False;
  if (Index >= 0) and (Index <= High(Labels)) then
  begin
    k := ParentOf(Index);
    while k >= 0 do
    begin
      open[k] := True;
      k := ParentOf(k);
    end;
  end;
  Rebuild;
  cur := VisPos(Index);
  w := AW;
  if w > COLS - 2 then w := COLS - 2;
  if w < 20 then w := 20;
  x := AX;
  if x + w > COLS then x := COLS - w;
  if x < 0 then x := 0;
  { under the field (AY) when 6 rows fit there, else above it; maxRows is
    the room, rows starts at what is visible and only grows (unfolding) }
  below := LINES - 1 - AY - 2 >= 6;
  if below then maxRows := LINES - 1 - AY - 2 else maxRows := AY - 1 - 2;
  if maxRows > 16 then maxRows := 16;
  if maxRows < 3 then maxRows := 3;
  rows := 0;
  Fit;
  top := 0;
  repeat
    if cur > High(vis) then cur := High(vis);
    if cur < 0 then cur := 0;
    if cur < top then top := cur;
    if cur >= top + rows then top := cur - rows + 1;
    if top > Length(vis) - rows then top := Length(vis) - rows;
    if top < 0 then top := 0;
    Draw;
    ch := getch;
    case ch of
      ERR: ;
      27: Exit(False);
      KEY_UP: if cur > 0 then Dec(cur);
      KEY_DOWN: if cur < High(vis) then Inc(cur);
      KEY_PPAGE: Dec(cur, rows);
      KEY_NPAGE: Inc(cur, rows);
      KEY_HOME: cur := 0;
      KEY_END: cur := High(vis);
      KEY_RIGHT, Ord('+'):
        if HasKids(vis[cur]) and not open[vis[cur]] then
        begin
          k := vis[cur];
          open[k] := True;
          Rebuild;
          Fit;
          cur := VisPos(k);
        end;
      KEY_LEFT, Ord('-'):
        begin
          k := vis[cur];
          if HasKids(k) and open[k] then open[k] := False
          else if ParentOf(k) >= 0 then
          begin
            k := ParentOf(k);       // on a child: fold its parent, stand on it
            open[k] := False;
          end;
          Rebuild;
          cur := VisPos(k);
        end;
      10, 13, KEY_ENTER, 32:
        begin
          Index := vis[cur];
          Exit(True);
        end;
      KEY_MOUSE:
        if (getmouse(@me) = OK) and
           ((me.bstate and (mbtn1Clicked or mbtn1Pressed or mbtn1Double)) <> 0) then
        begin
          if (me.y > y) and (me.y < y + h - 1) and (me.x > x) and (me.x < x + w - 1) and
             (top + me.y - y - 1 <= High(vis)) then
          begin
            cur := top + me.y - y - 1;
            k := vis[cur];
            { a click on the ▸/▾ mark folds, elsewhere it picks }
            if HasKids(k) and (me.x - x - 1 <= Levels[k] * 2 + 1) then
            begin
              open[k] := not open[k];
              Rebuild;
              Fit;
              cur := VisPos(k);
            end
            else
            begin
              Index := k;
              Exit(True);
            end;
          end
          else
            Exit(False);
        end;
    else
      if (ch >= 32) and (ch < 127) then Jump(Chr(ch));
    end;
  until False;
end;

function FormDialog(const Title: AnsiString; var Fields: array of TFormField): Boolean;
var
  w, h, y, x, i, cur, ch, lw, fw, n: Integer;
  me: MEVENT;
  okX, cancelX, by: Integer;
  u: AnsiString;

  function IsDrop(j: Integer): Boolean;
  begin
    Result := (Fields[j].Kind = fkChoice) and (Length(Fields[j].Levels) > 0) and
              (Length(Fields[j].Levels) = Length(Fields[j].Options));
  end;

  procedure Draw;
  var
    j, fy: Integer;
    v, caretCell: AnsiString;
    pair: Integer;
  begin
    Base;
    DrawBox(y, x, h, w, Title);
    for j := 0 to High(Fields) do
    begin
      fy := y + 1 + j;
      PutStr(fy, x + 2, Utf8PadRight(Fields[j].Caption, lw), cpDialog);
      case Fields[j].Kind of
        fkText:
          begin
            v := Fields[j].Value;
            { show the tail when the text is wider than the field }
            if Utf8Width(v) > fw - 1 then
              v := Utf8Copy(v, Utf8Len(v) - (fw - 2) + 1, fw - 1);
            PutStr(fy, x + 2 + lw, Utf8PadRight(v, fw), cpInput);
            if j = cur then
            begin
              caretCell := ' ';
              PutStr(fy, x + 2 + lw + Utf8Width(v), caretCell, cpCursor);
            end;
          end;
        fkChoice:
          begin
            v := '';
            if (Fields[j].Index >= 0) and (Fields[j].Index <= High(Fields[j].Options)) then
              v := Fields[j].Options[Fields[j].Index];
            if j = cur then pair := cpDlgSel else pair := cpInput;
            if IsDrop(j) then
              PutStr(fy, x + 2 + lw, Utf8PadRight(' ' + v, fw - 2) + '▾ ', pair)
            else
              PutStr(fy, x + 2 + lw, Utf8PadRight('< ' + v + ' >', fw), pair);
          end;
        fkCheck:
          begin
            if Fields[j].Checked then v := '[x]' else v := '[ ]';
            if j = cur then pair := cpDlgSel else pair := cpDialog;
            PutStr(fy, x + 2 + lw, v, pair);
            PutStr(fy, x + 5 + lw, StringOfChar(' ', fw - 3), cpDialog);
          end;
      end;
    end;
    if cur = n then PutStr(by, okX, '[ OK ]', cpDlgBtnSel)
    else PutStr(by, okX, '[ OK ]', cpDialog);
    if cur = n + 1 then PutStr(by, cancelX, '[ Cancel ]', cpDlgBtnSel)
    else PutStr(by, cancelX, '[ Cancel ]', cpDialog);
    refresh;
  end;

  procedure DropDown(j: Integer);
  var
    k: Integer;
  begin
    k := Fields[j].Index;
    if TreeDropDown(y + 2 + j, x + 2 + lw, fw, Fields[j].Options, Fields[j].Levels, k) then
      Fields[j].Index := k;
  end;

  procedure Cycle(d: Integer);
  var
    k: Integer;
  begin
    case Fields[cur].Kind of
      fkChoice:
        begin
          k := Length(Fields[cur].Options);
          if k > 0 then
            Fields[cur].Index := (Fields[cur].Index + d + k) mod k;
        end;
      fkCheck: Fields[cur].Checked := not Fields[cur].Checked;
    end;
  end;

begin
  Result := False;
  n := Length(Fields);
  lw := 0;
  for i := 0 to n - 1 do
    if Utf8Width(Fields[i].Caption) + 1 > lw then lw := Utf8Width(Fields[i].Caption) + 1;
  w := 72;
  if w > COLS - 4 then w := COLS - 4;
  fw := w - 4 - lw;
  h := n + 4;
  y := (LINES - h) div 2;
  x := (COLS - w) div 2;
  by := y + h - 2;
  okX := x + w div 2 - 10;
  cancelX := okX + 9;
  cur := 0;
  repeat
    Draw;
    ch := getch;
    case ch of
      ERR: ;
      27: Exit(False);
      9, KEY_DOWN: cur := (cur + 1) mod (n + 2);
      KEY_BTAB, KEY_UP: cur := (cur + n + 1) mod (n + 2);
      10, 13, KEY_ENTER:
        begin
          if (cur < n) and IsDrop(cur) then
            DropDown(cur)                 // Enter on a drop-down opens it
          else
          begin
            if cur = n + 1 then Exit(False);
            Exit(True);
          end;
        end;
      KEY_LEFT: if (cur < n) and (Fields[cur].Kind = fkChoice) then Cycle(-1);
      KEY_RIGHT: if (cur < n) and (Fields[cur].Kind = fkChoice) then Cycle(1);
      KEY_BACKSPACE, 127, 8:
        if (cur < n) and (Fields[cur].Kind = fkText) and (Fields[cur].Value <> '') then
        begin
          u := Fields[cur].Value;
          while (u <> '') and ((Ord(u[Length(u)]) and $C0) = $80) do
            SetLength(u, Length(u) - 1);
          SetLength(u, Length(u) - 1);
          Fields[cur].Value := u;
        end;
      21:                                 // Ctrl-U: clear the field
        if (cur < n) and (Fields[cur].Kind = fkText) then Fields[cur].Value := '';
      KEY_MOUSE:
        if (getmouse(@me) = OK) and
           ((me.bstate and (mbtn1Clicked or mbtn1Pressed)) <> 0) then
        begin
          if (me.y >= y + 1) and (me.y < y + 1 + n) then
          begin
            cur := me.y - y - 1;
            if IsDrop(cur) and (me.x >= x + 2 + lw) then DropDown(cur)
            else if (Fields[cur].Kind <> fkText) and (me.x >= x + 2 + lw) then Cycle(1);
          end
          else if me.y = by then
          begin
            if (me.x >= okX) and (me.x < okX + 6) then Exit(True);
            if (me.x >= cancelX) and (me.x < cancelX + 10) then Exit(False);
          end;
        end;
    else
      if (cur < n) and (ch = 32) and IsDrop(cur) then
        DropDown(cur)
      else if (cur < n) and (ch = 32) and (Fields[cur].Kind <> fkText) then
        Cycle(1)
      else if (cur < n) and (Fields[cur].Kind = fkText) and (ch >= 32) and (ch < 256) then
        Fields[cur].Value := Fields[cur].Value + Chr(ch);
    end;
  until False;
end;

procedure InfoBox(const Title, Msg: AnsiString);
var
  w, h, y, x: Integer;
begin
  w := Utf8Len(Msg) + 6;
  if w < Length(Title) + 8 then w := Length(Title) + 8;
  if w > COLS - 4 then w := COLS - 4;
  h := 3;
  y := (LINES - h) div 2;
  x := (COLS - w) div 2;
  Base;
  DrawBox(y, x, h, w, Title);
  PutStr(y + 1, x + 2, Utf8PadRight(' ' + Msg, w - 4), cpDialog);
  refresh;
end;

function ListDialog(const Title: AnsiString; Items: TStrings;
                    StartCur: Integer): Integer;
begin
  Result := LiveListDialog(Title, Items, nil, 0, 0, StartCur);
end;

function PasswordBox(const Title, Prompt: AnsiString;
                     var Value: AnsiString): Boolean;
begin
  InputMasked := True;
  try
    Result := InputBox(Title, Prompt, Value);
  finally
    InputMasked := False;
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
    PutStr(y + 1, x + 2, Prompt, cpDialog);
    if caret < ofs then ofs := caret;
    if caret - ofs >= fw then ofs := caret - fw + 1;
    if InputMasked then
      vis := Utf8PadRight(StringOfChar('*',
               Max(0, Min(fw, Utf8Len(Value) - ofs))), fw)
    else
      vis := Utf8PadRight(Utf8Copy(Value, ofs + 1, fw), fw);
    PutStr(y + 2, x + 2, vis, cpInput);
    if focus = 0 then  // visible caret cell
      PutStr(y + 2, x + 2 + caret - ofs,
             Utf8Copy(vis + ' ', caret - ofs + 1, 1), cpCursor);
    if focus = 1 then PutStr(by, okX, '[ OK ]', cpDlgBtnSel)
    else PutStr(by, okX, '[ OK ]', cpDialog);
    if focus = 2 then PutStr(by, cancelX, '[ Cancel ]', cpDlgBtnSel)
    else PutStr(by, cancelX, '[ Cancel ]', cpDialog);
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
