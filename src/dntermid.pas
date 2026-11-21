{ dntermid — which terminal DN runs in. Detection reads only environment
  variables (and the tty name), so it is pure and unit-testable: the
  caller passes the lookup function. Inside tmux/screen the emulator is
  guessed from variables inherited from the outer terminal; they can be
  stale if the multiplexer server was started from another terminal. }
unit dntermid;

{$mode objfpc}{$H+}

interface

type
  TTermKind = (tkUnknown, tkLinuxConsole, tkXterm, tkXtermCompat, tkUrxvt,
               tkKitty, tkWezTerm, tkITerm2, tkGhostty, tkAlacritty,
               tkAppleTerminal, tkVSCode, tkWindowsTerminal, tkKonsole,
               tkVte);

  TTermEnvFunc = function(const Name: AnsiString): AnsiString;

  TTermInfo = record
    Kind: TTermKind;
    Name: AnsiString;         // human name, e.g. 'iTerm2'
    Version: AnsiString;      // '' when unknown
    Source: AnsiString;       // the variable that decided it, e.g. 'KITTY_WINDOW_ID'
    Mux: AnsiString;          // 'tmux', 'GNU screen', 'zellij' or ''
  end;

function DetectTerm(Env: TTermEnvFunc; const TtyName: AnsiString): TTermInfo;
function DetectTermNow: TTermInfo;
{ How DN could change the font in this terminal ('' = no way). }
function FontMethod(Kind: TTermKind): AnsiString;
{ The tty of stdin, '' when not a tty. }
function CurrentTty: AnsiString;

implementation

uses
  SysUtils;

function c_ttyname(fd: LongInt): PChar; cdecl; external 'c' name 'ttyname';

function SysEnv(const Name: AnsiString): AnsiString;
begin
  Result := GetEnvironmentVariable(Name);
end;

function CurrentTty: AnsiString;
var
  p: PChar;
begin
  p := c_ttyname(0);
  if p = nil then Result := '' else Result := StrPas(p);
end;

function StartsWith(const s, prefix: AnsiString): Boolean;
begin
  Result := Copy(s, 1, Length(prefix)) = prefix;
end;

{ /dev/tty1../dev/tty63: a Linux virtual console (macOS ptys are ttysNNN) }
function IsVtName(const tty: AnsiString): Boolean;
var
  i: Integer;
begin
  Result := StartsWith(tty, '/dev/tty') and (Length(tty) > 8);
  if Result then
    for i := 9 to Length(tty) do
      if not (tty[i] in ['0'..'9']) then Exit(False);
end;

function DetectTerm(Env: TTermEnvFunc; const TtyName: AnsiString): TTermInfo;
var
  term, prog: AnsiString;

  procedure Found(k: TTermKind; const n, src: AnsiString);
  begin
    Result.Kind := k;
    Result.Name := n;
    Result.Source := src;
  end;

begin
  Result := Default(TTermInfo);
  Result.Kind := tkUnknown;
  Result.Name := 'unknown';
  term := Env('TERM');
  prog := Env('TERM_PROGRAM');

  if (Env('TMUX') <> '') or (prog = 'tmux') then Result.Mux := 'tmux'
  else if Env('STY') <> '' then Result.Mux := 'GNU screen'
  else if Env('ZELLIJ') <> '' then Result.Mux := 'zellij';
  { tmux overwrites TERM_PROGRAM with its own name }
  if prog = 'tmux' then prog := '';

  if StartsWith(term, 'linux') or ((Result.Mux = '') and IsVtName(TtyName)) then
    Found(tkLinuxConsole, 'Linux console', 'TERM=' + term)
  else if (Env('KITTY_WINDOW_ID') <> '') then
    Found(tkKitty, 'kitty', 'KITTY_WINDOW_ID')
  else if term = 'xterm-kitty' then
    Found(tkKitty, 'kitty', 'TERM=xterm-kitty')
  else if (Env('WEZTERM_PANE') <> '') then
    Found(tkWezTerm, 'WezTerm', 'WEZTERM_PANE')
  else if prog = 'WezTerm' then
    Found(tkWezTerm, 'WezTerm', 'TERM_PROGRAM')
  else if prog = 'iTerm.app' then
    Found(tkITerm2, 'iTerm2', 'TERM_PROGRAM')
  else if Env('ITERM_SESSION_ID') <> '' then
    Found(tkITerm2, 'iTerm2', 'ITERM_SESSION_ID')
  else if (prog = 'ghostty') or (term = 'xterm-ghostty') then
    Found(tkGhostty, 'Ghostty', 'TERM_PROGRAM')
  else if (Env('ALACRITTY_WINDOW_ID') <> '') or (term = 'alacritty') then
    Found(tkAlacritty, 'Alacritty', 'ALACRITTY_WINDOW_ID')
  else if prog = 'vscode' then
    Found(tkVSCode, 'VS Code terminal', 'TERM_PROGRAM')
  else if prog = 'Apple_Terminal' then
    Found(tkAppleTerminal, 'Terminal.app', 'TERM_PROGRAM')
  else if Env('WT_SESSION') <> '' then
    Found(tkWindowsTerminal, 'Windows Terminal', 'WT_SESSION')
  else if Env('KONSOLE_VERSION') <> '' then
  begin
    Found(tkKonsole, 'Konsole', 'KONSOLE_VERSION');
    Result.Version := Env('KONSOLE_VERSION');
  end
  else if Env('VTE_VERSION') <> '' then
  begin
    Found(tkVte, 'VTE-based (GNOME Terminal, Tilix, ...)', 'VTE_VERSION');
    Result.Version := Env('VTE_VERSION');
  end
  else if StartsWith(term, 'rxvt') then
    Found(tkUrxvt, 'rxvt-unicode', 'TERM=' + term)
  else if Env('XTERM_VERSION') <> '' then
  begin
    Found(tkXterm, 'xterm', 'XTERM_VERSION');
    Result.Version := Env('XTERM_VERSION');
  end
  else if StartsWith(term, 'xterm') then
    Found(tkXtermCompat, 'xterm-compatible', 'TERM=' + term);

  if (Result.Version = '') and (prog <> '') and
     (Result.Source = 'TERM_PROGRAM') then
    Result.Version := Env('TERM_PROGRAM_VERSION');
end;

function DetectTermNow: TTermInfo;
begin
  Result := DetectTerm(@SysEnv, CurrentTty);
end;

function FontMethod(Kind: TTermKind): AnsiString;
begin
  case Kind of
    tkLinuxConsole:  Result := 'PSF font via KDFONTOP ioctl';
    tkXterm:         Result := 'OSC 50 (installed font name)';
    tkUrxvt:         Result := 'OSC 710 (installed font name)';
    tkKitty:         Result := 'kitty remote control';
    tkITerm2:        Result := 'iTerm2 profile (OSC 1337 SetProfile)';
    tkAppleTerminal: Result := 'AppleScript';
  else
    Result := '';
  end;
end;

end.
