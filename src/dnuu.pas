{ dnuu — classic uuencode/uudecode (DN 3.17/3.18). Pure Pascal, no
  external tools; interoperates with the standard `uuencode`/`uudecode`. }
unit dnuu;

{$mode objfpc}{$H+}

interface

function UUEncodeFile(const Src, Dst: AnsiString; out Err: AnsiString): Boolean;
function UUDecodeFile(const Src, Dst: AnsiString; out Err: AnsiString): Boolean;

implementation

uses
  SysUtils, Classes;

function EncByte(b: Byte): Char; inline;
begin
  { classic uuencode: 0 maps to '`' (0x60) not space, matching GNU output }
  if b = 0 then Result := '`' else Result := Chr(b + 32);
end;

function EncodeLine(const data: AnsiString): AnsiString;
var
  i, n: Integer;
  b0, b1, b2: Byte;
begin
  n := Length(data);
  Result := EncByte(n);
  i := 1;
  while i <= n do
  begin
    b0 := Ord(data[i]);
    if i + 1 <= n then b1 := Ord(data[i + 1]) else b1 := 0;
    if i + 2 <= n then b2 := Ord(data[i + 2]) else b2 := 0;
    Result := Result +
      EncByte(b0 shr 2) +
      EncByte(((b0 and 3) shl 4) or (b1 shr 4)) +
      EncByte(((b1 and 15) shl 2) or (b2 shr 6)) +
      EncByte(b2 and 63);
    Inc(i, 3);
  end;
end;

function UUEncodeFile(const Src, Dst: AnsiString; out Err: AnsiString): Boolean;
var
  fs: TFileStream;
  outL: TStringList;
  buf: AnsiString;
  chunk: AnsiString;
  got: Integer;
begin
  Err := '';
  Result := False;
  try
    fs := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
    try
      SetLength(buf, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(buf[1], fs.Size);
    finally
      fs.Free;
    end;
    outL := TStringList.Create;
    try
      outL.Add(Format('begin 644 %s', [ExtractFileName(Src)]));
      got := 1;
      while got <= Length(buf) do
      begin
        chunk := Copy(buf, got, 45);
        outL.Add(EncodeLine(chunk));
        Inc(got, 45);
      end;
      outL.Add('`');
      outL.Add('end');
      outL.SaveToFile(Dst);
    finally
      outL.Free;
    end;
    Result := True;
  except
    on E: Exception do Err := E.Message;
  end;
end;

function DecByte(c: Char): Byte; inline;
begin
  if c = '`' then Result := 0 else Result := (Ord(c) - 32) and 63;
end;

function DecodeLine(const line: AnsiString): AnsiString;
var
  n, i: Integer;
  c0, c1, c2, c3: Byte;
begin
  Result := '';
  if line = '' then Exit;
  n := DecByte(line[1]);
  i := 2;
  while (Length(Result) < n) and (i + 3 <= Length(line) + 1) do
  begin
    c0 := DecByte(line[i]);
    if i + 1 <= Length(line) then c1 := DecByte(line[i + 1]) else c1 := 0;
    if i + 2 <= Length(line) then c2 := DecByte(line[i + 2]) else c2 := 0;
    if i + 3 <= Length(line) then c3 := DecByte(line[i + 3]) else c3 := 0;
    Result := Result + Chr((c0 shl 2) or (c1 shr 4));
    if Length(Result) < n then
      Result := Result + Chr(((c1 and 15) shl 4) or (c2 shr 2));
    if Length(Result) < n then
      Result := Result + Chr(((c2 and 3) shl 6) or c3);
    Inc(i, 4);
  end;
  SetLength(Result, n);
end;

function UUDecodeFile(const Src, Dst: AnsiString; out Err: AnsiString): Boolean;
var
  inL: TStringList;
  fs: TFileStream;
  i: Integer;
  line, outName, data: AnsiString;
  started: Boolean;
begin
  Err := '';
  Result := False;
  outName := Dst;
  try
    inL := TStringList.Create;
    try
      inL.LoadFromFile(Src);
      started := False;
      data := '';
      for i := 0 to inL.Count - 1 do
      begin
        line := inL[i];
        if not started then
        begin
          if Copy(line, 1, 6) = 'begin ' then started := True;
          Continue;
        end;
        if (Trim(line) = 'end') then Break;
        if (line = '') or (line = '`') then Continue;
        data := data + DecodeLine(line);
      end;
      if not started then
      begin
        Err := 'no "begin" line: not a uuencoded file';
        Exit(False);
      end;
    finally
      inL.Free;
    end;
    fs := TFileStream.Create(outName, fmCreate);
    try
      if Length(data) > 0 then fs.WriteBuffer(data[1], Length(data));
    finally
      fs.Free;
    end;
    Result := True;
  except
    on E: Exception do Err := E.Message;
  end;
end;

end.
