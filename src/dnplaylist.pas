{ dnplaylist — playlist model, directory scanning and tag reading for the
  media player (PLAYER.md). Pure logic: no ncurses, no terminal, fully
  unit-testable.

  A playlist is an ordered list of TTrack. Tracks are collected from a
  directory (recursively), from an .m3u/.m3u8 file, or from DN's own .dnpl
  format. Tags (ID3v2.3/2.4, ID3v1, Vorbis comments) are read best-effort:
  on any parse error the track keeps its filename. }
unit dnplaylist;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TTrack = record
    Path: AnsiString;       // full local path
    Title: AnsiString;      // tag title, '' if unknown
    Artist: AnsiString;
    Album: AnsiString;
    Duration: Integer;      // seconds, 0 = unknown
  end;
  TTrackArray = array of TTrack;

  TPlaylist = class
  private
    FTracks: TTrackArray;
    FName: AnsiString;      // source: file or directory, for the window title
  public
    constructor Create;
    function Count: Integer;
    function Get(Index: Integer): TTrack;
    procedure Clear;
    procedure Add(const T: TTrack);
    procedure Insert(Index: Integer; const T: TTrack);
    procedure Delete(Index: Integer);
    procedure Move(From, ATo: Integer);
    { replace the whole list }
    procedure SetTracks(const A: TTrackArray);
    { a copy of the whole list }
    function GetTracks: TTrackArray;
    property Name: AnsiString read FName write FName;
    { total duration in seconds of tracks with a known duration }
    function TotalDuration: Integer;
    { display label: 'Artist — Title' or the filename }
    function RowLabel(Index: Integer): AnsiString;
    function DisplayName(Index: Integer): AnsiString;
  end;

const
  { extensions the player queues and the panel recognizes as audio }
  AudioExts: array[0..10] of AnsiString =
    ('.mp3', '.m4a', '.aac', '.flac', '.ogg', '.oga', '.opus',
     '.wav', '.aiff', '.aif', '.wma');

{ True if the filename has one of AudioExts (case-insensitive). }
function IsAudioFile(const Name: AnsiString): Boolean;

{ Collect audio files under Dir. Recursive=True descends into subdirectories.
  Sorted by full path. Hidden files and hidden directories are skipped. }
function ScanDir(const Dir: AnsiString; Recursive: Boolean): TTrackArray;

{ Read tags for one file. Never raises: on any error Title stays ''. }
procedure ReadTags(const Path: AnsiString; var T: TTrack);
{ Fill Title/Artist/Album/Duration from tags where they are empty. }
procedure FillTags(var T: TTrack);

{ Playlist files ------------------------------------------------------- }

{ Load an .m3u/.m3u8 file. Relative paths resolve against the playlist's
  directory. Entries that do not exist are still kept (a playlist may point
  at removable media). Returns False if the file cannot be read. }
function LoadM3U(const Path: AnsiString; var A: TTrackArray): Boolean;

{ Save the tracks as an .m3u8 file (UTF-8, #EXTM3U + #EXTINF lines). }
function SaveM3U(const Path: AnsiString; const A: TTrackArray): Boolean;

{ DN's own playlist format: '#DNPL' header, then one '#EXTINF:<sec>|<artist>|
  <album>|<title>' line followed by the path. Round-trips more metadata than
  .m3u and is what F2 writes when the name ends in .dnpl. }
function LoadDnpl(const Path: AnsiString; var A: TTrackArray): Boolean;
function SaveDnpl(const Path: AnsiString; const A: TTrackArray): Boolean;

{ Load a playlist file by extension (.m3u/.m3u8/.dnpl). Returns False for an
  unknown extension. }
function LoadPlaylist(const Path: AnsiString; var A: TTrackArray): Boolean;

{ Format seconds as M:SS or H:MM:SS; '' for 0. }
function FormatTime(Sec: Integer): AnsiString;

implementation

uses
  SysUtils;

constructor TPlaylist.Create;
begin
  FTracks := nil;
  FName := '';
end;

function TPlaylist.Count: Integer;
begin
  Result := Length(FTracks);
end;

function TPlaylist.Get(Index: Integer): TTrack;
begin
  if (Index >= 0) and (Index < Length(FTracks)) then
    Result := FTracks[Index]
  else
    FillChar(Result, SizeOf(Result), 0);
end;

procedure TPlaylist.Clear;
begin
  SetLength(FTracks, 0);
end;

procedure TPlaylist.Add(const T: TTrack);
begin
  SetLength(FTracks, Length(FTracks) + 1);
  FTracks[High(FTracks)] := T;
end;

procedure TPlaylist.Insert(Index: Integer; const T: TTrack);
var
  i: Integer;
begin
  if Index < 0 then Index := 0;
  if Index > Length(FTracks) then Index := Length(FTracks);
  SetLength(FTracks, Length(FTracks) + 1);
  for i := High(FTracks) downto Index + 1 do
    FTracks[i] := FTracks[i - 1];
  FTracks[Index] := T;
end;

procedure TPlaylist.Delete(Index: Integer);
var
  i: Integer;
begin
  if (Index < 0) or (Index >= Length(FTracks)) then Exit;
  for i := Index to High(FTracks) - 1 do
    FTracks[i] := FTracks[i + 1];
  SetLength(FTracks, Length(FTracks) - 1);
end;

procedure TPlaylist.Move(From, ATo: Integer);
var
  t: TTrack;
  i: Integer;
begin
  if (From < 0) or (From > High(FTracks)) then Exit;
  if (ATo < 0) or (ATo > High(FTracks)) then Exit;
  if From = ATo then Exit;
  t := FTracks[From];
  if From < ATo then
    for i := From to ATo - 1 do
      FTracks[i] := FTracks[i + 1]
  else
    for i := From downto ATo + 1 do
      FTracks[i] := FTracks[i - 1];
  FTracks[ATo] := t;
end;

procedure TPlaylist.SetTracks(const A: TTrackArray);
begin
  FTracks := A;
end;

function TPlaylist.GetTracks: TTrackArray;
begin
  Result := Copy(FTracks, 0, Length(FTracks));
end;

function TPlaylist.TotalDuration: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FTracks) do
    Inc(Result, FTracks[i].Duration);
end;

function TPlaylist.RowLabel(Index: Integer): AnsiString;
var
  T: TTrack;
begin
  Result := '';
  if (Index < 0) or (Index > High(FTracks)) then Exit;
  T := FTracks[Index];
  if T.Artist <> '' then
  begin
    if T.Title <> '' then
      Result := T.Artist + ' — ' + T.Title
    else
      Result := T.Artist + ' — ' + ExtractFileName(T.Path);
  end
  else if T.Title <> '' then
    Result := T.Title
  else
    Result := ExtractFileName(T.Path);
end;

function TPlaylist.DisplayName(Index: Integer): AnsiString;
begin
  Result := RowLabel(Index);
end;

function IsAudioFile(const Name: AnsiString): Boolean;
var
  e: AnsiString;
  i: Integer;
begin
  Result := False;
  e := LowerCase(ExtractFileExt(Name));
  if e = '' then Exit;
  for i := 0 to High(AudioExts) do
    if e = AudioExts[i] then Exit(True);
end;

function ScanDir(const Dir: AnsiString; Recursive: Boolean): TTrackArray;
var
  L: TStringList;

  procedure Walk(const D: AnsiString);
  var
    sr: TSearchRec;
    full, name: AnsiString;
    T: TTrack;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(D) + '*', faAnyFile, sr) <> 0 then
      Exit;
    try
      repeat
        name := sr.Name;
        if (name = '.') or (name = '..') then Continue;
        if (Length(name) > 0) and (name[1] = '.') then Continue;  // hidden
        full := IncludeTrailingPathDelimiter(D) + name;
        if (sr.Attr and faDirectory) <> 0 then
        begin
          if Recursive then Walk(full);
        end
        else if IsAudioFile(name) then
          L.Add(full);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;

var
  i: Integer;
begin
  Result := nil;
  if not DirectoryExists(Dir) then Exit;
  L := TStringList.Create;
  try
    L.Sorted := True;
    L.Duplicates := dupAccept;
    Walk(Dir);
    SetLength(Result, L.Count);
    for i := 0 to L.Count - 1 do
    begin
      FillChar(Result[i], SizeOf(Result[i]), 0);
      Result[i].Path := L[i];
      FillTags(Result[i]);
    end;
  finally
    L.Free;
  end;
end;

{ --- tag reading ------------------------------------------------------ }

function SyncSafe(b0, b1, b2, b3: Byte): Integer;
begin
  Result := ((b0 and $7F) shl 21) or ((b1 and $7F) shl 14) or
            ((b2 and $7F) shl 7) or (b3 and $7F);
end;

function BeU32(b0, b1, b2, b3: Byte): LongWord;
begin
  Result := (LongWord(b0) shl 24) or (LongWord(b1) shl 16) or
            (LongWord(b2) shl 8) or LongWord(b3);
end;

{ strip a trailing NUL and any UTF-16 BOM / leading NULs, keep it simple:
  ID3v2 text frames are either ISO-8859-1 (1) or UTF-16 (0/2, with BOM). }
function CleanId3Text(const s: AnsiString): AnsiString;
var
  i: Integer;
  isUtf16: Boolean;
  src, out_: AnsiString;
begin
  src := s;
  while (src <> '') and (src[Length(src)] = #0) do
    SetLength(src, Length(src) - 1);
  if src = '' then Exit('');
  isUtf16 := False;
  i := 1;
  if (Length(src) >= 2) and (src[1] = #$FF) and (src[2] = #$FE) then
  begin
    isUtf16 := True;
    i := 3;
  end
  else if (Length(src) >= 2) and (src[1] = #$FE) and (src[2] = #$FF) then
  begin
    isUtf16 := True;
    i := 3;
  end;
  if not isUtf16 then Exit(src);
  { naive UTF-16 → ASCII: keep the low byte of each pair when it is
    printable, otherwise drop it. Tags in non-Latin scripts are rare in
    terminal playlists; this is a best-effort display, not a converter. }
  out_ := '';
  while i + 1 <= Length(src) do
  begin
    if (Ord(src[i]) >= 32) and (Ord(src[i]) < 127) then
      out_ := out_ + src[i];
    Inc(i, 2);
  end;
  Result := out_;
end;

function ReadId3v2(const Path: AnsiString; var T: TTrack): Boolean;
var
  f: TFileStream;
  hdr: array[0..9] of Byte;
  buf: array of Byte;
  bodyLen, p, frameLen, size: Integer;
  enc: Byte;
  id: AnsiString;
  s: AnsiString;
  i: Integer;
begin
  Result := False;
  f := nil;
  try
    f := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    if f.Size < 10 then Exit;
    if f.Read(hdr, 10) <> 10 then Exit;
    if (hdr[0] <> Ord('I')) or (hdr[1] <> Ord('D')) or (hdr[2] <> Ord('3')) then
      Exit;
    bodyLen := SyncSafe(hdr[6], hdr[7], hdr[8], hdr[9]);
    if bodyLen <= 0 then Exit;
    if bodyLen > 4 * 1024 * 1024 then bodyLen := 4 * 1024 * 1024;
    SetLength(buf, bodyLen);
    size := f.Read(buf[0], bodyLen);
    if size <= 0 then Exit;
    p := 0;
    while p + 10 <= size do
    begin
      id := Chr(buf[p]) + Chr(buf[p + 1]) + Chr(buf[p + 2]) + Chr(buf[p + 3]);
      if id[1] = #0 then Break;
      frameLen := BeU32(buf[p + 4], buf[p + 5], buf[p + 6], buf[p + 7]);
      if (frameLen <= 0) or (p + 10 + frameLen > size) then Break;
      if (id = 'TIT2') or (id = 'TPE1') or (id = 'TALB') or (id = 'TLEN') then
      begin
        enc := buf[p + 10];
        SetLength(s, frameLen - 1);
        for i := 0 to frameLen - 2 do
          s[i + 1] := Chr(buf[p + 11 + i]);
        if (enc = 1) or (enc = 2) then
          s := CleanId3Text(s)
        else
        begin
          while (s <> '') and (s[Length(s)] = #0) do
            SetLength(s, Length(s) - 1);
        end;
        if id = 'TIT2' then T.Title := s
        else if id = 'TPE1' then T.Artist := s
        else if id = 'TALB' then T.Album := s
        else if id = 'TLEN' then
          T.Duration := StrToIntDef(s, T.Duration * 1000) div 1000;
      end;
      Inc(p, 10 + frameLen);
    end;
    Result := True;
  except
    Result := False;
  end;
  if f <> nil then f.Free;
end;

function ReadId3v1(const Path: AnsiString; var T: TTrack): Boolean;
var
  f: TFileStream;
  tag: array[0..127] of Byte;
  s: AnsiString;
  i: Integer;

  function Field(off, len: Integer): AnsiString;
  var
    j: Integer;
    c: Byte;
  begin
    Result := '';
    for j := 0 to len - 1 do
    begin
      c := tag[off + j];
      if c = 0 then Break;
      Result := Result + Chr(c);
    end;
    while (Result <> '') and (Result[Length(Result)] = ' ') do
      SetLength(Result, Length(Result) - 1);
  end;

begin
  Result := False;
  f := nil;
  try
    f := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    if f.Size < 128 then Exit;
    f.Seek(f.Size - 128, soBeginning);
    if f.Read(tag, 128) <> 128 then Exit;
    if (tag[0] <> Ord('T')) or (tag[1] <> Ord('A')) or (tag[2] <> Ord('G')) then
      Exit;
    s := Field(3, 30);
    if (T.Title = '') and (s <> '') then T.Title := s;
    s := Field(33, 30);
    if (T.Artist = '') and (s <> '') then T.Artist := s;
    s := Field(63, 30);
    if (T.Album = '') and (s <> '') then T.Album := s;
    Result := True;
  except
    Result := False;
  end;
  if f <> nil then f.Free;
end;

{ Vorbis comment: the second packet after the identification header for
  Ogg/Opus. A full Ogg page walk is overkill for a playlist label; scan the
  file for a 'TITLE='/'ARTIST='/'ALBUM=' occurrence inside the comment
  packet. }
function ReadVorbis(const Path: AnsiString; var T: TTrack): Boolean;
var
  f: TFileStream;
  buf: array of Byte;
  n, i, p: Integer;
  s: AnsiString;

  function Grab(const Key: AnsiString): AnsiString;
  var
    j, k: Integer;
  begin
    Result := '';
    j := 0;
    while j <= n - Length(Key) - 1 do
    begin
      k := 1;
      while (k <= Length(Key)) and (Chr(buf[j + k - 1]) = Key[k]) do Inc(k);
      if k > Length(Key) then
      begin
        Inc(j, Length(Key));
        while (j < n) and (buf[j] <> 0) and (buf[j] <> 10) and (buf[j] <> 13) do
        begin
          if buf[j] >= 32 then Result := Result + Chr(buf[j]);
          Inc(j);
        end;
        Exit;
      end;
      Inc(j);
    end;
  end;

begin
  Result := False;
  f := nil;
  try
    f := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    if f.Size < 64 then Exit;
    n := 256 * 1024;
    if n > f.Size then n := f.Size;
    SetLength(buf, n);
    n := f.Read(buf[0], n);
    p := 0;
    s := Grab('TITLE=');
    if (T.Title = '') and (s <> '') then T.Title := s;
    s := Grab('ARTIST=');
    if (T.Artist = '') and (s <> '') then T.Artist := s;
    s := Grab('ALBUM=');
    if (T.Album = '') and (s <> '') then T.Album := s;
    Result := True;
  except
    Result := False;
  end;
  if f <> nil then f.Free;
end;

procedure ReadTags(const Path: AnsiString; var T: TTrack);
begin
  try
    ReadId3v2(Path, T);
    ReadId3v1(Path, T);
    ReadVorbis(Path, T);
  except
    { best-effort: leave the track with its filename }
  end;
end;

procedure FillTags(var T: TTrack);
begin
  ReadTags(T.Path, T);
end;

{ --- playlist files --------------------------------------------------- }

function LoadM3U(const Path: AnsiString; var A: TTrackArray): Boolean;
var
  L: TStringList;
  i: Integer;
  base, line, title: AnsiString;
  T: TTrack;
  secs: Integer;
  comma: Integer;
  pendingSecs: Integer;
  pendingTitle: AnsiString;
begin
  Result := False;
  A := nil;
  if not FileExists(Path) then Exit;
  base := ExtractFileDir(Path);
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      Exit;
    end;
    pendingSecs := 0;
    pendingTitle := '';
    for i := 0 to L.Count - 1 do
    begin
      line := Trim(L[i]);
      if line = '' then Continue;
      if (Copy(line, 1, 1) = '#') then
      begin
        if Copy(UpperCase(line), 1, 8) = '#EXTINF:' then
        begin
          title := Copy(line, 9, MaxInt);
          comma := Pos(',', title);
          if comma > 0 then
          begin
            pendingSecs := StrToIntDef(Copy(title, 1, comma - 1), 0);
            pendingTitle := Trim(Copy(title, comma + 1, MaxInt));
          end;
        end;
        Continue;
      end;
      FillChar(T, SizeOf(T), 0);
      if (Length(line) > 0) and (line[1] = '/') then
        T.Path := line
      else
        T.Path := IncludeTrailingPathDelimiter(base) + line;
      T.Title := pendingTitle;
      T.Duration := pendingSecs;
      pendingTitle := '';
      pendingSecs := 0;
      begin SetLength(A, Length(A) + 1); A[High(A)] := T; end;
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

function SaveM3U(const Path: AnsiString; const A: TTrackArray): Boolean;
var
  L: TStringList;
  i: Integer;
  t: TTrack;
  title: AnsiString;
begin
  Result := False;
  L := TStringList.Create;
  try
    L.Add('#EXTM3U');
    for i := 0 to High(A) do
    begin
      t := A[i];
      title := t.Title;
      if t.Artist <> '' then
      begin
        if title <> '' then title := t.Artist + ' - ' + title
        else title := t.Artist;
      end;
      if title = '' then title := ExtractFileName(t.Path);
      L.Add('#EXTINF:' + IntToStr(t.Duration) + ',' + title);
      L.Add(t.Path);
    end;
    try
      L.SaveToFile(Path);
      Result := True;
    except
      Result := False;
    end;
  finally
    L.Free;
  end;
end;

function LoadDnpl(const Path: AnsiString; var A: TTrackArray): Boolean;
var
  L: TStringList;
  i, p, q: Integer;
  line, rest, secs, artist, album, title: AnsiString;
  T: TTrack;
  base: AnsiString;
begin
  Result := False;
  A := nil;
  if not FileExists(Path) then Exit;
  base := ExtractFileDir(Path);
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      Exit;
    end;
    secs := ''; artist := ''; album := ''; title := '';
    for i := 0 to L.Count - 1 do
    begin
      line := Trim(L[i]);
      if line = '' then Continue;
      if UpperCase(line) = '#DNPL' then Continue;
      if Copy(UpperCase(line), 1, 8) = '#EXTINF:' then
      begin
        rest := Copy(line, 9, MaxInt);
        p := Pos('|', rest);
        if p > 0 then
        begin
          secs := Copy(rest, 1, p - 1);
          rest := Copy(rest, p + 1, MaxInt);
          p := Pos('|', rest);
          if p > 0 then
          begin
            artist := Copy(rest, 1, p - 1);
            rest := Copy(rest, p + 1, MaxInt);
            p := Pos('|', rest);
            if p > 0 then
            begin
              album := Copy(rest, 1, p - 1);
              title := Copy(rest, p + 1, MaxInt);
            end
            else
            begin
              album := '';
              title := rest;
            end;
          end
          else
          begin
            artist := ''; album := ''; title := rest;
          end;
        end
        else
          secs := rest;
        Continue;
      end;
      FillChar(T, SizeOf(T), 0);
      if (Length(line) > 0) and (line[1] = '/') then
        T.Path := line
      else
        T.Path := IncludeTrailingPathDelimiter(base) + line;
      T.Duration := StrToIntDef(secs, 0);
      T.Artist := artist;
      T.Album := album;
      T.Title := title;
      secs := ''; artist := ''; album := ''; title := '';
      begin SetLength(A, Length(A) + 1); A[High(A)] := T; end;
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

function SaveDnpl(const Path: AnsiString; const A: TTrackArray): Boolean;
var
  L: TStringList;
  i: Integer;
  t: TTrack;
begin
  Result := False;
  L := TStringList.Create;
  try
    L.Add('#DNPL');
    for i := 0 to High(A) do
    begin
      t := A[i];
      L.Add('#EXTINF:' + IntToStr(t.Duration) + '|' + t.Artist + '|' +
             t.Album + '|' + t.Title);
      L.Add(t.Path);
    end;
    try
      L.SaveToFile(Path);
      Result := True;
    except
      Result := False;
    end;
  finally
    L.Free;
  end;
end;

function LoadPlaylist(const Path: AnsiString; var A: TTrackArray): Boolean;
var
  e: AnsiString;
begin
  e := LowerCase(ExtractFileExt(Path));
  if (e = '.dnpl') then
    Result := LoadDnpl(Path, A)
  else
    Result := LoadM3U(Path, A);
end;

function FormatTime(Sec: Integer): AnsiString;
var
  h, m, s: Integer;
begin
  Result := '';
  if Sec <= 0 then Exit;
  h := Sec div 3600;
  m := (Sec div 60) mod 60;
  s := Sec mod 60;
  if h > 0 then
    Result := Format('%d:%.2d:%.2d', [h, m, s])
  else
    Result := Format('%d:%.2d', [m, s]);
end;

end.
