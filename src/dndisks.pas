{ dndisks — removable media (USB sticks, SD cards, disk images) as a
  list the Disks window can mount, unmount and eject, plus the mount
  lookup the panel title uses to draw its eject indicator.

  Pure logic, no ncurses: the UI lives in dndisksui.pas. macOS uses
  `diskutil list -plist external` / `diskutil info`; Linux uses `lsblk`
  with `udisksctl` for the actual mount (no sudo). Tests replace the
  listing with DN_DISKS_CMD (see RunDisksCmd) and the actions with
  DN_DISKS_MOUNT_CMD / DN_DISKS_UNMOUNT_CMD / DN_DISKS_EJECT_CMD. }
unit dndisks;

{$mode objfpc}{$H+}

interface

type
  TDisk = record
    Dev: AnsiString;         // /dev/disk4s1, /dev/sdb1, '' for an image
    Name: AnsiString;        // volume label, else the device identifier
    Fs: AnsiString;          // filesystem name (exFAT, FAT32, APFS, ext4…)
    Size: Int64;             // bytes, 0 when unknown
    Mount: AnsiString;       // mount point, '' when unmounted
    IsImage: Boolean;        // a disk image, not physical media
  end;
  TDiskArray = array of TDisk;

{ mount point of the removable volume holding Path, '' when Path is on a
  fixed disk or unknown; Label gets the volume name for the eject marker }
function RemovableMount(const Path: AnsiString; out Label_, Dev: AnsiString): Boolean;

{ refresh the removable-media list (platform dependent) }
function ListDisks(out Disks: TDiskArray; out Err: AnsiString): Boolean;

{ actions; on success Mount holds the new mount point }
function MountDisk(const D: TDisk; out MountPoint, Err: AnsiString): Boolean;
function UnmountDisk(const D: TDisk; out Err: AnsiString): Boolean;
function EjectDisk(const D: TDisk; out Err: AnsiString): Boolean;

{ formatted size for the list (32G, 877M, 200K) }
function FmtDiskSize(Size: Int64): AnsiString;

implementation

uses
  SysUtils, Classes, dnvfs;

{ --- test seams ------------------------------------------------------- }

{ the command that produces the listing; empty = use the platform default }
function DisksCmd: AnsiString;
begin
  Result := GetEnvironmentVariable('DN_DISKS_CMD');
end;

{ an action override: when set, the action runs this command with %d (device)
  and %m (mount point) instead of the platform tool. '' = default. }
function ActionCmd(const Env: AnsiString): AnsiString;
begin
  Result := GetEnvironmentVariable(Env);
end;

function Q(const s: AnsiString): AnsiString;
begin
  Result := AnsiQuotedStr(s, '''');
end;

function FmtDiskSize(Size: Int64): AnsiString;
begin
  if Size <= 0 then Exit('?');
  if Size < 1024 then Result := IntToStr(Size) + 'B'
  else if Size < 1024 * 1024 then Result := IntToStr(Size div 1024) + 'K'
  else if Size < Int64(1024) * 1024 * 1024 then
    Result := IntToStr(Size div (1024 * 1024)) + 'M'
  else
    Result := IntToStr(Size div (Int64(1024) * 1024 * 1024)) + 'G';
end;

{ --- a tiny plist reader ---------------------------------------------- }
{ Enough of Apple's XML plist to walk the diskutil output: nested dicts and
  arrays. Keys and values are pulled out by KeyValue below, which scans the
  block text line by line. }

type
  TPlistPair = record
    Key: AnsiString;
    IsDict: Boolean;         // value was <dict>, its body is in Body
    Value: AnsiString;       // scalar value ('' for containers)
    Body: AnsiString;        // text of a <dict>…</dict> value
  end;

{ values of the top-level keys inside Block (a <dict> body) }
function PListGet(const Block, Key: AnsiString; out Value: AnsiString): Boolean;
var
  L: TStringList;
  i, p: Integer;
  line: AnsiString;
begin
  Result := False;
  Value := '';
  L := TStringList.Create;
  try
    L.Text := Block;
    for i := 0 to L.Count - 1 do
    begin
      line := Trim(L[i]);
      if line <> '<key>' + Key + '</key>' then Continue;
      if i + 1 >= L.Count then Exit;
      line := Trim(L[i + 1]);
      if Copy(line, 1, 6) = '<dict>' then
      begin
        { multi-line container: gather until the matching </dict> }
        Value := '';
        p := i + 1;
        while p < L.Count do
        begin
          Value := Value + L[p] + #10;
          if Pos('</dict>', L[p]) > 0 then Break;
          Inc(p);
        end;
        Exit(True);
      end;
      if (Copy(line, 1, 8) = '<string>') and (Pos('</string>', line) > 0) then
      begin
        p := Pos('</string>', line);
        Value := Copy(line, 9, p - 9);
        Exit(True);
      end;
      if (Copy(line, 1, 9) = '<integer>') and (Pos('</integer>', line) > 0) then
      begin
        p := Pos('</integer>', line);
        Value := Copy(line, 10, p - 10);
        Exit(True);
      end;
      if (line = '<true/>') or (line = '<true />') then Exit(True);
      Exit;   // empty or unknown element
    end;
  finally
    L.Free;
  end;
end;

{ split Block into its immediate <dict> children of the <array> at Key }
procedure PListArray(const Block, Key: AnsiString; out Dicts: TStringList);
var
  L: TStringList;
  i, depth: Integer;
  line, cur: AnsiString;
  inArray, inDict: Boolean;
begin
  Dicts := TStringList.Create;
  Dicts.SkipLastLineBreak := True;
  L := TStringList.Create;
  try
    L.Text := Block;
    inArray := False;
    inDict := False;
    cur := '';
    depth := 0;
    for i := 0 to L.Count - 1 do
    begin
      line := Trim(L[i]);
      if not inArray then
      begin
        if line = '<key>' + Key + '</key>' then
          inArray := True;
        Continue;
      end;
      if not inDict then
      begin
        if line = '<array>' then Continue;
        if line = '</array>' then Break;
        if line = '<dict>' then
        begin
          inDict := True;
          depth := 1;
          cur := line + #10;
        end;
        Continue;
      end;
      cur := cur + L[i] + #10;
      if Pos('<dict>', line) > 0 then Inc(depth);
      if Pos('</dict>', line) > 0 then
      begin
        Dec(depth);
        if depth = 0 then
        begin
          Dicts.Add(cur);
          inDict := False;
          cur := '';
        end;
      end;
    end;
  finally
    L.Free;
  end;
end;

{ strip the XML doc down to the body of the top-level <dict>…</dict> }
function PListBody(const Xml: AnsiString): AnsiString;
var
  p, q: Integer;
begin
  p := Pos('<dict>', Xml);
  if p = 0 then Exit('');
  q := Length(Xml);
  while (q > p) and (Copy(Xml, q - 6, 7) <> '</dict>') do Dec(q);
  Result := Copy(Xml, p, q + 7 - p);
end;

{ --- macOS ------------------------------------------------------------ }

{$ifdef darwin}
{ map a diskutil filesystem/partition type to a short name }
function ShortFs(const Content: AnsiString): AnsiString;
var
  c: AnsiString;
begin
  c := LowerCase(Content);
  if Pos('hfs', c) > 0 then Exit('HFS+');
  if Pos('apfs', c) > 0 then Exit('APFS');
  if Pos('fat32', c) > 0 then Exit('FAT32');
  if Pos('fat', c) > 0 then Exit('FAT');
  if Pos('exfat', c) > 0 then Exit('exFAT');
  if Pos('ntfs', c) > 0 then Exit('NTFS');
  if Pos('udf', c) > 0 then Exit('UDF');
  if Pos('efi', c) > 0 then Exit('EFI');
  if Pos('iso9660', c) > 0 then Exit('ISO9660');
  if Content <> '' then Exit(Content);
  Result := '?';
end;

function ParseDiskutil(const Xml: AnsiString; out Disks: TDiskArray): Boolean;
var
  whole, parts: TStringList;
  i, j, n: Integer;
  body, v, ident, content, vname, mp: AnsiString;
  d: TDisk;
begin
  Result := False;
  SetLength(Disks, 0);
  whole := nil;
  parts := nil;
  try
    PListArray(PListBody(Xml), 'AllDisksAndPartitions', whole);
    n := 0;
    for i := 0 to whole.Count - 1 do
    begin
      body := whole[i];
      if not PListGet(body, 'DeviceIdentifier', ident) then Continue;
      if not PListGet(body, 'Content', content) then content := '';
      d.Dev := '/dev/' + ident;
      d.Fs := ShortFs(content);
      d.Size := 0;
      if PListGet(body, 'Size', v) then d.Size := StrToInt64Def(v, 0);
      d.Mount := '';
      if PListGet(body, 'MountPoint', mp) then d.Mount := mp;
      d.Name := ident;
      if PListGet(body, 'VolumeName', vname) and (vname <> '') then
        d.Name := vname;
      d.IsImage := Pos('disk image', LowerCase(content)) > 0;

      { a whole disk with no partitions is one entry (an image, a plain
        FAT stick); a partitioned disk contributes one entry per partition }
      if not PListGet(body, 'Partitions', v) then
      begin
        SetLength(Disks, n + 1);
        Disks[n] := d;
        Inc(n);
        Continue;
      end;
      parts := nil;
      PListArray(body, 'Partitions', parts);
      for j := 0 to parts.Count - 1 do
      begin
        if not PListGet(parts[j], 'DeviceIdentifier', ident) then Continue;
        SetLength(Disks, n + 1);
        Disks[n] := d;
        Disks[n].Dev := '/dev/' + ident;
        Disks[n].Name := ident;
        Disks[n].Mount := '';
        Disks[n].Size := 0;
        if PListGet(parts[j], 'Content', v) then
          Disks[n].Fs := ShortFs(v);
        if PListGet(parts[j], 'VolumeName', v) and (v <> '') then
          Disks[n].Name := v;
        if PListGet(parts[j], 'Size', v) then
          Disks[n].Size := StrToInt64Def(v, 0);
        if PListGet(parts[j], 'MountPoint', v) then
          Disks[n].Mount := v;
        Inc(n);
      end;
      FreeAndNil(parts);
    end;
    Result := True;
  finally
    whole.Free;
    if parts <> nil then parts.Free;
  end;
end;
{$endif}

{ --- Linux ------------------------------------------------------------ }

{$ifdef linux}
{ lsblk -P output: one line per device, KEY="value" pairs. We keep
  removable/hotplug devices only. }
function ParseLsblk(const Text: AnsiString; out Disks: TDiskArray): Boolean;
var
  L: TStringList;
  i, p: Integer;
  line, key, val, name, label_, fstype, size, mp, rm, hot: AnsiString;
  n: Integer;
  d: TDisk;

  function Field(const Line_, K: AnsiString): AnsiString;
  var
    q, r: Integer;
    pat: AnsiString;
  begin
    Result := '';
    pat := K + '="';
    q := Pos(pat, Line_);
    if q = 0 then Exit;
    q := q + Length(pat);
    r := q;
    while (r <= Length(Line_)) and (Line_[r] <> '"') do Inc(r);
    Result := Copy(Line_, q, r - q);
  end;

begin
  Result := False;
  SetLength(Disks, 0);
  n := 0;
  L := TStringList.Create;
  try
    L.Text := Text;
    for i := 0 to L.Count - 1 do
    begin
      line := L[i];
      if Trim(line) = '' then Continue;
      name := Field(line, 'NAME');
      if name = '' then Continue;
      rm := Field(line, 'RM');
      hot := Field(line, 'HOTPLUG');
      if (rm <> '1') and (hot <> '1') then Continue;   // fixed disk
      d.Dev := '/dev/' + name;
      label_ := Field(line, 'LABEL');
      if label_ = '' then d.Name := name else d.Name := label_;
      fstype := Field(line, 'FSTYPE');
      if fstype = '' then d.Fs := '?' else d.Fs := fstype;
      size := Field(line, 'SIZE');
      d.Size := 0;
      if size <> '' then d.Size := StrToInt64Def(size, 0);
      mp := Field(line, 'MOUNTPOINT');
      d.Mount := mp;
      d.IsImage := False;
      SetLength(Disks, n + 1);
      Disks[n] := d;
      Inc(n);
    end;
    Result := True;
  finally
    L.Free;
  end;
end;
{$endif}

{ --- listing ---------------------------------------------------------- }

{ the test seam: one device per line, 'dev|name|fs|size|mount|image',
  image is '1' for a disk image. Size is bytes. }
function ParseSeam(const Text: AnsiString; out Disks: TDiskArray): Boolean;
var
  L: TStringList;
  i, p: Integer;
  f: array[0..5] of AnsiString;

  function Cut(var s: AnsiString): AnsiString;
  var
    q: Integer;
  begin
    q := Pos('|', s);
    if q = 0 then
    begin
      Result := s;
      s := '';
    end
    else
    begin
      Result := Copy(s, 1, q - 1);
      s := Copy(s, q + 1, MaxInt);
    end;
  end;

begin
  Result := False;
  SetLength(Disks, 0);
  L := TStringList.Create;
  try
    L.Text := Text;
    for i := 0 to L.Count - 1 do
    begin
      if (Trim(L[i]) = '') or (Pos('|', L[i]) = 0) then Continue;
      for p := 0 to 5 do f[p] := '';
      f[0] := L[i];
      for p := 0 to 4 do f[p] := Cut(f[0]);
      f[5] := f[0];
      SetLength(Disks, Length(Disks) + 1);
      with Disks[High(Disks)] do
      begin
        Dev := f[0];
        Name := f[1];
        Fs := f[2];
        Size := StrToInt64Def(f[3], 0);
        Mount := f[4];
        IsImage := f[5] = '1';
      end;
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

function ListDisks(out Disks: TDiskArray; out Err: AnsiString): Boolean;
var
  cmd, outp: AnsiString;
begin
  Result := False;
  Err := '';
  SetLength(Disks, 0);

  cmd := DisksCmd;
  if cmd <> '' then
  begin
    if RunCapture(cmd, outp) <> 0 then
    begin
      Err := Trim(outp);
      if Err = '' then Err := 'cannot list disks';
      Exit;
    end;
    Exit(ParseSeam(outp, Disks));
  end;

  {$ifdef darwin}
  if RunCapture('diskutil list -plist external', outp) <> 0 then
  begin
    Err := Trim(outp);
    if Err = '' then Err := 'diskutil failed';
    Exit;
  end;
  Result := ParseDiskutil(outp, Disks);
  {$endif}
  {$ifdef linux}
  if RunCapture('lsblk -P -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT,RM,HOTPLUG', outp) <> 0 then
  begin
    Err := Trim(outp);
    if Err = '' then Err := 'lsblk failed';
    Exit;
  end;
  Result := ParseLsblk(outp, Disks);
  {$endif}
end;

{ --- actions ---------------------------------------------------------- }

function RunAction(const Env, DefCmd: AnsiString; const D: TDisk;
                   const MountPoint: AnsiString; out Err: AnsiString): Boolean;
var
  cmd, outp: AnsiString;
begin
  cmd := ActionCmd(Env);
  if cmd = '' then cmd := DefCmd;
  cmd := StringReplace(cmd, '%d', Q(D.Dev), [rfReplaceAll]);
  cmd := StringReplace(cmd, '%m', Q(MountPoint), [rfReplaceAll]);
  if cmd = '' then
  begin
    Err := 'no command for this action';
    Exit(False);
  end;
  Result := RunCapture(cmd, outp) = 0;
  if Result then Err := '' else Err := Trim(outp);
end;

{ mount point from a diskutil mount / hdiutil attach style output }
function MountPointOf(const Outp, Fallback: AnsiString): AnsiString;
var
  L: TStringList;
  i, p: Integer;
begin
  Result := Fallback;
  L := TStringList.Create;
  try
    L.Text := Outp;
    for i := 0 to L.Count - 1 do
    begin
      p := Pos('/Volumes/', L[i]);
      if p > 0 then Result := Trim(Copy(L[i], p, MaxInt))
      else
      begin
        p := Pos('/media/', L[i]);
        if p > 0 then Result := Trim(Copy(L[i], p, MaxInt));
      end;
    end;
  finally
    L.Free;
  end;
end;

function MountDisk(const D: TDisk; out MountPoint, Err: AnsiString): Boolean;
var
  cmd, outp: AnsiString;
begin
  MountPoint := D.Mount;
  Err := '';
  {$ifdef darwin}
  if ActionCmd('DN_DISKS_MOUNT_CMD') = '' then
  begin
    if RunCapture('diskutil mount ' + Q(D.Dev), outp) <> 0 then
    begin
      Err := Trim(outp);
      if Err = '' then Err := 'mount failed';
      Exit(False);
    end;
    MountPoint := MountPointOf(outp, '');
    Result := True;
    Exit;
  end;
  {$endif}
  {$ifdef linux}
  if ActionCmd('DN_DISKS_MOUNT_CMD') = '' then
  begin
    if GetEnvironmentVariable('DN_DISKS_NO_UDISKS') <> '' then
    begin
      Err := 'mounting needs root: run "sudo mount ' + D.Dev + ' <dir>"';
      Exit(False);
    end;
    if RunCapture('udisksctl mount -b ' + Q(D.Dev), outp) <> 0 then
    begin
      Err := Trim(outp);
      if Err = '' then Err := 'mount failed';
      Exit(False);
    end;
    MountPoint := MountPointOf(outp, '');
    Result := True;
    Exit;
  end;
  {$endif}
  Result := RunAction('DN_DISKS_MOUNT_CMD', '', D, '', Err);
end;

function UnmountDisk(const D: TDisk; out Err: AnsiString): Boolean;
begin
  {$ifdef darwin}
  if ActionCmd('DN_DISKS_UNMOUNT_CMD') = '' then
  begin
    Result := RunCapture('diskutil unmount ' + Q(D.Dev), Err) = 0;
    if not Result then Err := Trim(Err);
    Exit;
  end;
  {$endif}
  {$ifdef linux}
  if ActionCmd('DN_DISKS_UNMOUNT_CMD') = '' then
  begin
    if GetEnvironmentVariable('DN_DISKS_NO_UDISKS') <> '' then
    begin
      Err := 'unmounting needs root: run "sudo umount ' + D.Mount + '"';
      Exit(False);
    end;
    Result := RunCapture('udisksctl unmount -b ' + Q(D.Dev), Err) = 0;
    if not Result then Err := Trim(Err);
    Exit;
  end;
  {$endif}
  Result := RunAction('DN_DISKS_UNMOUNT_CMD', '', D, D.Mount, Err);
end;

function EjectDisk(const D: TDisk; out Err: AnsiString): Boolean;
begin
  {$ifdef darwin}
  if ActionCmd('DN_DISKS_EJECT_CMD') = '' then
  begin
    Result := RunCapture('diskutil eject ' + Q(D.Dev), Err) = 0;
    if not Result then Err := Trim(Err);
    Exit;
  end;
  {$endif}
  {$ifdef linux}
  if ActionCmd('DN_DISKS_EJECT_CMD') = '' then
  begin
    if GetEnvironmentVariable('DN_DISKS_NO_UDISKS') <> '' then
    begin
      Err := 'ejecting needs root: run "sudo eject ' + D.Dev + '"';
      Exit(False);
    end;
    Result := RunCapture('udisksctl power-off -b ' + Q(D.Dev), Err) = 0;
    if not Result then Err := Trim(Err);
    Exit;
  end;
  {$endif}
  Result := RunAction('DN_DISKS_EJECT_CMD', '', D, D.Mount, Err);
end;

{ --- removable-mount lookup (panel indicator) ------------------------- }

{ True when Path lies inside a removable volume's mount point; Label_ gets
  the volume name, Dev the device. Falls back to the mount point's own
  basename when the listing is unavailable. }
function RemovableMount(const Path: AnsiString; out Label_, Dev: AnsiString): Boolean;
var
  Disks: TDiskArray;
  err, full: AnsiString;
  i, best: Integer;
begin
  Result := False;
  Label_ := '';
  Dev := '';
  full := ExpandFileName(Path);
  if not ListDisks(Disks, err) then Exit;
  best := -1;
  for i := 0 to High(Disks) do
  begin
    if Disks[i].Mount = '' then Continue;
    if (full = Disks[i].Mount) or
       (Pos(Disks[i].Mount + '/', full) = 1) then
      if (best < 0) or (Length(Disks[i].Mount) > Length(Disks[best].Mount)) then
        best := i;
  end;
  if best < 0 then Exit;
  Dev := Disks[best].Dev;
  if Disks[best].Name <> '' then
    Label_ := Disks[best].Name
  else
    Label_ := ExtractFileName(ExcludeTrailingPathDelimiter(Disks[best].Mount));
  Result := True;
end;

end.
