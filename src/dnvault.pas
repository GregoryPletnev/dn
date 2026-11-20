{ dnvault — passwords for the database connections, encrypted with a
  master password.

  The vault is an SQLite file, ConfigDir/vault.db (mode 0600):
    meta(k, v)         'salt' (hex), 'rounds', 'check' (a sealed marker
                       that tells a right master password from a wrong one)
    secrets(id, blob)  one sealed secret per id, hex
  The key: PBKDF2-HMAC-SHA256(master, salt, rounds) -> 64 bytes; every
  secret is sealed with ChaCha20 + HMAC-SHA256 (dncrypto.Seal). The
  master password is asked for at the first vault access of a dn run
  (VaultAskHook, set by the UI) and the derived key lives in memory until
  dn exits; the master password itself is not kept.

  SQLite comes from the system library through FPC's sqlite3dyn; every
  statement binds its values (no SQL built from ids). }
unit dnvault;

{$mode objfpc}{$H+}

interface

type
  { ask for the master password; NewVault: there is none yet (ask twice).
    False = the user cancelled. }
  TVaultAskHook = function(NewVault: Boolean; const Hint: AnsiString;
                           out Master: AnsiString): Boolean;

var
  VaultAskHook: TVaultAskHook = nil;

const
  VaultRounds = 200000;

function VaultPath: AnsiString;
function VaultExists: Boolean;
function VaultUnlocked: Boolean;
{ derive the key; for a new vault create it. False: wrong password. }
function VaultUnlock(const Master: AnsiString; out Err: AnsiString): Boolean;
{ unlock through VaultAskHook if needed (3 tries); False: cancelled }
function VaultEnsureUnlocked(out Err: AnsiString): Boolean;
procedure VaultLock;

function VaultGet(const Id: AnsiString; out Secret: AnsiString;
                  out Err: AnsiString): Boolean;
function VaultPut(const Id, Secret: AnsiString; out Err: AnsiString): Boolean;
function VaultDelete(const Id: AnsiString; out Err: AnsiString): Boolean;
{ True when a secret is stored for Id (no unlock needed) }
function VaultHas(const Id: AnsiString): Boolean;

implementation

uses
  SysUtils, BaseUnix, ctypes, sqlite3dyn, dnconfig, dncrypto;

const
  CheckMarker = 'dn-vault-ok';

var
  Key: AnsiString = '';           // 64 bytes while unlocked
  LibReady: Integer = 0;          // 0 unknown, 1 loaded, -1 missing

function VaultPath: AnsiString;
begin
  Result := IncludeTrailingPathDelimiter(ConfigDir) + 'vault.db';
end;

function LibOk(out Err: AnsiString): Boolean;
begin
  Err := '';
  if LibReady = 0 then
  begin
    try
      if InitializeSQLite > 0 then LibReady := 1 else LibReady := -1;
    except
      LibReady := -1;
    end;
  end;
  Result := LibReady = 1;
  if not Result then Err := 'the SQLite library (libsqlite3) is not available';
end;

{ --- a tiny statement helper --------------------------------------------- }

function OpenDb(out Db: psqlite3; out Err: AnsiString): Boolean;
var
  isNew: Boolean;
begin
  Result := False;
  Db := nil;
  if not LibOk(Err) then Exit;
  ForceDirectories(ConfigDir);
  isNew := not FileExists(VaultPath);
  if sqlite3_open(PChar(VaultPath), @Db) <> SQLITE_OK then
  begin
    Err := 'cannot open ' + VaultPath;
    if Db <> nil then sqlite3_close(Db);
    Db := nil;
    Exit;
  end;
  if isNew then fpChmod(VaultPath, &600);
  sqlite3_busy_timeout(Db, 2000);
  if sqlite3_exec(Db, 'CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);' +
                      'CREATE TABLE IF NOT EXISTS secrets(id TEXT PRIMARY KEY, blob TEXT);',
                  nil, nil, nil) <> SQLITE_OK then
  begin
    Err := 'cannot initialise ' + VaultPath + ': ' + sqlite3_errmsg(Db);
    sqlite3_close(Db);
    Db := nil;
    Exit;
  end;
  Result := True;
end;

{ run Sql with text parameters; Rows gets column 0 of each result row }
function Exec(Db: psqlite3; const Sql: AnsiString;
              const Params: array of AnsiString; out Rows: TStringArray;
              out Err: AnsiString): Boolean;
var
  st: psqlite3_stmt;
  i, rc: Integer;
begin
  Result := False;
  Err := '';
  SetLength(Rows, 0);
  if sqlite3_prepare_v2(Db, PChar(Sql), -1, @st, nil) <> SQLITE_OK then
  begin
    Err := sqlite3_errmsg(Db);
    Exit;
  end;
  try
    for i := 0 to High(Params) do
      sqlite3_bind_text(st, i + 1, PChar(Params[i]), Length(Params[i]),
                        sqlite3_destructor_type(SQLITE_TRANSIENT));
    repeat
      rc := sqlite3_step(st);
      if rc = SQLITE_ROW then
      begin
        SetLength(Rows, Length(Rows) + 1);
        Rows[High(Rows)] := StrPas(sqlite3_column_text(st, 0));
      end;
    until rc <> SQLITE_ROW;
    if rc <> SQLITE_DONE then
    begin
      Err := sqlite3_errmsg(Db);
      Exit;
    end;
  finally
    sqlite3_finalize(st);
  end;
  Result := True;
end;

function MetaGet(Db: psqlite3; const K: AnsiString): AnsiString;
var
  rows: TStringArray;
  err: AnsiString;
begin
  Result := '';
  if Exec(Db, 'SELECT v FROM meta WHERE k = ?', [K], rows, err) and
     (Length(rows) > 0) then
    Result := rows[0];
end;

{ --- the vault ------------------------------------------------------------ }

function VaultExists: Boolean;
var
  db: psqlite3;
  err: AnsiString;
begin
  Result := False;
  if not FileExists(VaultPath) then Exit;
  if not OpenDb(db, err) then Exit;
  try
    Result := MetaGet(db, 'check') <> '';
  finally
    sqlite3_close(db);
  end;
end;

function VaultUnlocked: Boolean;
begin
  Result := Length(Key) = 64;
end;

procedure VaultLock;
begin
  if Key <> '' then
    FillChar(Key[1], Length(Key), 0);
  Key := '';
end;

function VaultUnlock(const Master: AnsiString; out Err: AnsiString): Boolean;
var
  db: psqlite3;
  rows: TStringArray;
  salt, check, k, plain: AnsiString;
  rounds: Integer;
begin
  Result := False;
  if Master = '' then
  begin
    Err := 'empty master password';
    Exit;
  end;
  if not OpenDb(db, Err) then Exit;
  try
    check := MetaGet(db, 'check');
    if check = '' then
    begin
      { a new vault }
      salt := RandomBytes(16);
      k := Pbkdf2Sha256(Master, salt, VaultRounds, 64);
      if not (Exec(db, 'INSERT OR REPLACE INTO meta VALUES(?, ?)',
                   ['salt', ToHex(salt)], rows, Err) and
              Exec(db, 'INSERT OR REPLACE INTO meta VALUES(?, ?)',
                   ['rounds', IntToStr(VaultRounds)], rows, Err) and
              Exec(db, 'INSERT OR REPLACE INTO meta VALUES(?, ?)',
                   ['check', ToHex(Seal(k, CheckMarker))], rows, Err)) then
        Exit;
    end
    else
    begin
      salt := FromHex(MetaGet(db, 'salt'));
      rounds := StrToIntDef(MetaGet(db, 'rounds'), VaultRounds);
      k := Pbkdf2Sha256(Master, salt, rounds, 64);
      if not (Unseal(k, FromHex(check), plain) and (plain = CheckMarker)) then
      begin
        Err := 'wrong master password';
        Exit;
      end;
    end;
    Key := k;
    Result := True;
  finally
    sqlite3_close(db);
  end;
end;

function VaultEnsureUnlocked(out Err: AnsiString): Boolean;
var
  master, hint: AnsiString;
  isNew: Boolean;
  tries: Integer;
begin
  Err := '';
  Result := VaultUnlocked;
  if Result then Exit;
  if not LibOk(Err) then Exit;
  if not Assigned(VaultAskHook) then
  begin
    Err := 'the vault is locked';
    Exit;
  end;
  isNew := not VaultExists;
  hint := '';
  for tries := 1 to 3 do
  begin
    if not VaultAskHook(isNew, hint, master) then
    begin
      Err := 'cancelled';
      Exit;
    end;
    Result := VaultUnlock(master, Err);
    if master <> '' then FillChar(master[1], Length(master), 0);
    if Result then Exit;
    hint := Err;
  end;
end;

function VaultGet(const Id: AnsiString; out Secret: AnsiString;
                  out Err: AnsiString): Boolean;
var
  db: psqlite3;
  rows: TStringArray;
begin
  Result := False;
  Secret := '';
  if not VaultEnsureUnlocked(Err) then Exit;
  if not OpenDb(db, Err) then Exit;
  try
    if not Exec(db, 'SELECT blob FROM secrets WHERE id = ?', [Id], rows, Err) then
      Exit;
    if Length(rows) = 0 then
    begin
      Err := 'no password stored';
      Exit;
    end;
    if not Unseal(Key, FromHex(rows[0]), Secret) then
    begin
      Err := 'the stored password does not open with this master password';
      Exit;
    end;
    Result := True;
  finally
    sqlite3_close(db);
  end;
end;

function VaultPut(const Id, Secret: AnsiString; out Err: AnsiString): Boolean;
var
  db: psqlite3;
  rows: TStringArray;
begin
  Result := False;
  if not VaultEnsureUnlocked(Err) then Exit;
  if not OpenDb(db, Err) then Exit;
  try
    Result := Exec(db, 'INSERT OR REPLACE INTO secrets VALUES(?, ?)',
                   [Id, ToHex(Seal(Key, Secret))], rows, Err);
  finally
    sqlite3_close(db);
  end;
end;

function VaultDelete(const Id: AnsiString; out Err: AnsiString): Boolean;
var
  db: psqlite3;
  rows: TStringArray;
begin
  Result := False;
  if not OpenDb(db, Err) then Exit;
  try
    Result := Exec(db, 'DELETE FROM secrets WHERE id = ?', [Id], rows, Err);
  finally
    sqlite3_close(db);
  end;
end;

function VaultHas(const Id: AnsiString): Boolean;
var
  db: psqlite3;
  rows: TStringArray;
  err: AnsiString;
begin
  Result := False;
  if not FileExists(VaultPath) then Exit;
  if not OpenDb(db, err) then Exit;
  try
    Result := Exec(db, 'SELECT 1 FROM secrets WHERE id = ?', [Id], rows, err) and
              (Length(rows) > 0);
  finally
    sqlite3_close(db);
  end;
end;

end.
