unit Share7.Fs.Scanner;

interface

uses
  mormot.core.base,
  Share7.Core.Types;

/// Recursively scan a directory and build a file manifest.
/// Excludes share7.exe and .share7tmp files.
procedure ScanDirectory(const ARootDir: string; out AEntries: TFileEntries);

/// Compute SHA-256 hash for a single file.
function HashFile(const AFilePath: string): RawUtf8;

/// Find a file entry by relative path (case-insensitive). Returns nil if not found.
function FindEntry(const AEntries: TFileEntries; const ARelPath: RawUtf8): PFileEntry;

/// Remove a file entry by relative path (case-insensitive). Returns True if found and removed.
function RemoveEntry(var AEntries: TFileEntries; const ARelPath: RawUtf8): Boolean;

implementation

uses
  SysUtils,
  mormot.core.os,
  mormot.core.text,
  mormot.core.datetime,
  mormot.crypt.core;

function EndsWithText(const AStr, ASuffix: string): Boolean;
var
  SLen, PLen: Integer;
begin
  SLen := Length(AStr);
  PLen := Length(ASuffix);
  if PLen > SLen then
    Result := False
  else
    Result := SameText(Copy(AStr, SLen - PLen + 1, PLen), ASuffix);
end;

function ShouldExclude(const AName: string): Boolean;
begin
  Result := SameText(AName, 'share7.exe') or
            EndsWithText(AName, '.share7tmp');
end;

function FileUtcTime(const AFullPath: TFileName): TDateTime;
var
  Unix: Int64;
begin
  Unix := FileAgeToUnixTimeUtc(AFullPath);
  if Unix <> 0 then
    Result := UnixTimeToDateTime(Unix)
  else
    Result := 0;
end;

function HashFile(const AFilePath: string): RawUtf8;
var
  Handle: THandle;
  Hasher: TSha256;
  Buf: array[0..65535] of Byte;
  BytesRead: Integer;
begin
  Result := '';
  Handle := FileOpen(AFilePath, fmOpenRead or fmShareDenyNone);
  if Handle = THandle(-1) then
    Exit;
  try
    Hasher.Init;
    repeat
      BytesRead := FileRead(Handle, Buf[0], SizeOf(Buf));
      if BytesRead > 0 then
        Hasher.Update(@Buf[0], BytesRead);
    until BytesRead <= 0;
    Result := Sha256DigestToString(Hasher.Final);
  finally
    FileClose(Handle);
  end;
end;

function FindEntry(const AEntries: TFileEntries; const ARelPath: RawUtf8): PFileEntry;
var
  I: Integer;
begin
  for I := 0 to High(AEntries) do
    if PropNameEquals(AEntries[I].RelPath, ARelPath) then
    begin
      Result := @AEntries[I];
      Exit;
    end;
  Result := nil;
end;

function RemoveEntry(var AEntries: TFileEntries; const ARelPath: RawUtf8): Boolean;
var
  I, J: Integer;
begin
  for I := High(AEntries) downto 0 do
    if PropNameEquals(AEntries[I].RelPath, ARelPath) then
    begin
      for J := I to High(AEntries) - 1 do
        AEntries[J] := AEntries[J + 1];
      SetLength(AEntries, Length(AEntries) - 1);
      Result := True;
      Exit;
    end;
  Result := False;
end;

procedure DoScan(const ARootDir, ACurrentDir: string; var AEntries: TFileEntries);
var
  SR: TSearchRec;
  SearchPath: string;
  FullPath: string;
  RelPath: string;
  Entry: TFileEntry;
begin
  SearchPath := IncludeTrailingPathDelimiter(ACurrentDir) + '*';
  if FindFirst(SearchPath, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      if ShouldExclude(SR.Name) then
        Continue;

      FullPath := IncludeTrailingPathDelimiter(ACurrentDir) + SR.Name;

      if (SR.Attr and faDirectory) <> 0 then
        DoScan(ARootDir, FullPath, AEntries)
      else
      begin
        RelPath := ExtractRelativePath(
          IncludeTrailingPathDelimiter(ARootDir), FullPath);
        // Normalize to forward slashes
        RelPath := StringReplace(RelPath, '\', '/', [rfReplaceAll]);

        Entry.RelPath := RawUtf8(RelPath);
        Entry.Size := SR.Size;
        Entry.ModifiedUtc := FileUtcTime(TFileName(FullPath));
        Entry.Sha256 := '';
        SetLength(AEntries, Length(AEntries) + 1);
        AEntries[High(AEntries)] := Entry;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure ScanDirectory(const ARootDir: string; out AEntries: TFileEntries);
begin
  AEntries := nil;
  DoScan(ARootDir, ARootDir, AEntries);
end;

end.
