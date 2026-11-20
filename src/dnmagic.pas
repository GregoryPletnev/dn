{ dnmagic — file types told by their content (magic numbers), not names.

  Each signature is bytes at an offset; a few need a second look:
    Mach-O universal vs Java class  both start CA FE BA BE: a universal
                                    binary's next word is a small arch
                                    count, a class file's is its version
    Windows PE                      'MZ' and 'PE'#0#0 at e_lfanew
    ISO 9660                        'CD001' at 32769
    Apple disk image                'koly' 512 bytes before the end
  Types belong to groups (Images, Archives, ...) so a search can ask for
  "any archive". }
unit dnmagic;

{$mode objfpc}{$H+}

interface

{ the names to offer: groups first ('Images', ...), then the types }
function MagicGroupCount: Integer;
function MagicGroupName(I: Integer): AnsiString;
function MagicTypeCount: Integer;
function MagicTypeName(I: Integer): AnsiString;
function MagicTypeGroup(I: Integer): AnsiString;

{ the type of a file by its content, '' when none is known }
function DetectMagic(const Path: AnsiString): AnsiString;

{ Filter: '' (anything), a group name or a type name }
function MatchesMagic(const Path, Filter: AnsiString): Boolean;

{ the type of a content held in memory (Head: the first bytes, Size: the
  whole file's size); no tail checks }
function DetectMagicHead(const Head: AnsiString): AnsiString;

implementation

uses
  SysUtils;

type
  TMagic = record
    Name: AnsiString;
    Group: AnsiString;
    Offset: Integer;
    Bytes: AnsiString;
  end;

const
  HeadSize = 4096;

  Groups: array[0..5] of AnsiString =
    ('Images', 'Archives', 'Executables', 'Audio & video', 'Documents',
     'Databases');

  { checked in order: the first match names the file }
  Magics: array[0..37] of TMagic = (
    (Name: 'SQLite';        Group: 'Databases';     Offset: 0;   Bytes: 'SQLite format 3'#0),
    (Name: 'Parquet';       Group: 'Databases';     Offset: 0;   Bytes: 'PAR1'),
    (Name: 'PDF';           Group: 'Documents';     Offset: 0;   Bytes: '%PDF-'),
    (Name: 'MS Office (old)'; Group: 'Documents';   Offset: 0;   Bytes: #$D0#$CF#$11#$E0#$A1#$B1#$1A#$E1),
    (Name: 'RTF';           Group: 'Documents';     Offset: 0;   Bytes: '{\rtf'),
    (Name: 'PostScript';    Group: 'Documents';     Offset: 0;   Bytes: '%!PS'),
    (Name: 'PNG';           Group: 'Images';        Offset: 0;   Bytes: #$89'PNG'#13#10#$1A#10),
    (Name: 'JPEG';          Group: 'Images';        Offset: 0;   Bytes: #$FF#$D8#$FF),
    (Name: 'GIF';           Group: 'Images';        Offset: 0;   Bytes: 'GIF8'),
    (Name: 'WebP';          Group: 'Images';        Offset: 8;   Bytes: 'WEBP'),
    (Name: 'TIFF';          Group: 'Images';        Offset: 0;   Bytes: 'II*'#0),
    (Name: 'TIFF';          Group: 'Images';        Offset: 0;   Bytes: 'MM'#0'*'),
    (Name: 'Photoshop';     Group: 'Images';        Offset: 0;   Bytes: '8BPS'),
    (Name: 'HEIC/AVIF';     Group: 'Images';        Offset: 4;   Bytes: 'ftypheic'),
    (Name: 'HEIC/AVIF';     Group: 'Images';        Offset: 4;   Bytes: 'ftypavif'),
    (Name: 'ZIP';           Group: 'Archives';      Offset: 0;   Bytes: 'PK'#3#4),
    (Name: 'ZIP';           Group: 'Archives';      Offset: 0;   Bytes: 'PK'#5#6),
    (Name: 'gzip';          Group: 'Archives';      Offset: 0;   Bytes: #$1F#$8B),
    (Name: 'bzip2';         Group: 'Archives';      Offset: 0;   Bytes: 'BZh'),
    (Name: 'xz';            Group: 'Archives';      Offset: 0;   Bytes: #$FD'7zXZ'#0),
    (Name: 'zstd';          Group: 'Archives';      Offset: 0;   Bytes: #$28#$B5#$2F#$FD),
    (Name: '7-Zip';         Group: 'Archives';      Offset: 0;   Bytes: '7z'#$BC#$AF#$27#$1C),
    (Name: 'RAR';           Group: 'Archives';      Offset: 0;   Bytes: 'Rar!'#$1A#7),
    (Name: 'tar';           Group: 'Archives';      Offset: 257; Bytes: 'ustar'),
    (Name: 'ELF';           Group: 'Executables';   Offset: 0;   Bytes: #$7F'ELF'),
    (Name: 'Mach-O';        Group: 'Executables';   Offset: 0;   Bytes: #$CF#$FA#$ED#$FE),
    (Name: 'Mach-O';        Group: 'Executables';   Offset: 0;   Bytes: #$CE#$FA#$ED#$FE),
    (Name: 'WebAssembly';   Group: 'Executables';   Offset: 0;   Bytes: #0'asm'),
    (Name: 'Script (#!)';   Group: 'Executables';   Offset: 0;   Bytes: '#!'),
    (Name: 'MP3';           Group: 'Audio & video'; Offset: 0;   Bytes: 'ID3'),
    (Name: 'FLAC';          Group: 'Audio & video'; Offset: 0;   Bytes: 'fLaC'),
    (Name: 'Ogg';           Group: 'Audio & video'; Offset: 0;   Bytes: 'OggS'),
    (Name: 'WAV';           Group: 'Audio & video'; Offset: 8;   Bytes: 'WAVE'),
    (Name: 'AVI';           Group: 'Audio & video'; Offset: 8;   Bytes: 'AVI '),
    (Name: 'MP4/MOV';       Group: 'Audio & video'; Offset: 4;   Bytes: 'ftyp'),
    (Name: 'Matroska/WebM'; Group: 'Audio & video'; Offset: 0;   Bytes: #$1A#$45#$DF#$A3),
    (Name: 'MIDI';          Group: 'Audio & video'; Offset: 0;   Bytes: 'MThd'),
    (Name: 'Apple disk image'; Group: 'Archives';   Offset: -1;  Bytes: 'koly')
  );

  { types decided by code, listed after the table ones }
  Extra: array[0..3] of TMagic = (
    (Name: 'Mach-O universal'; Group: 'Executables'; Offset: 0; Bytes: ''),
    (Name: 'Java class';    Group: 'Executables';   Offset: 0;   Bytes: ''),
    (Name: 'Windows PE';    Group: 'Executables';   Offset: 0;   Bytes: ''),
    (Name: 'ISO 9660';      Group: 'Archives';      Offset: 0;   Bytes: '')
  );

var
  TypeList: array of TMagic;      // unique names, table order

procedure BuildTypes;
var
  i, j: Integer;

  procedure Add(const M: TMagic);
  var
    k: Integer;
  begin
    for k := 0 to High(TypeList) do
      if TypeList[k].Name = M.Name then Exit;
    SetLength(TypeList, Length(TypeList) + 1);
    TypeList[High(TypeList)] := M;
  end;

begin
  if Length(TypeList) > 0 then Exit;
  for i := 0 to High(Magics) do Add(Magics[i]);
  for j := 0 to High(Extra) do Add(Extra[j]);
end;

function MagicGroupCount: Integer;
begin
  Result := Length(Groups);
end;

function MagicGroupName(I: Integer): AnsiString;
begin
  Result := Groups[I];
end;

function MagicTypeCount: Integer;
begin
  BuildTypes;
  Result := Length(TypeList);
end;

function MagicTypeName(I: Integer): AnsiString;
begin
  BuildTypes;
  Result := TypeList[I].Name;
end;

function MagicTypeGroup(I: Integer): AnsiString;
begin
  BuildTypes;
  Result := TypeList[I].Group;
end;

function At(const Head: AnsiString; Ofs: Integer; const B: AnsiString): Boolean;
begin
  Result := (Ofs >= 0) and (Length(Head) >= Ofs + Length(B)) and
            (Copy(Head, Ofs + 1, Length(B)) = B);
end;

function Be32(const S: AnsiString; Ofs: Integer): LongWord;
begin
  Result := (LongWord(Ord(S[Ofs + 1])) shl 24) or (LongWord(Ord(S[Ofs + 2])) shl 16) or
            (LongWord(Ord(S[Ofs + 3])) shl 8) or LongWord(Ord(S[Ofs + 4]));
end;

function Le32(const S: AnsiString; Ofs: Integer): LongWord;
begin
  Result := LongWord(Ord(S[Ofs + 1])) or (LongWord(Ord(S[Ofs + 2])) shl 8) or
            (LongWord(Ord(S[Ofs + 3])) shl 16) or (LongWord(Ord(S[Ofs + 4])) shl 24);
end;

function DetectMagicHead(const Head: AnsiString): AnsiString;
var
  i: Integer;
  lfanew: LongWord;
begin
  Result := '';
  { CA FE BA BE: a universal binary has a handful of architectures, a
    class file's version (major in the low half) is 45 or more }
  if At(Head, 0, #$CA#$FE#$BA#$BE) and (Length(Head) >= 8) then
  begin
    if Be32(Head, 4) < 40 then Exit('Mach-O universal') else Exit('Java class');
  end;
  if At(Head, 0, 'MZ') and (Length(Head) >= 64) then
  begin
    lfanew := Le32(Head, $3C);
    if (lfanew + 4 <= LongWord(Length(Head))) and At(Head, lfanew, 'PE'#0#0) then
      Exit('Windows PE');
  end;
  for i := 0 to High(Magics) do
    if (Magics[i].Offset >= 0) and At(Head, Magics[i].Offset, Magics[i].Bytes) then
      Exit(Magics[i].Name);
end;

function ReadAt(f: THandle; Ofs: Int64; N: Integer): AnsiString;
begin
  Result := '';
  if FileSeek(f, Ofs, 0) <> Ofs then Exit;
  SetLength(Result, N);
  SetLength(Result, FileRead(f, Result[1], N));
end;

function DetectMagic(const Path: AnsiString): AnsiString;
var
  f: THandle;
  head: AnsiString;
  size: Int64;
begin
  Result := '';
  f := FileOpen(Path, fmOpenRead or fmShareDenyNone);
  if f = THandle(-1) then Exit;
  try
    head := ReadAt(f, 0, HeadSize);
    if head = '' then Exit;
    Result := DetectMagicHead(head);
    if Result <> '' then Exit;
    size := FileSeek(f, Int64(0), 2);
    if (size > 32774) and (ReadAt(f, 32769, 5) = 'CD001') then Exit('ISO 9660');
    if (size >= 512) and (ReadAt(f, size - 512, 4) = 'koly') then
      Exit('Apple disk image');
  finally
    FileClose(f);
  end;
end;

function MatchesMagic(const Path, Filter: AnsiString): Boolean;
var
  t: AnsiString;
  i: Integer;
begin
  if Filter = '' then Exit(True);
  t := DetectMagic(Path);
  if t = '' then Exit(False);
  if t = Filter then Exit(True);
  BuildTypes;
  for i := 0 to High(TypeList) do
    if (TypeList[i].Name = t) and (TypeList[i].Group = Filter) then Exit(True);
  Result := False;
end;

end.
