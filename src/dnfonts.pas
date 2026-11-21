{ dnfonts — Options > Fonts/Colors: a fixed catalog of monospace fonts DN
  can put into the terminal it runs in. Two fonts ship in assets/fonts;
  the rest are downloaded on first use from their official releases and
  checked against a pinned SHA-256. Every font in the catalog allows
  redistribution (licenses checked 2026-11-20, see assets/fonts/README.md).

  A terminal draws the glyphs, not DN, so a font is applied by asking the
  terminal: setfont on the Linux console, OSC 50/710 on xterm/urxvt, an
  iTerm2 dynamic profile, AppleScript for Terminal.app. Other terminals get
  the font installed into the user font folder plus a hint where to pick
  it. RestoreFont undoes the change when DN exits. }
unit dnfonts;

{$mode objfpc}{$H+}

interface

uses
  dntermid;

type
  TFontKind = (fkOutline, fkConsole);

  TFontEntry = record
    Id: AnsiString;         // saved in options as font=<Id>
    Name: AnsiString;       // shown in the list
    Family: AnsiString;     // family name the terminal knows
    PsName: AnsiString;     // PostScript name (iTerm2 profiles)
    License: AnsiString;
    Author: AnsiString;
    Kind: TFontKind;
    Bundled: AnsiString;    // file in assets/fonts, '' = downloaded
    Url: AnsiString;        // release archive (zip)
    Sha256: AnsiString;     // of the archive
    Members: AnsiString;    // ';'-separated paths inside the zip
  end;

const
  FontCatalog: array[0..5] of TFontEntry = (
    (Id: 'vga'; Name: 'IBM VGA 9x16 (DOS)'; Family: 'PxPlus IBM VGA 9x16';
     PsName: 'PxPlus_IBM_VGA_9x16'; License: 'CC BY-SA 4.0';
     Author: 'VileR, int10h.org'; Kind: fkOutline;
     Bundled: 'PxPlus_IBM_VGA_9x16.ttf'; Url: ''; Sha256: ''; Members: ''),
    (Id: 'jetbrains'; Name: 'JetBrains Mono'; Family: 'JetBrains Mono';
     PsName: 'JetBrainsMono-Regular'; License: 'SIL OFL 1.1';
     Author: 'JetBrains'; Kind: fkOutline; Bundled: '';
     Url: 'https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip';
     Sha256: '6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf';
     Members: 'fonts/ttf/JetBrainsMono-Regular.ttf;fonts/ttf/JetBrainsMono-Bold.ttf;OFL.txt'),
    (Id: 'fira'; Name: 'Fira Code'; Family: 'Fira Code';
     PsName: 'FiraCode-Regular'; License: 'SIL OFL 1.1';
     Author: 'The Fira Code Project Authors'; Kind: fkOutline; Bundled: '';
     Url: 'https://github.com/tonsky/FiraCode/releases/download/6.2/Fira_Code_v6.2.zip';
     Sha256: '0949915ba8eb24d89fd93d10a7ff623f42830d7c5ffc3ecbf960e4ecad3e3e79';
     Members: 'ttf/FiraCode-Regular.ttf;ttf/FiraCode-Bold.ttf'),
    (Id: 'hack'; Name: 'Hack'; Family: 'Hack'; PsName: 'Hack-Regular';
     License: 'MIT + Bitstream Vera'; Author: 'Source Foundry';
     Kind: fkOutline; Bundled: '';
     Url: 'https://github.com/source-foundry/Hack/releases/download/v3.003/Hack-v3.003-ttf.zip';
     Sha256: '0c2604631b1f055041c68a0e09ae4801acab6c5072ba2db6a822f53c3f8290ac';
     Members: 'ttf/Hack-Regular.ttf;ttf/Hack-Bold.ttf'),
    (Id: 'sourcecode'; Name: 'Source Code Pro'; Family: 'Source Code Pro';
     PsName: 'SourceCodePro-Regular'; License: 'SIL OFL 1.1';
     Author: 'Adobe'; Kind: fkOutline; Bundled: '';
     Url: 'https://github.com/adobe-fonts/source-code-pro/releases/download/2.042R-u/1.062R-i/1.026R-vf/TTF-source-code-pro-2.042R-u_1.062R-i.zip';
     Sha256: '0c85bac90d15c040b82939aa92bc8404420fccc02e37bbcb9c93a7f21abb52c6';
     Members: 'TTF/SourceCodePro-Regular.ttf;TTF/SourceCodePro-Bold.ttf'),
    (Id: 'spleen'; Name: 'Spleen 8x16 (Linux console)'; Family: 'Spleen';
     PsName: ''; License: 'BSD 2-Clause'; Author: 'Frederic Cambus';
     Kind: fkConsole; Bundled: 'spleen-8x16.psfu'; Url: ''; Sha256: '';
     Members: '')
  );

  FontSizeDef = 14;

function FontIndex(const Id: AnsiString): Integer;
{ assets/fonts next to the binary (repo, .app bundle, /usr/share/dn) }
function FontAssetsDir: AnsiString;
{ where downloaded fonts are kept: <config>/fonts/<id> }
function FontCacheDir(const E: TFontEntry): AnsiString;
{ the font files on disk, '' entries skipped; empty when not downloaded }
function FontFiles(const E: TFontEntry): AnsiString;
function FontReady(const E: TFontEntry): Boolean;
{ True when Kind can be used in this terminal at all }
function FontFits(const E: TFontEntry; Term: TTermKind): Boolean;
const
  FontCancelled = 'cancelled';   // FontDownload's Err after Esc

{ download + verify + unpack; Err says why not }
function FontDownload(const E: TFontEntry; out Err: AnsiString): Boolean;
{ DataSha: the SHA-256 check used by FontDownload (exposed for tests) }
function ShaMatches(const Data, Hex: AnsiString): Boolean;
{ put the font into the terminal; Msg is a note for the user }
function FontApply(const E: TFontEntry; Size: Integer;
                   const T: TTermInfo; out Msg: AnsiString): Boolean;
{ undo FontApply (on exit) }
procedure FontRestore;
{ an escape sequence wrapped for tmux passthrough }
function TmuxWrap(const Seq: AnsiString): AnsiString;

implementation

uses
  SysUtils, Classes, BaseUnix, dnconfig, dnpath, dnsha256, dnvfs;

type
  TRestore = (rsNone, rsSetfont, rsXterm, rsITerm2, rsAppleTerminal);

var
  Restore: TRestore = rsNone;
  RestoreArg: AnsiString = '';     // saved font / profile
  RestoreMux: Boolean = False;

{ POSIX single-quote escaping for /bin/sh: wrap in single quotes and close,
  insert a backslash-escaped quote, then reopen. AnsiQuotedStr would double
  the quote (SQL style), which sh reads as two adjacent strings. }
function Q(const s: AnsiString): AnsiString;
begin
  Result := '''' + StringReplace(s, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function FontIndex(const Id: AnsiString): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FontCatalog) do
    if FontCatalog[i].Id = Id then Exit(i);
  Result := -1;
end;

function FontAssetsDir: AnsiString;
var
  exe, d: AnsiString;
  c: array[0..3] of AnsiString;
  i: Integer;
begin
  Result := GetEnvironmentVariable('DN_FONTS_DIR');
  if Result <> '' then Exit;
  exe := ExtractFileDir(RealPath(ExecutablePath));
  c[0] := exe + '/../assets/fonts';             // repo: bin/dn
  c[1] := exe + '/../Resources/fonts';          // dn.app/Contents/MacOS
  c[2] := exe + '/../share/dn/fonts';           // /usr/bin/dn
  c[3] := '/usr/share/dn/fonts';
  for i := 0 to High(c) do
  begin
    d := ExpandFileName(c[i]);
    if DirectoryExists(d) then Exit(d);
  end;
  Result := '';
end;

function FontCacheDir(const E: TFontEntry): AnsiString;
begin
  Result := ConfigDir + '/fonts/' + E.Id;
end;

function IsFontFile(const f: AnsiString): Boolean;
var
  x: AnsiString;
begin
  x := LowerCase(ExtractFileExt(f));
  Result := (x = '.ttf') or (x = '.otf') or (x = '.psf') or (x = '.psfu');
end;

function FontFiles(const E: TFontEntry): AnsiString;
var
  L: TStringList;
  i: Integer;
  f: AnsiString;
begin
  Result := '';
  if E.Bundled <> '' then
  begin
    f := FontAssetsDir + '/' + E.Bundled;
    if (FontAssetsDir <> '') and FileExists(f) then Result := f;
    Exit;
  end;
  L := TStringList.Create;
  try
    L.Delimiter := ';';
    L.StrictDelimiter := True;
    L.DelimitedText := E.Members;
    for i := 0 to L.Count - 1 do
    begin
      f := FontCacheDir(E) + '/' + ExtractFileName(L[i]);
      if not IsFontFile(f) then Continue;
      if not FileExists(f) then Exit('');
      if Result <> '' then Result := Result + ';';
      Result := Result + f;
    end;
  finally
    L.Free;
  end;
end;

function FontReady(const E: TFontEntry): Boolean;
begin
  Result := FontFiles(E) <> '';
end;

function FontFits(const E: TFontEntry; Term: TTermKind): Boolean;
begin
  if Term = tkLinuxConsole then Result := E.Kind = fkConsole
  else Result := E.Kind = fkOutline;
end;

function ReadFileStr(const f: AnsiString; out s: AnsiString): Boolean;
var
  fs: TFileStream;
begin
  s := '';
  Result := False;
  try
    fs := TFileStream.Create(f, fmOpenRead or fmShareDenyNone);
    try
      SetLength(s, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(s[1], fs.Size);
      Result := True;
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

function ShaMatches(const Data, Hex: AnsiString): Boolean;
begin
  Result := (Hex <> '') and (LowerCase(Sha256Hex(Data)) = LowerCase(Hex));
end;

function FontDownload(const E: TFontEntry; out Err: AnsiString): Boolean;
var
  dir, zip, outp, data, members: AnsiString;
  L: TStringList;
  i, rc: Integer;
begin
  Err := '';
  Result := FontReady(E);
  if Result then Exit;
  if E.Url = '' then
  begin
    Err := 'bundled font file is missing: ' + E.Bundled;
    Exit(False);
  end;
  dir := FontCacheDir(E);
  ForceDirectories(dir);
  zip := dir + '/download.zip';
  rc := RunCapture('curl -fsSL --max-time 300 -o ' + Q(zip) + ' ' + Q(E.Url),
                   outp, 'Downloading font', E.Name);
  if rc <> 0 then
  begin
    DeleteFile(zip);
    if rc = RunCancelledExit then Err := FontCancelled
    else Err := 'download failed: ' + Trim(outp);
    Exit(False);
  end;
  if not ReadFileStr(zip, data) or not ShaMatches(data, E.Sha256) then
  begin
    DeleteFile(zip);
    Err := 'SHA-256 mismatch: the file is not the pinned release';
    Exit(False);
  end;
  data := '';
  L := TStringList.Create;
  try
    L.Delimiter := ';';
    L.StrictDelimiter := True;
    L.DelimitedText := E.Members;
    members := '';
    for i := 0 to L.Count - 1 do members := members + ' ' + Q(L[i]);
  finally
    L.Free;
  end;
  if RunCapture('unzip -o -j -q ' + Q(zip) + members + ' -d ' + Q(dir),
                outp) <> 0 then
    Err := 'unzip failed: ' + Trim(outp);
  DeleteFile(zip);
  Result := (Err = '') and FontReady(E);
  if not Result and (Err = '') then Err := 'font files not found in the archive';
end;

{ --- installing into the user's font folder --------------------------- }

function UserFontDir: AnsiString;
begin
  Result := GetEnvironmentVariable('DN_USER_FONT_DIR');
  if Result <> '' then Exit;
  {$ifdef darwin}
  Result := GetUserDir + 'Library/Fonts';
  {$else}
  Result := GetEnvironmentVariable('XDG_DATA_HOME');
  if Result = '' then Result := GetUserDir + '.local/share';
  Result := Result + '/fonts/dn';
  {$endif}
end;

function CopyFile(const src, dst: AnsiString): Boolean;
var
  s: AnsiString;
  fs: TFileStream;
begin
  Result := ReadFileStr(src, s);
  if not Result then Exit;
  try
    fs := TFileStream.Create(dst, fmCreate);
    try
      if s <> '' then fs.WriteBuffer(s[1], Length(s));
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

{ copies the outline files; True when something new was installed }
function InstallUserFont(const E: TFontEntry; out Err: AnsiString): Boolean;
var
  L: TStringList;
  i: Integer;
  dir, dst, outp: AnsiString;
begin
  Result := False;
  Err := '';
  dir := UserFontDir;
  ForceDirectories(dir);
  L := TStringList.Create;
  try
    L.Delimiter := ';';
    L.StrictDelimiter := True;
    L.DelimitedText := FontFiles(E);
    for i := 0 to L.Count - 1 do
    begin
      dst := dir + '/' + ExtractFileName(L[i]);
      if FileExists(dst) then Continue;
      if not CopyFile(L[i], dst) then
      begin
        Err := 'cannot write ' + dst;
        Exit;
      end;
      Result := True;
    end;
  finally
    L.Free;
  end;
  {$ifndef darwin}
  if Result and (GetEnvironmentVariable('DN_USER_FONT_DIR') = '') then
    RunCapture('fc-cache -f ' + Q(dir), outp);
  {$endif}
end;

{ --- talking to the terminal ------------------------------------------ }

function TmuxWrap(const Seq: AnsiString): AnsiString;
begin
  Result := #27'Ptmux;' + StringReplace(Seq, #27, #27#27, [rfReplaceAll]) +
            #27'\';
end;

procedure SendSeq(const Seq: AnsiString; Mux: Boolean);
var
  s: AnsiString;
begin
  if Mux then s := TmuxWrap(Seq) else s := Seq;
  Write(s);
  Flush(Output);
end;

function Osa(const Script: AnsiString; out Outp: AnsiString): Boolean;
begin
  Result := RunCapture('osascript -e ' + Q(Script), Outp) = 0;
  Outp := Trim(Outp);
end;

{ an AppleScript that runs Body for the Terminal.app tab on our tty }
function AppleTermScript(const Body: AnsiString): AnsiString;
begin
  Result := 'tell application "Terminal"'#10 +
            'repeat with w in windows'#10 +
            'repeat with t in tabs of w'#10 +
            'if tty of t is "' + CurrentTty + '" then'#10 +
            Body + #10 +
            'end if'#10'end repeat'#10'end repeat'#10'end tell';
end;

{ set the font of the tab's own settings, not "current settings", which
  is the window's active tab: a background tab would change the wrong one,
  and the change would persist in the profile across restarts }
function AppleSetFont(const Font, Size: AnsiString): AnsiString;
begin
  Result := AppleTermScript(
    'set font name of t to "' + Font + '"'#10 +
    'set font size of t to ' + Size);
end;

function ApplyAppleTerminal(const E: TFontEntry; Size: Integer;
                            out Msg: AnsiString): Boolean;
var
  outp: AnsiString;
begin
  if Restore <> rsAppleTerminal then
  begin
    if not Osa(AppleTermScript('return (font name of t) & "|" & (font size of t)'), outp) or
       (Pos('|', outp) = 0) then
    begin
      Msg := 'Terminal.app did not answer (allow DN in System Settings > ' +
             'Privacy & Security > Automation)';
      Exit(False);
    end;
    RestoreArg := outp;
  end;
  Result := Osa(AppleSetFont(E.PsName, IntToStr(Size)), outp);
  if Result then
  begin
    Restore := rsAppleTerminal;
    Msg := 'Terminal.app profile font set; DN restores it on exit';
  end
  else
    Msg := 'Terminal.app refused: ' + outp;
end;

function ITermProfileFile: AnsiString;
begin
  Result := GetUserDir +
    'Library/Application Support/iTerm2/DynamicProfiles/dn-fonts.json';
end;

function JsonStr(const s: AnsiString): AnsiString;
begin
  Result := '"' + StringReplace(StringReplace(s, '\', '\\', [rfReplaceAll]),
                                '"', '\"', [rfReplaceAll]) + '"';
end;

function ApplyITerm2(const E: TFontEntry; Size: Integer; Mux: Boolean;
                     out Msg: AnsiString): Boolean;
var
  parent, name, json, old: AnsiString;
  f: TextFile;
begin
  parent := GetEnvironmentVariable('ITERM_PROFILE');
  if parent = '' then parent := 'Default';
  if Restore = rsITerm2 then parent := RestoreArg;
  name := 'DN: ' + E.Name + ' ' + IntToStr(Size);
  json := '{"Profiles": [{"Name": ' + JsonStr(name) +
          ', "Guid": ' + JsonStr('dn-font-' + E.Id + '-' + IntToStr(Size)) +
          ', "Dynamic Profile Parent Name": ' + JsonStr(parent) +
          ', "Normal Font": ' + JsonStr(E.PsName + ' ' + IntToStr(Size)) +
          ', "Use Non-ASCII Font": false}]}' + LineEnding;
  if not ReadFileStr(ITermProfileFile, old) or (old <> json) then
  begin
    try
      ForceDirectories(ExtractFileDir(ITermProfileFile));
      AssignFile(f, ITermProfileFile);
      Rewrite(f);
      Write(f, json);
      CloseFile(f);
    except
      Msg := 'cannot write ' + ITermProfileFile;
      Exit(False);
    end;
    Sleep(700);   // iTerm2 picks up dynamic profiles from a file watcher
  end;
  SendSeq(#27']1337;SetProfile=' + name + #7, Mux);
  if Restore <> rsITerm2 then
  begin
    Restore := rsITerm2;
    RestoreArg := parent;
  end;
  RestoreMux := Mux;
  Msg := 'iTerm2 profile "' + name + '"; DN switches back to "' +
         RestoreArg + '" on exit';
  Result := True;
end;

function ApplySetfont(const E: TFontEntry; out Msg: AnsiString): Boolean;
var
  saved, outp: AnsiString;
begin
  saved := ConfigDir + '/fonts/console-saved.psf';
  ForceDirectories(ExtractFileDir(saved));
  if Restore <> rsSetfont then
    if RunCapture('setfont -O ' + Q(saved), outp) <> 0 then
    begin
      Msg := 'setfont is not available (install the kbd package): ' + Trim(outp);
      Exit(False);
    end;
  Result := RunCapture('setfont ' + Q(FontFiles(E)), outp) = 0;
  if Result then
  begin
    Restore := rsSetfont;
    RestoreArg := saved;
    Msg := 'console font loaded; DN restores the old one on exit';
  end
  else
    Msg := 'setfont failed: ' + Trim(outp);
end;

function SettingsHint(Kind: TTermKind; const Family: AnsiString): AnsiString;
begin
  case Kind of
    tkVSCode: Result := 'set "terminal.integrated.fontFamily": "' + Family +
                        '" in VS Code settings';
    tkKitty: Result := 'add "font_family ' + Family + '" to kitty.conf';
    tkWezTerm: Result := 'set font = wezterm.font("' + Family +
                         '") in wezterm.lua';
    tkAlacritty: Result := 'set font.normal.family = "' + Family +
                           '" in alacritty.toml';
    tkGhostty: Result := 'add "font-family = ' + Family +
                         '" to the Ghostty config';
  else
    Result := 'pick "' + Family + '" in the terminal''s settings';
  end;
end;

function FontApply(const E: TFontEntry; Size: Integer;
                   const T: TTermInfo; out Msg: AnsiString): Boolean;
var
  err: AnsiString;
  mux: Boolean;
begin
  Msg := '';
  if not FontFits(E, T.Kind) then
  begin
    if T.Kind = tkLinuxConsole then
      Msg := 'the Linux console shows only console (PSF) fonts'
    else
      Msg := 'a console (PSF) font works only on the Linux console';
    Exit(False);
  end;
  if not FontReady(E) then
  begin
    Msg := 'font is not downloaded';
    Exit(False);
  end;
  if Size <= 0 then Size := FontSizeDef;
  if T.Kind = tkLinuxConsole then Exit(ApplySetfont(E, Msg));

  InstallUserFont(E, err);
  if err <> '' then
  begin
    Msg := err;
    Exit(False);
  end;
  mux := T.Mux = 'tmux';
  Result := True;
  case T.Kind of
    tkXterm:
      begin
        SendSeq(#27']50;xft:' + E.Family + ':size=' + IntToStr(Size) + #7, mux);
        Restore := rsXterm;
        RestoreMux := mux;
        Msg := 'xterm font set';
      end;
    tkUrxvt:
      begin
        SendSeq(#27']710;xft:' + E.Family + ':size=' + IntToStr(Size) + #7, mux);
        Msg := 'urxvt font set (stays until urxvt restarts)';
      end;
    tkITerm2: Result := ApplyITerm2(E, Size, mux, Msg);
    tkAppleTerminal: Result := ApplyAppleTerminal(E, Size, Msg);
  else
    Msg := 'Installed into ' + UserFontDir + #10 +
           'To use it, ' + SettingsHint(T.Kind, E.Family);
  end;
  if Result and mux and (T.Kind in [tkXterm, tkUrxvt, tkITerm2]) then
    Msg := Msg + #10'tmux needs "set -g allow-passthrough on"';
end;

procedure FontRestore;
var
  outp: AnsiString;
  p: Integer;
begin
  case Restore of
    rsSetfont: RunCapture('setfont ' + Q(RestoreArg), outp);
    rsXterm: SendSeq(#27']50;#0'#7, RestoreMux);
    rsITerm2: SendSeq(#27']1337;SetProfile=' + RestoreArg + #7, RestoreMux);
    rsAppleTerminal:
      begin
        p := Pos('|', RestoreArg);
        if p > 0 then
          Osa(AppleSetFont(Copy(RestoreArg, 1, p - 1),
                           Copy(RestoreArg, p + 1, MaxInt)), outp);
      end;
  end;
  Restore := rsNone;
end;

end.
