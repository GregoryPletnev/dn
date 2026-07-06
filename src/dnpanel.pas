{ dnpanel — a Dos Navigator file panel: listing, cursor, scrolling, drawing. }
unit dnpanel;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ncurses, dnscreen, dnvfs, dnoptions;

type
  TSortMode = (smName, smExt, smSize, smDate, smUnsorted);

  TFileRec = record
    Name: AnsiString;
    Size: Int64;
    MTime: TDateTime;
    IsDir: Boolean;
    Sel: Boolean;
    SizeKnown: Boolean;      // a directory whose size was counted (Ctrl-G)
  end;

  TPanel = class
  public
    Path: AnsiString;
    Files: array of TFileRec;
    Cur, Top: Integer;
    X0, W, H: Integer;      // panel geometry: left column, width, height (rows 1..H)
    Active: Boolean;
    SortMode: TSortMode;
    Mask: AnsiString;        // file mask filter, '' = all
    { visible columns (Left/Right menu > Columns...); Name is always on }
    ColSize, ColDate, ColTime: Boolean;
    Vfs: TVFS;               // never nil; LocalVFS by default
    constructor Create(const APath: AnsiString);
    destructor Destroy; override;
    { switch to another VFS (frees the old one unless it is LocalVFS) }
    procedure SetVfs(AVfs: TVFS; const APath: AnsiString);
    function DisplayPath: AnsiString;
    procedure Load;
    procedure Draw;
    procedure MoveCursor(delta: Integer);
    procedure EnterCurrent;
    procedure GoUp;
    procedure ToggleSelect;
    procedure InvertSel;
    procedure SelectByMask(const M: AnsiString; Val: Boolean);
    procedure InvertAll;
    procedure QuickJump(c: Char);
    function ListHeight: Integer;
    function CurFile: TFileRec;
    function ScrollbarVisible: Boolean;
    function ThumbRow: Integer;         // 1..ListHeight-2, relative to track
    procedure ClickScrollbar(relRow: Integer);
  end;

{ '*'/'?' mask match, case-insensitive; Masks may be a ','/';' list }
function MatchMask(const Name, Masks: AnsiString): Boolean;

implementation

function MatchOne(const n, m: AnsiString; ni, mi: Integer): Boolean;
begin
  while mi <= Length(m) do
  begin
    if m[mi] = '*' then
    begin
      if MatchOne(n, m, ni, mi + 1) then Exit(True);
      if ni > Length(n) then Exit(False);
      Inc(ni);
      Continue;
    end;
    if ni > Length(n) then Exit(False);
    if (m[mi] <> '?') and (m[mi] <> n[ni]) then Exit(False);
    Inc(ni);
    Inc(mi);
  end;
  Result := ni > Length(n);
end;

function MatchMask(const Name, Masks: AnsiString): Boolean;
var
  L: TStringList;
  i: Integer;
  n, m: AnsiString;
begin
  Result := False;
  n := LowerCase(Name);
  L := TStringList.Create;
  try
    L.Delimiter := ',';
    L.StrictDelimiter := True;
    L.DelimitedText := StringReplace(Masks, ';', ',', [rfReplaceAll]);
    for i := 0 to L.Count - 1 do
    begin
      m := LowerCase(Trim(L[i]));
      if (m <> '') and MatchOne(n, m, 1, 1) then Exit(True);
    end;
  finally
    L.Free;
  end;
end;

{ color pair for a file matching a highlight group, 0 = no match }
function HlPairFor(const Name: AnsiString): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to HlGroupCount do
    if (Opt.Hl[i].Mask <> '') and MatchMask(Name, Opt.Hl[i].Mask) then
      Exit(cpHl1 + i - 1);
end;

function FmtSize(Size: Int64): AnsiString;
var
  i: Integer;
begin
  if Opt.ExactSizes then
  begin
    { thousands-separated bytes while they fit the 9-char column }
    Result := IntToStr(Size);
    i := Length(Result) - 3;
    while i >= 1 do
    begin
      Insert(',', Result, i + 1);
      Dec(i, 3);
    end;
    if Length(Result) <= 9 then Exit;
  end;
  if Size < 10000000 then
    Result := IntToStr(Size)
  else if Size < Int64(10240) * 1024 * 1024 then
    Result := IntToStr(Size div 1024) + 'K'
  else
    Result := IntToStr(Size div (1024 * 1024)) + 'M';
end;

procedure SortFiles(var A: array of TFileRec; L, R: Integer; Mode: TSortMode);
var
  i, j: Integer;
  p, t: TFileRec;

  { strict weak ordering — Less(x, x) must be False, or quicksort's
    scan loops run off the array and hang }
  function Less(const a1, b1: TFileRec): Boolean;
  var
    c: Integer;
  begin
    if (a1.Name = '..') or (b1.Name = '..') then
      Exit((a1.Name = '..') and (b1.Name <> '..'));
    if a1.IsDir <> b1.IsDir then Exit(a1.IsDir);
    case Mode of
      smExt:
        begin
          c := AnsiCompareText(ExtractFileExt(a1.Name), ExtractFileExt(b1.Name));
          if c <> 0 then Exit(c < 0);
        end;
      smSize:
        if a1.Size <> b1.Size then Exit(a1.Size > b1.Size);   // largest first
      smDate:
        if a1.MTime <> b1.MTime then Exit(a1.MTime > b1.MTime); // newest first
    end;
    Result := AnsiCompareText(a1.Name, b1.Name) < 0;
  end;

begin
  i := L; j := R;
  p := A[(L + R) div 2];
  repeat
    while Less(A[i], p) do Inc(i);
    while Less(p, A[j]) do Dec(j);
    if i <= j then
    begin
      t := A[i]; A[i] := A[j]; A[j] := t;
      Inc(i); Dec(j);
    end;
  until i > j;
  if L < j then SortFiles(A, L, j, Mode);
  if i < R then SortFiles(A, i, R, Mode);
end;

constructor TPanel.Create(const APath: AnsiString);
begin
  Vfs := LocalVFS;
  Path := ExpandFileName(APath);
  Cur := 0;
  Top := 0;
  SortMode := smName;
  Mask := '';
  ColSize := Opt.ColSize;
  ColDate := Opt.ColDate;
  ColTime := Opt.ColTime;
  Load;
end;

destructor TPanel.Destroy;
begin
  if Vfs <> TVFS(LocalVFS) then
    Vfs.Free;
  inherited;
end;

procedure TPanel.SetVfs(AVfs: TVFS; const APath: AnsiString);
begin
  if (Vfs <> TVFS(LocalVFS)) and (Vfs <> AVfs) then
    Vfs.Free;
  Vfs := AVfs;
  Path := APath;
  Cur := 0;
  Top := 0;
  Load;
end;

function TPanel.DisplayPath: AnsiString;
begin
  if Vfs.IsLocal then
    Result := Path
  else
    Result := Vfs.Display(Path);
end;

procedure TPanel.Load;
var
  items: TVfsItems;
  err: AnsiString;
  i, n: Integer;
  hasUp: Boolean;
begin
  SetLength(Files, 0);
  n := 0;
  { '..' everywhere except the local root — inside a VFS it exits at root }
  hasUp := not (Vfs.IsLocal and (Path = '/'));
  if hasUp then
  begin
    SetLength(Files, 1);
    Files[0].Name := '..';
    Files[0].IsDir := True;
    Files[0].Size := 0;
    Files[0].MTime := 0;
    Files[0].Sel := False;
    n := 1;
  end;
  if Vfs.List(Path, items, err) then
    for i := 0 to High(items) do
    begin
      if not Opt.ShowHidden and (items[i].Name <> '') and
         (items[i].Name[1] = '.') then Continue;
      if (Mask <> '') and not items[i].IsDir and
         not MatchMask(items[i].Name, Mask) then Continue;
      SetLength(Files, n + 1);
      Files[n].Name := items[i].Name;
      Files[n].IsDir := items[i].IsDir;
      Files[n].Size := items[i].Size;
      Files[n].MTime := items[i].MTime;
      Files[n].Sel := False;
      Files[n].SizeKnown := False;
      Inc(n);
    end;
  if (n > 1) and (SortMode <> smUnsorted) then
    SortFiles(Files, 0, n - 1, SortMode);
  if Cur >= n then Cur := n - 1;
  if Cur < 0 then Cur := 0;
  if Top > Cur then Top := Cur;
end;

function TPanel.ListHeight: Integer;
begin
  Result := H - 4;  // minus top border, header, separator, mini-status (bottom border is row H+1)
end;

function TPanel.CurFile: TFileRec;
begin
  if (Cur >= 0) and (Cur < Length(Files)) then
    Result := Files[Cur]
  else
  begin
    Result.Name := '';
    Result.Size := 0;
    Result.MTime := 0;
    Result.IsDir := False;
    Result.Sel := False;
  end;
end;

procedure TPanel.Draw;
const
  MaxCols = 3;
  ColW: array[0..MaxCols - 1] of Integer = (9, 8, 5);   // Size, Date, Time
  ColTitle: array[0..MaxCols - 1] of AnsiString = ('Size ', 'Date ', 'Time ');
var
  inner, NmW, i, row, idx, pair, c, nc, x: Integer;
  title, line, nm: AnsiString;
  bold: Boolean;
  f: TFileRec;
  cols: array[0..MaxCols - 1] of Integer;   // active column kinds, in order
  cell: array[0..MaxCols - 1] of AnsiString;

  function CellText(const fr: TFileRec; kind: Integer): AnsiString;
  begin
    case kind of
      0: if fr.IsDir then
         begin
           if fr.Name = '..' then Result := '>UP--DIR<'
           else if fr.SizeKnown then Result := FmtSize(fr.Size)
           else Result := '>SUB-DIR<';
         end
         else
           Result := FmtSize(fr.Size);
      1: if fr.MTime > 0 then Result := FormatDateTime('mm-dd-yy', fr.MTime)
         else Result := '';
    else
      if fr.MTime > 0 then Result := FormatDateTime('hh:nn', fr.MTime)
      else Result := '';
    end;
    Result := PadLeft(Result, ColW[kind]);
  end;

begin
  inner := W - 2;

  { active columns; drop the rightmost ones if the panel is too narrow }
  nc := 0;
  if ColSize then begin cols[nc] := 0; Inc(nc); end;
  if ColDate then begin cols[nc] := 1; Inc(nc); end;
  if ColTime then begin cols[nc] := 2; Inc(nc); end;
  repeat
    NmW := inner;
    for c := 0 to nc - 1 do
      Dec(NmW, ColW[cols[c]] + 1);
    if (NmW < 8) and (nc > 0) then Dec(nc) else Break;
  until False;

  { top border with centered path title }
  title := ' ' + DisplayPath + ' ';
  if Utf8Len(title) > inner - 2 then
    title := ' …' + Utf8Copy(DisplayPath, Utf8Len(DisplayPath) - (inner - 6),
                             inner - 5) + ' ';
  PutStr(1, X0, bxTL + Rep(bxH, inner) + bxTR, cpFrame, True);
  if Active then
    PutStr(1, X0 + 1 + (inner - Utf8Len(title)) div 2, title, cpTitleAct)
  else
    PutStr(1, X0 + 1 + (inner - Utf8Len(title)) div 2, title, cpFrame, True);

  { column headers }
  PutStr(2, X0, bxV, cpFrame, True);
  PutStr(2, X0 + 1, PadRight(' Name', NmW), cpSelected, True);
  x := X0 + 1 + NmW;
  for c := 0 to nc - 1 do
  begin
    PutStr(2, x, bxColV, cpFrame, True);
    PutStr(2, x + 1, PadLeft(ColTitle[cols[c]], ColW[cols[c]]), cpSelected, True);
    x := x + 1 + ColW[cols[c]];
  end;
  PutStr(2, X0 + W - 1, bxV, cpFrame, True);

  { file rows }
  if Cur < Top then Top := Cur;
  if Cur >= Top + ListHeight then Top := Cur - ListHeight + 1;
  for i := 0 to ListHeight - 1 do
  begin
    row := 3 + i;
    idx := Top + i;
    PutStr(row, X0, bxV, cpFrame, True);
    if ScrollbarVisible then
    begin
      if i = 0 then
        PutStr(row, X0 + W - 1, '▲', cpFrame, True)
      else if i = ListHeight - 1 then
        PutStr(row, X0 + W - 1, '▼', cpFrame, True)
      else if i = ThumbRow then
        PutStr(row, X0 + W - 1, '■', cpFrame, True)
      else
        PutStr(row, X0 + W - 1, '▒', cpFrame, True);
    end
    else
      PutStr(row, X0 + W - 1, bxV, cpFrame, True);
    if idx < Length(Files) then
    begin
      f := Files[idx];
      nm := Utf8PadRight(f.Name, NmW);
      for c := 0 to nc - 1 do
        cell[c] := CellText(f, cols[c]);
      bold := f.IsDir;
      if Active and (idx = Cur) then
      begin
        if f.Sel then pair := cpSelCursor else pair := cpCursor;
        bold := f.Sel;
      end
      else if f.Sel then
      begin
        pair := cpSelected;
        bold := True;
      end
      else if f.IsDir then
        pair := cpDir
      else
      begin
        pair := HlPairFor(f.Name);
        if pair = 0 then pair := cpFile;
      end;
      PutStr(row, X0 + 1, nm, pair, bold);
      x := X0 + 1 + NmW;
      for c := 0 to nc - 1 do
      begin
        PutStr(row, x, bxColV, cpFrame, True);
        PutStr(row, x + 1, cell[c], pair, bold);
        x := x + 1 + ColW[cols[c]];
      end;
    end
    else
    begin
      PutStr(row, X0 + 1, StringOfChar(' ', NmW), cpFile);
      x := X0 + 1 + NmW;
      for c := 0 to nc - 1 do
      begin
        PutStr(row, x, bxColV, cpFrame, True);
        PutStr(row, x + 1, StringOfChar(' ', ColW[cols[c]]), cpFile);
        x := x + 1 + ColW[cols[c]];
      end;
    end;
  end;

  { separator + mini-status }
  line := bxSepL + Rep(bxSepH, NmW);
  for c := 0 to nc - 1 do
    line := line + bxColB + Rep(bxSepH, ColW[cols[c]]);
  line := line + bxSepR;
  PutStr(H - 1, X0, line, cpFrame, True);
  f := CurFile;
  if f.Name <> '' then
  begin
    if f.IsDir then
      line := ' ' + f.Name
    else
      line := ' ' + f.Name + '  ' + FmtSize(f.Size);
    if f.MTime > 0 then
      line := line + '  ' + FormatDateTime('mm-dd-yy hh:nn', f.MTime);
  end
  else
    line := '';
  PutStr(H, X0, bxV, cpFrame, True);
  PutStr(H, X0 + 1, Utf8PadRight(line, inner), cpFrame, True);
  PutStr(H, X0 + W - 1, bxV, cpFrame, True);

  { bottom border }
  PutStr(H + 1, X0, bxBL + Rep(bxH, inner) + bxBR, cpFrame, True);
end;

procedure TPanel.MoveCursor(delta: Integer);
begin
  Cur := Cur + delta;
  if Cur < 0 then Cur := 0;
  if Cur > Length(Files) - 1 then Cur := Length(Files) - 1;
  if Cur < 0 then Cur := 0;
end;

procedure TPanel.EnterCurrent;
var
  f: TFileRec;
begin
  f := CurFile;
  if f.Name = '' then Exit;
  if not f.IsDir then Exit;
  if f.Name = '..' then
  begin
    GoUp;
    Exit;
  end;
  Path := VfsJoin(Path, f.Name);
  Cur := 0;
  Top := 0;
  Load;
end;

procedure TPanel.GoUp;
var
  prev, ldir, lcur: AnsiString;
  i, p: Integer;
begin
  if (Path = '') or (Path = '/') then
  begin
    { at the VFS root: leave the VFS (archive -> its local directory) }
    if Vfs.ParentExit(ldir, lcur) then
    begin
      SetVfs(LocalVFS, ldir);
      for i := 0 to High(Files) do
        if Files[i].Name = lcur then
        begin
          Cur := i;
          Break;
        end;
    end;
    Exit;
  end;
  p := Length(Path);
  while (p > 0) and (Path[p] <> '/') do
    Dec(p);
  prev := Copy(Path, p + 1, MaxInt);
  if Vfs.IsLocal then
  begin
    Path := Copy(Path, 1, p - 1);
    if Path = '' then Path := '/';
  end
  else
    Path := Copy(Path, 1, p - 1);   // '' = VFS root
  Cur := 0;
  Top := 0;
  Load;
  for i := 0 to Length(Files) - 1 do
    if Files[i].Name = prev then
    begin
      Cur := i;
      Break;
    end;
end;

procedure TPanel.ToggleSelect;
begin
  InvertSel;
  MoveCursor(1);
end;

procedure TPanel.InvertSel;
begin
  if (Cur >= 0) and (Cur < Length(Files)) and (Files[Cur].Name <> '..') then
    Files[Cur].Sel := not Files[Cur].Sel;
end;

procedure TPanel.SelectByMask(const M: AnsiString; Val: Boolean);
var
  i: Integer;
begin
  for i := 0 to High(Files) do
    if (Files[i].Name <> '..') and not Files[i].IsDir and
       MatchMask(Files[i].Name, M) then
      Files[i].Sel := Val;
end;

procedure TPanel.InvertAll;
var
  i: Integer;
begin
  for i := 0 to High(Files) do
    if (Files[i].Name <> '..') and not Files[i].IsDir then
      Files[i].Sel := not Files[i].Sel;
end;

procedure TPanel.QuickJump(c: Char);
var
  i, idx: Integer;
begin
  c := LowerCase(c);
  for i := 1 to Length(Files) do
  begin
    idx := (Cur + i) mod Length(Files);
    if (Files[idx].Name <> '') and (LowerCase(Files[idx].Name[1]) = c) then
    begin
      Cur := idx;
      Exit;
    end;
  end;
end;

function TPanel.ScrollbarVisible: Boolean;
begin
  Result := (Length(Files) > ListHeight) and (ListHeight >= 4);
end;

function TPanel.ThumbRow: Integer;
var
  track: Integer;
begin
  track := ListHeight - 2;                 // rows between the two arrows
  if Length(Files) <= 1 then Exit(1);
  Result := 1 + (Cur * (track - 1)) div (Length(Files) - 1);
end;

procedure TPanel.ClickScrollbar(relRow: Integer);
begin
  if relRow = 0 then
    MoveCursor(-1)
  else if relRow = ListHeight - 1 then
    MoveCursor(1)
  else if relRow < ThumbRow then
    MoveCursor(-ListHeight)
  else if relRow > ThumbRow then
    MoveCursor(ListHeight);
end;

end.
