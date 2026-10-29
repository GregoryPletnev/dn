{ dnoptions — user-configurable settings (the Options menu).
  Persisted as key=value lines in <config>/options; loaded at startup,
  saved automatically whenever a dialog changes something. }
unit dnoptions;

{$mode objfpc}{$H+}

interface

const
  palClassic = 0;   // white-on-blue DN palette
  palDark    = 1;   // black background
  palBW      = 2;   // monochrome

  HlGroupCount = 4;

type
  { one file-highlight rule: files matching Mask draw in Color.
    Color is an ncurses COLOR_* number (1..7); Mask = '' disables the rule. }
  THlGroup = record
    Mask: AnsiString;
    Color: Integer;
  end;
  THlGroups = array[1..HlGroupCount] of THlGroup;

  TOptions = record
    ShowHidden: Boolean;        // show dot-files in panels
    SpaceSelect: Boolean;       // Space toggles selection (command line empty)
    ConfirmDelete: Boolean;     // ask before F8
    ConfirmOverwrite: Boolean;  // ask before copy/move over an existing file
    ConfirmExit: Boolean;       // ask before quitting
    ExactSizes: Boolean;        // sizes as 1,234,567 instead of 1234K
    ColSize: Boolean;           // default panel columns (new panels)
    ColDate: Boolean;
    ColTime: Boolean;
    Palette: Integer;           // pal* constant
    Hl: THlGroups;              // per-file-type colors
    SyntaxHl: Boolean;          // syntax highlighting in editor/viewer
    SaverDelay: Integer;        // screen saver idle minutes, 0 = off
    SaverType: Integer;         // dnsaver sv* constant
    PlayerVolume: Integer;      // media player volume 0..100
    PlayerViz: Integer;         // visualizer: 0 off, 1 bars, 2 scope
    PlayerEqPreset: AnsiString;  // last equalizer preset name
    PlayerEqBands: array[0..9] of Integer;  // last equalizer gains, dB
    LocalSendPort: Integer;     // LocalSend receive port, 0 = receive off
    LocalSendName: AnsiString;  // device name peers see
  end;

const
  { ncurses COLOR_* values usable as a highlight foreground }
  HlColorNames: array[1..7] of AnsiString =
    ('Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White');

var
  Opt: TOptions = (
    ShowHidden: True;
    SpaceSelect: True;
    ConfirmDelete: True;
    ConfirmOverwrite: True;
    ConfirmExit: False;
    ExactSizes: False;
    ColSize: True;
    ColDate: True;
    ColTime: False;
    Palette: palClassic;
    Hl: (
      (Mask: '*.sh,*.command,*.py,*.pl,*.rb'; Color: 2),                  // green
      (Mask: '*.zip,*.tar,*.tgz,*.tbz,*.gz,*.bz2,*.xz,*.7z,*.rar'; Color: 3), // yellow
      (Mask: '*.dmg,*.iso,*.img,*.sparseimage'; Color: 5),                // magenta
      (Mask: ''; Color: 7)                                                // custom, off
    );
    SyntaxHl: True;
    SaverDelay: 5;
    SaverType: 0;
    PlayerVolume: 80;
    PlayerViz: 0;
    PlayerEqPreset: 'Flat';
    PlayerEqBands: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    LocalSendPort: 0;
    LocalSendName: 'DN'
  );

procedure OptLoad;
procedure OptSave;

implementation

uses
  SysUtils, Classes, dnconfig;

function OptFile: AnsiString;
begin
  Result := ConfigDir + '/options';
end;

function AsBool(const v: AnsiString; Def: Boolean): Boolean;
begin
  if v = '1' then Result := True
  else if v = '0' then Result := False
  else Result := Def;
end;

function BoolStr(b: Boolean): AnsiString;
begin
  if b then Result := '1' else Result := '0';
end;

procedure OptLoad;
var
  L: TStringList;
  p, i: Integer;
  k: AnsiString;
begin
  if not FileExists(OptFile) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(OptFile);
    except
      Exit;
    end;
    Opt.ShowHidden := AsBool(L.Values['show_hidden'], Opt.ShowHidden);
    Opt.SpaceSelect := AsBool(L.Values['space_select'], Opt.SpaceSelect);
    Opt.ConfirmDelete := AsBool(L.Values['confirm_delete'], Opt.ConfirmDelete);
    Opt.ConfirmOverwrite := AsBool(L.Values['confirm_overwrite'], Opt.ConfirmOverwrite);
    Opt.ConfirmExit := AsBool(L.Values['confirm_exit'], Opt.ConfirmExit);
    Opt.ExactSizes := AsBool(L.Values['exact_sizes'], Opt.ExactSizes);
    Opt.ColSize := AsBool(L.Values['col_size'], Opt.ColSize);
    Opt.ColDate := AsBool(L.Values['col_date'], Opt.ColDate);
    Opt.ColTime := AsBool(L.Values['col_time'], Opt.ColTime);
    p := StrToIntDef(L.Values['palette'], Opt.Palette);
    if (p >= palClassic) and (p <= palBW) then Opt.Palette := p;
    Opt.SyntaxHl := AsBool(L.Values['syntax_hl'], Opt.SyntaxHl);
    p := StrToIntDef(L.Values['saver_delay'], Opt.SaverDelay);
    if (p >= 0) and (p <= 999) then Opt.SaverDelay := p;
    p := StrToIntDef(L.Values['saver_type'], Opt.SaverType);
    if (p >= 0) and (p <= 2) then Opt.SaverType := p;
    p := StrToIntDef(L.Values['player_volume'], Opt.PlayerVolume);
    if (p >= 0) and (p <= 100) then Opt.PlayerVolume := p;
    p := StrToIntDef(L.Values['player_viz'], Opt.PlayerViz);
    if (p >= 0) and (p <= 2) then Opt.PlayerViz := p;
    if L.Values['player_eq_preset'] <> '' then
      Opt.PlayerEqPreset := L.Values['player_eq_preset'];
    for i := 0 to 9 do
    begin
      p := StrToIntDef(L.Values['player_eq_band' + IntToStr(i)],
                       Opt.PlayerEqBands[i]);
      if (p >= -12) and (p <= 12) then Opt.PlayerEqBands[i] := p;
    end;
    p := StrToIntDef(L.Values['localsend_port'], Opt.LocalSendPort);
    if (p >= 0) and (p <= 65535) then Opt.LocalSendPort := p;
    if L.Values['localsend_name'] <> '' then
      Opt.LocalSendName := L.Values['localsend_name'];
    for i := 1 to HlGroupCount do
    begin
      k := 'hl' + IntToStr(i);
      if L.IndexOfName(k + '_mask') >= 0 then
        Opt.Hl[i].Mask := L.Values[k + '_mask'];
      p := StrToIntDef(L.Values[k + '_color'], Opt.Hl[i].Color);
      if (p >= 1) and (p <= 7) then Opt.Hl[i].Color := p;
    end;
  finally
    L.Free;
  end;
end;

procedure OptSave;
var
  L: TStringList;
  i: Integer;
  k: AnsiString;
begin
  L := TStringList.Create;
  try
    L.Add('show_hidden=' + BoolStr(Opt.ShowHidden));
    L.Add('space_select=' + BoolStr(Opt.SpaceSelect));
    L.Add('confirm_delete=' + BoolStr(Opt.ConfirmDelete));
    L.Add('confirm_overwrite=' + BoolStr(Opt.ConfirmOverwrite));
    L.Add('confirm_exit=' + BoolStr(Opt.ConfirmExit));
    L.Add('exact_sizes=' + BoolStr(Opt.ExactSizes));
    L.Add('col_size=' + BoolStr(Opt.ColSize));
    L.Add('col_date=' + BoolStr(Opt.ColDate));
    L.Add('col_time=' + BoolStr(Opt.ColTime));
    L.Add('palette=' + IntToStr(Opt.Palette));
    L.Add('syntax_hl=' + BoolStr(Opt.SyntaxHl));
    L.Add('saver_delay=' + IntToStr(Opt.SaverDelay));
    L.Add('saver_type=' + IntToStr(Opt.SaverType));
    L.Add('player_volume=' + IntToStr(Opt.PlayerVolume));
    L.Add('player_viz=' + IntToStr(Opt.PlayerViz));
    L.Add('player_eq_preset=' + Opt.PlayerEqPreset);
    for i := 0 to 9 do
      L.Add('player_eq_band' + IntToStr(i) + '=' +
            IntToStr(Opt.PlayerEqBands[i]));
    L.Add('localsend_port=' + IntToStr(Opt.LocalSendPort));
    L.Add('localsend_name=' + Opt.LocalSendName);
    for i := 1 to HlGroupCount do
    begin
      k := 'hl' + IntToStr(i);
      L.Add(k + '_mask=' + Opt.Hl[i].Mask);
      L.Add(k + '_color=' + IntToStr(Opt.Hl[i].Color));
    end;
    try
      L.SaveToFile(OptFile);
    except
      { non-fatal }
    end;
  finally
    L.Free;
  end;
end;

end.
