{ dnmenu — the pull-down menu bar. Keyboard: F9 opens, arrows navigate,
  Enter executes, Esc closes. Mouse: click a title to open, click an item
  to execute, click elsewhere to close. }
unit dnmenu;

{$mode objfpc}{$H+}

interface

const
  cmNone       = 0;
  cmQuit       = 1;
  cmRereadLeft = 2;
  cmRereadRight= 3;
  cmRereadAll  = 4;
  cmView       = 5;
  cmEdit       = 6;
  cmCopy       = 7;
  cmMove       = 8;
  cmMkDir      = 9;
  cmDelete     = 10;
  cmInvert     = 11;
  cmTetris     = 12;
  cmHelp       = 13;
  cmSortLeft   = 14;
  cmSortRight  = 15;
  cmFilterLeft = 16;
  cmFilterRight= 17;
  cmSessions   = 18;
  cmSftpConnect= 19;
  cmUUEncode   = 20;
  cmUUDecode   = 21;
  cmPanelSetup = 22;
  cmConfirmations = 23;
  cmColors     = 24;
  cmHighlight  = 25;
  cmUserMenu   = 26;
  cmMenuEditGlobal = 27;
  cmMenuEditLocal  = 28;
  cmColumnsLeft  = 29;
  cmColumnsRight = 30;
  cmSyntaxHl     = 31;
  cmSaverSetup   = 32;

procedure DrawBar(sel: Integer);
{ Modal menu loop; startSel = menu index to open (0-based), returns cm*. }
function RunMenuBar(startSel: Integer): Integer;
{ Menu index whose title covers bar column x, or -1. }
function TitleAt(x: Integer): Integer;
function MenuCount: Integer;

implementation

uses
  SysUtils, ncurses, dnscreen, dnoptions;

type
  TMenuItem = record
    Caption: AnsiString;   // '-' alone is never used; '' = disabled row
    Hotkey: AnsiString;
    Cmd: Integer;
  end;
  TMenu = record
    Title: AnsiString;
    X: Integer;
    Items: array of TMenuItem;
  end;

var
  Menus: array of TMenu;

procedure AddMenu(const Title: AnsiString);
begin
  SetLength(Menus, Length(Menus) + 1);
  Menus[High(Menus)].Title := Title;
end;

procedure AddItem(const Caption, Hotkey: AnsiString; Cmd: Integer);
var
  m: Integer;
begin
  m := High(Menus);
  SetLength(Menus[m].Items, Length(Menus[m].Items) + 1);
  Menus[m].Items[High(Menus[m].Items)].Caption := Caption;
  Menus[m].Items[High(Menus[m].Items)].Hotkey := Hotkey;
  Menus[m].Items[High(Menus[m].Items)].Cmd := Cmd;
end;

procedure InitMenus;
var
  i, x: Integer;
begin
  if Length(Menus) > 0 then Exit;
  AddMenu('Left');
  AddItem('Sort by...', 'Alt-S', cmSortLeft);
  AddItem('Filter...', '', cmFilterLeft);
  AddItem('Columns...', '', cmColumnsLeft);
  AddItem('Re-read', 'Ctrl-R', cmRereadLeft);
  AddMenu('Files');
  AddItem('View', 'F3', cmView);
  AddItem('Edit', 'F4', cmEdit);
  AddItem('Copy', 'F5', cmCopy);
  AddItem('Rename or move', 'F6', cmMove);
  AddItem('Make directory', 'F7', cmMkDir);
  AddItem('Delete', 'F8', cmDelete);
  AddItem('Invert selection', 'Ins', cmInvert);
  AddItem('Exit', 'F10', cmQuit);
  AddMenu('Disk');
  AddItem('SSH sessions...', 'Ctrl-S', cmSessions);
  AddItem('Connect sftp...', '', cmSftpConnect);
  AddMenu('Commands');
  AddItem('User menu', 'F2', cmUserMenu);
  AddItem('Re-read panels', 'Ctrl-R', cmRereadAll);
  AddItem('UU-encode file', 'Ctrl-F7', cmUUEncode);
  AddItem('UU-decode file', 'Ctrl-F8', cmUUDecode);
  AddMenu('Tools');
  AddItem('Tetris', 'Ctrl-T', cmTetris);
  AddMenu('Options');
  AddItem('Panel setup...', '', cmPanelSetup);
  AddItem('Confirmations...', '', cmConfirmations);
  AddItem('', '', cmNone);            // separator
  AddItem('Global menu definition...', '', cmMenuEditGlobal);
  AddItem('Local menu definition...', '', cmMenuEditLocal);
  AddItem('', '', cmNone);            // separator
  AddItem('Colors...', '', cmColors);
  AddItem('Highlight groups...', '', cmHighlight);
  AddItem('Syntax highlight', '', cmSyntaxHl);
  AddItem('Screen saver...', '', cmSaverSetup);
  AddMenu('Right');
  AddItem('Sort by...', 'Alt-S', cmSortRight);
  AddItem('Filter...', '', cmFilterRight);
  AddItem('Columns...', '', cmColumnsRight);
  AddItem('Re-read', 'Ctrl-R', cmRereadRight);

  x := 2;
  for i := 0 to High(Menus) do
  begin
    Menus[i].X := x;
    x := x + Length(Menus[i].Title) + 4;
  end;
end;

function MenuCount: Integer;
begin
  InitMenus;
  Result := Length(Menus);
end;

function TitleAt(x: Integer): Integer;
var
  i: Integer;
begin
  InitMenus;
  Result := -1;
  for i := 0 to High(Menus) do
    if (x >= Menus[i].X - 1) and (x <= Menus[i].X + Length(Menus[i].Title)) then
      Exit(i);
end;

procedure DrawBar(sel: Integer);
var
  i: Integer;
begin
  InitMenus;
  FillRow(0, 0, COLS, cpMenuBar);
  for i := 0 to High(Menus) do
    if i = sel then
      PutStr(0, Menus[i].X - 1, ' ' + Menus[i].Title + ' ', cpMenuSel)
    else
      PutStr(0, Menus[i].X, Menus[i].Title, cpMenuBar);
end;

{ checkbox items render their live state; everything else is static }
function ItemCaption(const it: TMenuItem): AnsiString;
begin
  Result := it.Caption;
  if it.Cmd = cmSyntaxHl then
    if Opt.SyntaxHl then
      Result := '[x] ' + Result
    else
      Result := '[ ] ' + Result;
end;

{ Enter/click on a checkbox item flips it in place instead of closing
  the menu; returns True when the command was consumed that way }
function ToggleItem(cmd: Integer): Boolean;
begin
  Result := cmd = cmSyntaxHl;
  if Result then
  begin
    Opt.SyntaxHl := not Opt.SyntaxHl;
    OptSave;
  end;
end;

function DropWidth(const m: TMenu): Integer;
var
  i, w: Integer;
begin
  Result := 20;
  for i := 0 to High(m.Items) do
  begin
    w := Length(ItemCaption(m.Items[i])) + Length(m.Items[i].Hotkey) + 6;
    if w > Result then Result := w;
  end;
end;

function RunMenuBar(startSel: Integer): Integer;
var
  sel, item, ch, i, w, dx: Integer;
  me: MEVENT;

  function Selectable(i: Integer): Boolean;
  begin
    Result := (i >= 0) and (i <= High(Menus[sel].Items)) and
              (Menus[sel].Items[i].Cmd <> cmNone);
  end;

  procedure FirstItem;
  begin
    item := 0;
    while (item <= High(Menus[sel].Items)) and not Selectable(item) do
      Inc(item);
    if item > High(Menus[sel].Items) then item := 0;
  end;

  procedure NextItem(dir: Integer);
  var
    n, cand, k: Integer;
  begin
    n := Length(Menus[sel].Items);
    cand := item;
    for k := 1 to n do
    begin
      cand := (cand + dir + n) mod n;
      if Selectable(cand) then
      begin
        item := cand;
        Exit;
      end;
    end;
  end;

  procedure DrawDrop;
  var
    j, pair: Integer;
    m: ^TMenu;
    cap: AnsiString;
  begin
    m := @Menus[sel];
    w := DropWidth(m^);
    dx := m^.X - 1;
    if dx + w >= COLS then dx := COLS - w - 1;
    PutStr(1, dx, bxSTL + Rep(bxSepH, w - 2) + bxSTR, cpMenuBar);
    for j := 0 to High(m^.Items) do
    begin
      if (j = item) and Selectable(j) then pair := cpMenuSel else pair := cpMenuBar;
      cap := ' ' + PadRight(ItemCaption(m^.Items[j]),
              w - 4 - Length(m^.Items[j].Hotkey)) + m^.Items[j].Hotkey + ' ';
      PutStr(2 + j, dx, bxColV, cpMenuBar);
      PutStr(2 + j, dx + 1, cap, pair);
      PutStr(2 + j, dx + w - 1, bxColV, cpMenuBar);
    end;
    PutStr(2 + Length(m^.Items), dx, bxSBL + Rep(bxSepH, w - 2) + bxSBR, cpMenuBar);
  end;

begin
  InitMenus;
  Result := cmNone;
  sel := startSel;
  if (sel < 0) or (sel > High(Menus)) then sel := 0;
  FirstItem;

  repeat
    if Assigned(RedrawBase) then RedrawBase();
    DrawBar(sel);
    DrawDrop;
    refresh;
    ch := getch;
    case ch of
      ERR: ;
      KEY_LEFT:
        begin
          sel := (sel + High(Menus)) mod Length(Menus);
          FirstItem;
        end;
      KEY_RIGHT:
        begin
          sel := (sel + 1) mod Length(Menus);
          FirstItem;
        end;
      KEY_UP: NextItem(-1);
      KEY_DOWN: NextItem(1);
      10, 13, KEY_ENTER:
        if Selectable(item) then
        begin
          if not ToggleItem(Menus[sel].Items[item].Cmd) then
            Exit(Menus[sel].Items[item].Cmd);
        end;
      27, KEY_F0 + 9: Exit(cmNone);
      KEY_MOUSE:
        if getmouse(@me) = OK then
        begin
          if (me.bstate and (mbtn1Clicked or mbtn1Pressed or mbtn1Double or
                             mbtn3Clicked or mbtn3Pressed)) = 0 then
            Continue;
          if me.y = 0 then
          begin
            i := TitleAt(me.x);
            if i < 0 then Exit(cmNone);
            sel := i;
            FirstItem;
          end
          else if (me.x > dx) and (me.x < dx + w - 1) and
                  (me.y >= 2) and (me.y < 2 + Length(Menus[sel].Items)) then
          begin
            item := me.y - 2;
            if Selectable(item) then
              if not ToggleItem(Menus[sel].Items[item].Cmd) then
                Exit(Menus[sel].Items[item].Cmd);
          end
          else
            Exit(cmNone);
        end;
    end;
  until False;
end;

end.
