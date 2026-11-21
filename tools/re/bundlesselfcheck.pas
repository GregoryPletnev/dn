{ bundlesselfcheck — standalone verifier for src/dnbundlessav.pas against the
  Python ground-truth emulator tools/re/bundles_oracle.py. Not part of the
  app build. Build and run:
    fpc -MObjFPC -Sh -Fusrc -FUbuild -FEbin tools/re/bundlesselfcheck.pas
    bin/bundlesselfcheck
  Compare the FNV grid/display checksums against:
    python3 tools/re/bundles_oracle.py <seed> --vectors }
program bundlesselfcheck;

{$mode objfpc}{$H+}

uses
  SysUtils, dnbundlessav;

function FnvGrid(const S: TBundlesSim): Cardinal;
var
  px, py, v: Integer;
begin
  Result := $811C9DC5;
  for py := 0 to BnGridH - 1 do
    for px := 0 to BnGridW - 1 do
    begin
      v := BundlesPixel(S, px, py);
      Result := Result xor Cardinal(v);
      Result := Result * $01000193;
    end;
end;

function FnvDisp(const S: TBundlesSim): Cardinal;
var
  px, py, v: Integer;
begin
  Result := $811C9DC5;
  for py := 0 to BnDispH - 1 do
    for px := 0 to BnDispW - 1 do
    begin
      v := BundlesDisplayValue(S, px, py);
      Result := Result xor Cardinal(v);
      Result := Result * $01000193;
    end;
end;

function FirstGrid(const S: TBundlesSim): string;
var
  px, py, v: Integer;
begin
  for py := 0 to BnGridH - 1 do
    for px := 0 to BnGridW - 1 do
    begin
      v := BundlesPixel(S, px, py);
      if v <> 0 then
        Exit(Format('(%d, %d, %d)', [py, px, v]));
    end;
  Result := 'None';
end;

var
  S: TBundlesSim;
  seed, k: Integer;
begin
  for seed := 0 to 3 do
  begin
    BundlesInit(S, 0, 0, Word(seed));
    WriteLn(Format('seed %d frame 0 fnv %08x d_fnv %08x first %s',
      [seed, FnvGrid(S), FnvDisp(S), FirstGrid(S)]));
    for k := 1 to 10 do
    begin
      BundlesStep(S);
      WriteLn(Format('seed %d frame %d fnv %08x d_fnv %08x first %s color [%d, %d]',
        [seed, k, FnvGrid(S), FnvDisp(S), FirstGrid(S),
         S.ColorArr[0], S.ColorArr[1]]));
    end;
  end;
end.
