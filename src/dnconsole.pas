{ dnconsole — a console window on the desktop (Tools > Console):
  a scrollback of captured command output plus an input line with
  history. Commands run through /bin/sh with stdout+stderr captured
  and streamed into the window; stdin is /dev/null and TERM=dumb, so
  full-screen interactive programs can't run here — the window detects
  them and points at Ctrl-O (an interactive shell on the real screen).
  Ctrl-C or Esc kills a running command. }
unit dnconsole;

{$mode objfpc}{$H+}

interface

uses
  Classes, dnwin;

type
  TConsoleWin = class(TWin)
  public
    Lines: TStringList;         // scrollback, owned
    Dir: AnsiString;            // working directory ('cd' is a builtin)
    Input: AnsiString;
    Scroll: Integer;            // lines scrolled up from the tail
    Hist: TStringList;
    HistAt: Integer;
    PendingEnter: Boolean;   // Enter typed while a command was running
    constructor CreateConsole(const ADir: AnsiString);
    destructor Destroy; override;
    procedure DrawContent(Focused: Boolean); override;
    function StatusText: AnsiString; override;
    function HandleKey(ch: LongInt): TKeyAction; override;
    function HandleText(const s: AnsiString): TKeyAction; override;
    procedure HandleClick(mx, my: Integer; bstate: QWord); override;
    procedure RunCommand(cmd: AnsiString);
    procedure RunCaptured(const cmd: AnsiString);
  end;

function OpenConsole(const ADir: AnsiString): TConsoleWin;

implementation

uses
  SysUtils, BaseUnix, Unix, ncurses, dnscreen;

const
  MaxScrollback = 1000;

function c_setpgid(pid, pgid: LongInt): LongInt;
  cdecl; external 'c' name 'setpgid';

var
  Cascade: Integer = 0;

constructor TConsoleWin.CreateConsole(const ADir: AnsiString);
var
  rw, rh: Integer;
begin
  rw := (COLS * 3) div 4;
  rh := ((DeskY1 - DeskY0 + 1) * 3) div 4;
  inherited Create(2 + (Cascade mod 4) * 3, DeskY0 + 1 + (Cascade mod 4),
                   rw, rh, 'Console');
  Inc(Cascade);
  Lines := TStringList.Create;
  Lines.Add('Command output is captured here. Full-screen programs');
  Lines.Add('(htop, mc, vim, …) need Ctrl-O — an interactive shell.');
  Hist := TStringList.Create;
  HistAt := 0;
  Dir := ADir;
  Input := '';
  Scroll := 0;
end;

destructor TConsoleWin.Destroy;
begin
  Lines.Free;
  Hist.Free;
  inherited;
end;

function TConsoleWin.StatusText: AnsiString;
begin
  Result := Dir;
end;

{ tabs and control bytes would break the frame like in the viewer }
function CleanLine(const src: AnsiString): AnsiString;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(src) do
    if src[i] = #9 then
      Result := Result + '    '
    else if (src[i] < #32) or (src[i] = #127) then
      { skip CR, mark other control bytes }
      begin
        if not (src[i] in [#13, #10]) then
          Result := Result + '·';
      end
    else
      Result := Result + src[i];
end;

{ first shell word of cmd, lowercased and stripped of any path, so
  "/usr/bin/vim" and "vim" both match the known-apps list }
function FirstWordBase(const cmd: AnsiString): AnsiString;
var
  i: Integer;
begin
  Result := '';
  i := 1;
  while (i <= Length(cmd)) and (cmd[i] in [' ', #9]) do Inc(i);
  while (i <= Length(cmd)) and not (cmd[i] in [' ', #9]) do
  begin
    Result := Result + cmd[i];
    Inc(i);
  end;
  Result := LowerCase(ExtractFileName(Result));
end;

{ programs that need a real terminal (full-screen TUI) or a windowing
  session (GUI) — they can't run in this captured console }
function IsInteractiveApp(const cmd: AnsiString; out gui: Boolean): Boolean;
const
  TuiApps = ',vi,vim,nvim,view,nano,pico,emacs,mc,mcedit,htop,top,btop,'
          + 'less,more,man,tmux,screen,ncdu,ranger,nnn,lazygit,tig,'
          + 'watch,vifm,ssh,telnet,irssi,weechat,dialog,whiptail,';
  GuiApps = ',open,code,subl,xdg-open,firefox,chrome,safari,'
          + 'gitk,gvim,xterm,';
var
  w: AnsiString;
begin
  w := FirstWordBase(cmd);
  gui := (w <> '') and (Pos(',' + w + ',', GuiApps) > 0);
  Result := gui or ((w <> '') and (Pos(',' + w + ',', TuiApps) > 0));
end;

procedure TConsoleWin.RunCommand(cmd: AnsiString);
var
  arg: AnsiString;
  gui: Boolean;
begin
  cmd := Trim(cmd);
  if cmd = '' then Exit;
  if (Hist.Count = 0) or (Hist[Hist.Count - 1] <> cmd) then
    Hist.Add(cmd);
  HistAt := Hist.Count;
  Lines.Add(Dir + '> ' + cmd);

  { catch full-screen / GUI programs before capturing them: the console
    is a pipe, not a terminal, so point the user at the right place
    instead of running them here (a captured TUI app renders as garbage) }
  if IsInteractiveApp(cmd, gui) then
  begin
    if gui then
      Lines.Add('"' + FirstWordBase(cmd) +
                '" is a GUI program — run it outside DN.')
    else
      Lines.Add('"' + FirstWordBase(cmd) + '" needs a real terminal. ' +
                'Press Ctrl-O for an interactive shell.');
  end
  else if (cmd = 'cd') or (Copy(cmd, 1, 3) = 'cd ') then
  begin
    arg := Trim(Copy(cmd, 3, MaxInt));
    if arg = '' then arg := GetUserDir;
    if (arg <> '') and (arg[1] <> '/') then arg := Dir + '/' + arg;
    arg := ExpandFileName(arg);
    if DirectoryExists(arg) then
      Dir := arg
    else
      Lines.Add('cd: no such directory: ' + arg);
  end
  else if cmd = 'clear' then
    Lines.Clear
  else
    RunCaptured(cmd);

  while Lines.Count > MaxScrollback do
    Lines.Delete(0);
  Scroll := 0;

  { a command typed ahead while the previous one was running }
  if PendingEnter then
  begin
    PendingEnter := False;
    arg := Input;
    Input := '';
    RunCommand(arg);
  end;
end;

{ error lines that mean "I need a real terminal, not a pipe" }
function LooksLikeTtyComplaint(const s: AnsiString): Boolean;
var
  u: AnsiString;
begin
  u := LowerCase(s);
  Result := (Pos('not a terminal', u) > 0) or
            (Pos('not a tty', u) > 0) or
            (Pos('inappropriate ioctl', u) > 0) or
            (Pos('opening terminal', u) > 0) or
            (Pos('terminal lacks', u) > 0) or
            (Pos('must be run from a terminal', u) > 0) or
            (Pos('requires a terminal', u) > 0) or
            (Pos('cannot get terminal', u) > 0);
end;

procedure TConsoleWin.RunCaptured(const cmd: AnsiString);
var
  pfd: TFilDes;
  pid: TPid;
  buf: array[0..4095] of Char;
  partial, chunk: AnsiString;
  n: TsSize;
  status: cint;
  devnull: cint;
  ch: LongInt;
  linesBefore, li: Integer;
  killed, wantsTty: Boolean;
  mev: MEVENT;

  procedure AddOut(const chunk: AnsiString);
  var
    p, start: Integer;
  begin
    partial := partial + chunk;
    start := 1;
    for p := 1 to Length(partial) do
      if partial[p] = #10 then
      begin
        Lines.Add(CleanLine(Copy(partial, start, p - start)));
        start := p + 1;
      end;
    partial := Copy(partial, start, MaxInt);
    while Lines.Count > MaxScrollback do
      Lines.Delete(0);
  end;

begin
  linesBefore := Lines.Count;
  if fpPipe(pfd) <> 0 then
  begin
    Lines.Add('cannot run: ' + cmd);
    Exit;
  end;

  pid := fpFork;
  if pid = 0 then
  begin
    { own process group, so Ctrl-C kills the whole pipeline }
    c_setpgid(0, 0);
    fpSignal(SIGINT, SignalHandler(SIG_DFL));
    fpSignal(SIGQUIT, SignalHandler(SIG_DFL));
    devnull := fpOpen('/dev/null', O_RDONLY);
    fpDup2(devnull, 0);                // no tty: interactive programs quit
    fpDup2(pfd[1], 1);
    fpDup2(pfd[1], 2);
    fpClose(pfd[0]);
    fpClose(pfd[1]);
    FpChdir(Dir);
    { TERM=dumb via the shell: fpExecl passes the RTL's own environment
      copy, so libc setenv would not reach the child }
    fpExecl('/bin/sh', ['-c', 'export TERM=dumb; ' + cmd]);
    fpExit(127);
  end;

  fpClose(pfd[1]);
  if pid < 0 then
  begin
    fpClose(pfd[0]);
    Lines.Add('cannot run: ' + cmd);
    Exit;
  end;
  fpFcntl(pfd[0], F_SETFL, fpFcntl(pfd[0], F_GETFL) or O_NONBLOCK);

  partial := '';
  killed := False;
  timeout(50);
  repeat
    { drain whatever the pipe has right now }
    repeat
      n := fpRead(pfd[0], buf, SizeOf(buf));
      if n > 0 then
      begin
        SetString(chunk, @buf[0], n);
        AddOut(chunk);
      end;
    until n <= 0;
    if n = 0 then Break;                       // EOF: command finished
    if fpGetErrno <> ESysEAGAIN then Break;

    { stream to the screen and stay interruptible }
    Scroll := 0;
    Draw(True);
    refresh;
    ch := getch;
    case ch of
      3, 27:                                   // Ctrl-C / Esc
        begin
          if killed then
            fpKill(-pid, SIGKILL)              // second press: no mercy
          else
            fpKill(-pid, SIGTERM);
          killed := True;
        end;
      10, 13, KEY_ENTER: PendingEnter := True;
      KEY_BACKSPACE, 127, 8:
        if Input <> '' then
          SetLength(Input, Length(Input) - 1);
      KEY_MOUSE: getmouse(@mev);               // drain, ignore
    else
      { type-ahead: keys pressed during a run land on the input line }
      if ((ch >= 32) and (ch < 127)) or ((ch >= 128) and (ch <= 255)) then
        Input := Input + Chr(ch);
    end;
  until False;
  timeout(1000);

  fpClose(pfd[0]);
  fpWaitPid(pid, status, 0);
  if partial <> '' then
    Lines.Add(CleanLine(partial));
  if killed then
    Lines.Add('[terminated]')
  else if wifexited(status) and (wexitstatus(status) <> 0) then
  begin
    Lines.Add('[exit code ' + IntToStr(wexitstatus(status)) + ']');
    { a failed command whining about the terminal is a TUI app the
      known-apps list missed: point at Ctrl-O like the up-front guard }
    wantsTty := False;
    for li := linesBefore to Lines.Count - 1 do
      if LooksLikeTtyComplaint(Lines[li]) then wantsTty := True;
    if wantsTty then
      Lines.Add('(needs a real terminal — press Ctrl-O for a shell)');
  end;
end;

procedure TConsoleWin.DrawContent(Focused: Boolean);
var
  ph, cw, j, first: Integer;
  prompt, vis: AnsiString;
begin
  cw := W - 2;
  ph := H - 3;                       // output rows; the last row is input
  if Scroll > Lines.Count - ph then Scroll := Lines.Count - ph;
  if Scroll < 0 then Scroll := 0;
  first := Lines.Count - ph - Scroll;
  for j := 0 to ph - 1 do
  begin
    if first + j >= 0 then
      vis := Utf8Copy(Lines[first + j], 1, cw)
    else
      vis := '';
    PutStr(Y + 1 + j, X + 1, Utf8PadRight(vis, cw), cpViewer);
  end;

  { the input line, kept right-anchored when it outgrows the window }
  prompt := Dir + '> ' + Input;
  if Utf8Len(prompt) > cw - 1 then
    prompt := Utf8Copy(prompt, Utf8Len(prompt) - (cw - 2), cw - 1);
  PutStr(Y + H - 2, X + 1, Utf8PadRight(prompt, cw), cpInput);
  if Focused then
    PutStr(Y + H - 2, X + 1 + Utf8Len(prompt), ' ', cpCursor);
end;

function TConsoleWin.HandleKey(ch: LongInt): TKeyAction;
var
  cmd: AnsiString;
begin
  Result := kaConsumed;
  case ch of
    10, 13, KEY_ENTER:
      begin
        { clear Input before running: keys typed while the command is
          busy land there as type-ahead and must survive }
        cmd := Input;
        Input := '';
        RunCommand(cmd);
      end;
    KEY_BACKSPACE, 127, 8:
      if Input <> '' then
      begin
        while (Input <> '') and ((Ord(Input[Length(Input)]) and $C0) = $80) do
          SetLength(Input, Length(Input) - 1);
        if Input <> '' then
          SetLength(Input, Length(Input) - 1);
      end;
    KEY_UP:
      if HistAt > 0 then
      begin
        Dec(HistAt);
        Input := Hist[HistAt];
      end;
    KEY_DOWN:
      if HistAt < Hist.Count - 1 then
      begin
        Inc(HistAt);
        Input := Hist[HistAt];
      end
      else
      begin
        HistAt := Hist.Count;
        Input := '';
      end;
    KEY_PPAGE: Inc(Scroll, H - 3);
    KEY_NPAGE: Dec(Scroll, H - 3);
    21: Input := '';                       // Ctrl-U
    27:
      if Input <> '' then Input := ''
      else Exit(kaClose);
    KEY_F0 + 10: Exit(kaClose);
  else
    if (ch >= 32) and (ch < 127) then
      Input := Input + Chr(ch)
    else
      Exit(kaPass);
  end;
end;

function TConsoleWin.HandleText(const s: AnsiString): TKeyAction;
begin
  Input := Input + s;
  Result := kaConsumed;
end;

procedure TConsoleWin.HandleClick(mx, my: Integer; bstate: QWord);
begin
  if (bstate and mbtnWheelUp) <> 0 then Inc(Scroll, 3);
  if (bstate and mbtnWheelDown) <> 0 then Dec(Scroll, 3);
end;

function OpenConsole(const ADir: AnsiString): TConsoleWin;
begin
  Result := TConsoleWin.CreateConsole(ADir);
  WinAdd(Result);
end;

end.
