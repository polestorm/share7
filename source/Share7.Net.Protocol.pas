unit Share7.Net.Protocol;

{$SCOPEDENUMS ON}

interface

uses
  mormot.core.base,
  Share7.Core.Types;

/// Encode a UDP announce/ack/goodbye message into a binary buffer.
/// Wire format: [4B magic][1B kind][8B utcTime][2B tcpPort][1B nameLen][NB name]
function EncodeUdpMessage(AKind: TShare7MessageKind; ATcpPort: Word;
  const AName: RawUtf8): RawByteString;

/// Decode a UDP message. Returns False if magic mismatch or malformed.
function DecodeUdpMessage(AData: PByte; ALen: Integer;
  out AKind: TShare7MessageKind; out AUtcTime: TDateTime;
  out ATcpPort: Word; out AName: RawUtf8): Boolean;

/// Encode a file list into a binary buffer for TCP transfer.
function EncodeFileList(const AEntries: TFileEntries): RawByteString;

/// Decode a file list from a binary buffer.
function DecodeFileList(const AData: RawByteString): TFileEntries;

implementation

uses
  System.SysUtils,
  System.Math;

function EncodeUdpMessage(AKind: TShare7MessageKind; ATcpPort: Word;
  const AName: RawUtf8): RawByteString;
begin
  var NameLen: Byte := Length(AName);
  var TotalLen := 4 + 1 + 8 + 2 + 1 + NameLen;
  SetLength(Result, TotalLen);

  var P: PByte := @Result[1];

  PCardinal(P)^ := SHARE7_MAGIC;
  Inc(P, 4);

  P^ := Byte(AKind);
  Inc(P);

  var Utc := NowUtc;
  PDouble(P)^ := Utc;
  Inc(P, 8);

  PWord(P)^ := ATcpPort;
  Inc(P, 2);

  P^ := NameLen;
  Inc(P);

  if NameLen > 0 then
    Move(AName[1], P^, NameLen);
end;

function DecodeUdpMessage(AData: PByte; ALen: Integer;
  out AKind: TShare7MessageKind; out AUtcTime: TDateTime;
  out ATcpPort: Word; out AName: RawUtf8): Boolean;
begin
  Result := False;
  // Minimum: magic(4) + kind(1) + utc(8) + port(2) + nameLen(1) = 16
  if ALen < 16 then
    Exit;

  var P := AData;

  if PCardinal(P)^ <> SHARE7_MAGIC then
    Exit;
  Inc(P, 4);

  var KindByte := P^;
  if not (KindByte in [Byte(TShare7MessageKind.smkAnnounce)..Byte(TShare7MessageKind.smkGoodbye)]) then
    Exit;
  AKind := TShare7MessageKind(KindByte);
  Inc(P);

  AUtcTime := PDouble(P)^;
  Inc(P, 8);

  ATcpPort := PWord(P)^;
  Inc(P, 2);

  var NameLen := P^;
  Inc(P);

  if ALen < 16 + NameLen then
    Exit;

  SetString(AName, PAnsiChar(P), NameLen);
  Result := True;
end;

function EncodeFileList(const AEntries: TFileEntries): RawByteString;
begin
  // Format: [4B count][ for each: [2B pathLen][path][8B size][8B modUtc][64B sha256hex] ]
  var Count: Cardinal := Length(AEntries);

  // Estimate size
  var EstSize := 4;
  for var I := 0 to High(AEntries) do
    Inc(EstSize, 2 + Length(AEntries[I].RelPath) + 8 + 8 + 64);

  SetLength(Result, EstSize);
  var P: PByte := @Result[1];

  PCardinal(P)^ := Count;
  Inc(P, 4);

  for var I := 0 to High(AEntries) do
  begin
    var PathLen: Word := Length(AEntries[I].RelPath);
    PWord(P)^ := PathLen;
    Inc(P, 2);

    if PathLen > 0 then
    begin
      Move(AEntries[I].RelPath[1], P^, PathLen);
      Inc(P, PathLen);
    end;

    PInt64(P)^ := AEntries[I].Size;
    Inc(P, 8);

    PDouble(P)^ := AEntries[I].ModifiedUtc;
    Inc(P, 8);

    // SHA-256 as 64 hex chars, zero-padded
    var HashStr := AEntries[I].Sha256;
    var HashBuf: array[0..63] of AnsiChar;
    FillChar(HashBuf, 64, 0);
    if Length(HashStr) > 0 then
      Move(HashStr[1], HashBuf[0], Min(Length(HashStr), 64));
    Move(HashBuf[0], P^, 64);
    Inc(P, 64);
  end;

  // Trim to actual size
  SetLength(Result, PByte(P) - PByte(@Result[1]));
end;

function DecodeFileList(const AData: RawByteString): TFileEntries;
begin
  Result := nil;
  if Length(AData) < 4 then
    Exit;

  var P: PByte := @AData[1];
  var Remaining := Length(AData);

  var Count := PCardinal(P)^;
  Inc(P, 4);
  Dec(Remaining, 4);

  SetLength(Result, Count);

  for var I := 0 to Count - 1 do
  begin
    if Remaining < 2 then
      Exit;

    var PathLen := PWord(P)^;
    Inc(P, 2);
    Dec(Remaining, 2);

    if Remaining < PathLen then
      Exit;
    SetString(Result[I].RelPath, PAnsiChar(P), PathLen);
    Inc(P, PathLen);
    Dec(Remaining, PathLen);

    if Remaining < 8 + 8 + 64 then
      Exit;

    Result[I].Size := PInt64(P)^;
    Inc(P, 8);

    Result[I].ModifiedUtc := PDouble(P)^;
    Inc(P, 8);

    var HashBuf: RawUtf8;
    SetString(HashBuf, PAnsiChar(P), 64);
    Result[I].Sha256 := RawUtf8(string(HashBuf).Trim);
    Inc(P, 64);
    Dec(Remaining, 8 + 8 + 64);
  end;
end;

end.
