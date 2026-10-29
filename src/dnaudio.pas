{ dnaudio — audio analysis for the player's visualizer and the equalizer
  (PLAYER.md). Pure logic: no ncurses, no terminal, fully unit-testable.

  FFT1024 is an iterative radix-2 Cooley-Tukey transform over 1024 complex
  points. TAnalyzer feeds it mono PCM samples and folds the bins into display
  nb with decay smoothing. TEqualizer holds a 10-band gain curve and renders
  the backend argument lists. }
unit dnaudio;

{$mode objfpc}{$H+}

interface

const
  FftSize  = 1024;      // FFT points
  FftBins  = FftSize div 2 + 1;
  EqBands  = 10;
  VizLevels = 8;        // block heights per band

  { centre frequencies of the 10 equalizer nb, Hz }
  EqFreqs: array[0..EqBands - 1] of Integer =
    (31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000);

  EqMinDb = -12;
  EqMaxDb = 12;

type
  { iterative radix-2 FFT, in-place. Re and Im are overwritten with the
    transform. Real input goes in Re; Im must be zeroed by the caller. }
  TComplex = record
    Re, Im: Double;
  end;

  TAnalyzer = class
  private
    FWin: array[0..FftSize - 1] of Double;    // Hann window
    FPrev: array[0..63] of Double;             // last frame per band
    FSamples: array[0..FftSize - 1] of Double;  // sliding input
    FFill: Integer;
    FBandCount: Integer;
    FFakePhase: Double;
    FFakeSeed: LongWord;
  public
    constructor Create;
    { push mono samples in -32768..32767 }
    procedure Push(const Samples: array of SmallInt);
    procedure PushOne(S: SmallInt);
    { compute band levels 0..100 into Levels (length = BandCount) }
    procedure Bands(var Levels: array of Integer);
    { oscilloscope: fill Points (length = Count) with -1..1 samples }
    procedure Scope(var Points: array of Double; Count: Integer);
    { fill Levels with a smoothed random walk, for the fake mode }
    procedure FakeBands(var Levels: array of Integer);
    procedure Reset;
    property BandCount: Integer read FBandCount write FBandCount;
  end;

  TEqualizer = class
  private
    FGains: array[0..EqBands - 1] of Integer;   // dB
    FPreset: AnsiString;
    FActive: Boolean;
  public
    constructor Create;
    procedure Reset;
    procedure SetBand(Index, Db: Integer);
    function GetBand(Index: Integer): Integer;
    procedure LoadPreset(const Name: AnsiString);
    { load the next named preset after the current one, wrapping around }
    procedure NextPreset;
    { set every band from Gains and label the curve Name (no clamping beyond
      the valid dB range); used to restore the saved curve }
    procedure ApplyCurve(const Name: AnsiString; const Gains: array of Integer);
    function PresetNames: AnsiString;            // comma-separated
    { the ffmpeg -af equalizer chain, e.g.
      'equalizer=f=31:g=3,equalizer=f=62:g=-2,...' }
    function FilterChain: AnsiString;
    { the mpg123 -e argument, e.g. '31,3,62,-2,...' }
    function Mpg123Arg: AnsiString;
    property Active: Boolean read FActive write FActive;
    property Preset: AnsiString read FPreset;
  end;

  { The 8 block characters used for the visualizer bars, index 1..8. }
const
  VizBlocks: array[1..8] of AnsiString =
    ('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█');

{ iterative radix-2 Cooley-Tukey FFT over FftSize complex points, in place }
procedure FFT1024(var Data: array of TComplex);

implementation

uses
  SysUtils, Classes, Math;

procedure FFT1024(var Data: array of TComplex);
var
  n, i, j, m, mmax, istep, lev: Integer;
  tr, ti, wr, wi, ur, ui, vr, vi, ang: Double;
  t: TComplex;
  bits: Integer;
begin
  n := FftSize;
  { bit-reversal permutation }
  j := 0;
  for i := 0 to n - 2 do
  begin
    if i < j then
    begin
      t := Data[i]; Data[i] := Data[j]; Data[j] := t;
    end;
    m := n shr 1;
    while m <= j do
    begin
      j := j - m;
      m := m shr 1;
    end;
    j := j + m;
  end;
  { butterflies }
  mmax := 1;
  while mmax < n do
  begin
    istep := mmax shl 1;
    ang := -Pi / mmax;
    wr := Cos(ang); wi := Sin(ang);
    i := 0;
    while i < n do
    begin
      ur := 1.0; ui := 0.0;
      for lev := 0 to mmax - 1 do
      begin
        j := i + lev;
        vr := Data[j + mmax].Re * ur - Data[j + mmax].Im * ui;
        vi := Data[j + mmax].Re * ui + Data[j + mmax].Im * ur;
        Data[j + mmax].Re := Data[j].Re - vr;
        Data[j + mmax].Im := Data[j].Im - vi;
        Data[j].Re := Data[j].Re + vr;
        Data[j].Im := Data[j].Im + vi;
        tr := ur * wr - ui * wi;
        ui := ur * wi + ui * wr;
        ur := tr;
      end;
      Inc(i, istep);
    end;
    mmax := istep;
  end;
end;

{ --- analyzer --------------------------------------------------------- }

constructor TAnalyzer.Create;
var
  i: Integer;
begin
  FBandCount := 40;
  Reset;
  for i := 0 to FftSize - 1 do
    FWin[i] := 0.5 - 0.5 * Cos(2.0 * Pi * i / (FftSize - 1));
end;

procedure TAnalyzer.Reset;
var
  i: Integer;
begin
  FFill := 0;
  for i := 0 to FftSize - 1 do FSamples[i] := 0;
  for i := 0 to High(FPrev) do FPrev[i] := 0;
  FFakePhase := 0;
end;

procedure TAnalyzer.PushOne(S: SmallInt);
begin
  if FFill >= FftSize then
  begin
    Move(FSamples[1], FSamples[0], (FftSize - 1) * SizeOf(Double));
    Dec(FFill);
  end;
  FSamples[FFill] := S;
  Inc(FFill);
end;

procedure TAnalyzer.Push(const Samples: array of SmallInt);
var
  i: Integer;
begin
  for i := 0 to High(Samples) do
    PushOne(Samples[i]);
end;

{ log-spaced band edges in bin indices (bin = freq * FftSize / SampleRate),
  assuming 8 kHz input; band 0 starts at bin 1 }
function BandBin(Band, BandCount: Integer): Integer;
var
  f0, f1, lo, hi: Double;
begin
  lo := 20.0 * Power(16000.0 / 20.0, Band / BandCount);
  hi := 20.0 * Power(16000.0 / 20.0, (Band + 1) / BandCount);
  f0 := lo * FftSize / 8000.0;
  f1 := hi * FftSize / 8000.0;
  Result := Trunc(f0);
  if Result < 1 then Result := 1;
  if Trunc(f1) > Result then
    Result := Trunc(f1);
  if Result > FftSize div 2 then Result := FftSize div 2;
end;

procedure TAnalyzer.Bands(var Levels: array of Integer);
var
  Data: array[0..FftSize - 1] of TComplex;
  i, b, b0, b1, k, mag, lvl, nb: Integer;
begin
  nb := FBandCount;
  if nb < 1 then nb := 1;
  if nb > Length(Levels) then nb := Length(Levels);
  for i := 0 to FftSize - 1 do
  begin
    Data[i].Re := FSamples[i] * FWin[i];
    Data[i].Im := 0;
  end;
  FFT1024(Data);
  for b := 0 to nb - 1 do
  begin
    b0 := BandBin(b, nb);
    b1 := BandBin(b + 1, nb);
    if b1 <= b0 then b1 := b0 + 1;
    if b1 > FftSize div 2 then b1 := FftSize div 2;
    mag := 0;
    for k := b0 to b1 - 1 do
      Inc(mag, Trunc(Sqrt(Data[k].Re * Data[k].Re + Data[k].Im * Data[k].Im)));
    if b1 > b0 then mag := mag div (b1 - b0);
    { log-ish compression, then scale to 0..100 }
    lvl := Trunc(Ln(1 + mag) * 12);
    if lvl > 100 then lvl := 100;
    if lvl < 0 then lvl := 0;
    { decay: the bar falls to the new level, it never jumps up instantly }
    if b <= High(FPrev) then
    begin
      if lvl < FPrev[b] then
        lvl := Trunc(FPrev[b] * 0.6);
      FPrev[b] := lvl;
    end;
    Levels[b] := lvl;
  end;
end;

procedure TAnalyzer.Scope(var Points: array of Double; Count: Integer);
var
  i, idx: Integer;
begin
  if Count < 1 then Exit;
  for i := 0 to Count - 1 do
  begin
    idx := (i * FftSize) div Count;
    if idx > FftSize - 1 then idx := FftSize - 1;
    if idx < 0 then idx := 0;
    Points[i] := FSamples[idx] / 32768.0;
    if Points[i] > 1.0 then Points[i] := 1.0;
    if Points[i] < -1.0 then Points[i] := -1.0;
  end;
end;

procedure TAnalyzer.FakeBands(var Levels: array of Integer);
var
  i, nb, lvl: Integer;
begin
  nb := FBandCount;
  if nb < 1 then nb := 1;
  if nb > Length(Levels) then nb := Length(Levels);
  FFakePhase := FFakePhase + 0.7;
  for i := 0 to nb - 1 do
  begin
    FFakeSeed := FFakeSeed * 1103515245 + 12345;
    { a smooth pseudo-random walk, heavier in the low nb }
    lvl := 40 + Trunc(35 * Sin(FFakePhase + i * 0.6)) +
           ((FFakeSeed shr 16) and 15);
    lvl := lvl - i;   // tilt towards the bass, like a real spectrum
    if lvl > 100 then lvl := 100;
    if lvl < 0 then lvl := 0;
    if i <= High(FPrev) then
    begin
      if lvl < FPrev[i] then lvl := Trunc(FPrev[i] * 0.6);
      FPrev[i] := lvl;
    end;
    Levels[i] := lvl;
  end;
end;

{ --- equalizer -------------------------------------------------------- }

constructor TEqualizer.Create;
begin
  Reset;
end;

procedure TEqualizer.Reset;
var
  i: Integer;
begin
  for i := 0 to EqBands - 1 do FGains[i] := 0;
  FPreset := 'Flat';
  FActive := False;
end;

procedure TEqualizer.SetBand(Index, Db: Integer);
begin
  if (Index < 0) or (Index >= EqBands) then Exit;
  if Db < EqMinDb then Db := EqMinDb;
  if Db > EqMaxDb then Db := EqMaxDb;
  FGains[Index] := Db;
  FPreset := 'Custom';
  FActive := True;
end;

function TEqualizer.GetBand(Index: Integer): Integer;
begin
  if (Index < 0) or (Index >= EqBands) then Exit(0);
  Result := FGains[Index];
end;

procedure TEqualizer.LoadPreset(const Name: AnsiString);
var
  i: Integer;

  procedure SetAll(const A: array of Integer);
  var
    j: Integer;
  begin
    for j := 0 to EqBands - 1 do
      if j <= High(A) then FGains[j] := A[j] else FGains[j] := 0;
  end;

begin
  if Name = 'Rock' then
    SetAll([5, 4, 2, 0, -1, -1, 1, 3, 4, 4])
  else if Name = 'Pop' then
    SetAll([-1, 2, 4, 4, 2, 0, -1, -1, -1, -1])
  else if Name = 'Jazz' then
    SetAll([3, 2, 1, 2, -1, -1, 0, 1, 2, 3])
  else if Name = 'Classical' then
    SetAll([4, 3, 2, 1, -1, -1, 0, 2, 3, 4])
  else if Name = 'Vocal' then
    SetAll([-2, -1, 0, 2, 4, 4, 3, 1, 0, -1])
  else if Name = 'Bass Boost' then
    SetAll([8, 7, 6, 5, 3, 1, 0, 0, 0, 0])
  else if Name = 'Treble Boost' then
    SetAll([0, 0, 0, 0, 0, 1, 2, 4, 6, 7])
  else
    SetAll([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  if Name = 'Flat' then
    FPreset := 'Flat'
  else
    FPreset := Name;
  FActive := False;
  for i := 0 to EqBands - 1 do
    if FGains[i] <> 0 then FActive := True;
end;

procedure TEqualizer.NextPreset;
var
  L: TStringList;
  i: Integer;
  next: AnsiString;
begin
  L := TStringList.Create;
  try
    L.CommaText := PresetNames;
    next := L[0];
    for i := 0 to L.Count - 1 do
      if L[i] = FPreset then
      begin
        next := L[(i + 1) mod L.Count];
        Break;
      end;
    LoadPreset(next);
  finally
    L.Free;
  end;
end;

procedure TEqualizer.ApplyCurve(const Name: AnsiString;
  const Gains: array of Integer);
var
  i: Integer;
begin
  for i := 0 to EqBands - 1 do
    if i <= High(Gains) then FGains[i] := Gains[i] else FGains[i] := 0;
  if Name = '' then
    FPreset := 'Flat'
  else
    FPreset := Name;
  FActive := False;
  for i := 0 to EqBands - 1 do
    if FGains[i] <> 0 then FActive := True;
end;

function TEqualizer.PresetNames: AnsiString;
begin
  Result := 'Flat,Rock,Pop,Jazz,Classical,Vocal,Bass Boost,Treble Boost';
end;

function TEqualizer.FilterChain: AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to EqBands - 1 do
    if FGains[i] <> 0 then
    begin
      if Result <> '' then Result := Result + ',';
      Result := Result + 'equalizer=f=' + IntToStr(EqFreqs[i]) +
                ':g=' + IntToStr(FGains[i]);
    end;
end;

function TEqualizer.Mpg123Arg: AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to EqBands - 1 do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + IntToStr(FGains[i]);
  end;
end;

end.
