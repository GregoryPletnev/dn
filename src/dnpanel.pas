{ dnpanel — a Dos Navigator file panel: listing, cursor, scrolling, drawing. }
unit dnpanel;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ncurses, dnscreen;

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
    constructor Create(const APath: AnsiString);
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

function FmtSize(Size: Int64): AnsiString;
begin
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
  Path := ExpandFileName(APath);
  Cur := 0;
  Top := 0;
  SortMode := smName;
  Mask := '';
  Load;
end;

procedure TPanel.Load;
var
  sr: TSearchRec;
  n: Integer;
begin
  SetLength(Files, 0);
  n := 0;
  if Path <> '/' then
  begin
    SetLength(Files, 1);
    Files[0].Name := '..';
    Files[0].IsDir := True;
    Files[0].Size := 0;
    Files[0].MTime := 0;
    Files[0].Sel := False;
    n := 1;
  end;
  if FindFirst(IncludeTrailingPathDelimiter(Path) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if (Mask <> '') and ((sr.Attr and faDirectory) = 0) and
         not MatchMask(sr.Name, Mask) then Continue;
      SetLength(Files, n + 1);
      Files[n].Name := sr.Name;
      Files[n].IsDir := (sr.Attr and faDirectory) <> 0;
      Files[n].Size := sr.Size;
      Files[n].MTime := FileDateToDateTime(sr.Time);
      Files[n].Sel := False;
      Files[n].SizeKnown := False;
      Inc(n);
    until FindNext(sr) <> 0;
    FindClose(sr);
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
  SzW = 9;   // size column
  DtW = 8;   // date column "mm-dd-yy"
var
  inner, NmW, i, row, idx, pair: Integer;
  title, line, nm, sz, dt: AnsiString;
  bold: Boolean;
  f: TFileRec;
begin
  inner := W - 2;
  NmW := inner - SzW - DtW - 2;

  { top border with centered path title }
  title := ' ' + Path + ' ';
  if Utf8Len(title) > inner - 2 then
    title := ' …' + Utf8Copy(Path, Utf8Len(Path) - (inner - 6), inner - 5) + ' ';
  PutStr(1, X0, bxTL + Rep(bxH, inner) + bxTR, cpFrame, True);
  if Active then
    PutStr(1, X0 + 1 + (inner - Utf8Len(title)) div 2, title, cpTitleAct)
  else
    PutStr(1, X0 + 1 + (inner - Utf8Len(title)) div 2, title, cpFrame, True);

  { column headers }
  PutStr(2, X0, bxV, cpFrame, True);
  PutStr(2, X0 + 1, PadRight(' Name', NmW), cpSelected, True);
  PutStr(2, X0 + 1 + NmW, bxColV, cpFrame, True);
  PutStr(2, X0 + 1 + NmW + 1, PadLeft('Size ', SzW), cpSelected, True);
  PutStr(2, X0 + 1 + NmW + 1 + SzW, bxColV, cpFrame, True);
  PutStr(2, X0 + 1 + NmW + 1 + SzW + 1, PadLeft('Date ', DtW), cpSelected, True);
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
      if f.IsDir then
      begin
        if f.Name = '..' then sz := PadLeft('>UP--DIR<', SzW)
        else if f.SizeKnown then sz := PadLeft(FmtSize(f.Size), SzW)
        else sz := PadLeft('>SUB-DIR<', SzW);
      end
      else
        sz := PadLeft(FmtSize(f.Size), SzW);
      if f.MTime > 0 then
        dt := FormatDateTime('mm-dd-yy', f.MTime)
      else
        dt := StringOfChar(' ', DtW);
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
        pair := cpFile;
      PutStr(row, X0 + 1, nm, pair, bold);
      PutStr(row, X0 + 1 + NmW, bxColV, cpFrame, True);
      PutStr(row, X0 + 1 + NmW + 1, sz, pair, bold);
      PutStr(row, X0 + 1 + NmW + 1 + SzW, bxColV, cpFrame, True);
      PutStr(row, X0 + 1 + NmW + 1 + SzW + 1, PadLeft(dt, DtW), pair, bold);
    end
    else
    begin
      PutStr(row, X0 + 1, StringOfChar(' ', NmW), cpFile);
      PutStr(row, X0 + 1 + NmW, bxColV, cpFrame, True);
      PutStr(row, X0 + 1 + NmW + 1, StringOfChar(' ', SzW), cpFile);
      PutStr(row, X0 + 1 + NmW + 1 + SzW, bxColV, cpFrame, True);
      PutStr(row, X0 + 1 + NmW + 1 + SzW + 1, StringOfChar(' ', DtW), cpFile);
    end;
  end;

  { separator + mini-status }
  PutStr(H - 1, X0,
    bxSepL + Rep(bxSepH, NmW) + bxColB + Rep(bxSepH, SzW) + bxColB + Rep(bxSepH, DtW) + bxSepR,
    cpFrame, True);
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
  Path := IncludeTrailingPathDelimiter(Path) + f.Name;
  Cur := 0;
  Top := 0;
  Load;
end;

procedure TPanel.GoUp;
var
  prev: AnsiString;
  i: Integer;
begin
  if Path = '/' then Exit;
  prev := ExtractFileName(Path);
  Path := ExtractFileDir(Path);
  if Path = '' then Path := '/';
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
