{ unittests — FPC-native unit tests for pure logic (no terminal needed).
  Runs as part of `make test` before the Python end-to-end suite. }
program unittests;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, dnscreen, dnpanel, dnfileops;

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

begin
  TestUtf8;
  TestMatchMask;
  TestTreeSize;
  TestPads;
  if Failures = 0 then
    WriteLn(Checks, ' unit checks passed')
  else
  begin
    WriteLn(Failures, ' of ', Checks, ' unit checks FAILED');
    ExitCode := 1;
  end;
end.
