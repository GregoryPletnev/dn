{ unittests — FPC-native unit tests for pure logic (no terminal needed).
  Runs as part of `make test` before the Python end-to-end suite. }
program unittests;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, dnscreen, dnpanel, dnfileops, dnuu, dnvfs, dnsftp,
  dnsession, dnusermenu, dnhighlite, dnplaylist, dnaudio, dnlsproto,
  dnhtml, dncss;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(cond: Boolean; const name: AnsiString);
begin
  Inc(Checks);
  if not cond then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', name);
  end;
end;

procedure CheckEq(const got, want, name: AnsiString);
begin
  Inc(Checks);
  if got <> want then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', name, ': got "', got, '", want "', want, '"');
  end;
end;

procedure TestUtf8;
begin
  Check(Utf8Len('') = 0, 'Utf8Len empty');  Check(Utf8Len('abc') = 3, 'Utf8Len ascii');
  Check(Utf8Len('привет') = 6, 'Utf8Len cyrillic');
  Check(Utf8Len('aпb') = 3, 'Utf8Len mixed');
  Check(Utf8CharBytes('a', 1) = 1, 'Utf8CharBytes ascii');
  Check(Utf8CharBytes('п', 1) = 2, 'Utf8CharBytes cyrillic');
  Check(Utf8CharBytes('€', 1) = 3, 'Utf8CharBytes euro');
  Check(Utf8BytePos('пример', 1) = 1, 'Utf8BytePos first');
  Check(Utf8BytePos('пример', 3) = 5, 'Utf8BytePos third');
  CheckEq(Utf8Copy('привет мир', 8, 3), 'мир', 'Utf8Copy tail');
  CheckEq(Utf8Copy('привет', 1, 2), 'пр', 'Utf8Copy head');
  CheckEq(Utf8Copy('abc', 2, 5), 'bc', 'Utf8Copy over end');
  CheckEq(Utf8PadRight('аб', 4), 'аб  ', 'Utf8PadRight pads by cp');
  CheckEq(Utf8PadRight('абвг', 2), 'аб', 'Utf8PadRight truncates by cp');
  CheckEq(Utf8PadLeft('аб', 4), '  аб', 'Utf8PadLeft');
  { defensive: broken input must not loop or crash }
  Check(Utf8Len(#$C3) = 1, 'Utf8Len truncated char');
  Check(Utf8Len(#$80#$80) = 2, 'Utf8Len stray continuations');
end;

procedure TestMatchMask;
begin
  Check(MatchMask('file.txt', '*.txt'), 'mask star');
  Check(MatchMask('FILE.TXT', '*.txt'), 'mask case-insensitive');
  Check(not MatchMask('file.txt', '*.log'), 'mask negative');
  Check(MatchMask('file.txt', '*.log,*.txt'), 'mask list');
  Check(MatchMask('file.txt', '*.log; *.txt'), 'mask list semicolon+space');
  Check(MatchMask('file.txt', 'f?le.*'), 'mask question');
  Check(MatchMask('abc', '*'), 'mask star only');
  Check(MatchMask('abc', 'abc'), 'mask exact');
  Check(not MatchMask('abc', 'ab'), 'mask prefix is not a match');
  Check(not MatchMask('abc', ''), 'empty mask matches nothing');
  Check(MatchMask('a.b.c', '*.c'), 'mask multiple dots');
end;

procedure TestTreeSize;
var
  base: AnsiString;
begin
  base := GetTempDir + 'dn-unit-' + IntToStr(GetProcessID);
  ForceDirectories(base + '/sub');
  with TStringList.Create do
  begin
    Text := 'hello';    // 6 bytes with newline
    SaveToFile(base + '/f1');
    SaveToFile(base + '/sub/f2');
    Free;
  end;
  Check(TreeSize(base) = 12, 'TreeSize recursive: ' + IntToStr(TreeSize(base)));
  Check(TreeSize(base + '/f1') = 6, 'TreeSize single file');
  Check(TreeSize(base + '/nope') = 0, 'TreeSize missing');
  DeleteFile(base + '/f1');
  DeleteFile(base + '/sub/f2');
  RemoveDir(base + '/sub');
  RemoveDir(base);
end;

procedure TestPads;
begin
  CheckEq(PadRight('ab', 4), 'ab  ', 'PadRight');
  CheckEq(PadLeft('ab', 4), '  ab', 'PadLeft');
  CheckEq(PadRight('abcdef', 3), 'abc', 'PadRight truncate');
  CheckEq(Rep('ab', 3), 'ababab', 'Rep');
  CheckEq(Rep('x', 0), '', 'Rep zero');
end;

procedure TestUU;
var
  base, src, enc, dec, err, outp: AnsiString;
  data: AnsiString;
  fs: TFileStream;
  L: TStringList;
begin
  base := GetTempDir + 'dn-uu-' + IntToStr(GetProcessID);
  src := base + '.bin';
  enc := base + '.uue';
  dec := base + '.out';
  { binary payload including a NUL and high bytes }
  data := '';
  data := data + #0#1#2#255'Hello, UU! '#10#9'end?';
  fs := TFileStream.Create(src, fmCreate);
  fs.WriteBuffer(data[1], Length(data));
  fs.Free;

  Check(UUEncodeFile(src, enc, err), 'UUEncode ok: ' + err);
  L := TStringList.Create;
  L.LoadFromFile(enc);
  Check(Copy(L[0], 1, 6) = 'begin ', 'UU begin header');
  Check(Trim(L[L.Count - 1]) = 'end', 'UU end trailer');
  L.Free;

  Check(UUDecodeFile(enc, dec, err), 'UUDecode ok: ' + err);
  fs := TFileStream.Create(dec, fmOpenRead);
  SetLength(outp, fs.Size);
  if fs.Size > 0 then fs.ReadBuffer(outp[1], fs.Size);
  fs.Free;
  CheckEq(outp, data, 'UU round-trip preserves bytes');

  { interop: our output must decode with the system uudecode }
  if RunCapture('command -v uudecode', outp) = 0 then
  begin
    RunCapture('cd ' + AnsiQuotedStr(GetTempDir, '''') +
               ' && uudecode -o ' + AnsiQuotedStr(dec + '.sys', '''') + ' ' +
               AnsiQuotedStr(enc, ''''), outp);
    if FileExists(dec + '.sys') then
    begin
      fs := TFileStream.Create(dec + '.sys', fmOpenRead);
      SetLength(outp, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(outp[1], fs.Size);
      fs.Free;
      CheckEq(outp, data, 'system uudecode reads our output');
      DeleteFile(dec + '.sys');
    end;
  end;
  DeleteFile(src); DeleteFile(enc); DeleteFile(dec);
end;

procedure TestParseLs;
var
  it: TVfsItem;
  full: AnsiString;
begin
  Check(ParseLsLine('-rw-r--r--  1 u g   1234 Jul  6 01:23 file.txt', it, full),
        'ParseLs file');
  Check(not it.IsDir, 'ParseLs not dir');
  Check(it.Size = 1234, 'ParseLs size');
  CheckEq(it.Name, 'file.txt', 'ParseLs name');
  Check(ParseLsLine('drwxr-xr-x  2 u g    0 Jan 10  2020 subdir', it, full),
        'ParseLs dir');
  Check(it.IsDir, 'ParseLs isdir');
  CheckEq(it.Name, 'subdir', 'ParseLs dir name');
  Check(ParseLsLine('-rw-r--r-- 1 u g 5 Jul 6 01:23 two words.txt', it, full),
        'ParseLs spaces');
  CheckEq(it.Name, 'two words.txt', 'ParseLs name with spaces');
  Check(ParseLsLine('lrwxr-xr-x 1 u g 3 Jul 6 01:23 lnk -> tgt', it, full),
        'ParseLs symlink');
  CheckEq(it.Name, 'lnk', 'ParseLs symlink name stripped');
  Check(not ParseLsLine('total 8', it, full), 'ParseLs rejects total line');
  Check(not ParseLsLine('', it, full), 'ParseLs rejects empty');
end;

procedure TestSftpUrl;
var
  t, p, path: AnsiString;
begin
  Check(ParseSftpUrl('sftp://user@host/var/log', t, p, path), 'sftp url ok');
  CheckEq(t, 'user@host', 'sftp target'); CheckEq(p, '', 'sftp no port');
  CheckEq(path, '/var/log', 'sftp path');
  Check(ParseSftpUrl('sftp://host:2222/', t, p, path), 'sftp url port');
  CheckEq(t, 'host', 'sftp target no user'); CheckEq(p, '2222', 'sftp port');
  Check(ParseSftpUrl('sftp://u@h', t, p, path), 'sftp url no path');
  CheckEq(path, '/', 'sftp default path');
  Check(not ParseSftpUrl('/local/path', t, p, path), 'reject local path');
  Check(not ParseSftpUrl('http://x/y', t, p, path), 'reject http');
end;

procedure TestSessionsRoundTrip;
var
  A, B: TSessionArray;
  saved: AnsiString;
begin
  { keep the real user's file untouched: point ConfigDir elsewhere }
  SetLength(A, 2);
  A[0].Folder := 'work'; A[0].Name := 'db'; A[0].HostName := 'db.local';
  A[0].User := 'admin'; A[0].Port := ''; A[0].IdentityFile := '';
  A[0].RemoteDir := '/srv'; SetLength(A[0].Forwards, 1);
  A[0].Forwards[0].Kind := fwLocal; A[0].Forwards[0].Spec := '8080:localhost:80';
  A[1].Folder := ''; A[1].Name := 'home'; A[1].HostName := 'home.local';
  A[1].User := ''; A[1].Port := '22'; A[1].IdentityFile := '';
  A[1].RemoteDir := ''; SetLength(A[1].Forwards, 0);

  saved := GetEnvironmentVariable('DN_CONFIG_DIR');
  SaveSessions(A);
  LoadSessions(B);
  Check(Length(B) = 2, 'sessions count round-trip');
  if Length(B) = 2 then
  begin
    CheckEq(B[0].Name, 'db', 'session name');
    CheckEq(B[0].Folder, 'work', 'session folder');
    CheckEq(B[0].HostName, 'db.local', 'session hostname');
    CheckEq(B[0].RemoteDir, '/srv', 'session remote dir');
    Check((Length(B[0].Forwards) = 1) and
          (B[0].Forwards[0].Spec = '8080:localhost:80'), 'session forward');
    CheckEq(B[1].Port, '22', 'session port');
  end;
  if saved <> '' then { leave the generated file for inspection } ;
end;

procedure TestUserMenu;
var
  L: TStringList;
  M: TUserMenu;
  fn: AnsiString;
begin
  fn := GetTempDir + 'dn-unittest.mnu';
  L := TStringList.Create;
  try
    L.Add('# comment');
    L.Add('First entry');
    L.Add(#9'echo one');
    L.Add(#9'echo two');
    L.Add('; another comment');
    L.Add('Orphan title (no command)');
    L.Add('Second entry');
    L.Add('    echo three');
    L.SaveToFile(fn);
  finally
    L.Free;
  end;
  Check(LoadUserMenu(fn, M), 'usermenu loads');
  Check(Length(M) = 2, 'usermenu entry count (orphans dropped)');
  if Length(M) = 2 then
  begin
    CheckEq(M[0].Title, 'First entry', 'usermenu title');
    CheckEq(M[0].Command, 'echo one'#10'echo two', 'usermenu multiline cmd');
    CheckEq(M[1].Command, 'echo three', 'usermenu space-indented cmd');
  end;
  DeleteFile(fn);
  Check(not LoadUserMenu(fn, M), 'usermenu missing file');

  CheckEq(ExpandUserCmd('file %f', 'a b.txt', '', '', '', ''),
          'file ''a b.txt''', 'expand %f quotes');
  CheckEq(ExpandUserCmd('cp %p %D', '', '/x/a', '', '/y', ''),
          'cp ''/x/a'' ''/y''', 'expand %p %D');
  CheckEq(ExpandUserCmd('du %s', '', '', '', '', '''a'' ''b'''),
          'du ''a'' ''b''', 'expand %s list');
  CheckEq(ExpandUserCmd('100%% done', '', '', '', '', ''),
          '100% done', 'expand %%');
end;

procedure TestPlaylistModel;
var
  P: TPlaylist;
  T: TTrack;
begin
  P := TPlaylist.Create;
  try
    Check(P.Count = 0, 'playlist starts empty');

    FillChar(T, SizeOf(T), 0);
    T.Path := '/music/a.mp3'; T.Title := 'A'; T.Artist := 'X'; T.Duration := 100;
    P.Add(T);
    FillChar(T, SizeOf(T), 0);
    T.Path := '/music/b.mp3'; T.Duration := 50;
    P.Add(T);
    Check(P.Count = 2, 'playlist add');
    CheckEq(P.RowLabel(0), 'X — A', 'label with artist and title');
    CheckEq(P.RowLabel(1), 'b.mp3', 'label falls back to filename');
    Check(P.TotalDuration = 150, 'total duration');

    P.Move(0, 1);
    CheckEq(P.Get(0).Path, '/music/b.mp3', 'move down');
    CheckEq(P.Get(1).Path, '/music/a.mp3', 'move down tail');

    FillChar(T, SizeOf(T), 0);
    T.Path := '/music/c.mp3';
    P.Insert(0, T);
    Check(P.Count = 3, 'insert grows');
    CheckEq(P.Get(0).Path, '/music/c.mp3', 'insert at head');
    CheckEq(P.Get(1).Path, '/music/b.mp3', 'insert shifts the rest');

    P.Delete(0);
    Check(P.Count = 2, 'delete shrinks');
    CheckEq(P.Get(0).Path, '/music/b.mp3', 'delete removes the head row');

    P.Clear;
    Check(P.Count = 0, 'clear');
  finally
    P.Free;
  end;

  Check(IsAudioFile('song.mp3'), 'audio mp3');
  Check(IsAudioFile('SONG.MP3'), 'audio case-insensitive');
  Check(IsAudioFile('a.flac'), 'audio flac');
  Check(not IsAudioFile('notes.txt'), 'not audio txt');
  Check(not IsAudioFile('noext'), 'not audio no extension');

  CheckEq(FormatTime(0), '', 'FormatTime zero');
  CheckEq(FormatTime(42), '0:42', 'FormatTime under a minute');
  CheckEq(FormatTime(198), '3:18', 'FormatTime minutes');
  CheckEq(FormatTime(3661), '1:01:01', 'FormatTime hours');
end;

procedure TestPlaylistScan;
var
  base: AnsiString;
  A: TTrackArray;
  L: TStringList;
begin
  base := GetTempDir + 'dn-pl-' + IntToStr(GetProcessID);
  ForceDirectories(base + '/sub');
  ForceDirectories(base + '/.hidden');
  L := TStringList.Create;
  try
    L.Text := 'x'; L.SaveToFile(base + '/one.mp3');
    L.Text := 'x'; L.SaveToFile(base + '/two.flac');
    L.Text := 'x'; L.SaveToFile(base + '/skip.txt');
    L.Text := 'x'; L.SaveToFile(base + '/sub/three.mp3');
    L.Text := 'x'; L.SaveToFile(base + '/.hidden/four.mp3');
    L.Text := 'x'; L.SaveToFile(base + '/.dotfile.mp3');
  finally
    L.Free;
  end;

  A := ScanDir(base, False);
  Check(Length(A) = 2, 'scan non-recursive: ' + IntToStr(Length(A)));
  A := ScanDir(base, True);
  Check(Length(A) = 3, 'scan recursive skips hidden: ' + IntToStr(Length(A)));

  DeleteFile(base + '/one.mp3');
  DeleteFile(base + '/two.flac');
  DeleteFile(base + '/skip.txt');
  DeleteFile(base + '/sub/three.mp3');
  DeleteFile(base + '/.hidden/four.mp3');
  DeleteFile(base + '/.dotfile.mp3');
  RemoveDir(base + '/sub');
  RemoveDir(base + '/.hidden');
  RemoveDir(base);
end;

procedure TestPlaylistFiles;
var
  base, m3u, dnpl: AnsiString;
  A, B: TTrackArray;
  L: TStringList;
begin
  base := GetTempDir + 'dn-plf-' + IntToStr(GetProcessID);
  ForceDirectories(base);
  m3u := base + '/list.m3u';
  dnpl := base + '/list.dnpl';

  SetLength(A, 2);
  FillChar(A[0], SizeOf(A[0]), 0);
  A[0].Path := base + '/a.mp3'; A[0].Title := 'First';
  A[0].Artist := 'Artist'; A[0].Duration := 65;
  FillChar(A[1], SizeOf(A[1]), 0);
  A[1].Path := base + '/b.mp3'; A[1].Title := 'Second';
  A[1].Duration := 0;

  Check(SaveM3U(m3u, A), 'save m3u');
  Check(LoadM3U(m3u, B), 'load m3u');
  Check(Length(B) = 2, 'm3u count');
  if Length(B) = 2 then
  begin
    CheckEq(B[0].Path, base + '/a.mp3', 'm3u path');
    CheckEq(B[0].Title, 'Artist - First', 'm3u extinf title');
    Check(B[0].Duration = 65, 'm3u duration');
    CheckEq(B[1].Title, 'Second', 'm3u second title');
  end;

  Check(SaveDnpl(dnpl, A), 'save dnpl');
  Check(LoadDnpl(dnpl, B), 'load dnpl');
  Check(Length(B) = 2, 'dnpl count');
  if Length(B) = 2 then
  begin
    CheckEq(B[0].Path, base + '/a.mp3', 'dnpl path');
    CheckEq(B[0].Title, 'First', 'dnpl title');
    CheckEq(B[0].Artist, 'Artist', 'dnpl artist');
    Check(B[0].Duration = 65, 'dnpl duration');
  end;
  Check(LoadPlaylist(m3u, B), 'LoadPlaylist dispatches m3u');
  Check(LoadPlaylist(dnpl, B), 'LoadPlaylist dispatches dnpl');

  { relative paths resolve against the playlist directory }
  L := TStringList.Create;
  try
    L.Add('#EXTM3U');
    L.Add('#EXTINF:10,Rel');
    L.Add('rel.mp3');
    L.SaveToFile(base + '/rel.m3u');
  finally
    L.Free;
  end;
  Check(LoadM3U(base + '/rel.m3u', B), 'load relative m3u');
  Check((Length(B) = 1) and (B[0].Path = base + '/rel.mp3'),
        'm3u relative path resolves');

  DeleteFile(m3u); DeleteFile(dnpl); DeleteFile(base + '/rel.m3u');
  RemoveDir(base);
  Check(not LoadM3U(m3u, B), 'load m3u missing file');
end;

procedure TestPlaylistTags;
var
  base, fn: AnsiString;
  f: TFileStream;
  T: TTrack;

  procedure W(const s: AnsiString);
  begin
    if s <> '' then f.Write(s[1], Length(s));
  end;
  function SyncSafe(n: Integer): AnsiString;
  begin
    Result := Chr((n shr 21) and $7F) + Chr((n shr 14) and $7F) +
              Chr((n shr 7) and $7F) + Chr(n and $7F);
  end;
  function Frame(const id, text: AnsiString): AnsiString;
  var
    body: AnsiString;
  begin
    body := #0 + text;   // encoding 0 = ISO-8859-1
    Result := id + Chr(0) + Chr(0) + Chr(0) + Chr(Length(body)) +
              #0#0 + body;
  end;

var
  frames: AnsiString;
begin
  base := GetTempDir + 'dn-tag-' + IntToStr(GetProcessID);
  fn := base + '.mp3';
  frames := Frame('TIT2', 'My Song') + Frame('TPE1', 'The Artist') +
            Frame('TALB', 'The Album') + Frame('TLEN', '198000');
  f := TFileStream.Create(fn, fmCreate);
  try
    W('ID3' + #3#0#0 + SyncSafe(Length(frames)));
    W(frames);
    W(#$FF#$FB#$90#$00 + StringOfChar(#0, 100));   // fake frame header
  finally
    f.Free;
  end;

  FillChar(T, SizeOf(T), 0);
  T.Path := fn;
  ReadTags(fn, T);
  CheckEq(T.Title, 'My Song', 'id3v2 title');
  CheckEq(T.Artist, 'The Artist', 'id3v2 artist');
  CheckEq(T.Album, 'The Album', 'id3v2 album');
  Check(T.Duration = 198, 'id3v2 tlen');

  DeleteFile(fn);

  { a file with no tags at all must not raise }
  f := TFileStream.Create(fn, fmCreate);
  try
    W(StringOfChar('x', 64));
  finally
    f.Free;
  end;
  FillChar(T, SizeOf(T), 0);
  T.Path := fn;
  ReadTags(fn, T);
  CheckEq(T.Title, '', 'no tags leaves title empty');
  Check(T.Duration = 0, 'no tags leaves duration zero');
  DeleteFile(fn);
end;

procedure TestAudioFft;
var
  Data: array[0..FftSize - 1] of TComplex;
  i, peakBin: Integer;
  peak, mag: Double;
  k: Double;
begin
  { a pure sine at bin 64 must put the spectral peak at bin 64 }
  k := 2 * Pi * 64 / FftSize;
  for i := 0 to FftSize - 1 do
  begin
    Data[i].Re := Sin(k * i);
    Data[i].Im := 0;
  end;
  FFT1024(Data);
  peak := -1;
  peakBin := -1;
  for i := 1 to FftSize div 2 do
  begin
    mag := Sqrt(Data[i].Re * Data[i].Re + Data[i].Im * Data[i].Im);
    if mag > peak then
    begin
      peak := mag;
      peakBin := i;
    end;
  end;
  Check(peakBin = 64, 'fft sine peak bin: got ' + IntToStr(peakBin));
  Check(peak > 100, 'fft sine peak magnitude: ' + FloatToStr(peak));

  { a DC signal lands in bin 0 and nowhere else }
  for i := 0 to FftSize - 1 do
  begin
    Data[i].Re := 1.0;
    Data[i].Im := 0;
  end;
  FFT1024(Data);
  Check(Abs(Data[0].Re - FftSize) < 0.01, 'fft DC in bin 0');
  Check(Abs(Data[5].Re) < 0.01, 'fft DC leaves other bins empty');
end;

procedure TestAudioAnalyzer;
var
  A: TAnalyzer;
  L: array[0..39] of Integer;
  i, nonZero: Integer;
  S: array[0..1023] of SmallInt;
begin
  A := TAnalyzer.Create;
  try
    A.BandCount := 40;
    { silence: every band is zero }
    A.Bands(L);
    nonZero := 0;
    for i := 0 to High(L) do
      if L[i] <> 0 then Inc(nonZero);
    Check(nonZero = 0, 'analyzer silence is zero');

    { a loud 1 kHz tone: at least one band lights up }
    for i := 0 to High(S) do
      S[i] := Trunc(20000 * Sin(2 * Pi * 1000 * i / 8000));
    A.Push(S);
    A.Push(S);
    A.Bands(L);
    nonZero := 0;
    for i := 0 to High(L) do
      if L[i] > 0 then Inc(nonZero);
    Check(nonZero > 0, 'analyzer tone lights bands: ' + IntToStr(nonZero));

    { decay: after silence, a lit band falls but is not instantly zero }
    A.Bands(L);
    Check(L[20] >= 0, 'analyzer band stays in range');

    { the fake mode also produces values in range }
    A.FakeBands(L);
    nonZero := 0;
    for i := 0 to High(L) do
    begin
      Check((L[i] >= 0) and (L[i] <= 100), 'fake band in range');
      if L[i] > 0 then Inc(nonZero);
    end;
    Check(nonZero > 0, 'fake mode lights bands');
  finally
    A.Free;
  end;
end;

procedure TestEqualizer;
var
  E: TEqualizer;
  i: Integer;
  s: AnsiString;
begin
  E := TEqualizer.Create;
  try
    CheckEq(E.Preset, 'Flat', 'eq starts flat');
    Check(not E.Active, 'eq flat is not active');
    CheckEq(E.FilterChain, '', 'eq flat has an empty chain');

    E.LoadPreset('Rock');
    CheckEq(E.Preset, 'Rock', 'eq preset name');
    Check(E.Active, 'eq rock is active');
    Check(E.GetBand(0) = 5, 'eq rock band 0');
    Check(E.GetBand(5) = -1, 'eq rock band 5');
    s := E.FilterChain;
    Check(Pos('equalizer=f=31:g=5', s) > 0, 'eq chain first band: ' + s);
    Check(Pos('equalizer=f=8000:g=4', s) > 0, 'eq chain last band');

    s := E.Mpg123Arg;
    CheckEq(s, '5,4,2,0,-1,-1,1,3,4,4', 'mpg123 arg rock');

    E.SetBand(2, 7);
    CheckEq(E.Preset, 'Custom', 'eq edit makes it custom');
    Check(E.GetBand(2) = 7, 'eq edit stores the value');

    { clamping }
    E.SetBand(2, 99);
    Check(E.GetBand(2) = EqMaxDb, 'eq clamps high');
    E.SetBand(2, -99);
    Check(E.GetBand(2) = EqMinDb, 'eq clamps low');

    E.LoadPreset('Flat');
    Check(not E.Active, 'eq flat is not active again');
    for i := 0 to EqBands - 1 do
      Check(E.GetBand(i) = 0, 'eq flat band zero');
  finally
    E.Free;
  end;
end;

const
  { class letters: . plain, n number, s string, c comment, y symbol,
    k/K keyword bank 1/2 }
  ClsLetters: array[hhNothing..hhKeyword2] of Char = ('.', 'n', 's', 'c', 'y', 'k', 'K');

{ render classes as a string, one letter per byte }
function ClsStr(const R: THglRules; const s: AnsiString): AnsiString;
var
  cls: THlClasses;
  i: Integer;
begin
  Result := '';
  cls := HglColorLine(R, s);
  for i := 0 to High(cls) do
    Result := Result + ClsLetters[cls[i]];
end;

{ same, carrying the multi-line comment state across calls }
function ClsStrSt(const R: THglRules; const s: AnsiString; var st: Integer): AnsiString;
var
  cls: THlClasses;
  i, stOut: Integer;
begin
  Result := '';
  cls := HglColorLine(R, s, st, stOut);
  st := stOut;
  for i := 0 to High(cls) do
    Result := Result + ClsLetters[cls[i]];
end;

procedure TestHighlite;
var
  pas, cs, sh, py, ini, none: THglRules;
begin
  pas := HglForFile('test.pas');
  cs := HglForFile('main.c');
  sh := HglForFile('run.sh');
  py := HglForFile('tool.py');
  ini := HglForFile('app.ini');
  none := HglForFile('photo.jpg');

  Check(pas.Valid, 'hgl pas rules found');
  Check(cs.Valid, 'hgl c rules found');
  Check(sh.Valid, 'hgl sh rules found');
  Check(py.Valid, 'hgl py rules found');
  Check(ini.Valid, 'hgl ini rules found');
  Check(not none.Valid, 'hgl no rules for jpg');
  Check(HglForFile('Makefile').Valid, 'hgl makefile by name');
  Check(Length(pas.Keywords1) > 30, 'hgl pas keywords loaded');
  Check(HglColorLine(none, 'text') = nil, 'no classes without rules');

  { Pascal: keywords, strings, { } comments, // comments, $-hex }
  CheckEq(ClsStr(pas, 'begin'), 'kkkkk', 'pas keyword');
  CheckEq(ClsStr(pas, 'if x then'), 'kky.ykkkk', 'pas if/then');
  CheckEq(ClsStr(pas, '{ note }'), 'cccccccc', 'pas brace comment');
  CheckEq(ClsStr(pas, '(* x *)'), 'ccccccc', 'pas paren-star comment');
  CheckEq(ClsStr(pas, 'x := 1; // c'), '.yyyynyycccc', 'pas line comment + number');
  CheckEq(ClsStr(pas, 's := ''ab'''), '.yyyyssss', 'pas string');
  CheckEq(ClsStr(pas, '$1F'), 'nnn', 'pas hex number');
  CheckEq(ClsStr(pas, 'begins'), '......', 'pas keyword needs boundary');
  CheckEq(ClsStr(pas, 'virtual'), 'KKKKKKK', 'pas keyword bank 2');
  CheckEq(ClsStr(pas, 'BEGIN'), 'kkkkk', 'pas is case-insensitive');

  { C: case sensitivity, 0x-hex, paired and line comments, escapes }
  CheckEq(ClsStr(cs, 'return'), 'kkkkkk', 'c keyword');
  CheckEq(ClsStr(cs, 'RETURN'), '......', 'c keyword is case-sensitive');
  CheckEq(ClsStr(cs, '0x2A'), 'nnnn', 'c hex number');
  CheckEq(ClsStr(cs, '/* x */ y'), 'cccccccy.', 'c paired comment ends');
  CheckEq(ClsStr(cs, 'a /* x'), '.ycccc', 'c unterminated comment to EOL');
  CheckEq(ClsStr(cs, '#include <a>'), 'KKKKKKKKyy.y', 'c preprocessor keyword');
  CheckEq(ClsStr(cs, '"a\"b"'), 'ssssss', 'c escaped quote stays in string');

  { unix types }
  CheckEq(ClsStr(sh, 'exit # done'), 'kkkkycccccc', 'sh comment');
  CheckEq(ClsStr(py, 'def f():'), 'kkky.yyy', 'py def');
  CheckEq(ClsStr(ini, '; note'), 'cccccc', 'ini whole-line comment');
end;

procedure TestHighliteState;
var
  pas, cs, xml: THglRules;
  st: Integer;
begin
  pas := HglForFile('a.pas');
  cs := HglForFile('a.c');
  xml := HglForFile('a.xml');

  { pascal { } comment across three lines }
  st := -1;
  CheckEq(ClsStrSt(pas, 'x { c', st), '.yccc', 'ml open line');
  Check(st >= 0, 'ml state open after {');
  CheckEq(ClsStrSt(pas, 'inside', st), 'cccccc', 'ml middle line all comment');
  Check(st >= 0, 'ml state persists');
  CheckEq(ClsStrSt(pas, 'y } z', st), 'cccy.', 'ml close line');
  Check(st = -1, 'ml state closed after }');

  { C /* */ across lines; a string hides the comment opener }
  st := -1;
  CheckEq(ClsStrSt(cs, 'a /* x', st), '.ycccc', 'c ml open');
  CheckEq(ClsStrSt(cs, 'b */ c', st), 'ccccy.', 'c ml close');
  Check(st = -1, 'c ml closed');
  st := -1;
  CheckEq(ClsStrSt(cs, '"/* x"', st), 'ssssss', 'comment opener inside string');
  Check(st = -1, 'string does not open comment');

  { empty line inside a comment keeps the state }
  st := -1;
  ClsStrSt(pas, '(* a', st);
  CheckEq(ClsStrSt(pas, '', st), '', 'ml empty line');
  Check(st >= 0, 'ml state through empty line');

  { xml <!-- --> across lines }
  st := -1;
  CheckEq(ClsStrSt(xml, '<a> <!-- c', st), 'y.yycccccc', 'xml ml open');
  CheckEq(ClsStrSt(xml, 'z --> ok', st), 'cccccy..', 'xml ml close');
  Check(st = -1, 'xml ml closed');
end;

procedure TestHighliteMore;
var
  sql, yml, csv: THglRules;
  st: Integer;
begin
  sql := HglForFile('q.sql');
  yml := HglForFile('c.yaml');
  csv := HglForFile('d.csv');
  Check(sql.Valid, 'hgl sql rules found');
  Check(yml.Valid, 'hgl yaml rules found');
  Check(csv.Valid, 'hgl csv rules found');
  Check(HglForFile('c.yml').Valid, 'hgl yml mask');

  CheckEq(ClsStr(sql, 'SELECT 1'), 'kkkkkkyn', 'sql keyword + number');
  CheckEq(ClsStr(sql, 'select'), 'kkkkkk', 'sql is case-insensitive');
  CheckEq(ClsStr(sql, '-- note'), 'ccccccc', 'sql line comment');
  CheckEq(ClsStr(sql, '''ab'''), 'ssss', 'sql single-quoted string');
  CheckEq(ClsStr(sql, 'varchar'), 'KKKKKKK', 'sql type keyword');
  st := -1;
  CheckEq(ClsStrSt(sql, 'a /* x', st), '.ycccc', 'sql ml comment opens');
  Check(st >= 0, 'sql ml state');

  CheckEq(ClsStr(yml, 'key: true # x'), '...yykkkkyccc', 'yaml key/bool/comment');
  CheckEq(ClsStr(csv, '1.5,"a b",x'), 'nnnysssssy.', 'csv number/string/field');
end;

procedure TestMarkdown;
var
  md: THglRules;
  st: Integer;
begin
  md := HglForFile('README.md');
  Check(md.Valid, 'hgl md rules found');
  CheckEq(ClsStr(md, '# Title'), 'kkkkkkk', 'md header whole line');
  CheckEq(ClsStr(md, '## Sub h'), 'kkkkkkkk', 'md subheader');
  CheckEq(ClsStr(md, '> quote'), 'KKKKKKK', 'md blockquote');
  CheckEq(ClsStr(md, '- item'), 'KKKKKK', 'md list item');
  CheckEq(ClsStr(md, 'a `b` c'), '..ccc..', 'md inline code span');
  CheckEq(ClsStr(md, 'plain text'), '..........', 'md prose stays plain');
  { fenced code block across lines }
  st := -1;
  CheckEq(ClsStrSt(md, '```pas', st), 'cccccc', 'md fence opens');
  Check(st >= 0, 'md fence state');
  CheckEq(ClsStrSt(md, 'x := 1;', st), 'ccccccc', 'md fenced line is code');
  CheckEq(ClsStrSt(md, '```', st), 'ccc', 'md fence closes');
  Check(st = -1, 'md fence state closed');

  { a hard-wrapped list item: the indented tail keeps the item class }
  st := -1;
  CheckEq(ClsStrSt(md, '- long item', st), 'KKKKKKKKKKK', 'md wrapped item head');
  CheckEq(ClsStrSt(md, '  tail', st), 'KKKKKK', 'md wrapped item tail');
  CheckEq(ClsStrSt(md, '  more', st), 'KKKKKK', 'md wrap continues');
  CheckEq(ClsStrSt(md, 'plain', st), '.....', 'md unindented line ends the item');
  st := -1;
  ClsStrSt(md, '- a', st);
  CheckEq(ClsStrSt(md, '', st), '', 'md blank line');
  Check(st = -1, 'md blank line ends the item');
  CheckEq(ClsStrSt(md, '  code?', st), '.......', 'md indent after blank is plain');
  { headers do not spill onto the next line }
  st := -1;
  ClsStrSt(md, '# H', st);
  CheckEq(ClsStrSt(md, '  x', st), '...', 'md header has no continuation');
end;

procedure TestLsProto;
var
  info, back: TDeviceInfo;
  req, rback: TUploadRequest;
  resp, rresp: TPrepareResponse;
  ev, rev: TLsEvent;
begin
  { device info round-trip }
  info.Alias := 'My Desktop';
  info.Version := LsProtocolVersion;
  info.DeviceModel := 'DN';
  info.DeviceType := 'desktop';
  info.Fingerprint := 'ABC123';
  info.Port := 53317;
  info.Protocol := 'https';
  Check(ParseDeviceInfo(BuildDeviceInfo(info), back), 'ls info parse');
  CheckEq(back.Alias, 'My Desktop', 'ls info alias');
  CheckEq(back.Version, LsProtocolVersion, 'ls info version');
  CheckEq(back.DeviceModel, 'DN', 'ls info model');
  CheckEq(back.DeviceType, 'desktop', 'ls info type');
  CheckEq(back.Fingerprint, 'ABC123', 'ls info fingerprint');
  Check(back.Port = 53317, 'ls info port');
  CheckEq(back.Protocol, 'https', 'ls info protocol');

  { upload request with two files round-trip }
  req.SessionId := 'sess-1';
  req.Info := info;
  SetLength(req.Files, 2);
  req.Files[0].Id := 'f1';
  req.Files[0].FileName := 'a.txt';
  req.Files[0].Size := 10;
  req.Files[0].FileType := 'text';
  req.Files[0].Mime := 'text/plain';
  req.Files[1].Id := 'f2';
  req.Files[1].FileName := 'b.bin';
  req.Files[1].Size := 2048;
  req.Files[1].FileType := 'file';
  Check(ParseUploadRequest(BuildUploadRequest(req), rback), 'ls upload parse');
  CheckEq(rback.SessionId, 'sess-1', 'ls upload session');
  CheckEq(rback.Info.Alias, 'My Desktop', 'ls upload peer alias');
  CheckEq(rback.Info.Fingerprint, 'ABC123', 'ls upload peer fingerprint');
  Check(Length(rback.Files) = 2, 'ls upload file count');
  CheckEq(rback.Files[0].FileName, 'a.txt', 'ls upload file 0 name');
  Check(rback.Files[0].Size = 10, 'ls upload file 0 size');
  CheckEq(rback.Files[0].FileType, 'text', 'ls upload file 0 type');
  CheckEq(rback.Files[0].Mime, 'text/plain', 'ls upload file 0 mime');
  CheckEq(rback.Files[1].FileName, 'b.bin', 'ls upload file 1 name');
  Check(rback.Files[1].Size = 2048, 'ls upload file 1 size');

  { prepare response round-trip }
  resp.SessionId := 'sess-1';
  SetLength(resp.Accepted, 1);
  resp.Accepted[0] := 'f1';
  Check(ParsePrepareResponse(BuildPrepareResponse(resp), rresp), 'ls prepare parse');
  CheckEq(rresp.SessionId, 'sess-1', 'ls prepare session');
  Check(Length(rresp.Accepted) = 1, 'ls prepare accepted count');
  CheckEq(rresp.Accepted[0], 'f1', 'ls prepare accepted id');

  { decision line }
  Check(ParseEventLine(BuildDecision('sess-1', True), ev), 'ls decision parse');
  Check(ev.Kind = leOk, 'ls decision kind');
  CheckEq(ev.SessionId, 'sess-1', 'ls decision session');

  { event line round-trip }
  ev.Kind := leIncoming;
  ev.SessionId := 'sess-2';
  ev.PeerName := 'Phone';
  ev.PeerAddr := '192.168.1.5:53317';
  ev.Err := '';
  ev.BytesDone := 0;
  ev.BytesTotal := 0;
  SetLength(ev.Files, 1);
  ev.Files[0].Id := 'x1';
  ev.Files[0].FileName := 'photo.jpg';
  ev.Files[0].Size := 4096;
  ev.Files[0].FileType := 'file';
  Check(ParseEventLine(BuildEventLine(ev), rev), 'ls event parse');
  Check(rev.Kind = leIncoming, 'ls event kind');
  CheckEq(rev.SessionId, 'sess-2', 'ls event session');
  CheckEq(rev.PeerName, 'Phone', 'ls event peer name');
  CheckEq(rev.PeerAddr, '192.168.1.5:53317', 'ls event peer addr');
  Check(Length(rev.Files) = 1, 'ls event file count');
  CheckEq(rev.Files[0].FileName, 'photo.jpg', 'ls event file name');
  Check(rev.Files[0].Size = 4096, 'ls event file size');

  { progress event }
  ev.Kind := leProgress;
  ev.BytesDone := 512;
  ev.BytesTotal := 4096;
  SetLength(ev.Files, 0);
  Check(ParseEventLine(BuildEventLine(ev), rev), 'ls progress parse');
  Check(rev.Kind = leProgress, 'ls progress kind');
  Check(rev.BytesDone = 512, 'ls progress done');
  Check(rev.BytesTotal = 4096, 'ls progress total');

  { malformed input must not crash }
  Check(not ParseEventLine('not json', rev), 'ls bad event rejected');
  Check(not ParseDeviceInfo('{', back), 'ls bad info rejected');
  Check(not ParseUploadRequest('[]', rback), 'ls bad upload rejected');

  { file type hint }
  CheckEq(FileTypeOf('note.txt'), 'text', 'ls txt is text');
  CheckEq(FileTypeOf('song.mp3'), 'file', 'ls mp3 is file');

  { safe local names }
  CheckEq(SafeLocalName('photo.jpg'), 'photo.jpg', 'ls safe plain name');
  CheckEq(SafeLocalName('/etc/passwd'), 'passwd', 'ls safe strips dirs');
  CheckEq(SafeLocalName('..'), 'unnamed', 'ls safe rejects dotdot');
  CheckEq(SafeLocalName(''), 'unnamed', 'ls safe rejects empty');
  CheckEq(SafeLocalName('a/b/c.txt'), 'c.txt', 'ls safe keeps last');
end;

procedure TestHtmlTokenizer;
var
  tok: THtmlTokenizer;
  t: THtmlToken;
  i: Integer;

  procedure Nth(const src: AnsiString; idx: Integer; const nm: AnsiString);
  var
    tkz: THtmlTokenizer;
    k: Integer;
  begin
    tkz := THtmlTokenizer.Create(src);
    try
      for k := 0 to idx do t := tkz.Next;
    finally
      tkz.Free;
    end;
    CheckEq(t.Name, nm, 'tokenizer tag ' + src);
  end;

begin
  Nth('<DIV CLASS=x>t</DIV>', 0, 'div');
  Nth('<SPAN></SPAN>', 1, 'span');
  Nth('<p>x</p>', 2, 'p');
  Nth('<br/>', 0, 'br');

  tok := THtmlTokenizer.Create('<p a="1" b c=3>x</p>');
  try
    t := tok.Next;
    Check(Ord(t.Kind) = Ord(tkStartTag), 'tokenizer start kind');
    CheckEq(t.Name, 'p', 'tokenizer start name');
    Check(Length(t.Attrs) = 3, 'tokenizer attr count');
    CheckEq(t.Attrs[0].Name, 'a', 'tokenizer attr0 name');
    CheckEq(t.Attrs[0].Value, '1', 'tokenizer attr0 value');
    CheckEq(t.Attrs[1].Name, 'b', 'tokenizer attr1 name');
    CheckEq(t.Attrs[1].Value, '', 'tokenizer missing value is empty');
    CheckEq(t.Attrs[2].Value, '3', 'tokenizer unquoted value');
    t := tok.Next;
    Check(Ord(t.Kind) = Ord(tkText), 'tokenizer text kind');
    CheckEq(t.Data, 'x', 'tokenizer text data');
    t := tok.Next;
    Check(Ord(t.Kind) = Ord(tkEndTag), 'tokenizer end kind');
    CheckEq(t.Name, 'p', 'tokenizer end name');
    t := tok.Next;
    Check(Ord(t.Kind) = Ord(tkEof), 'tokenizer eof kind');
  finally
    tok.Free;
  end;

  tok := THtmlTokenizer.Create('<!DOCTYPE html><p>x</p>');
  try
    t := tok.Next;
    Check(Ord(t.Kind) = Ord(tkDoctype), 'tokenizer doctype kind');
    CheckEq(t.Data, 'html', 'tokenizer doctype data');
  finally
    tok.Free;
  end;

  tok := THtmlTokenizer.Create('<script>a<b></script><p>q</p>');
  try
    t := tok.Next;
    CheckEq(t.Name, 'script', 'tokenizer script name');
    CheckEq(t.Data, 'a<b>', 'tokenizer script raw body');
    t := tok.Next;
    CheckEq(t.Name, 'p', 'tokenizer tag after script');
  finally
    tok.Free;
  end;
  for i := 1 to 1 do
  begin
    tok := THtmlTokenizer.Create('<style>p{color:red}</style>');
    try
      t := tok.Next;
      CheckEq(t.Data, 'p{color:red}', 'tokenizer style raw body');
    finally
      tok.Free;
    end;
  end;

  tok := THtmlTokenizer.Create('<!--c1--><!-->c2--><p>x</p>');
  try
    t := tok.Next;
    Check(Ord(t.Kind) = Ord(tkComment), 'tokenizer comment kind');
    CheckEq(t.Data, 'c1', 'tokenizer comment data');
    t := tok.Next;
    Check(Ord(t.Kind) = Ord(tkComment), 'tokenizer bogus comment kind');
    CheckEq(t.Data, '>c2', 'tokenizer bogus comment data');
  finally
    tok.Free;
  end;
end;

procedure TestHtmlTree;
var
  doc: TDomDoc;
  n, n2: TDomNode;
  L: TDomNodeArray;
  sl: TStringList;

  function TagsOf(const html: AnsiString): AnsiString;
  var
    d: TDomDoc;
    i: Integer;
  begin
    Result := '';
    d := ParseHtml('<body>' + html);
    try
      for i := 0 to High(d.Body.Children) do
      begin
        if Result <> '' then Result := Result + ' ';
        Result := Result + d.Body.Children[i].NodeName;
      end;
    finally
      d.Free;
    end;
  end;

  function ParentOf(const html, tag: AnsiString): AnsiString;
  var
    d: TDomDoc;
    E: TDomNodeArray;
  begin
    Result := '<missing>';
    d := ParseHtml('<body>' + html);
    try
      E := d.GetElementsByTagName(tag);
      if Length(E) > 0 then
        if E[0].Parent <> nil then Result := E[0].Parent.Tag;
    finally
      d.Free;
    end;
  end;

  function CountOf(const html, tag: AnsiString): AnsiString;
  var
    d: TDomDoc;
  begin
    Result := '';
    d := ParseHtml('<body>' + html);
    try
      Result := IntToStr(Length(d.GetElementsByTagName(tag)));
    finally
      d.Free;
    end;
  end;

begin
  doc := ParseHtml('<html><head><title>My  T </title></head>' +
    '<body><div><p>one</p><p>two</p></div></body></html>');
  try
    CheckEq(doc.Title, 'My  T', 'dom title trimmed');
    CheckEq(doc.TextContent, 'onetwo', 'dom text content of body');
    n := doc.Html.FirstChildElement('body');
    Check(n = doc.Body, 'dom body is html child');
    n := doc.Html.FirstChildElement('head');
    Check(n = doc.Head, 'dom head is html child');
    Check(Length(doc.Body.ChildElements) = 1, 'dom one body child');
    n := doc.Body.FirstChildElement('div');
    Check(n <> nil, 'dom div found');
    if n <> nil then
    begin
      CheckEq(n.NodeName, 'div', 'dom node name');
      Check(Length(n.ChildElements) = 2, 'dom two p children');
      Check(Length(n.Children) = 2, 'dom div has no stray nodes');
      n2 := n.FirstChildElement('p');
      Check(n2 <> nil, 'dom first p found');
      if n2 <> nil then
      begin
        CheckEq(n2.Children[0].Text, 'one', 'dom first p text');
        Check(n2.Parent = n, 'dom parent link');
      end;
    end;
    Check(doc.GetElementById('absent') = nil, 'dom by id absent');
    Check(doc.QuerySelector('h9') = nil, 'dom query absent');
    Check(Length(doc.GetElementsByTagName('td')) = 0, 'dom by tag absent');
    Check(Length(doc.GetElementsByTagName('p')) = 2, 'dom by tag counts all');
  finally
    doc.Free;
  end;

  CheckEq(TagsOf('<p>a<p>b<p>c'), 'p p p', 'dom p implied end tag');
  CheckEq(TagsOf('<p>a<div>b</div>'), 'p div', 'dom div closes p');
  CheckEq(TagsOf('<p>a<h1>b</h1>'), 'p h1', 'dom h1 closes p');
  CheckEq(TagsOf('<p>a</p><div>b</div>'), 'p div', 'dom explicit close then div');
  CheckEq(CountOf('<ul><li>a<li>b</ul>', 'li'), '2', 'dom two li elements');
  CheckEq(ParentOf('<ul><li>a<li>b</ul>', 'li'), 'ul', 'dom li parent is ul');
  CheckEq(ParentOf('<ul><li>a<li>b</ul>', 'ul'), 'body', 'dom ul parent is body');
  CheckEq(ParentOf('<div><span>hi</span></div>', 'span'), 'div',
      'dom span nested in div');

  { void elements must not become parents of their siblings }
  CheckEq(TagsOf('<br>a<p>x</p>'), 'br #text p', 'dom br does not nest');
  CheckEq(TagsOf('<img src=a><p>x</p>'), 'img p', 'dom img does not nest');
  CheckEq(TagsOf('<hr><p>x</p>'), 'hr p', 'dom hr does not nest');
  CheckEq(CountOf('<p>a<br>b<img src=x>c<hr>d</p>', 'br'), '1', 'dom br is element');
  CheckEq(ParentOf('<p>a<br>b</p>', 'br'), 'p', 'dom br stays inside p');

  doc := ParseHtml('<body><table><tbody><tr><td>a</td><td>b</td></tr></tbody></table>');
  try
    CheckEq(CountOf('<table><tbody><tr><td>a</td><td>b</td></tr></tbody></table>',
      'td'), '2', 'dom explicit td count');
    L := doc.GetElementsByTagName('td');
    if Length(L) = 2 then
    begin
      Check(L[0].Parent = L[1].Parent, 'dom sibling td share parent');
      CheckEq(L[1].Parent.Tag, 'tr', 'dom td parent is tr');
    end;
  finally
    doc.Free;
  end;
  { implied end tags: <tr> and <td> without any end tag }
  CheckEq(CountOf('<table><tr><td>a<td>b<tr><td>c</table>', 'td'), '3',
      'dom implied td count');
  CheckEq(CountOf('<table><tr><td>a<td>b<tr><td>c</table>', 'tr'), '2',
      'dom implied tr count');
  CheckEq(ParentOf('<table><tr><td>a</td></tr></table>', 'table'), 'body',
      'dom table parent is body');

  doc := ParseHtml('<body><DIV CLASS="Foo"><P CLASS=bar>T</P></DIV>');
  try
    L := doc.GetElementsByTagName('p');
    Check(Length(L) = 1, 'dom upper case tag stored lower case');
    CheckEq(doc.GetElementsByTagName('div')[0].Attr('class'), 'Foo',
        'dom upper case attr name lower cased');
    if Length(L) = 1 then
      CheckEq(L[0].Attr('class'), 'bar', 'dom attr value case preserved');
  finally
    doc.Free;
  end;

  doc := ParseHtml('<html><head><style>p{color:red}</style></head>' +
    '<body><p>vis</p></body></html>');
  try
    CheckEq(doc.TextContent, 'vis', 'dom text content excludes style');
  finally
    doc.Free;
  end;
  doc := ParseHtml('<html><body><p>vis<script>gone=1</script></p></body></html>');
  try
    CheckEq(doc.TextContent, 'vis', 'dom text content excludes script');
  finally
    doc.Free;
  end;

  doc := ParseHtml('<html><head><script>head1</script></head>' +
    '<body><script>body1</script><script type="text/x">data</script>' +
    '<script>body2</script></body></html>');
  try
    sl := doc.Scripts;
    try
      CheckEq(IntToStr(sl.Count), '3', 'dom scripts count');
      if sl.Count = 3 then
      begin
        CheckEq(sl[0], 'head1', 'dom head script kept');
        CheckEq(sl[1], 'body1', 'dom body script order');
        CheckEq(sl[2], 'body2', 'dom typed script skipped');
      end;
    finally
      sl.Free;
    end;
  finally
    doc.Free;
  end;

  doc := ParseHtml('<body><pre>  a  </pre><p>  b  </p></body>');
  try
    CheckEq(doc.GetElementsByTagName('pre')[0].Children[0].Text, '  a  ',
        'dom pre keeps inner spaces');
    CheckEq(doc.GetElementsByTagName('p')[0].Children[0].Text, '  b  ',
        'dom p keeps inner spaces for layout');
  finally
    doc.Free;
  end;

  doc := ParseHtml('<body><p>a<b>x</b>y</p>');
  try
    n := doc.Body.FirstChildElement('p');
    if n <> nil then
    begin
      Check(Length(n.Children) = 3, 'dom formatting keeps text siblings');
      CheckEq(ParentOf('<p>a<b>x</b>y</p>', 'b'), 'p', 'dom b stays inside p');
    end;
  finally
    doc.Free;
  end;

  { KNOWN-RED: documents with no literal <body> keep content outside body }
  CheckEq(TagsOf('<div>x</div>'), 'div', 'dom implicit body receives content');
  CheckEq(ParentOf('<div>x</div>', 'div'), 'body', 'dom implicit body is parent');
  CheckEq(ParseHtml('<div>x</div>').TextContent, 'x',
      'dom text content with implicit body');
end;
procedure TestHtmlEntities;

  function Dec(const s: AnsiString): AnsiString;
  var
    d: TDomDoc;
    L: TDomNodeArray;
  begin
    Result := '<p text missing>';
    d := ParseHtml('<p>' + s);
    try
      L := d.GetElementsByTagName('p');
      if (Length(L) = 1) and (Length(L[0].Children) > 0) then
        Result := L[0].Children[0].Text;
    finally
      d.Free;
    end;
  end;

begin
  CheckEq(DecodeEntities('&amp;'), '&', 'decode named amp');
  CheckEq(DecodeEntities('&lt;&gt;'), '<>', 'decode named lt gt');
  CheckEq(DecodeEntities('&quot;&apos;'), '"''', 'decode named quote apos');
  CheckEq(DecodeEntities('&copy;'), #194#169, 'decode named copy');
  CheckEq(DecodeEntities('&mdash;'), #226#128#148, 'decode named mdash');
  CheckEq(DecodeEntities('&nbsp;'), #194#160, 'decode named nbsp is u00a0');
  CheckEq(DecodeEntities('&#65;'), 'A', 'decode decimal numeric');
  CheckEq(DecodeEntities('&#128;'), #194#128, 'decode decimal above 127');
  CheckEq(DecodeEntities('&#1080;'), #208#184, 'decode decimal cyrillic codepoint');
  CheckEq(DecodeEntities('&#128400;'), #240#159#150#144, 'decode numeric astral');
  CheckEq(DecodeEntities('&#0;'), '', 'decode zero drops');
  CheckEq(DecodeEntities('&#x41;'), 'A', 'decode hex numeric');
  CheckEq(DecodeEntities('a&#x41;b'), 'aAb', 'decode hex numeric mid string');
  CheckEq(DecodeEntities('&bogus;'), '&bogus;', 'decode unknown kept literal');
  CheckEq(DecodeEntities('a & b'), 'a & b', 'decode raw amp kept');
  CheckEq(DecodeEntities('a&'), 'a&', 'decode trailing amp kept');
  CheckEq(DecodeEntities('&AMP;'), '&AMP;', 'decode named is case sensitive');
  CheckEq(DecodeEntities(''), '', 'decode empty');

  CheckEq(Dec('&amp;&lt;&gt;'), '&<>', 'parse decodes named refs');
  CheckEq(Dec('&copy;&nbsp;'), #194#169#194#160, 'parse decodes copy and nbsp');
  CheckEq(Dec('a &amp; b'), 'a & b', 'parse decodes in mixed text');
  CheckEq(Dec('&#65;'), 'A', 'parse decimal numeric');
  CheckEq(Dec('&#1080;'), #208#184, 'parse decimal cyrillic numeric');
  CheckEq(Dec('caf&#233;'), 'caf' + #195#169, 'parse decimal latin accent');
  CheckEq(Dec('&amp;'), '&', 'parse single amp entity');
  CheckEq(Dec('&bogus;'), '&bogus;', 'parse unknown entity kept');
  CheckEq(Dec('raw & tail'), 'raw & tail', 'parse raw amp kept');
end;

procedure TestHtmlMalformed;
var
  doc: TDomDoc;
  L: TDomNodeArray;

  function BodyChildTags(const html: AnsiString): AnsiString;
  var
    d: TDomDoc;
    i: Integer;
  begin
    Result := '';
    d := ParseHtml('<body>' + html);
    try
      for i := 0 to High(d.Body.Children) do
      begin
        if Result <> '' then Result := Result + ' ';
        Result := Result + d.Body.Children[i].NodeName;
      end;
    finally
      d.Free;
    end;
  end;

  function NodeKindAt(const html: AnsiString; idx: Integer): AnsiString;
  var
    d: TDomDoc;
  begin
    Result := '<missing>';
    d := ParseHtml('<body>' + html);
    try
      if (d.Body <> nil) and (idx <= High(d.Body.Children)) then
        Result := d.Body.Children[idx].NodeName;
    finally
      d.Free;
    end;
  end;

  function AttrAt(const html, name: AnsiString): AnsiString;
  var
    d: TDomDoc;
    L: TDomNodeArray;
  begin
    Result := '<missing>';
    d := ParseHtml('<body>' + html);
    try
      L := d.GetElementsByTagName('p');
      if Length(L) > 0 then Result := L[0].Attr(name);
    finally
      d.Free;
    end;
  end;

begin
  CheckEq(BodyChildTags('<div>a<b>x'), 'div', 'malformed nested unclosed');
  CheckEq(BodyChildTags('stray & plain'), '#text', 'malformed stray amp text in body');
  CheckEq(BodyChildTags('<!DOCTYPE html><p>x</p>'), 'p',
      'malformed doctype does not block parse');
  CheckEq(BodyChildTags('<div><span>hi</div>tail'), 'div #text',
      'malformed span closes with div');
  CheckEq(NodeKindAt('<div><span>hi</div>tail', 0), 'div',
      'malformed stray text lands after div');
  CheckEq(BodyChildTags('<p>a<b>x<i>y</b>z</i>w'), 'p', 'malformed misnest keeps p');
  CheckEq(NodeKindAt('<p>unterminated', 0), 'p', 'malformed unclosed p survives');
  CheckEq(NodeKindAt('<p>text', 0), 'p', 'malformed unclosed text kept');
  CheckEq(BodyChildTags('<p>a</p></p></div></html>'), 'p',
      'malformed stray end tags dropped');

  CheckEq(NodeKindAt('<!-- ok --><p>x</p>', 0), '#comment',
      'malformed comment before p');
  CheckEq(NodeKindAt('<!-- unterminated', 0), '#comment',
      'malformed unterminated comment survives');
  CheckEq(NodeKindAt('<!-->a<p>b', 0), '#comment', 'malformed bogus comment survives');
  CheckEq(NodeKindAt('<!---->', 0), '#comment', 'malformed empty comment survives');
  CheckEq(BodyChildTags('<p>a<!---->b<p>c'), 'p #comment p',
      'malformed empty comment splits p');
  CheckEq(BodyChildTags('<div>a<b>x'), 'div', 'malformed nested unclosed');

  doc := ParseHtml('<p>a<b>x<i>y</b>z</i>w</p>');
  try
    L := doc.GetElementsByTagName('i');
    if Length(L) = 1 then
      Check(L[0].Parent.Tag = 'b', 'malformed i stays inside b');
    L := doc.GetElementsByTagName('p');
    if Length(L) = 1 then
      Check(Length(L[0].ChildElements) >= 1, 'malformed p keeps first child');
  finally
    doc.Free;
  end;

  CheckEq(AttrAt('<p a=1 b c="d" e=''f'' g=h&i&j k="">x</p>', 'b'), '',
      'malformed bare attr has empty value');
  CheckEq(AttrAt('<p a=1 b c="d" e=''f'' g=h&i&j k="">x</p>', 'c'), 'd',
      'malformed double quoted attr');
  CheckEq(AttrAt('<p a=1 b c="d" e=''f'' g=h&i&j k="">x</p>', 'e'), 'f',
      'malformed single quoted attr');
  CheckEq(AttrAt('<p a=1 b c="d" e=''f'' g=h&i&j k="">x</p>', 'g'), 'h&i&j',
      'malformed unquoted attr keeps ampersands');
  CheckEq(AttrAt('<p a=1 b c="d" e=''f'' g=h&i&j k="">x</p>', 'k'), '',
      'malformed empty quoted attr');
  CheckEq(AttrAt('<p a=1 b c="d" e=''f'' g=h&i&j k="">x</p>', 'a'), '1',
      'malformed first attr');
  CheckEq(AttrAt('<p class="a" CLASS="b">x</p>', 'class'), 'b',
      'malformed duplicate attr keeps last');
  CheckEq(AttrAt('<p title=a=b>x</p>', 'title'), 'a=b',
      'malformed unquoted value keeps equals');
end;

procedure TestHtmlUtf8;
const
  CyRus = #208#159#209#128#208#184#208#178#208#181#209#130;
  CyMir = #208#188#208#184#209#128#209#130;
  CyZhil = #208#161#208#190#208#187#208#184#209#130;

  function TextOf(const html: AnsiString): AnsiString;
  var
    d: TDomDoc;
    L: TDomNodeArray;
  begin
    Result := '<missing>';
    d := ParseHtml(html);
    try
      L := d.GetElementsByTagName('p');
      if (Length(L) = 1) and (Length(L[0].Children) > 0) then
        Result := L[0].Children[0].Text;
    finally
      d.Free;
    end;
  end;

var
  doc: TDomDoc;
  L: TDomNodeArray;
  src: AnsiString;
begin
  src := '<p>' + CyRus + ' ' + CyMir + '</p>';
  CheckEq(TextOf(src), CyRus + ' ' + CyMir, 'utf8 cyrillic body round trip');
  CheckEq(TextOf('<p>' + CyRus + 'a</p>'), CyRus + 'a', 'utf8 mixed ascii cyrillic');
  CheckEq(TextOf('<p>caf' + #195#169 + '</p>'), 'caf' + #195#169,
      'utf8 latin accent round trip');
  CheckEq(TextOf('<p>e' + #226#130#172 + '</p>'), 'e' + #226#130#172,
      'utf8 euro three byte round trip');
  CheckEq(DecodeEntities(CyRus), CyRus, 'utf8 decode leaves raw bytes alone');
  CheckEq(DecodeEntities(''), '', 'utf8 decode empty');

  doc := ParseHtml('<html><head><title>' + CyRus + '</title></head><body><b>' +
    CyZhil + '</b></body></html>');
  try
    CheckEq(doc.Title, CyRus, 'utf8 title round trip');
    L := doc.GetElementsByTagName('b');
    if Length(L) = 1 then
      CheckEq(L[0].Children[0].Text, CyZhil, 'utf8 bold text round trip');
    CheckEq(doc.TextContent, CyZhil, 'utf8 text content round trip');
  finally
    doc.Free;
  end;

  doc := ParseHtml('<div data-x="' + CyRus + '">t</div>');
  try
    L := doc.GetElementsByTagName('div');
    if Length(L) = 1 then
      CheckEq(L[0].Attr('data-x'), CyRus, 'utf8 attribute value round trip');
  finally
    doc.Free;
  end;
end;

procedure TestCssParse;
var
  sh: TCssSheet;
  sl: TStringList;
  r: TCssRule;
  count: Integer;
  firstProp, firstVal, firstSel: AnsiString;

  procedure Rules(const css: AnsiString; wantCount: Integer;
    const sel, prop, val: AnsiString; const nm: AnsiString);
  var
    s: TCssSheet;
  begin
    s := TCssSheet.Create;
    try
      s.Parse(css);
      count := s.Count;
      if count = 0 then
      begin
        firstSel := '';
        firstProp := '';
        firstVal := '';
      end
      else
      begin
        r := s.Get(0);
        firstSel := r.Selector;
        firstProp := r.Prop;
        firstVal := r.Value;
      end;
      CheckEq(IntToStr(count), IntToStr(wantCount), nm + ' rule count');
      if count > 0 then
      begin
        CheckEq(firstSel, sel, nm + ' selector');
        CheckEq(firstProp, prop, nm + ' property');
        CheckEq(firstVal, val, nm + ' value');
      end;
    finally
      s.Free;
    end;
  end;

begin
  Rules('p { color: red }', 1, 'p', 'color', 'red', 'parse simple');
  Rules('p { COLOR : Red }', 1, 'p', 'color', 'Red', 'parse lower cases property');
  Rules('p{color:red}', 1, 'p', 'color', 'red', 'parse no spaces');
  Rules('p { color: red; }', 1, 'p', 'color', 'red', 'parse trailing semicolon');
  Rules('/* lead */ p { /* mid */ color: red /* tail */ }', 1, 'p', 'color', 'red',
      'parse strips comments');
  Rules('/* unterminated p { color: red', 0, '', '', '', 'parse unterminated comment');
  Rules('p { color }', 0, '', '', '', 'parse declaration without colon dropped');
  Rules('p { } ', 0, '', '', '', 'parse empty block dropped');
  Rules('p { color: red !important }', 1, 'p', 'color', 'red !important',
      'parse important marker kept in value');
  Rules('p { margin: 1em 2em 3em 4em }', 1, 'p', 'margin', '1em 2em 3em 4em',
      'parse multi value declaration');
  Rules('p { font-family: Arial } p { color: red } div { color: blue }', 3,
      'p', 'font-family', 'Arial', 'parse several rule sets');
  Rules('p { color } p { color: red }', 1, 'p', 'color', 'red',
      'parse bad declaration keeps next rule');
  Rules('p { color: red; span { color: pink }', 2, 'p', 'color', 'red',
      'parse unclosed brace keeps following rule');
  Rules('@media screen { p { color: red } } h1 { color: olive }', 2,
      'p', 'color', 'red', 'parse media screen and following rule');
  Rules('@media print { p { color: red } }', 0, '', '', '', 'parse media print skipped');
  Rules('@media all { p { color: red } }', 1, 'p', 'color', 'red',
      'parse media all kept');
  Rules('@import "x.css"; p { color: red }', 1, 'p', 'color', 'red',
      'parse import skipped keeps following rule');
  Rules('@charset "utf-8"; p { color: red }', 1, 'p', 'color', 'red',
      'parse unknown at rule skipped keeps following rule');

  sh := TCssSheet.Create;
  try
    sh.Parse('p { color: red }');
    CheckEq(IntToStr(sh.Count), '1', 'parse Parse replaces old rules');
    sh.AddRules('h1 { color: olive }');
    CheckEq(IntToStr(sh.Count), '2', 'parse AddRules appends');
    if sh.Count = 2 then
    begin
      CheckEq(sh.Get(0).Value, 'red', 'parse AddRules keeps first rule');
      CheckEq(sh.Get(1).Value, 'olive', 'parse AddRules appends rule');
      Check(sh.Get(1).Order > sh.Get(0).Order, 'parse order increases');
    end;
    r := sh.Get(-1);
    CheckEq(r.Prop, '', 'parse Get negative index empty');
    r := sh.Get(99);
    CheckEq(r.Prop, '', 'parse Get past end empty');
  finally
    sh.Free;
  end;

  sl := TStringList.Create;
  try
    SplitSelectorList('a, b > c , d', sl);
    CheckEq(IntToStr(sl.Count), '3', 'parse selector list count');
    if sl.Count = 3 then
    begin
      CheckEq(sl[0], 'a', 'parse selector list first');
      CheckEq(sl[1], 'b > c', 'parse selector list keeps combinator');
      CheckEq(sl[2], 'd', 'parse selector list last');
    end;
    SplitSelectorList('p', sl);
    CheckEq(IntToStr(sl.Count), '1', 'parse single selector list');
    SplitSelectorList('a,x', sl);
    CheckEq(IntToStr(sl.Count), '2', 'parse comma without space');
  finally
    sl.Free;
  end;

  CheckEq(IntToStr(Specificity('p')), '1', 'specificity type');
  CheckEq(IntToStr(Specificity('.c')), '100', 'specificity class');
  CheckEq(IntToStr(Specificity('#i')), '10000', 'specificity id');
  CheckEq(IntToStr(Specificity('div p')), '2', 'specificity two types');
  CheckEq(IntToStr(Specificity('ul li a')), '3', 'specificity three types');
  CheckEq(IntToStr(Specificity('*')), '1', 'specificity star not zero');
  CheckEq(IntToStr(Specificity('#i .c')), '10100', 'specificity id and class');
  CheckEq(IntToStr(Specificity('div.a#b')), '10101', 'specificity compound');
  CheckEq(IntToStr(Specificity('a:hover')), '1', 'specificity pseudo ignored');
  CheckEq(IntToStr(Specificity('input[t=x]')), '1', 'specificity attribute ignored');
  Check(Specificity('#i') > Specificity('.c'), 'specificity id beats class');
  Check(Specificity('.c') > Specificity('p'), 'specificity class beats type');
  Check(Specificity('.c') > Specificity('div p span'), 'specificity class beats types');

  CheckEq(IntToStr(ParseLength('12px')), '12', 'length px');
  CheckEq(IntToStr(ParseLength('0')), '0', 'length zero');
  CheckEq(IntToStr(ParseLength('2em')), '32', 'length em');
  CheckEq(IntToStr(ParseLength('1.5rem')), '24', 'length rem');
  CheckEq(IntToStr(ParseLength('50%')), '0', 'length percent defers');
  CheckEq(IntToStr(ParseLength('12pt')), '16', 'length pt');
  CheckEq(IntToStr(ParseLength('auto')), '0', 'length auto');
  CheckEq(IntToStr(ParseLength('-3px')), '-3', 'length negative');

  CheckEq(ParseColor('#abc'), '#aabbcc', 'color short hex expanded');
  CheckEq(ParseColor('#AABBCC'), '#aabbcc', 'color hex lower cased');
  CheckEq(ParseColor('red'), '#ff0000', 'color named');
  CheckEq(ParseColor('RED'), '#ff0000', 'color named case insensitive');
  CheckEq(ParseColor('rgb(1, 2, 3)'), '#010203', 'color rgb function');
  CheckEq(ParseColor('bogus'), '', 'color unknown empty');
  CheckEq(ParseColor('transparent'), '', 'color transparent empty');
  CheckEq(ParseColor('#12'), '', 'color bad hex length empty');
end;

procedure TestCssMatch;
var
  doc: TDomDoc;
  target, parent: TDomNode;
  sh: TCssSheet;
  v: AnsiString;

  function Match(const html, tag, sel: AnsiString): AnsiString;
  var
    d: TDomDoc;
    L: TDomNodeArray;
  begin
    Result := 'E';
    d := ParseHtml(html);
    try
      L := d.GetElementsByTagName(tag);
      if Length(L) > 0 then
        if MatchSelector(L[0], sel) then Result := 'T' else Result := 'F';
    finally
      d.Free;
    end;
  end;

  function Win(const css, html, prop: AnsiString): AnsiString;
  var
    s: TCssSheet;
    d: TDomDoc;
    L: TDomNodeArray;
  begin
    Result := '<none>';
    s := TCssSheet.Create;
    try
      s.Parse(css);
      d := ParseHtml(html);
      try
        L := d.GetElementsByTagName('*');
        if Length(L) > 0 then
          if s.Winner(L[High(L)], prop, v) then Result := v;
      finally
        d.Free;
      end;
    finally
      s.Free;
    end;
  end;

begin
  doc := ParseHtml('<div id=o class="a b"><p class=x id=y>t</p>' +
    '<span><p>q</p></span></div>');
  try
    target := doc.GetElementById('y');
    Check(target <> nil, 'match fixture found');
    if target <> nil then
    begin
      Check(MatchSelector(target, 'p'), 'match type selector');
      Check(MatchSelector(target, '*'), 'match universal');
      Check(not MatchSelector(target, 'div'), 'match wrong type fails');
      Check(MatchSelector(target, '.x'), 'match own class');
      Check(MatchSelector(target, '#y'), 'match own id');
      Check(not MatchSelector(target, '.q'), 'match absent class fails');
      Check(not MatchSelector(target, '#q'), 'match absent id fails');
      Check(MatchSelector(target, 'div p'), 'match descendant');
      Check(MatchSelector(target, 'div>p'), 'match child');
      Check(MatchSelector(target, 'div > p'), 'match child with spaces');
      Check(not MatchSelector(target, 'span p'), 'match wrong descendant fails');
      Check(not MatchSelector(target, 'div>span p'), 'match deep child fails');
      Check(not MatchSelector(target, ''), 'match empty selector fails');
    end;
    CheckEq(Match('<div class=a><p class=x>t</p></div>', 'div', '.a'), 'T',
        'match class on element');
    CheckEq(Match('<div id=q><p>t</p></div>', 'div', '#q'), 'T', 'match id on element');
    CheckEq(Match('<div id=q class=a><p>t</p></div>', 'div', 'div.a#q'), 'T',
        'match compound selector');
    CheckEq(Match('<div><p class=x>t</p></div>', 'p', 'p.x'), 'T', 'match type with class');
    CheckEq(Match('<div class=a><p class=x>t</p></div>', 'p', '.a>p'), 'T',
        'match class as ancestor in child selector');
    CheckEq(Match('<div class=a><p>t</p></div>', 'p', '.a p'), 'T',
        'match class as ancestor in descendant selector');
    CheckEq(Match('<div><span><p>t</p></span></div>', 'p', 'div p'), 'T',
        'match descendant across levels');
    CheckEq(Match('<div><span><p>t</p></span></div>', 'p', 'div>p'), 'F',
        'match child rejects grandchild');

    CheckEq(Win('p, h1, .c, #d { color: blue }', '<html><body><p>x</p></body></html>',
      'color'), 'blue', 'match comma list type');
    CheckEq(Win('p, h1, .c, #d { color: blue }', '<html><body><h1>x</h1></body></html>',
      'color'), 'blue', 'match comma list second');
    CheckEq(Win('p, h1, .c, #d { color: blue }', '<html><body><span class=c>x</span></body></html>',
      'color'), 'blue', 'match comma list class');
    CheckEq(Win('p, h1, .c, #d { color: blue }', '<html><body><span id=d>x</span></body></html>',
      'color'), 'blue', 'match comma list id');
    CheckEq(Win('span, b { color: olive }', '<html><body><i>x</i></body></html>',
      'color'), '<none>', 'match comma list no match');
    CheckEq(Win('div p { color: red }', '<html><body><div><p>x</p></div></body></html>',
      'color'), 'red', 'match descendant in sheet');
    CheckEq(Win('div>p { color: red }', '<html><body><div><p>x</p></div></body></html>',
      'color'), 'red', 'match child in sheet');
    CheckEq(Win('div>b { color: red }', '<html><body><div><p>x</p></div></body></html>',
      'color'), '<none>', 'match child mismatch in sheet');
    CheckEq(Win('p:hover { color: red }', '<html><body><p>x</p></body></html>',
      'color'), '<none>', 'match pseudo class rule never applies');
    CheckEq(Win('input[t=x] { color: red }', '<html><body><input t=x></body></html>',
      'color'), '<none>', 'match attribute rule never applies');
    CheckEq(Win('* { color: red }', '<html><body><p>x</p></body></html>',
      'color'), 'red', 'match universal in sheet');
  finally
    doc.Free;
  end;

  sh := TCssSheet.Create;
  try
    sh.Parse('p { color: red }');
    doc := ParseHtml('<html><body><h1>x</h1></body></html>');
    try
      parent := doc.GetElementsByTagName('h1')[0];
      Check(not sh.Winner(parent, 'color', v), 'match winner no matching rule');
      Check(not sh.Winner(parent, 'display', v), 'match winner unknown property');
    finally
      doc.Free;
    end;
  finally
    sh.Free;
  end;
end;

procedure TestCssCascade;
var
  doc: TDomDoc;
  sh: TCssSheet;
  m: TStyleMap;

  function Computed(const html, css, tag: AnsiString): AnsiString;
  var
    d: TDomDoc;
    s: TCssSheet;
    map: TStyleMap;
    L: TDomNodeArray;
    st: TCssStyle;
  begin
    Result := '<missing>';
    d := ParseHtml(html);
    s := TCssSheet.Create;
    try
      s.Parse(css);
      map := ComputeStyles(d, s);
      try
        L := d.GetElementsByTagName(tag);
        if Length(L) > 0 then
        begin
          st := map.StyleOf(L[0]);
          Result := 'd=' + IntToStr(Ord(st.Display)) + ' fw=' +
            IntToStr(st.FontWeight) + ' it=' + IntToStr(Ord(st.FontStyle)) +
            ' ul=' + IntToStr(Ord(st.Underline)) + ' al=[' + st.Align + ']' +
            ' co=[' + st.Color + '] bg=[' + st.BgColor + ']' +
            ' mt=' + IntToStr(st.MarginTop) + ' mr=' + IntToStr(st.MarginRight) +
            ' mb=' + IntToStr(st.MarginBottom) + ' ml=' + IntToStr(st.MarginLeft) +
            ' pt=' + IntToStr(st.PaddingTop) + ' pl=' + IntToStr(st.PaddingLeft) +
            ' w=' + IntToStr(st.Width) + ' h=' + IntToStr(st.Height) +
            ' ls=[' + st.ListStyle + '] ws=[' + st.WhiteSpace + ']' +
            ' hid=' + IntToStr(Ord(st.Hidden));
        end;
      finally
        map.Free;
      end;
    finally
      s.Free;
      d.Free;
    end;
  end;

  function ColorOf(const html, css: AnsiString): AnsiString;
  var
    res, field: AnsiString;
    p, q: Integer;
  begin
    res := Computed(html, css, 'p');
    p := Pos(' co=[', res);
    Result := '<no color field>';
    if p > 0 then
    begin
      field := Copy(res, p + 5, MaxInt);
      q := Pos(']', field);
      if q > 0 then Result := Copy(field, 1, q - 1);
    end;
  end;

begin
  CheckEq(ColorOf('<html><body><p>x</p></body></html>',
    'p { color: red } p { color: blue }'), '#0000ff',
    'cascade same specificity keeps last rule');
  CheckEq(ColorOf('<html><body><p id=q>x</p></body></html>',
    'p { color: red } #q { color: green } p { color: blue }'), '#008000',
    'cascade higher specificity wins over later rule');
  CheckEq(ColorOf('<html><body><p>x</p></body></html>',
    'p { color: red !important } p { color: blue }'), '#ff0000',
    'cascade important value survives when compared by string');
  CheckEq(ColorOf('<html><body><div><p>x</p></div></body></html>',
    'p { color: red } div p { color: blue }'), '#0000ff',
    'cascade descendant specificity beats type');
  CheckEq(ColorOf('<html><body><p style="color:red">x</p></body></html>',
    'p { color: blue }'), '#ff0000', 'cascade inline style beats sheet');
  CheckEq(ColorOf('<html><body><p>x</p></body></html>',
    'p { color: bogus }'), '', 'cascade unknown colour value ignored');
  CheckEq(ColorOf('<html><body><p>x</p></body></html>',
    'p { colour: red }'), '', 'cascade unknown property ignored');
  CheckEq(ColorOf('<html><body><div style="color:red"><p>x</p></div></body></html>',
    ''), '#ff0000', 'cascade colour inherits to child');
  CheckEq(ColorOf('<html><body><p>x</p></body></html>',
    'p { color: rgb(1, 2, 3) }'), '#010203', 'cascade colour via rgb');

  Check(Pos('co=[]', Computed('<html><body><h1>H</h1></body></html>',
    'h1 { font-weight: normal } p { color: red }', 'h1')) > 0,
    'cascade author rule does not leak to sibling selector');
  Check(Pos('fw=400', Computed('<html><body><h1>H</h1></body></html>',
    'h1 { font-weight: normal } p { color: red }', 'h1')) > 0,
    'cascade author normal overrides user agent bold');
  Check(Pos('d=1', Computed('<html><body><h1>H</h1></body></html>', '', 'h1')) > 0,
      'cascade user agent block display survives');
  Check(Pos('fw=700', Computed('<html><body><h1>H</h1></body></html>', '', 'h1')) > 0,
      'cascade user agent bold heading survives');
  Check(Pos('fw=400', Computed('<html><body><h1>H</h1></body></html>',
    'h1 { font-weight: normal }', 'h1')) > 0, 'cascade normal font weight');

  Check(Pos('d=2', Computed('<html><body><p>x</p></body></html>',
    'p { display: inline }', 'p')) > 0, 'cascade display inline');
  Check(Pos('d=1', Computed('<html><body><p>x</p></body></html>',
    'p { display: flex }', 'p')) > 0, 'cascade flex computes to block');
  Check(Pos('hid=1', Computed('<html><body><p>x</p></body></html>',
    'p { display: none }', 'p')) > 0, 'cascade display none hides');
  Check(Pos('co=[#0000ff]', Computed('<html><body><p>x</p></body></html>',
    'p { color: red } p { color: blue }', 'p')) > 0, 'cascade colour field order keeps last');

  Check(Pos('hid=1', Computed('<html><body><div><p>x</p></div></body></html>',
    'div { display: none }', 'div')) > 0, 'cascade hidden ancestor');
  Check(Pos('hid=1', Computed('<html><body><div style="display:none"><p>x</p></div></body></html>',
    '', 'p')) > 0, 'cascade hidden inline ancestor hides child');
  Check(Pos('hid=1', Computed('<html><body><div style="display:none"><p>x</p></div></body></html>',
    'p { display: block }', 'p')) > 0, 'cascade hidden ancestor beats author display');

  Check(Pos('w=100', Computed('<html><body><p>x</p></body></html>',
    'p { width: 100px }', 'p')) > 0, 'cascade width length');
  Check(Pos('w=0', Computed('<html><body><p>x</p></body></html>',
    'p { width: 50% }', 'p')) > 0, 'cascade percent width defers to layout');
  Check(Pos('mt=16 mr=16 mb=16 ml=16', Computed('<html><body><p>x</p></body></html>',
    'p { margin: 16px }', 'p')) > 0, 'cascade one value margin shorthand');
  Check(Pos('pt=5 pl=5', Computed('<html><body><p>x</p></body></html>',
    'p { padding: 5px }', 'p')) > 0, 'cascade padding shorthand');
  Check(Pos('mt=16', Computed('<html><body><p>x</p></body></html>',
    'p { margin-top: 1em }', 'p')) > 0, 'cascade margin-top longhand');
  Check(Pos('pl=8', Computed('<html><body><p>x</p></body></html>',
    'p { padding-left: 8px }', 'p')) > 0, 'cascade padding-left longhand');
  Check(Pos('ws=[pre]', Computed('<html><body><p>x</p></body></html>',
    'p { white-space: pre }', 'p')) > 0, 'cascade white-space');
  Check(Pos('ls=[square]', Computed('<html><body><p>x</p></body></html>',
    'p { list-style-type: square }', 'p')) > 0, 'cascade list-style-type');
  Check(Pos('al=[center]', Computed('<html><body><p>x</p></body></html>',
    'p { text-align: center }', 'p')) > 0, 'cascade text-align');
  Check(Pos('al=[]', Computed('<html><body><p>x</p></body></html>',
    'p { text-align: justify }', 'p')) > 0, 'cascade unknown align value ignored');
  Check(Pos('bg=[#ff0000]', Computed('<html><body><p>x</p></body></html>',
    'p { background: red }', 'p')) > 0, 'cascade background shorthand');
  Check(Pos('ul=1', Computed('<html><body><p>x</p></body></html>',
    'p { text-decoration: underline }', 'p')) > 0, 'cascade underline');
  Check(Pos('it=1', Computed('<html><body><p>x</p></body></html>',
    'p { font-style: italic }', 'p')) > 0, 'cascade italic');
  Check(Pos('fw=700', Computed('<html><body><p>x</p></body></html>',
    'p { font-weight: 700 }', 'p')) > 0, 'cascade numeric bold');

  { the whole-document path used by the browser }
  doc := ParseHtml('<html><head><style>h1 { color: red }</style></head>' +
    '<body><h1>H</h1></body></html>');
  sh := CollectSheets(doc);
  try
    CheckEq(IntToStr(sh.Count), '1', 'cascade collects style block');
    m := ComputeStyles(doc, sh);
    try
      CheckEq(IntToStr(m.Count),
        IntToStr(Length(doc.GetElementsByTagName('*'))),
        'cascade styles every element');
      CheckEq(m.StyleOf(doc.GetElementsByTagName('h1')[0]).Color, '#ff0000',
        'cascade collects style into map');
    finally
      m.Free;
    end;
  finally
    sh.Free;
    doc.Free;
  end;
end;

procedure TestCssUa;
var
  sh: TCssSheet;
  doc: TDomDoc;
  m: TStyleMap;

  function UaDisp(const tag: AnsiString): AnsiString;
  var
    L: TDomNodeArray;
  begin
    Result := '<missing>';
    L := doc.GetElementsByTagName(tag);
    if Length(L) > 0 then
      Result := IntToStr(Ord(m.StyleOf(L[0]).Display));
  end;

  function UaStyle(const tag: AnsiString): AnsiString;
  var
    L: TDomNodeArray;
    st: TCssStyle;
  begin
    Result := '<missing>';
    L := doc.GetElementsByTagName(tag);
    if Length(L) > 0 then
    begin
      st := m.StyleOf(L[0]);
      Result := 'fw=' + IntToStr(st.FontWeight) + ' it=' +
        IntToStr(Ord(st.FontStyle)) + ' ul=' + IntToStr(Ord(st.Underline)) +
        ' al=[' + st.Align + '] ws=[' + st.WhiteSpace + ']';
    end;
  end;

  function UaWinner(const tag, prop: AnsiString): AnsiString;
  var
    L: TDomNodeArray;
    val: AnsiString;
  begin
    Result := '<none>';
    L := doc.GetElementsByTagName(tag);
    if (Length(L) > 0) and sh.Winner(L[0], prop, val) then Result := val;
  end;

begin
  doc := ParseHtml('<html><head><title>t</title></head><body>' +
    '<p>a</p><div>b</div><h1>h</h1><h6>h</h6><b>B</b><i>I</i><u>U</u>' +
    '<s>S</s><a href=x>l</a><span>s</span><ul><li>k</li></ul><pre>r</pre>' +
    '<table><tbody><tr><td>c</td><th>d</th></tr></tbody></table><center>w</center>' +
    '</body></html>');
  m := ComputeStyles(doc, nil);
  try
    CheckEq(UaDisp('p'), IntToStr(Ord(dpBlock)), 'ua p is block');
    CheckEq(UaDisp('div'), IntToStr(Ord(dpBlock)), 'ua div is block');
    CheckEq(UaDisp('h1'), IntToStr(Ord(dpBlock)), 'ua h1 is block');
    CheckEq(UaDisp('h6'), IntToStr(Ord(dpBlock)), 'ua h6 is block');
    CheckEq(UaDisp('b'), IntToStr(Ord(dpInline)), 'ua b is inline');
    CheckEq(UaDisp('i'), IntToStr(Ord(dpInline)), 'ua i is inline');
    CheckEq(UaDisp('span'), IntToStr(Ord(dpInline)), 'ua span is inline');
    CheckEq(UaDisp('a'), IntToStr(Ord(dpInline)), 'ua a is inline');
    CheckEq(UaDisp('li'), IntToStr(Ord(dpListItem)), 'ua li is list item');
    CheckEq(UaDisp('pre'), IntToStr(Ord(dpBlock)), 'ua pre is block');
    CheckEq(UaDisp('table'), IntToStr(Ord(dpTable)), 'ua table is table');
    CheckEq(UaDisp('tr'), IntToStr(Ord(dpTableRow)), 'ua tr is table row');
    CheckEq(UaDisp('td'), IntToStr(Ord(dpTableCell)), 'ua td is table cell');
    CheckEq(UaDisp('th'), IntToStr(Ord(dpTableCell)), 'ua th is table cell');
    CheckEq(UaDisp('html'), IntToStr(Ord(dpBlock)), 'ua html is block');
    CheckEq(UaDisp('body'), IntToStr(Ord(dpBlock)), 'ua body is block');
    CheckEq(UaDisp('head'), IntToStr(Ord(dpNone)), 'ua head is none');
    CheckEq(UaDisp('title'), IntToStr(Ord(dpNone)), 'ua title is none');

    Check(Pos('fw=700', UaStyle('h1')) > 0, 'ua h1 bold');
    Check(Pos('fw=700', UaStyle('b')) > 0, 'ua b bold');
    Check(Pos('fw=700', UaStyle('th')) > 0, 'ua th bold');
    Check(Pos('fw=400', UaStyle('p')) > 0, 'ua p normal weight');
    Check(Pos('it=1', UaStyle('i')) > 0, 'ua i italic');
    Check(Pos('ul=1', UaStyle('a')) > 0, 'ua a underline');
    Check(Pos('ul=1', UaStyle('u')) > 0, 'ua u underline');
    Check(Pos('ul=0', UaStyle('p')) > 0, 'ua p not underlined');
    Check(Pos('ws=[pre]', UaStyle('pre')) > 0, 'ua pre white-space pre');
    Check(Pos('al=[center]', UaStyle('center')) > 0, 'ua center aligns center');
    Check(Pos('fw=700', UaStyle('b')) > 0, 'ua bold on b');
  finally
    m.Free;
  end;

  sh := UserAgentSheet;
  Check(sh = UserAgentSheet, 'ua sheet is shared instance');
  Check(sh.Count > 50, 'ua sheet has rules');
  CheckEq(UaWinner('p', 'display'), 'block', 'ua winner p display');
  CheckEq(UaWinner('div', 'display'), 'block', 'ua winner div display');
  CheckEq(UaWinner('h1', 'font-weight'), 'bold', 'ua winner h1 bold');
  CheckEq(UaWinner('b', 'font-weight'), 'bold', 'ua winner b bold');
  CheckEq(UaWinner('a', 'text-decoration'), 'underline', 'ua winner a underline');
  CheckEq(UaWinner('li', 'display'), 'list-item', 'ua winner li display');
  CheckEq(UaWinner('pre', 'white-space'), 'pre', 'ua winner pre white-space');
  CheckEq(UaWinner('span', 'display'), '<none>', 'ua span has no display rule');
  CheckEq(UaWinner('p', 'border'), '<none>', 'ua unknown property has no rule');

  { a page with no author sheet still gets the ua cascade }
  doc := ParseHtml('<html><body><h1>H</h1></body></html>');
  m := ComputeStyles(doc, nil);
  try
    CheckEq(IntToStr(Ord(m.StyleOf(doc.GetElementsByTagName('h1')[0]).Display)),
      IntToStr(Ord(dpBlock)), 'ua applies with nil author sheet');
  finally
    m.Free;
    doc.Free;
  end;
end;

begin
  TestUtf8;
  TestMatchMask;
  TestHighlite;
  TestHighliteState;
  TestHighliteMore;
  TestMarkdown;
  TestTreeSize;
  TestPads;
  TestUU;
  TestParseLs;
  TestSftpUrl;
  TestSessionsRoundTrip;
  TestUserMenu;
  TestPlaylistModel;
  TestPlaylistScan;
  TestPlaylistFiles;
  TestPlaylistTags;
  TestAudioFft;
  TestAudioAnalyzer;
  TestEqualizer;
  TestLsProto;
  TestHtmlTokenizer;
  TestHtmlTree;
  TestHtmlEntities;
  TestHtmlMalformed;
  TestHtmlUtf8;
  TestCssParse;
  TestCssMatch;
  TestCssCascade;
  TestCssUa;
  if Failures = 0 then
    WriteLn(Checks, ' unit checks passed')
  else
  begin
    WriteLn(Failures, ' of ', Checks, ' unit checks FAILED');
    ExitCode := 1;
  end;
end.
