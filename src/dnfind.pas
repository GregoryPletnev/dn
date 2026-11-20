{ dnfind — Find File (Alt-F7, Commands menu), after DN 1.51 and DN OSP.

  The dialog follows DN's dlgFileFind as DN OSP/Necromancer's DN grew it:
  file mask, text to find, hex string; options (advanced search,
  recursive, case sensitive, whole words, hidden files); scope (current
  directory, selected, home, entire disk). dn adds a file type told by
  content (dnmagic: 'SQLite', 'PDF', a group such as 'Archives'). The
  Advanced form is DN's dlgAdvanceSearch: date after/before, size
  greater/less, attributes.

  As in DN (TFindDrive), the results go to the panel: TFindVFS lists the
  hits by their path relative to where the search started. It reports
  itself as local and the names join onto that directory, so view, edit,
  copy, move and delete act on the real files. Enter goes to a hit in its
  own directory; '..' returns to the starting directory.

  The walk does not follow symbolic links to directories and reads
  regular files only (a FIFO would block). While it runs, RunBusyHook
  (dnvfs) shows the progress box; Esc asks whether to stop, as DN did,
  and keeps what was found. }
unit dnfind;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnvfs;

type
  TFindScope = (fsCurrent, fsSelected, fsHome, fsDisk);

  TFindOptions = record
    Masks: AnsiString;         // '' or '*' = any name; ';' or ',' separated
    Text: AnsiString;          // '' = any content
    Hex: AnsiString;           // '53 51 4C' = bytes; wins over Text
    TypeFilter: AnsiString;    // '' = any; a dnmagic type or group name
    Advanced: Boolean;
    Recursive: Boolean;
    CaseSensitive: Boolean;
    WholeWords: Boolean;
    Hidden: Boolean;           // look into dot files and dot directories
    Scope: TFindScope;
    { advanced }
    DateAfter: AnsiString;     // 'YYYY-MM-DD' or 'DD.MM.YYYY', '' = any
    DateBefore: AnsiString;
    SizeGreater: AnsiString;   // '10K', '2M', '1G', bytes; '' = any
    SizeLess: AnsiString;
    OnlyReadOnly: Boolean;
    OnlyExecutable: Boolean;
  end;

  TFindHit = record
    Path: AnsiString;          // full path
    IsDir: Boolean;
  end;
  TFindHits = array of TFindHit;

  { the results panel }
  TFindVFS = class(TVFS)
  public
    Root: AnsiString;          // the panel path: names are relative to it
    Title: AnsiString;
    Hits: TFindHits;
    constructor CreateFind(const ARoot, ATitle: AnsiString; const AHits: TFindHits);
    function List(const Dir: AnsiString; out Items: TVfsItems;
                  out Err: AnsiString): Boolean; override;
    { the operations act on the real files: the panel passes full paths }
    function GetFile(const Path, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function GetTree(const Path, LocalDest: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function PutFile(const LocalSrc, Path: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function PutTree(const LocalSrc, Path: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function DeletePath(const Path: AnsiString; IsDir: Boolean;
                        out Err: AnsiString): Boolean; override;
    function MakeDir(const Path: AnsiString;
                     out Err: AnsiString): Boolean; override;
    function Display(const Path: AnsiString): AnsiString; override;
    function IsLocal: Boolean; override;
    function IsRootPath(const Path: AnsiString): Boolean; override;
    function ParentExit(out LocalDir, CursorName: AnsiString): Boolean; override;
    { the full path of a panel entry name }
    function FullPath(const Name: AnsiString): AnsiString;
  end;

const
  FindMaxHits = 100000;

{ the form(s); False = cancelled. O keeps the values for the next time. }
function FindDialog(var O: TFindOptions): Boolean;

{ '53 51 4c' / '53514C' -> bytes; False when it is not hex }
function ParseHex(const S: AnsiString; out Bytes: AnsiString): Boolean;
{ '10K', '2M', '1G', '512' -> bytes; -1 for '' ; False when malformed }
function ParseSize(const S: AnsiString; out N: Int64): Boolean;
{ 'YYYY-MM-DD' or 'DD.MM.YYYY'; 0 for '' ; False when malformed }
function ParseDay(const S: AnsiString; out D: TDateTime): Boolean;

{ True when Path's content holds Needle (as bytes when CaseSensitive;
  WholeWords: not inside a longer word) }
function FileContains(const Path, Needle: AnsiString;
                      CaseSensitive, WholeWords: Boolean): Boolean;

{ search Roots; False when the user stopped it (Hits holds what was found);
  Err set when an advanced value is malformed }
function FindFiles(const O: TFindOptions; const Roots: array of AnsiString;
                   out Hits: TFindHits; out Err: AnsiString): Boolean;

{ the panel title of a search }
function FindTitle(const O: TFindOptions): AnsiString;

implementation

uses
  SysUtils, DateUtils, BaseUnix, Unix, dnpanel, dndialog, dnmagic;

const
  ChunkSize = 65536;

{ --- parsing ------------------------------------------------------------------ }

function ParseHex(const S: AnsiString; out Bytes: AnsiString): Boolean;
var
  t: AnsiString;
  i: Integer;
begin
  Bytes := '';
  t := '';
  for i := 1 to Length(S) do
    if not (S[i] in [' ', #9, ',', ':', '-']) then t := t + S[i];
  if (Length(t) mod 2 <> 0) then Exit(False);
  for i := 1 to Length(t) do
    if not (t[i] in ['0'..'9', 'a'..'f', 'A'..'F']) then Exit(False);
  for i := 0 to Length(t) div 2 - 1 do
    Bytes := Bytes + Chr(StrToInt('$' + Copy(t, i * 2 + 1, 2)));
  Result := True;
end;

function ParseSize(const S: AnsiString; out N: Int64): Boolean;
var
  t: AnsiString;
  mul: Int64;
begin
  N := -1;
  t := UpperCase(Trim(S));
  if t = '' then Exit(True);
  mul := 1;
  if (t <> '') and (t[Length(t)] = 'B') then SetLength(t, Length(t) - 1);
  if t <> '' then
    case t[Length(t)] of
      'K': mul := 1024;
      'M': mul := 1024 * 1024;
      'G': mul := 1024 * 1024 * 1024;
    end;
  if mul > 1 then SetLength(t, Length(t) - 1);
  Result := TryStrToInt64(Trim(t), N) and (N >= 0);
  if Result then N := N * mul else N := -1;
end;

function ParseDay(const S: AnsiString; out D: TDateTime): Boolean;
var
  t: AnsiString;
  y, m, dd: Integer;
  parts: TStringArray;
begin
  D := 0;
  t := Trim(S);
  if t = '' then Exit(True);
  Result := False;
  if Pos('-', t) > 0 then
  begin
    parts := t.Split('-');
    if Length(parts) <> 3 then Exit;
    y := StrToIntDef(parts[0], -1); m := StrToIntDef(parts[1], -1);
    dd := StrToIntDef(parts[2], -1);
  end
  else if Pos('.', t) > 0 then
  begin
    parts := t.Split('.');
    if Length(parts) <> 3 then Exit;
    dd := StrToIntDef(parts[0], -1); m := StrToIntDef(parts[1], -1);
    y := StrToIntDef(parts[2], -1);
    if (y >= 0) and (y < 100) then Inc(y, 2000);
  end
  else
    Exit;
  Result := TryEncodeDate(y, m, dd, D);
end;

{ --- content ------------------------------------------------------------------ }

function IsWordChar(c: Char): Boolean; inline;
begin
  Result := (c in ['A'..'Z', 'a'..'z', '0'..'9', '_']) or (Ord(c) >= 128);
end;

{ a match at p (1-based) in hay stands alone: no word character around it }
function Whole(const Hay: AnsiString; P, Len: Integer): Boolean;
begin
  Result := ((P = 1) or not IsWordChar(Hay[P - 1])) and
            ((P + Len > Length(Hay)) or not IsWordChar(Hay[P + Len]));
end;

function FindIn(const Hay, Needle: AnsiString; WholeWords: Boolean): Boolean;
var
  p, from: Integer;
begin
  from := 1;
  repeat
    p := Pos(Needle, Copy(Hay, from, MaxInt));
    if p = 0 then Exit(False);
    p := p + from - 1;
    if not WholeWords or Whole(Hay, p, Length(Needle)) then Exit(True);
    from := p + 1;
  until False;
end;

function FileContains(const Path, Needle: AnsiString;
                      CaseSensitive, WholeWords: Boolean): Boolean;
var
  f: THandle;
  buf, tail, hay, ndl: AnsiString;
  n, keep: Integer;
begin
  Result := False;
  if Needle = '' then Exit(True);
  ndl := Needle;
  if not CaseSensitive then ndl := LowerCase(ndl);
  f := FileOpen(Path, fmOpenRead or fmShareDenyNone);
  if f = THandle(-1) then Exit;
  try
    tail := '';
    { a match may span two chunks; a whole-word check needs one more byte
      on each side }
    keep := Length(ndl) + 1;       // + the byte before a match
    SetLength(buf, ChunkSize);
    repeat
      n := FileRead(f, buf[1], ChunkSize);
      if n <= 0 then Break;
      hay := tail + Copy(buf, 1, n);
      if not CaseSensitive then hay := LowerCase(hay);
      if FindIn(hay, ndl, WholeWords) then Exit(True);
      if Length(hay) > keep then
        tail := Copy(hay, Length(hay) - keep + 1, keep)
      else
        tail := hay;
    until False;
  finally
    FileClose(f);
  end;
end;

{ --- the walk ------------------------------------------------------------------ }

function FindFiles(const O: TFindOptions; const Roots: array of AnsiString;
                   out Hits: TFindHits; out Err: AnsiString): Boolean;
var
  busy: TRunBusy;
  start, lastTick: QWord;
  cancel: Boolean;
  masks, needle: AnsiString;
  nameOnly: Boolean;
  dAfter, dBefore: TDateTime;
  sGreater, sLess: Int64;
  i: Integer;

  procedure Tick(const Dir: AnsiString);
  begin
    if not Assigned(RunBusyHook) then Exit;
    busy.ElapsedMs := GetTickCount64 - start;
    if (busy.ElapsedMs < RunBusyDelayMs) or
       (GetTickCount64 - lastTick < RunBusyTickMs) then Exit;
    lastTick := GetTickCount64;
    busy.Detail := Dir;
    busy.Lines := Length(Hits);
    RunBusyHook(busy, cancel);
    { as DN: Esc asks before throwing the walk away }
    if cancel and (MsgBox('Find file', 'Stop the search?', ['Yes', 'No']) <> 0) then
    begin
      cancel := False;
      BusyBoxRedraw;           // the question box is gone: repaint under it
    end;
  end;

  procedure Add(const Path: AnsiString; IsDir: Boolean);
  begin
    SetLength(Hits, Length(Hits) + 1);
    Hits[High(Hits)].Path := Path;
    Hits[High(Hits)].IsDir := IsDir;
  end;

  { the advanced criteria on what stat said }
  function AdvancedOk(const st: Stat; const Full: AnsiString): Boolean;
  var
    mt: TDateTime;
  begin
    Result := True;
    if not O.Advanced then Exit;
    mt := UnixToDateTime(st.st_mtime, False);
    if (dAfter > 0) and (mt < dAfter) then Exit(False);
    if (dBefore > 0) and (mt >= dBefore + 1) then Exit(False);   // the whole day
    if (sGreater >= 0) and (st.st_size <= sGreater) then Exit(False);
    if (sLess >= 0) and (st.st_size >= sLess) then Exit(False);
    if O.OnlyReadOnly and (fpAccess(PChar(Full), W_OK) = 0) then Exit(False);
    if O.OnlyExecutable and ((st.st_mode and &111) = 0) then Exit(False);
  end;

  procedure Walk(const Dir: AnsiString; Depth: Integer);
  var
    sr: TSearchRec;
    full: AnsiString;
    st: Stat;
  begin
    if cancel or (Length(Hits) >= FindMaxHits) then Exit;
    Tick(Dir);
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile or faDirectory,
                 sr) <> 0 then
    begin
      FindClose(sr);
      Exit;
    end;
    try
      repeat
        if cancel or (Length(Hits) >= FindMaxHits) then Break;
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if not O.Hidden and (sr.Name[1] = '.') then Continue;
        full := IncludeTrailingPathDelimiter(Dir) + sr.Name;
        if fpLStat(PChar(full), st) <> 0 then Continue;
        if fpS_ISDIR(st.st_mode) then
        begin
          if nameOnly and MatchMask(sr.Name, masks) and AdvancedOk(st, full) then
            Add(full, True);
          if O.Recursive then Walk(full, Depth + 1);
          Continue;
        end;
        { a symbolic link: judge its target, never walk into it }
        if fpS_ISLNK(st.st_mode) and (fpStat(PChar(full), st) <> 0) then Continue;
        if fpS_ISDIR(st.st_mode) then
        begin
          if nameOnly and MatchMask(sr.Name, masks) and AdvancedOk(st, full) then
            Add(full, True);
          Continue;
        end;
        if not fpS_ISREG(st.st_mode) then Continue;   // FIFOs, sockets, devices
        if not MatchMask(sr.Name, masks) then Continue;
        if not AdvancedOk(st, full) then Continue;
        if (O.TypeFilter <> '') and not MatchesMagic(full, O.TypeFilter) then
          Continue;
        if (needle <> '') and
           not FileContains(full, needle, O.CaseSensitive or (O.Hex <> ''),
                            O.WholeWords and (O.Hex = '')) then
          Continue;
        Add(full, False);
        Tick(Dir);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;

begin
  SetLength(Hits, 0);
  Err := '';
  Result := True;
  masks := Trim(O.Masks);
  if masks = '' then masks := '*';
  needle := O.Text;
  if Trim(O.Hex) <> '' then
    if not ParseHex(O.Hex, needle) then
    begin
      Err := 'the hex string is not hex: ' + O.Hex;
      Exit;
    end;
  dAfter := 0; dBefore := 0; sGreater := -1; sLess := -1;
  if O.Advanced then
  begin
    if not ParseDay(O.DateAfter, dAfter) then Err := 'bad date: ' + O.DateAfter
    else if not ParseDay(O.DateBefore, dBefore) then Err := 'bad date: ' + O.DateBefore
    else if not ParseSize(O.SizeGreater, sGreater) then Err := 'bad size: ' + O.SizeGreater
    else if not ParseSize(O.SizeLess, sLess) then Err := 'bad size: ' + O.SizeLess;
    if Err <> '' then Exit;
  end;
  { a search by name alone lists matching directories too, as DN did }
  nameOnly := (needle = '') and (O.TypeFilter = '');
  busy.Title := 'Find file';
  busy.Detail := '';
  busy.CountWhat := 'found';
  busy.Lines := 0;
  busy.Percent := -1;
  busy.ElapsedMs := 0;
  start := GetTickCount64;
  lastTick := 0;
  cancel := False;
  for i := 0 to High(Roots) do
  begin
    if cancel then Break;
    if DirectoryExists(Roots[i]) then
      Walk(ExcludeTrailingPathDelimiter(Roots[i]), 0)
    else if FileExists(Roots[i]) and MatchMask(ExtractFileName(Roots[i]), masks) and
            ((needle = '') or FileContains(Roots[i], needle, O.CaseSensitive,
                                           O.WholeWords)) and
            ((O.TypeFilter = '') or MatchesMagic(Roots[i], O.TypeFilter)) then
      Add(Roots[i], False);
  end;
  Result := not cancel;
end;

function FindTitle(const O: TFindOptions): AnsiString;
begin
  Result := 'find: ' + O.Masks;
  if Trim(O.Hex) <> '' then Result := Result + ' hex ' + Trim(O.Hex)
  else if O.Text <> '' then Result := Result + ' "' + O.Text + '"';
  if O.TypeFilter <> '' then Result := Result + ' [' + O.TypeFilter + ']';
end;

{ --- the forms ------------------------------------------------------------------ }

function AdvancedDialog(var O: TFindOptions): Boolean;
var
  f: array[0..5] of TFormField;
begin
  f[0].Caption := 'Date is after (YYYY-MM-DD)'; f[0].Kind := fkText; f[0].Value := O.DateAfter;
  f[1].Caption := 'Date is before'; f[1].Kind := fkText; f[1].Value := O.DateBefore;
  f[2].Caption := 'Size is greater than (10K, 2M)'; f[2].Kind := fkText; f[2].Value := O.SizeGreater;
  f[3].Caption := 'Size is less than'; f[3].Kind := fkText; f[3].Value := O.SizeLess;
  f[4].Caption := 'Read-only'; f[4].Kind := fkCheck; f[4].Checked := O.OnlyReadOnly;
  f[5].Caption := 'Executable'; f[5].Kind := fkCheck; f[5].Checked := O.OnlyExecutable;
  Result := FormDialog('Advanced search', f);
  if not Result then Exit;
  O.DateAfter := Trim(f[0].Value);
  O.DateBefore := Trim(f[1].Value);
  O.SizeGreater := Trim(f[2].Value);
  O.SizeLess := Trim(f[3].Value);
  O.OnlyReadOnly := f[4].Checked;
  O.OnlyExecutable := f[5].Checked;
end;

function FindDialog(var O: TFindOptions): Boolean;
var
  names, values: array of AnsiString;
  levels: array of Integer;

  procedure AddItem(const Name: AnsiString; Level: Integer; const Value: AnsiString);
  begin
    SetLength(names, Length(names) + 1);
    names[High(names)] := Name;
    SetLength(levels, Length(levels) + 1);
    levels[High(levels)] := Level;
    SetLength(values, Length(values) + 1);
    values[High(values)] := Value;
  end;

const
  ScopeNames: array[TFindScope] of AnsiString =
    ('Current directory', 'Selected', 'Home directory', 'Entire disk');
var
  f: array[0..9] of TFormField;
  i, g: Integer;
  s: TFindScope;
begin
  { the content types as a tree: any; each group (= all its types) with
    its types under it. values[] is what the filter gets. }
  SetLength(names, 0);
  SetLength(levels, 0);
  SetLength(values, 0);
  AddItem('any', 0, '');
  for g := 0 to MagicGroupCount - 1 do
  begin
    AddItem(MagicGroupName(g) + ' (all)', 0, MagicGroupName(g));
    for i := 0 to MagicTypeCount - 1 do
      if MagicTypeGroup(i) = MagicGroupName(g) then
        AddItem(MagicTypeName(i), 1, MagicTypeName(i));
  end;

  f[0].Caption := 'File mask'; f[0].Kind := fkText; f[0].Value := O.Masks;
  f[1].Caption := 'Text to find'; f[1].Kind := fkText; f[1].Value := O.Text;
  f[2].Caption := 'Hex string'; f[2].Kind := fkText; f[2].Value := O.Hex;
  f[3].Caption := 'File type (content)'; f[3].Kind := fkChoice;
  SetLength(f[3].Options, Length(names));
  SetLength(f[3].Levels, Length(names));
  for i := 0 to High(names) do
  begin
    f[3].Options[i] := names[i];
    f[3].Levels[i] := levels[i];
  end;
  f[3].Index := 0;
  for i := 1 to High(values) do
    if (O.TypeFilter <> '') and (values[i] = O.TypeFilter) then
      f[3].Index := i;
  f[4].Caption := 'Advanced search...'; f[4].Kind := fkCheck; f[4].Checked := O.Advanced;
  f[5].Caption := 'Recursive search'; f[5].Kind := fkCheck; f[5].Checked := O.Recursive;
  f[6].Caption := 'Case sensitive'; f[6].Kind := fkCheck; f[6].Checked := O.CaseSensitive;
  f[7].Caption := 'Whole words'; f[7].Kind := fkCheck; f[7].Checked := O.WholeWords;
  f[8].Caption := 'Hidden files'; f[8].Kind := fkCheck; f[8].Checked := O.Hidden;
  f[9].Caption := 'Scope'; f[9].Kind := fkChoice;
  SetLength(f[9].Options, 4);
  for s := Low(TFindScope) to High(TFindScope) do
    f[9].Options[Ord(s)] := ScopeNames[s];
  f[9].Index := Ord(O.Scope);

  Result := FormDialog('Find File', f);
  if not Result then Exit;
  O.Masks := Trim(f[0].Value);
  if O.Masks = '' then O.Masks := '*';
  O.Text := f[1].Value;
  O.Hex := Trim(f[2].Value);
  O.TypeFilter := values[f[3].Index];
  O.Advanced := f[4].Checked;
  O.Recursive := f[5].Checked;
  O.CaseSensitive := f[6].Checked;
  O.WholeWords := f[7].Checked;
  O.Hidden := f[8].Checked;
  O.Scope := TFindScope(f[9].Index);
  if O.Advanced then
    Result := AdvancedDialog(O);
end;

{ --- the results panel ----------------------------------------------------------- }

constructor TFindVFS.CreateFind(const ARoot, ATitle: AnsiString; const AHits: TFindHits);
begin
  inherited Create;
  Root := ExcludeTrailingPathDelimiter(ARoot);
  if Root = '' then Root := '/';
  Title := ATitle;
  Hits := AHits;
end;

function TFindVFS.FullPath(const Name: AnsiString): AnsiString;
begin
  if (Name <> '') and (Name[1] = '/') then Result := Name    // joined already
  else Result := VfsJoin(Root, Name);
end;

function RelTo(const Root, Path: AnsiString): AnsiString;
var
  r: AnsiString;
begin
  r := IncludeTrailingPathDelimiter(Root);
  if Copy(Path, 1, Length(r)) = r then
    Result := Copy(Path, Length(r) + 1, MaxInt)
  else
    Result := Path;
end;

function TFindVFS.List(const Dir: AnsiString; out Items: TVfsItems;
                       out Err: AnsiString): Boolean;
var
  i, n: Integer;
  st: Stat;
begin
  Err := '';
  SetLength(Items, Length(Hits));
  n := 0;
  { a hit deleted, moved or renamed since the search drops out }
  for i := 0 to High(Hits) do
    if fpStat(PChar(Hits[i].Path), st) = 0 then
    begin
      Items[n].Name := RelTo(Root, Hits[i].Path);
      Items[n].Size := st.st_size;
      Items[n].MTime := UnixToDateTime(st.st_mtime, False);
      Items[n].IsDir := fpS_ISDIR(st.st_mode);
      Inc(n);
    end;
  SetLength(Items, n);
  Result := True;
end;

function TFindVFS.GetFile(const Path, LocalDest: AnsiString;
                          out Err: AnsiString): Boolean;
begin
  Result := LocalVFS.GetFile(FullPath(Path), LocalDest, Err);
end;

function TFindVFS.GetTree(const Path, LocalDest: AnsiString;
                          out Err: AnsiString): Boolean;
begin
  Result := LocalVFS.GetTree(FullPath(Path), LocalDest, Err);
end;

function TFindVFS.PutFile(const LocalSrc, Path: AnsiString;
                          out Err: AnsiString): Boolean;
begin
  Result := LocalVFS.PutFile(LocalSrc, FullPath(Path), Err);
end;

function TFindVFS.PutTree(const LocalSrc, Path: AnsiString;
                          out Err: AnsiString): Boolean;
begin
  Result := LocalVFS.PutTree(LocalSrc, FullPath(Path), Err);
end;

function TFindVFS.DeletePath(const Path: AnsiString; IsDir: Boolean;
                             out Err: AnsiString): Boolean;
begin
  Result := LocalVFS.DeletePath(FullPath(Path), IsDir, Err);
end;

function TFindVFS.MakeDir(const Path: AnsiString; out Err: AnsiString): Boolean;
begin
  Err := 'the find results are a list, not a directory';
  Result := False;
end;

function TFindVFS.Display(const Path: AnsiString): AnsiString;
var
  where: AnsiString;
begin
  { the panel title is cut from the left: the query goes first, the
    directory by its last name only }
  where := ExtractFileName(Root);
  if where = '' then where := '/';
  Result := Title + ' in ' + where;
end;

function TFindVFS.IsLocal: Boolean;
begin
  Result := True;
end;

function TFindVFS.IsRootPath(const Path: AnsiString): Boolean;
begin
  Result := True;                // a flat list: '..' leaves it
end;

function TFindVFS.ParentExit(out LocalDir, CursorName: AnsiString): Boolean;
begin
  LocalDir := Root;
  CursorName := '';
  Result := True;
end;

end.
