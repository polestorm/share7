unit Share7.Tests.Protocol;

interface

procedure TestUdpRoundtrip;
procedure TestUdpBadMagic;
procedure TestUdpShortData;
procedure TestFileListRoundtrip;
procedure TestFileListEmpty;

implementation

uses
  System.SysUtils,
  System.Math,
  mormot.core.base,
  Share7.Core.Types,
  Share7.Net.Protocol;

procedure Assert(ACondition: Boolean; const AMsg: string = 'assertion failed');
begin
  if not ACondition then
    raise Exception.Create(AMsg);
end;

procedure TestUdpRoundtrip;
begin
  var Encoded := EncodeUdpMessage(TShare7MessageKind.smkAnnounce, 7732, 'test-peer');

  var Kind: TShare7MessageKind;
  var UtcTime: TDateTime;
  var TcpPort: Word;
  var Name: RawUtf8;

  var Ok := DecodeUdpMessage(@Encoded[1], Length(Encoded), Kind, UtcTime, TcpPort, Name);
  Assert(Ok, 'decode failed');
  Assert(Kind = TShare7MessageKind.smkAnnounce, 'wrong kind');
  Assert(TcpPort = 7732, 'wrong port');
  Assert(Name = 'test-peer', 'wrong name: ' + string(Name));
  Assert(Abs(UtcTime - NowUtc) < 1 / 86400, 'UTC time too far off'); // within 1 second
end;

procedure TestUdpBadMagic;
begin
  var Buf: array[0..31] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PCardinal(@Buf[0])^ := $DEADBEEF;

  var Kind: TShare7MessageKind;
  var UtcTime: TDateTime;
  var TcpPort: Word;
  var Name: RawUtf8;

  var Ok := DecodeUdpMessage(@Buf[0], SizeOf(Buf), Kind, UtcTime, TcpPort, Name);
  Assert(not Ok, 'should reject bad magic');
end;

procedure TestUdpShortData;
begin
  var Buf: array[0..3] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);

  var Kind: TShare7MessageKind;
  var UtcTime: TDateTime;
  var TcpPort: Word;
  var Name: RawUtf8;

  var Ok := DecodeUdpMessage(@Buf[0], SizeOf(Buf), Kind, UtcTime, TcpPort, Name);
  Assert(not Ok, 'should reject short data');
end;

procedure TestFileListRoundtrip;
begin
  var Entries: TFileEntries;
  SetLength(Entries, 2);

  Entries[0].RelPath := 'docs/readme.txt';
  Entries[0].Size := 1234;
  Entries[0].ModifiedUtc := EncodeDate(2025, 6, 15) + EncodeTime(10, 30, 0, 0);
  Entries[0].Sha256 := 'abc123def456';

  Entries[1].RelPath := 'photo.jpg';
  Entries[1].Size := 5678900;
  Entries[1].ModifiedUtc := EncodeDate(2025, 7, 1) + EncodeTime(8, 0, 0, 0);
  Entries[1].Sha256 := '';

  var Encoded := EncodeFileList(Entries);
  var Decoded := DecodeFileList(Encoded);

  Assert(Length(Decoded) = 2, 'expected 2 entries, got ' + IntToStr(Length(Decoded)));
  Assert(Decoded[0].RelPath = 'docs/readme.txt', 'wrong path 0');
  Assert(Decoded[0].Size = 1234, 'wrong size 0');
  Assert(Decoded[1].RelPath = 'photo.jpg', 'wrong path 1');
  Assert(Decoded[1].Size = 5678900, 'wrong size 1');
end;

procedure TestFileListEmpty;
begin
  var Entries: TFileEntries;
  SetLength(Entries, 0);

  var Encoded := EncodeFileList(Entries);
  var Decoded := DecodeFileList(Encoded);
  Assert(Length(Decoded) = 0, 'expected 0 entries');
end;

end.
