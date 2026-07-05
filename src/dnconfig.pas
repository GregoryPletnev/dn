{ dnconfig — configuration directory, command history, dn.ext map.
  DN_CONFIG_DIR overrides the location (tests use it); default is
  $XDG_CONFIG_HOME/dnfpc or ~/.config/dnfpc. }
unit dnconfig;

{$mode objfpc}{$H+}

interface

uses
  Classes;

function ConfigDir: AnsiString;
procedure HistoryLoad(L: TStringList);
procedure HistorySave(L: TStringList);
{ command for a file extension from dn.ext ('' if none).
  Values: '@edit', '@view' or a shell command with %f placeholder. }
function ExtCommand(const Ext: AnsiString): AnsiString;

implementation

uses
  SysUtils;

const
  HistoryMax = 100;

var
  CachedDir: AnsiString = '';
  ExtMap: TStringList = nil;

function ConfigDir: AnsiString;
var
  base: AnsiString;
begin
  if CachedDir <> '' then Exit(CachedDir);
  Result := GetEnvironmentVariable('DN_CONFIG_DIR');
  if Result = '' then
  begin
    base := GetEnvironmentVariable('XDG_CONFIG_HOME');
    if base = '' then
      base := GetEnvironmentVariable('HOME') + '/.config';
    Result := base + '/dnfpc';
  end;
  ForceDirectories(Result);
  CachedDir := Result;
end;

procedure HistoryLoad(L: TStringList);
begin
  if FileExists(ConfigDir + '/history') then
  try
    L.LoadFromFile(ConfigDir + '/history');
  except
    L.Clear;
  end;
end;

procedure HistorySave(L: TStringList);
begin
  while L.Count > HistoryMax do
    L.Delete(0);
  try
    L.SaveToFile(ConfigDir + '/history');
  except
    { non-fatal }
  end;
end;

function ExtCommand(const Ext: AnsiString): AnsiString;
begin
  if ExtMap = nil then
  begin
    ExtMap := TStringList.Create;
    if FileExists(ConfigDir + '/dn.ext') then
    try
      ExtMap.LoadFromFile(ConfigDir + '/dn.ext');
    except
      ExtMap.Clear;
    end;
  end;
  Result := ExtMap.Values[LowerCase(Ext)];
end;

finalization
  ExtMap.Free;
end.
