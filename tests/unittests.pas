{ unittests — FPC-native unit tests for pure logic (no terminal needed).
  Runs as part of `make test` before the Python end-to-end suite. }
program unittests;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, dnscreen, dnpanel, dnfileops, dnuu, dnvfs, dnsftp,
  dnsession, dnusermenu;

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
  Check(Utf8Len('') = 0, 'Utf8Len empty');
  Check(Utf8Len('abc') = 3, 'Utf8Len ascii');
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

begin
  TestUtf8;
  TestMatchMask;
  TestTreeSize;
  TestPads;
  TestUU;
  TestParseLs;
  TestSftpUrl;
  TestSessionsRoundTrip;
  TestUserMenu;
  if Failures = 0 then
    WriteLn(Checks, ' unit checks passed')
  else
  begin
    WriteLn(Failures, ' of ', Checks, ' unit checks FAILED');
    ExitCode := 1;
  end;
end.
