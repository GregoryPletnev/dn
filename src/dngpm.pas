{ Direct gpm client for the Linux text console.

  ncurses can talk to gpm itself, but it asks only for button presses and
  releases and never draws the pointer: on a bare console there is no
  visible pointer, no drag motion and no wheel. Here DN connects to gpm on
  its own (libgpm is loaded at run time, so nothing changes where it is
  missing), draws the pointer and hands events to ncurses with ungetmouse,
  so the usual KEY_MOUSE / getmouse handling sees them unchanged.

  Shift + mouse is left to gpm: copy and paste on the console keep working. }
unit dngpm;

{$mode objfpc}{$H+}

interface

{ before initscr: on a Linux console keep ncurses' own gpm support off }
procedure GpmPreInit;
{ after initscr: connect to gpm; False when not on a console / no gpm }
function GpmInit: Boolean;
procedure GpmDone;
function GpmActive: Boolean;
{ around endwin'ed shell runs: let the shell (or a program) own the mouse }
procedure GpmSuspend;
procedure GpmResume;
{ wait up to ms (-1: forever) for a key or a gpm event; a mouse event is
  queued with ungetmouse. Returns False on timeout. }
function GpmWait(ms: LongInt): Boolean;
{ draw the pointer again: every screen write erases it }
procedure GpmShowPointer;

implementation

{$ifdef linux}
uses
  SysUtils, BaseUnix, dynlibs, ncurses;

{$packrecords c}
type
  TGpmConnect = record
    eventMask, defaultMask, minMod, maxMod: Word;
    pid, vc: LongInt;
  end;

  TGpmEvent = record
    buttons, modifiers: Byte;
    vc: Word;
    dx, dy, x, y: SmallInt;
    typ, clicks, margin: LongInt;
    wdx, wdy: SmallInt;
  end;

const
  GPM_MOVE = 1; GPM_DRAG = 2; GPM_DOWN = 4; GPM_UP = 8; GPM_HARD = 256;
  GPM_B_RIGHT = 1; GPM_B_MIDDLE = 2; GPM_B_LEFT = 4;
  GPM_B_UP = 16; GPM_B_DOWN = 32;
  KG_SHIFT = 0; KG_SHIFTL = 4; KG_SHIFTR = 5;

  { ncurses mouse version 2 masks (see dnscreen) }
  BTN1_RELEASED = $1;   BTN1_PRESSED = $2;
  BTN2_RELEASED = $20;  BTN2_PRESSED = $40;
  BTN3_RELEASED = $400; BTN3_PRESSED = $800;
  BTN4_PRESSED  = $10000;     // wheel up
  BTN5_PRESSED  = $200000;    // wheel down
  MOUSE_POSITION = $10000000;

  TIOCLINUX = $541C;
  TIOCL_SETSEL = 2;
  TIOCL_SELPOINTER = 3;

var
  Lib: TLibHandle = NilHandle;
  Gpm_Open: function(conn: Pointer; flag: LongInt): LongInt; cdecl;
  Gpm_Close: function: LongInt; cdecl;
  Gpm_GetEvent: function(ev: Pointer): LongInt; cdecl;
  Fd: LongInt = -1;
  Wanted: Boolean = False;     // GpmInit succeeded once (resume target)
  PtrX: Integer = 0;           // 1-based pointer cell, 0 = unknown
  PtrY: Integer = 0;

function c_setenv(name, value: PChar; overwrite: LongInt): LongInt;
  cdecl; external 'c' name 'setenv';

function OnConsole: Boolean;
begin
  Result := Copy(GetEnvironmentVariable('TERM'), 1, 5) = 'linux';
end;

procedure GpmPreInit;
begin
  { an explicit user setting wins; "none" matches no terminal name }
  if OnConsole and (GetEnvironmentVariable('NCURSES_GPM_TERMS') = '') then
    c_setenv('NCURSES_GPM_TERMS', 'none', 1);
end;

function Connect: Boolean;
var
  conn: TGpmConnect;
begin
  FillChar(conn, SizeOf(conn), 0);
  conn.eventMask := GPM_MOVE or GPM_DRAG or GPM_DOWN or GPM_UP;
  conn.defaultMask := not (conn.eventMask or GPM_HARD);
  conn.minMod := 0;
  conn.maxMod := $FFFF and not ((1 shl KG_SHIFT) or (1 shl KG_SHIFTL) or (1 shl KG_SHIFTR));
  Fd := Gpm_Open(@conn, 0);
  if Fd < 0 then
    Fd := -1;
  Result := Fd >= 0;
end;

function GpmInit: Boolean;
begin
  Result := False;
  if not OnConsole then Exit;
  if Lib = NilHandle then
  begin
    Lib := LoadLibrary('libgpm.so.2');
    if Lib = NilHandle then Exit;
    Pointer(Gpm_Open) := GetProcAddress(Lib, 'Gpm_Open');
    Pointer(Gpm_Close) := GetProcAddress(Lib, 'Gpm_Close');
    Pointer(Gpm_GetEvent) := GetProcAddress(Lib, 'Gpm_GetEvent');
    if (Pointer(Gpm_Open) = nil) or (Pointer(Gpm_Close) = nil) or
       (Pointer(Gpm_GetEvent) = nil) then
    begin
      UnloadLibrary(Lib);
      Lib := NilHandle;
      Exit;
    end;
  end;
  Result := Connect;
  Wanted := Result;
end;

procedure GpmDone;
begin
  if Fd >= 0 then
    Gpm_Close();
  Fd := -1;
  Wanted := False;
end;

function GpmActive: Boolean;
begin
  Result := Fd >= 0;
end;

procedure GpmSuspend;
begin
  if Fd >= 0 then
    Gpm_Close();
  Fd := -1;
end;

procedure GpmResume;
begin
  if Wanted and (Fd < 0) then
    Connect;
end;

procedure GpmShowPointer;
var
  sel: packed record
    sub: Byte;
    xs, ys, xe, ye, mode: Word;
  end;
begin
  if (Fd < 0) or (PtrX < 1) then Exit;
  sel.sub := TIOCL_SETSEL;
  sel.xs := PtrX; sel.ys := PtrY;
  sel.xe := PtrX; sel.ye := PtrY;
  sel.mode := TIOCL_SELPOINTER;
  FpIOCtl(0, TIOCLINUX, @sel);
end;

procedure Queue(const ev: TGpmEvent; bstate: LongWord);
var
  me: MEVENT;
begin
  FillChar(me, SizeOf(me), 0);
  me.x := ev.x - 1;
  me.y := ev.y - 1;
  if me.x < 0 then me.x := 0;
  if me.y < 0 then me.y := 0;
  if me.x >= COLS then me.x := COLS - 1;
  if me.y >= LINES then me.y := LINES - 1;
  me.bstate := bstate;
  ungetmouse(@me);
end;

procedure ReadEvent;
var
  ev: TGpmEvent;
  b: LongWord;
begin
  FillChar(ev, SizeOf(ev), 0);
  if Gpm_GetEvent(@ev) <= 0 then
  begin
    Fd := -1;          // gpm went away: fall back to keyboard only
    Exit;
  end;
  PtrX := ev.x;
  PtrY := ev.y;
  { wheel: newer gpm reports wdy, older ones extra buttons }
  if (ev.wdy > 0) or ((ev.typ and GPM_DOWN <> 0) and (ev.buttons and GPM_B_UP <> 0)) then
  begin
    Queue(ev, BTN4_PRESSED);
    Exit;
  end;
  if (ev.wdy < 0) or ((ev.typ and GPM_DOWN <> 0) and (ev.buttons and GPM_B_DOWN <> 0)) then
  begin
    Queue(ev, BTN5_PRESSED);
    Exit;
  end;
  b := 0;
  if ev.typ and GPM_DOWN <> 0 then
  begin
    if ev.buttons and GPM_B_LEFT <> 0 then b := b or BTN1_PRESSED;
    if ev.buttons and GPM_B_MIDDLE <> 0 then b := b or BTN2_PRESSED;
    if ev.buttons and GPM_B_RIGHT <> 0 then b := b or BTN3_PRESSED;
  end
  else if ev.typ and GPM_UP <> 0 then
  begin
    if ev.buttons and GPM_B_LEFT <> 0 then b := b or BTN1_RELEASED;
    if ev.buttons and GPM_B_MIDDLE <> 0 then b := b or BTN2_RELEASED;
    if ev.buttons and GPM_B_RIGHT <> 0 then b := b or BTN3_RELEASED;
  end
  else if ev.typ and GPM_DRAG <> 0 then
    b := MOUSE_POSITION;    // like xterm 1002: motion with a button held
  { plain moves only move the pointer }
  if b <> 0 then
    Queue(ev, b);
end;

function GpmWait(ms: LongInt): Boolean;
var
  fds: array[0..1] of pollfd;
begin
  fds[0].fd := 0;  fds[0].events := POLLIN; fds[0].revents := 0;
  fds[1].fd := Fd; fds[1].events := POLLIN; fds[1].revents := 0;
  Result := FpPoll(@fds[0], 2, ms) > 0;
  if Result and (fds[1].revents <> 0) then
    ReadEvent;
end;

{$else}

procedure GpmPreInit; begin end;
function GpmInit: Boolean; begin Result := False; end;
procedure GpmDone; begin end;
function GpmActive: Boolean; begin Result := False; end;
procedure GpmSuspend; begin end;
procedure GpmResume; begin end;
function GpmWait(ms: LongInt): Boolean; begin Result := False; end;
procedure GpmShowPointer; begin end;

{$endif}

end.
