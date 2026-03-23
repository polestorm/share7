unit Share7.Core.Types;

{$SCOPEDENUMS ON}

interface

uses
  mormot.core.base;

const
  SHARE7_VERSION = '1.0';
  SHARE7_MAGIC: Cardinal = $53374D47; // 'S7MG'
  SHARE7_UDP_PORT = 7731;
  SHARE7_TCP_PORT = 7732;
  CLOCK_MAX_DRIFT_SEC = 5;
  PEER_TIMEOUT_SEC = 15;
  ANNOUNCE_INTERVAL_TICKS = 10; // 10 x 512ms = ~5s
  WATCHER_DEBOUNCE_MS = 200;
  FILE_RETRY_COUNT = 3;
  FILE_RETRY_DELAY_MS = 100;
  TRANSFER_BUFFER_SIZE = 65536; // 64KB

type
  TShare7MessageKind = (
    smkAnnounce = 1,
    smkAnnounceAck = 2,
    smkGoodbye = 3
  );

  TFileEntry = record
    RelPath: RawUtf8;
    Size: Int64;
    ModifiedUtc: TDateTime;
    Sha256: RawUtf8;
  end;
  PFileEntry = ^TFileEntry;
  TFileEntries = array of TFileEntry;

  TPeerInfo = record
    Name: RawUtf8;
    IP: RawUtf8;
    TcpPort: Word;
    LastSeenTick: Int64;
    UtcTime: TDateTime;
  end;
  PPeerInfo = ^TPeerInfo;
  TPeerInfoDynArray = array of TPeerInfo;
  TFileAction = (faCreated, faModified, faDeleted, faRenamed);

  TTcpCommand = Byte;

const
  TCP_REQUEST_FILE_LIST = 1;
  TCP_REQUEST_FILE      = 2;
  TCP_NOTIFY_DELETE     = 3;
  TCP_NOTIFY_CHANGES    = 4;

function FormatFileSize(ASize: Int64): RawUtf8;
function TimeStampStr: RawUtf8;
function NowUtc: TDateTime;

implementation

uses
  System.SysUtils,
  mormot.core.os;

function FormatFileSize(ASize: Int64): RawUtf8;
begin
  var Fmt: TFormatSettings;
  Fmt := TFormatSettings.Invariant;
  if ASize < 1024 then
    Result := RawUtf8(IntToStr(ASize) + ' B')
  else if ASize < 1024 * 1024 then
    Result := RawUtf8(Format('%.1f KB', [ASize / 1024], Fmt))
  else if ASize < 1024 * 1024 * 1024 then
    Result := RawUtf8(Format('%.1f MB', [ASize / (1024 * 1024)], Fmt))
  else
    Result := RawUtf8(Format('%.1f GB', [ASize / (1024 * 1024 * 1024)], Fmt));
end;

function TimeStampStr: RawUtf8;
begin
  Result := RawUtf8(FormatDateTime('hh:nn:ss', Now));
end;

function NowUtc: TDateTime;
begin
  Result := mormot.core.os.NowUtc;
end;

end.
