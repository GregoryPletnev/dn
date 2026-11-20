{ dnsha256 — SHA-256 (FIPS 180-4) for LocalSend certificate pinning.
  FPC 3.2.2 ships MD5 and SHA-1 only. LocalSend identifies an HTTPS device
  by the SHA-256 of its self-signed certificate (the `fingerprint` it
  announces), so the sender checks the certificate it is shown against
  that value. Pure code, unit-tested against the FIPS test vectors. }
unit dnsha256;

{$mode objfpc}{$H+}

interface

{ digest of Data as 64 uppercase hex digits }
function Sha256Hex(const Data: AnsiString): AnsiString;

{ digest of Data as 32 raw bytes (HMAC and PBKDF2 build on it) }
function Sha256Raw(const Data: AnsiString): AnsiString;

{ the DER bytes of the first certificate in a PEM text (curl's %{certs}
  output, or a .pem file); '' when there is none }
function PemFirstCertDer(const Pem: AnsiString): AnsiString;

implementation

uses
  SysUtils, base64;

const
  K: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1,
    $923f82a4, $ab1c5ed5, $d807aa98, $12835b01, $243185be, $550c7dc3,
    $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174, $e49b69c1, $efbe4786,
    $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147,
    $06ca6351, $14292967, $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13,
    $650a7354, $766a0abb, $81c2c92e, $92722c85, $a2bfe8a1, $a81a664b,
    $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a,
    $5b9cca4f, $682e6ff3, $748f82ee, $78a5636f, $84c87814, $8cc70208,
    $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function Ror(x: LongWord; n: Integer): LongWord; inline;
begin
  Result := (x shr n) or (x shl (32 - n));
end;

function Sha256Raw(const Data: AnsiString): AnsiString;
var
  h: array[0..7] of LongWord;
  w: array[0..63] of LongWord;
  msg: AnsiString;
  bits: QWord;
  i, j, blk: Integer;
  a, b, c, d, e, f, g, hh, s0, s1, t1, t2: LongWord;
begin
  {$push}{$Q-}{$R-}
  h[0] := $6a09e667; h[1] := $bb67ae85; h[2] := $3c6ef372; h[3] := $a54ff53a;
  h[4] := $510e527f; h[5] := $9b05688c; h[6] := $1f83d9ab; h[7] := $5be0cd19;

  { padding: 0x80, zeros to 56 mod 64, then the bit length big-endian }
  bits := QWord(Length(Data)) * 8;
  { pad in one allocation: PBKDF2 hashes short messages many times }
  j := Length(Data) + 1;
  while j mod 64 <> 56 do Inc(j);
  SetLength(msg, j + 8);
  if Length(Data) > 0 then
    Move(Data[1], msg[1], Length(Data));
  msg[Length(Data) + 1] := #$80;
  for i := Length(Data) + 2 to j do
    msg[i] := #0;
  for i := 0 to 7 do
    msg[j + 1 + i] := Chr((bits shr ((7 - i) * 8)) and $FF);

  blk := 0;
  while blk < Length(msg) do
  begin
    for i := 0 to 15 do
    begin
      j := blk + i * 4 + 1;
      w[i] := (LongWord(Ord(msg[j])) shl 24) or (LongWord(Ord(msg[j + 1])) shl 16) or
              (LongWord(Ord(msg[j + 2])) shl 8) or LongWord(Ord(msg[j + 3]));
    end;
    for i := 16 to 63 do
    begin
      s0 := Ror(w[i - 15], 7) xor Ror(w[i - 15], 18) xor (w[i - 15] shr 3);
      s1 := Ror(w[i - 2], 17) xor Ror(w[i - 2], 19) xor (w[i - 2] shr 10);
      w[i] := w[i - 16] + s0 + w[i - 7] + s1;
    end;
    a := h[0]; b := h[1]; c := h[2]; d := h[3];
    e := h[4]; f := h[5]; g := h[6]; hh := h[7];
    for i := 0 to 63 do
    begin
      s1 := Ror(e, 6) xor Ror(e, 11) xor Ror(e, 25);
      t1 := hh + s1 + ((e and f) xor ((not e) and g)) + K[i] + w[i];
      s0 := Ror(a, 2) xor Ror(a, 13) xor Ror(a, 22);
      t2 := s0 + ((a and b) xor (a and c) xor (b and c));
      hh := g; g := f; f := e; e := d + t1;
      d := c; c := b; b := a; a := t1 + t2;
    end;
    h[0] := h[0] + a; h[1] := h[1] + b; h[2] := h[2] + c; h[3] := h[3] + d;
    h[4] := h[4] + e; h[5] := h[5] + f; h[6] := h[6] + g; h[7] := h[7] + hh;
    Inc(blk, 64);
  end;
  {$pop}
  SetLength(Result, 32);
  for i := 0 to 7 do
  begin
    Result[i * 4 + 1] := Chr(h[i] shr 24);
    Result[i * 4 + 2] := Chr((h[i] shr 16) and $FF);
    Result[i * 4 + 3] := Chr((h[i] shr 8) and $FF);
    Result[i * 4 + 4] := Chr(h[i] and $FF);
  end;
end;

function Sha256Hex(const Data: AnsiString): AnsiString;
var
  raw: AnsiString;
  i: Integer;
begin
  raw := Sha256Raw(Data);
  Result := '';
  for i := 1 to 32 do
    Result := Result + IntToHex(Ord(raw[i]), 2);
end;

function PemFirstCertDer(const Pem: AnsiString): AnsiString;
const
  BeginTag = '-----BEGIN CERTIFICATE-----';
  EndTag = '-----END CERTIFICATE-----';
var
  p, q, i: Integer;
  b64: AnsiString;
begin
  Result := '';
  p := Pos(BeginTag, Pem);
  if p = 0 then Exit;
  Inc(p, Length(BeginTag));
  q := Pos(EndTag, Copy(Pem, p, Length(Pem)));
  if q = 0 then Exit;
  b64 := '';
  for i := p to p + q - 2 do
    if Pem[i] in ['A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='] then
      b64 := b64 + Pem[i];
  Result := DecodeStringBase64(b64);
end;

end.
