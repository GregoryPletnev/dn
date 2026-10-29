{ dndisksui — the modal Disks window (ROADMAP M7, 6.2).
  Lists removable volumes from dndisks and mounts, unmounts and ejects
  them; Enter opens a mounted volume in the active panel (drOpen with the
  mount point). The df free-space column is read here with statvfs:
  dndisks.pas exposes no free-space data. }
unit dndisksui;

{$mode objfpc}{$H+}

interface

uses
  dndisks;

type
  TDisksResult = (drCancel, drOpen);

{ Run the window. On drOpen, OpenPath holds the mount point to open. }
function DisksManager(out OpenPath: AnsiString): TDisksResult;

implementation

uses
  SysUtils, ncurses, {$ifdef unix}BaseUnix, Unix,{$endif}
  dnscreen, dndialog;

const
  ColDev = 12;
  ColName = 15;
  ColFs = 8;
  ColSize = 5;
  ColFree = 6;
  ColState = 9;

var
  Disks: TDiskArray;

{ free space on a mounted filesystem: bytes, 0 when unknown }
function FreeSpace(const MountPoint: AnsiString): Int64;
{$ifdef unix}
var
  fs: TStatFS;
begin
  Result := 0;
  if MountPoint = '' then Exit;
  if FpStatFS(PChar(MountPoint), @fs) <> 0 then Exit;
  Result := Int64(fs.bavail) * fs.bsize;
end;
{$else}
begin
  Result := 0;
end;
{$endif}

function DiskState(const D: TDisk): AnsiString;
begin
  if D.Mount <> '' then Result := 'mounted' else Result := 'ejectable';
end;

{ Info dialog text: the listing plus the df data read here }
function DiskInfo(const D: TDisk): AnsiString;
var
  free: Int64;
begin
  Result := 'Device: ' + D.Dev + #10 +
    'Label:  ' + D.Name + #10 +
    'FS:     ' + D.Fs + #10 +
    'Size:   ' + FmtDiskSize(D.Size);
  if D.Mount <> '' then
  begin
    free := FreeSpace(D.Mount);
    Result := Result + #10 +
      'Mount:  ' + D.Mount + #10 +
      'Free:   ' + FmtDiskSize(free) + #10 +
      'Used:   ' + FmtDiskSize(D.Size - free);
  end;
  if D.IsImage then Result := Result + #10 + 'Type:   disk image';
end;

const
  Caps: array[0..7] of AnsiString =
    ('Open', 'Mount', 'Unmount', 'Eject', 'Info', 'Refresh', 'Help', 'Esc');
  Acts: array[0..7] of Char = ('o', 'm', 'u', 'e', 'i', 'r', 'h', 'x');

procedure RefreshDisks;
var
  err: AnsiString;
begin
  if not ListDisks(Disks, err) then
    MsgBox('Disks', 'Cannot list disks:'#10 + err, ['OK']);
end;

{ one action; destructive ones ask first, like dn does everywhere }
procedure DoDiskAction(cur: Integer; kind: Char);
var
  i: Integer;
  mp, err, q: AnsiString;
  free: Int64;
begin
  if (cur < 0) or (cur > High(Disks)) then
  begin
    MsgBox('Disks', 'No disk is selected.', ['OK']);
    Exit;
  end;
  i := cur;
  case kind of
    'm':
      if Disks[i].Mount <> '' then
        MsgBox('Mount', Disks[i].Name + ' is already mounted:'#10 +
               Disks[i].Mount, ['OK'])
      else if MountDisk(Disks[i], mp, err) then
        RefreshDisks
      else
        MsgBox('Mount', 'Cannot mount ' + Disks[i].Name + ':'#10 + err, ['OK']);
    'u':
      if Disks[i].Mount = '' then
        MsgBox('Unmount', Disks[i].Name + ' is not mounted.', ['OK'])
      else if MsgBox('Unmount', 'Unmount ' + Disks[i].Name + '?'#10 +
                     Disks[i].Mount, ['Yes', 'No']) = 0 then
      begin
        if UnmountDisk(Disks[i], err) then
          RefreshDisks
        else
          MsgBox('Unmount', 'Cannot unmount ' + Disks[i].Name + ':'#10 + err,
                 ['OK']);
      end;
    'e':
      if MsgBox('Eject', 'Eject ' + Disks[i].Name + '?', ['Yes', 'No']) = 0 then
      begin
        if EjectDisk(Disks[i], err) then
          RefreshDisks
        else
          MsgBox('Eject', 'Cannot eject ' + Disks[i].Name + ':'#10 + err,
                 ['OK']);
      end;
    'i':
      begin
        q := DiskInfo(Disks[i]);
        free := 0;
        if Disks[i].Mount <> '' then free := FreeSpace(Disks[i].Mount);
        if free = 0 then
          q := q + #10#10 + 'Free-space data is unavailable.';
        MsgBox('Disk Info', q, ['OK']);
      end;
  end;
end;

function DisksManager(out OpenPath: AnsiString): TDisksResult;
var
  x, y, w, h, cur, top, ph, ch, i: Integer;
  me: MEVENT;
  done: Boolean;

  type
    TFooterBtn = record
      Cap: AnsiString;
      Act: Char;      // o=open m=mount u=unmount e=eject i=info r=refresh h=help x=close
      X0, X1: Integer;
    end;
  var
    btns: array of TFooterBtn;

  procedure BuildFooter;
  var
    j, cx: Integer;
  begin
    SetLength(btns, 8);
    cx := x + 2;
    for j := 0 to 7 do
    begin
      btns[j].Cap := Caps[j];
      btns[j].Act := Acts[j];
      btns[j].X0 := cx;
      btns[j].X1 := cx + Length(Caps[j]) - 1;
      cx := cx + Length(Caps[j]) + 2;
    end;
  end;

  function RowText(idx: Integer): AnsiString;
  var
    d: TDisk;
    fr: Int64;
  begin
    d := Disks[idx];
    fr := 0;
    if d.Mount <> '' then fr := FreeSpace(d.Mount);
    Result := PadRight(d.Dev, ColDev) + ' ' +
      Utf8PadRight(d.Name, ColName) + ' ' +
      PadRight(d.Fs, ColFs) + ' ' +
      PadLeft(FmtDiskSize(d.Size), ColSize) + ' ' +
      PadLeft(FmtDiskSize(fr), ColFree) + ' ' +
      DiskState(d);
  end;

  procedure Draw;
  var
    j, row, pair: Integer;
    line: AnsiString;
  begin
    if Assigned(RedrawBase) then RedrawBase();
    PutStr(y, x, bxTL + Rep(bxH, w - 2) + bxTR, cpMenuBar);
    PutStr(y, x + (w - 8) div 2, ' Disks ', cpTitleAct);
    line := PadRight('Device', ColDev) + ' ' +
      Utf8PadRight('Label', ColName) + ' ' +
      Utf8PadRight('FS', ColFs) + ' ' +
      PadLeft('Size', ColSize) + ' ' +
      PadLeft('Free', ColFree) + ' ' + 'Status';
    PutStr(y + 1, x + 1, PadRight(' ' + line, w - 2), cpTitleAct);
    for j := 0 to ph - 1 do
    begin
      row := y + 2 + j;
      PutStr(row, x, bxV, cpMenuBar);
      PutStr(row, x + w - 1, bxV, cpMenuBar);
      if top + j <= High(Disks) then
      begin
        if top + j = cur then pair := cpMenuSel else pair := cpMenuBar;
        PutStr(row, x + 1, PadRight(' ' + RowText(top + j), w - 2), pair);
      end
      else
        PutStr(row, x + 1, StringOfChar(' ', w - 2), cpMenuBar);
    end;
    if High(Disks) < 0 then
    begin
      line := 'No removable media found.';
      PutStr(y + ph div 2 + 1, x + (w - Length(line)) div 2, line, cpMenuBar);
      line := 'Insert a USB stick or press R to refresh.';
      PutStr(y + ph div 2 + 2, x + (w - Length(line)) div 2, line, cpMenuBar);
    end;
    PutStr(y + h - 2, x, bxSepL + Rep(bxSepH, w - 2) + bxSepR, cpMenuBar);
    PutStr(y + h - 1, x, bxSBL + Rep(bxSepH, w - 2) + bxSBR, cpMenuBar);
    PutStr(y + h - 2, x + 1, StringOfChar(' ', w - 2), cpMenuBar);
    for j := 0 to High(btns) do
      PutStr(y + h - 2, btns[j].X0, btns[j].Cap, cpMenuSel);
    refresh;
  end;

  procedure ShowHelp;
  begin
    MsgBox('Disks — Help',
      'Enter   mount, or open the mount point in the panel'#10 +
      'M  mount        U  unmount      E  eject'#10 +
      'I  info         R  refresh      F1   this help'#10 +
      'Up/Down move    Esc  close'#10 +
      #10 +
      'Free space comes from statvfs on the mount point.'#10 +
      'Only removable and hot-plug disks are listed.',
      ['OK']);
  end;

  { Enter: mount when unmounted, open the mount point when mounted }
  procedure ActivateRow;
  var
    p: AnsiString;
    ok: Boolean;
  begin
    if (cur < 0) or (cur > High(Disks)) then Exit;
    if Disks[cur].Mount <> '' then
    begin
      OpenPath := Disks[cur].Mount;
      Result := drOpen;
      done := True;
      Exit;
    end;
    DoDiskAction(cur, 'm');
    { a seam mount command knows the new mount point only by convention:
      DN_DISKS_MOUNT_POINT }
    if GetEnvironmentVariable('DN_DISKS_MOUNT_CMD') <> '' then
    begin
      p := GetEnvironmentVariable('DN_DISKS_MOUNT_POINT');
      ok := p <> '';
      if ok and not DirectoryExists(p) then ok := False;
      if ok then
      begin
        OpenPath := ExcludeTrailingPathDelimiter(p);
        Result := drOpen;
        done := True;
      end;
    end;
  end;

  procedure DoAct(a: Char);
  begin
    case a of
      'o': ActivateRow;
      'm', 'u', 'e', 'i': DoDiskAction(cur, a);
      'r': RefreshDisks;
      'h': ShowHelp;
      'x':
        begin
          Result := drCancel;
          done := True;
        end;
    end;
  end;

begin
  Result := drCancel;
  OpenPath := '';
  RefreshDisks;
  cur := 0;
  top := 0;
  w := 2 + ColDev + 1 + ColName + 1 + ColFs + 1 + ColSize + 1 +
       ColFree + 1 + ColState + 2;
  h := 14;
  if w > COLS - 2 then w := COLS - 2;
  if h > LINES - 2 then h := LINES - 2;
  x := (COLS - w) div 2;
  y := (LINES - h) div 2;
  ph := h - 4;
  done := False;
  BuildFooter;
  if (cur < 0) or (cur > High(Disks)) then cur := 0;

  repeat
    if cur < top then top := cur;
    if cur >= top + ph then top := cur - ph + 1;
    Draw;
    ch := getch;
    case ch of
      ERR: ;
      KEY_UP: if cur > 0 then Dec(cur);
      KEY_DOWN: if cur < High(Disks) then Inc(cur);
      KEY_HOME: cur := 0;
      KEY_END: cur := High(Disks);
      10, 13, KEY_ENTER: DoAct('o');
      Ord('M'), Ord('m'): DoAct('m');
      Ord('U'), Ord('u'): DoAct('u');
      Ord('E'), Ord('e'): DoAct('e');
      Ord('I'), Ord('i'): DoAct('i');
      Ord('R'), Ord('r'): DoAct('r');
      KEY_F0 + 1: DoAct('h');              // F1 help
      27, KEY_F0 + 10: DoAct('x');         // Esc / F10
      KEY_MOUSE:
        if getmouse(@me) = OK then
          if (me.bstate and (mbtn1Pressed or mbtn1Clicked or mbtn1Double)) <> 0 then
          begin
            if me.y = y + h - 2 then
            begin
              for i := 0 to High(btns) do
                if (me.x >= btns[i].X0) and (me.x <= btns[i].X1) then
                begin
                  DoAct(btns[i].Act);
                  Break;
                end;
            end
            else
            begin
              i := me.y - y - 2 + top;
              if (i >= 0) and (i <= High(Disks)) then
              begin
                cur := i;
                if (me.bstate and mbtn1Double) <> 0 then DoAct('o');
              end;
            end;
          end;
    end;
    if (cur < 0) or (cur > High(Disks)) then
      if High(Disks) < 0 then cur := 0
      else if cur > High(Disks) then cur := High(Disks);
  until done;
  SetLength(Disks, 0);
end;

end.
