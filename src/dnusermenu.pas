{ dnusermenu — the F2 user menu (DN's dn.mnu, simplified MC-style format).

  File format (dn.mnu):
    # or ; at column 1 — comment
    Title line              — starts at column 1
        shell command(s)    — indented lines below the title
  A local ./dn.mnu in the panel directory overrides the global
  <config>/dn.mnu (DN's "Local/Global menu definition").

  Placeholders in commands: %f file name, %p full path, %d panel dir,
  %D other panel dir, %s selected files (each quoted), %% literal %. }
unit dnusermenu;

{$mode objfpc}{$H+}

interface

type
  TUserMenuItem = record
    Title: AnsiString;
    Command: AnsiString;   // lines joined with #10
  end;
  TUserMenu = array of TUserMenuItem;

function GlobalMenuFile: AnsiString;
{ local dn.mnu in Dir if it exists there, else the global file }
function UserMenuFile(const Dir: AnsiString): AnsiString;
function LoadUserMenu(const Path: AnsiString; out Menu: TUserMenu): Boolean;
{ write a commented template to the global file if it does not exist }
procedure EnsureGlobalMenu;
function ExpandUserCmd(const Cmd, CurName, CurPath, PanelDir, OtherDir,
                       SelList: AnsiString): AnsiString;

implementation

uses
  SysUtils, Classes, dnconfig;

function GlobalMenuFile: AnsiString;
begin
  Result := ConfigDir + '/dn.mnu';
end;

function UserMenuFile(const Dir: AnsiString): AnsiString;
begin
  Result := IncludeTrailingPathDelimiter(Dir) + 'dn.mnu';
  if not FileExists(Result) then
    Result := GlobalMenuFile;
end;

function LoadUserMenu(const Path: AnsiString; out Menu: TUserMenu): Boolean;
var
  L: TStringList;
  i, n: Integer;
  s: AnsiString;
begin
  SetLength(Menu, 0);
  if not FileExists(Path) then Exit(False);
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(Path);
    except
      Exit(False);
    end;
    n := 0;
    for i := 0 to L.Count - 1 do
    begin
      s := TrimRight(L[i]);
      if s = '' then Continue;
      if (s[1] = '#') or (s[1] = ';') then Continue;
      if (s[1] = ' ') or (s[1] = #9) then
      begin
        { command line for the last title }
        if n = 0 then Continue;
        if Menu[n - 1].Command <> '' then
          Menu[n - 1].Command := Menu[n - 1].Command + #10;
        Menu[n - 1].Command := Menu[n - 1].Command + Trim(s);
      end
      else
      begin
        SetLength(Menu, n + 1);
        Menu[n].Title := s;
        Menu[n].Command := '';
        Inc(n);
      end;
    end;
    { drop titles that never got a command }
    i := 0;
    while i < n do
      if Menu[i].Command = '' then
      begin
        Move(Menu[i + 1], Menu[i], (n - i - 1) * SizeOf(Menu[0]));
        FillChar(Menu[n - 1], SizeOf(Menu[0]), 0);
        Dec(n);
        SetLength(Menu, n);
      end
      else
        Inc(i);
    Result := True;
  finally
    L.Free;
  end;
end;

procedure EnsureGlobalMenu;
var
  L: TStringList;
begin
  if FileExists(GlobalMenuFile) then Exit;
  L := TStringList.Create;
  try
    L.Add('# DN - DataNavigator user menu (F2)');
    L.Add('#');
    L.Add('# Lines at column 1 are menu titles; the indented lines below a');
    L.Add('# title are the shell commands it runs.');
    L.Add('# Placeholders: %f file name, %p full path, %d panel dir,');
    L.Add('#               %D other panel dir, %s selected files, %% percent.');
    L.Add('');
    L.Add('Show file type');
    L.Add(#9'file %p');
    L.Add('');
    L.Add('Disk usage of selection');
    L.Add(#9'du -sh %s');
    L.Add('');
    L.Add('Pack selection to selection.tar.gz');
    L.Add(#9'tar czvf selection.tar.gz %s');
    try
      L.SaveToFile(GlobalMenuFile);
    except
      { non-fatal }
    end;
  finally
    L.Free;
  end;
end;

function ExpandUserCmd(const Cmd, CurName, CurPath, PanelDir, OtherDir,
                       SelList: AnsiString): AnsiString;
var
  i: Integer;

  function Q(const s: AnsiString): AnsiString;
  begin
    Result := AnsiQuotedStr(s, '''');
  end;

begin
  Result := '';
  i := 1;
  while i <= Length(Cmd) do
  begin
    if (Cmd[i] = '%') and (i < Length(Cmd)) then
    begin
      case Cmd[i + 1] of
        'f': Result := Result + Q(CurName);
        'p': Result := Result + Q(CurPath);
        'd': Result := Result + Q(PanelDir);
        'D': Result := Result + Q(OtherDir);
        's': Result := Result + SelList;   // pre-quoted list
        '%': Result := Result + '%';
      else
        Result := Result + Cmd[i] + Cmd[i + 1];
      end;
      Inc(i, 2);
    end
    else
    begin
      Result := Result + Cmd[i];
      Inc(i);
    end;
  end;
end;

end.
