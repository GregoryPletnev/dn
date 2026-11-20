{ dnlsident — this device's LocalSend identity: a self-signed certificate.

  LocalSend with Encryption on (the default) runs mutual TLS: the
  receiving device asks the sender for a client certificate and refuses
  the connection without one (TLS alert 116, certificate required). The
  device fingerprint everyone announces is the SHA-256 of that
  certificate, uppercase hex.

  dn makes its certificate once, with the openssl command, under
  ConfigDir/localsend:
    cert.pem, key.pem  the certificate and its key (key mode 0600)
    cert.p12           the same pair as PKCS#12 (macOS only): the system
                       curl (Secure Transport) takes a client certificate
                       in that form only. It is written by the system
                       /usr/bin/openssl (LibreSSL), whose PKCS#12
                       encryption Secure Transport can read.

  Only the main process creates the files (LsEnsureIdentity); the receive
  helper only reads them, so both report the same fingerprint. }
unit dnlsident;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

{ ConfigDir/localsend }
function LsIdentityDir: AnsiString;

{ Create the certificate when it is missing. False (Err says why) when
  openssl is not available or fails; LocalSend then works without an
  identity: discovery and plain HTTP still do, HTTPS peers refuse. }
function LsEnsureIdentity(out Err: AnsiString): Boolean;

{ SHA-256 of the certificate, uppercase hex; '' without one }
function LsIdentityFingerprint: AnsiString;

{ the curl arguments that present the certificate; empty without one }
function LsCurlClientCertArgs: TStringArray;

implementation

uses
  BaseUnix, process, dnconfig, dnsha256;

const
  P12Pass = 'dn';

var
  CachedFp: AnsiString = '';
  CachedFpFor: AnsiString = '';
  CurlKind: Integer = 0;          // 0 unknown, 1 Secure Transport, 2 other

function LsIdentityDir: AnsiString;
begin
  Result := IncludeTrailingPathDelimiter(ConfigDir) + 'localsend';
end;

function CertPath: AnsiString;
begin
  Result := LsIdentityDir + '/cert.pem';
end;

function KeyPath: AnsiString;
begin
  Result := LsIdentityDir + '/key.pem';
end;

function P12Path: AnsiString;
begin
  Result := LsIdentityDir + '/cert.p12';
end;

function ReadFileText(const Path: AnsiString): AnsiString;
var
  f: THandle;
  n: Int64;
begin
  Result := '';
  f := FileOpen(Path, fmOpenRead or fmShareDenyNone);
  if f = THandle(-1) then Exit;
  try
    n := FileSeek(f, 0, 2);
    FileSeek(f, 0, 0);
    if n > 0 then
    begin
      SetLength(Result, n);
      if FileRead(f, Result[1], n) <> n then Result := '';
    end;
  finally
    FileClose(f);
  end;
end;

function RunOk(const Exe: AnsiString; const Args: array of AnsiString): Boolean;
var
  outp: AnsiString;
  status: Integer;
begin
  Result := (RunCommandIndir(LsIdentityDir, Exe, Args, outp, status,
                             [poStderrToOutPut]) = 0) and (status = 0);
end;

function OpensslFor(Pkcs12: Boolean): AnsiString;
begin
  Result := 'openssl';
  {$ifdef darwin}
  if Pkcs12 and FileExists('/usr/bin/openssl') then
    Result := '/usr/bin/openssl';
  {$endif}
end;

function LsEnsureIdentity(out Err: AnsiString): Boolean;
begin
  Err := '';
  Result := False;
  if not ForceDirectories(LsIdentityDir) then
  begin
    Err := 'cannot create ' + LsIdentityDir;
    Exit;
  end;
  if not (FileExists(CertPath) and FileExists(KeyPath)) then
  begin
    if ExeSearch('openssl', GetEnvironmentVariable('PATH')) = '' then
    begin
      Err := 'openssl is not on PATH';
      Exit;
    end;
    DeleteFile(P12Path);       // belongs to the old pair, if any
    if not RunOk(OpensslFor(False),
         ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
          '-subj', '/CN=DN', '-keyout', KeyPath, '-out', CertPath]) then
    begin
      DeleteFile(KeyPath);
      DeleteFile(CertPath);
      Err := 'openssl could not create the certificate';
      Exit;
    end;
    fpChmod(KeyPath, &600);
  end;
  {$ifdef darwin}
  if not FileExists(P12Path) then
  begin
    if not RunOk(OpensslFor(True),
         ['pkcs12', '-export', '-inkey', KeyPath, '-in', CertPath,
          '-out', P12Path, '-name', 'DN', '-passout', 'pass:' + P12Pass]) then
    begin
      DeleteFile(P12Path);
      Err := 'openssl could not write ' + P12Path;
      Exit;
    end;
    fpChmod(P12Path, &600);
  end;
  {$endif}
  Result := True;
end;

function LsIdentityFingerprint: AnsiString;
var
  der: AnsiString;
begin
  Result := '';
  if not FileExists(CertPath) then Exit;
  { cached per path: tests switch DN_CONFIG_DIR between runs, not within }
  if CachedFpFor = CertPath then Exit(CachedFp);
  der := PemFirstCertDer(ReadFileText(CertPath));
  if der = '' then Exit;
  Result := UpperCase(Sha256Hex(der));
  CachedFp := Result;
  CachedFpFor := CertPath;
end;

function CurlIsSecureTransport: Boolean;
var
  outp: AnsiString;
  status: Integer;
begin
  if CurlKind = 0 then
  begin
    CurlKind := 2;
    if (RunCommandIndir(GetCurrentDir, 'curl', ['--version'], outp, status,
                        []) = 0) and (Pos('SecureTransport', outp) > 0) then
      CurlKind := 1;
  end;
  Result := CurlKind = 1;
end;

function LsCurlClientCertArgs: TStringArray;
begin
  SetLength(Result, 0);
  if not (FileExists(CertPath) and FileExists(KeyPath)) then Exit;
  if CurlIsSecureTransport then
  begin
    if not FileExists(P12Path) then Exit;
    Result := ['--cert-type', 'P12', '--cert', P12Path + ':' + P12Pass];
  end
  else
    Result := ['--cert', CertPath, '--key', KeyPath];
end;

end.
