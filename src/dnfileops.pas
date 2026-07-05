{ dnfileops — recursive file operations for the panels. }
unit dnfileops;

{$mode objfpc}{$H+}

interface

function CopyTree(const Src, Dst: AnsiString; out Err: AnsiString): Boolean;
function DeleteTree(const Path: AnsiString; out Err: AnsiString): Boolean;
function MoveTree(const Src, Dst: AnsiString; out Err: AnsiString): Boolean;
function TreeSize(const Path: AnsiString): Int64;

implementation

uses
  SysUtils, Classes;

function CopyOneFile(const Src, Dst: AnsiString; out Err: AnsiString): Boolean;
var
  si, so: TFileStream;
begin
  Result := False;
  Err := '';
  try
    si := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
    try
      so := TFileStream.Create(Dst, fmCreate);
      try
        if si.Size > 0 then
          so.CopyFrom(si, si.Size);
      finally
        so.Free;
      end;
    finally
      si.Free;
    end;
    Result := True;
  except
    on E: Exception do Err := E.Message;
  end;
end;

function CopyTree(const Src, Dst: AnsiString; out Err: AnsiString): Boolean;
var
  sr: TSearchRec;
begin
  Err := '';
  if DirectoryExists(Src) then
  begin
    if not ForceDirectories(Dst) then
    begin
      Err := 'cannot create directory ' + Dst;
      Exit(False);
    end;
    if FindFirst(IncludeTrailingPathDelimiter(Src) + '*', faAnyFile, sr) = 0 then
    begin
      try
        repeat
          if (sr.Name = '.') or (sr.Name = '..') then Continue;
          if not CopyTree(IncludeTrailingPathDelimiter(Src) + sr.Name,
                          IncludeTrailingPathDelimiter(Dst) + sr.Name, Err) then
            Exit(False);
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;
    Result := True;
  end
  else
    Result := CopyOneFile(Src, Dst, Err);
end;

function DeleteTree(const Path: AnsiString; out Err: AnsiString): Boolean;
var
  sr: TSearchRec;
begin
  Err := '';
  if DirectoryExists(Path) then
  begin
    if FindFirst(IncludeTrailingPathDelimiter(Path) + '*', faAnyFile, sr) = 0 then
    begin
      try
        repeat
          if (sr.Name = '.') or (sr.Name = '..') then Continue;
          if not DeleteTree(IncludeTrailingPathDelimiter(Path) + sr.Name, Err) then
            Exit(False);
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;
    if not RemoveDir(Path) then
    begin
      Err := 'cannot remove directory ' + Path;
      Exit(False);
    end;
    Result := True;
  end
  else
  begin
    Result := DeleteFile(Path);
    if not Result then
      Err := 'cannot delete ' + Path;
  end;
end;

function TreeSize(const Path: AnsiString): Int64;
var
  sr: TSearchRec;
begin
  Result := 0;
  if not DirectoryExists(Path) then
  begin
    if FindFirst(Path, faAnyFile, sr) = 0 then
    begin
      Result := sr.Size;
      FindClose(sr);
    end;
    Exit;
  end;
  if FindFirst(IncludeTrailingPathDelimiter(Path) + '*', faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if (sr.Attr and faDirectory) <> 0 then
          Inc(Result, TreeSize(IncludeTrailingPathDelimiter(Path) + sr.Name))
        else
          Inc(Result, sr.Size);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
end;

function MoveTree(const Src, Dst: AnsiString; out Err: AnsiString): Boolean;
begin
  Err := '';
  if RenameFile(Src, Dst) then
    Exit(True);
  { cross-device or other failure: copy then delete }
  Result := CopyTree(Src, Dst, Err) and DeleteTree(Src, Err);
end;

end.
