{ dncrypto — the primitives the password vault (dnvault) is built from.

  FPC 3.2.2 ships no AES, HMAC or KDF, so this unit implements the small
  standard set, each checked against its RFC test vectors in the unit
  tests:
    HMAC-SHA256          RFC 2104 / RFC 4231
    PBKDF2-HMAC-SHA256   RFC 8018 (vectors: RFC 7914 section 11)
    ChaCha20             RFC 8439
  and seals data with them as encrypt-then-MAC:
    blob = 'v1' | nonce(12) | ChaCha20(encKey, nonce, ctr=1, plain) |
           HMAC-SHA256(macKey, 'v1' | nonce | ciphertext)
  The 64-byte key (encKey | macKey) comes from PBKDF2 of the master
  password. All strings here are byte strings. }
unit dncrypto;

{$mode objfpc}{$H+}

interface

function HmacSha256(const Key, Msg: AnsiString): AnsiString;
function Pbkdf2Sha256(const Password, Salt: AnsiString; Iterations: Integer;
                      DkLen: Integer): AnsiString;
{ XOR Data with the ChaCha20 stream (encrypts and decrypts alike) }
function ChaCha20(const Key32, Nonce12: AnsiString; Counter: LongWord;
                  const Data: AnsiString): AnsiString;
{ N bytes from /dev/urandom }
function RandomBytes(N: Integer): AnsiString;
{ equal without an early exit (no timing hint on the MAC) }
function SameBytes(const A, B: AnsiString): Boolean;

{ Key64 = encKey(32) | macKey(32) }
function Seal(const Key64, Plain: AnsiString): AnsiString;
{ False when Blob was not sealed with Key64 or was altered }
function Unseal(const Key64, Blob: AnsiString; out Plain: AnsiString): Boolean;

function ToHex(const Bytes: AnsiString): AnsiString;
function FromHex(const Hex: AnsiString): AnsiString;

implementation

uses
  SysUtils, dnsha256;

const
  SealTag = 'v1';

function HmacSha256(const Key, Msg: AnsiString): AnsiString;
var
  k, ipad, opad: AnsiString;
  i: Integer;
begin
  k := Key;
  if Length(k) > 64 then k := Sha256Raw(k);
  SetLength(ipad, 64);
  SetLength(opad, 64);
  for i := 1 to 64 do
  begin
    if i <= Length(k) then
    begin
      ipad[i] := Chr(Ord(k[i]) xor $36);
      opad[i] := Chr(Ord(k[i]) xor $5C);
    end
    else
    begin
      ipad[i] := #$36;
      opad[i] := #$5C;
    end;
  end;
  Result := Sha256Raw(opad + Sha256Raw(ipad + Msg));
end;

function Pbkdf2Sha256(const Password, Salt: AnsiString; Iterations: Integer;
                      DkLen: Integer): AnsiString;
var
  u, t: AnsiString;
  i, j, k: Integer;
begin
  Result := '';
  i := 0;
  while Length(Result) < DkLen do
  begin
    Inc(i);
    u := HmacSha256(Password, Salt + Chr(i shr 24) + Chr((i shr 16) and $FF) +
                              Chr((i shr 8) and $FF) + Chr(i and $FF));
    t := u;
    for j := 2 to Iterations do
    begin
      u := HmacSha256(Password, u);
      for k := 1 to 32 do
        t[k] := Chr(Ord(t[k]) xor Ord(u[k]));
    end;
    Result := Result + t;
  end;
  SetLength(Result, DkLen);
end;

{ --- ChaCha20 (RFC 8439) --- }

function Rotl(x: LongWord; n: Integer): LongWord; inline;
begin
  Result := (x shl n) or (x shr (32 - n));
end;

function Le32(const s: AnsiString; p: Integer): LongWord; inline;
begin
  Result := LongWord(Ord(s[p])) or (LongWord(Ord(s[p + 1])) shl 8) or
            (LongWord(Ord(s[p + 2])) shl 16) or (LongWord(Ord(s[p + 3])) shl 24);
end;

procedure QR(var a, b, c, d: LongWord); inline;
begin
  {$push}{$Q-}{$R-}
  a := a + b; d := Rotl(d xor a, 16);
  c := c + d; b := Rotl(b xor c, 12);
  a := a + b; d := Rotl(d xor a, 8);
  c := c + d; b := Rotl(b xor c, 7);
  {$pop}
end;

function ChaCha20(const Key32, Nonce12: AnsiString; Counter: LongWord;
                  const Data: AnsiString): AnsiString;
var
  st, x: array[0..15] of LongWord;
  ks: array[0..63] of Byte;
  i, r, pos, n: Integer;
begin
  Result := Data;
  if (Length(Key32) <> 32) or (Length(Nonce12) <> 12) then
    raise Exception.Create('ChaCha20: bad key or nonce length');
  st[0] := $61707865; st[1] := $3320646e; st[2] := $79622d32; st[3] := $6b206574;
  for i := 0 to 7 do st[4 + i] := Le32(Key32, i * 4 + 1);
  st[12] := Counter;
  for i := 0 to 2 do st[13 + i] := Le32(Nonce12, i * 4 + 1);
  pos := 1;
  while pos <= Length(Data) do
  begin
    x := st;
    for r := 1 to 10 do
    begin
      QR(x[0], x[4], x[8], x[12]); QR(x[1], x[5], x[9], x[13]);
      QR(x[2], x[6], x[10], x[14]); QR(x[3], x[7], x[11], x[15]);
      QR(x[0], x[5], x[10], x[15]); QR(x[1], x[6], x[11], x[12]);
      QR(x[2], x[7], x[8], x[13]); QR(x[3], x[4], x[9], x[14]);
    end;
    {$push}{$Q-}{$R-}
    for i := 0 to 15 do
    begin
      x[i] := x[i] + st[i];
      ks[i * 4] := x[i] and $FF;
      ks[i * 4 + 1] := (x[i] shr 8) and $FF;
      ks[i * 4 + 2] := (x[i] shr 16) and $FF;
      ks[i * 4 + 3] := x[i] shr 24;
    end;
    st[12] := st[12] + 1;
    {$pop}
    n := Length(Data) - pos + 1;
    if n > 64 then n := 64;
    for i := 0 to n - 1 do
      Result[pos + i] := Chr(Ord(Data[pos + i]) xor ks[i]);
    Inc(pos, 64);
  end;
end;

function RandomBytes(N: Integer): AnsiString;
var
  f: THandle;
begin
  SetLength(Result, N);
  if N = 0 then Exit;
  f := FileOpen('/dev/urandom', fmOpenRead);
  if f = THandle(-1) then
    raise Exception.Create('cannot open /dev/urandom');
  try
    if FileRead(f, Result[1], N) <> N then
      raise Exception.Create('short read from /dev/urandom');
  finally
    FileClose(f);
  end;
end;

function SameBytes(const A, B: AnsiString): Boolean;
var
  i: Integer;
  d: Byte;
begin
  if Length(A) <> Length(B) then Exit(False);
  d := 0;
  for i := 1 to Length(A) do
    d := d or (Ord(A[i]) xor Ord(B[i]));
  Result := d = 0;
end;

function Seal(const Key64, Plain: AnsiString): AnsiString;
var
  nonce, ct: AnsiString;
begin
  nonce := RandomBytes(12);
  ct := ChaCha20(Copy(Key64, 1, 32), nonce, 1, Plain);
  Result := SealTag + nonce + ct;
  Result := Result + HmacSha256(Copy(Key64, 33, 32), Result);
end;

function Unseal(const Key64, Blob: AnsiString; out Plain: AnsiString): Boolean;
var
  body, tag: AnsiString;
begin
  Plain := '';
  Result := False;
  if (Length(Blob) < Length(SealTag) + 12 + 32) or
     (Copy(Blob, 1, Length(SealTag)) <> SealTag) then Exit;
  body := Copy(Blob, 1, Length(Blob) - 32);
  tag := Copy(Blob, Length(Blob) - 31, 32);
  if not SameBytes(tag, HmacSha256(Copy(Key64, 33, 32), body)) then Exit;
  Plain := ChaCha20(Copy(Key64, 1, 32), Copy(body, Length(SealTag) + 1, 12), 1,
                    Copy(body, Length(SealTag) + 13, Length(body)));
  Result := True;
end;

function ToHex(const Bytes: AnsiString): AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(Bytes) do
    Result := Result + LowerCase(IntToHex(Ord(Bytes[i]), 2));
end;

function FromHex(const Hex: AnsiString): AnsiString;
var
  i: Integer;
begin
  SetLength(Result, Length(Hex) div 2);
  for i := 1 to Length(Result) do
    Result[i] := Chr(StrToInt('$' + Copy(Hex, i * 2 - 1, 2)));
end;

end.
