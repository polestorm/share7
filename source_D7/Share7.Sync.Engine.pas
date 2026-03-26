unit Share7.Sync.Engine;

interface

uses
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  Share7.Core.Types,
  Share7.Core.Captions,
  Share7.Fs.Watcher;

type
  TSyncStats = record
    Received: Integer;
    Sent: Integer;
    Deleted: Integer;
  end;

  /// Sync engine: merges file lists between local and remote peer,
  /// downloads newer files, handles deletions.
  TSyncEngine = record
    RootDir: string;
    Entries: ^TFileEntries;
    EntriesLock: ^TLightLock;
    Watcher: TFileWatcher;
  end;

procedure ClearSyncStats(var AStats: TSyncStats);

/// Perform initial sync with a peer: pull files newer on peer.
function SyncWithPeer(var AEngine: TSyncEngine; const APeerIP: RawUtf8;
  APeerPort: Word; const APeerName: RawUtf8): TSyncStats;

/// Handle a delete notification from a peer: delete local file.
procedure HandleRemoteDelete(var AEngine: TSyncEngine; const ARelPath: RawUtf8);

/// Handle a local file change: notify all peers to pull.
procedure NotifyPeersOfChange(const APeers: TPeerInfoDynArray);

/// Handle a local file deletion: notify all peers.
procedure NotifyPeersOfDelete(const ARelPath: RawUtf8;
  const APeers: TPeerInfoDynArray);

implementation

uses
  SysUtils,
  mormot.core.datetime,
  Share7.Net.Transfer,
  Share7.Fs.Scanner;

const
  SecsPerDay = 86400;
  PROGRESS_BAR_WIDTH = 20;
  PROGRESS_MIN_SIZE = 256 * 1024; // show progress bar for files >= 256 KB

type
  /// Helper object to provide a progress callback method with captured rel path.
  TSyncProgressHelper = class
  private
    FRelPath: RawUtf8;
  public
    constructor Create(const ARelPath: RawUtf8);
    procedure OnProgress(AReceived, ATotal: Int64);
  end;

constructor TSyncProgressHelper.Create(const ARelPath: RawUtf8);
begin
  inherited Create;
  FRelPath := ARelPath;
end;

procedure TSyncProgressHelper.OnProgress(AReceived, ATotal: Int64);
var
  Pct: Int64;
  Filled: Int64;
  Bar: RawUtf8;
  J: Integer;
  Line: RawUtf8;
begin
  if ATotal <= 0 then
    Exit;
  Pct := (AReceived * 100) div ATotal;
  Filled := (AReceived * PROGRESS_BAR_WIDTH) div ATotal;
  SetLength(Bar, PROGRESS_BAR_WIDTH);
  for J := 1 to PROGRESS_BAR_WIDTH do
    if J <= Filled then
      Bar[J] := '#'
    else
      Bar[J] := '.';
  Line := FormatUtf8(SCaptionFileProgress, [FRelPath, Bar, Pct, '%']);
  // Pad with spaces to overwrite previous longer line
  while Length(Line) < 78 do
    Line := Line + ' ';
  ConsoleWriteRaw(#13 + Line, True);
end;

{ TSyncStats }

procedure ClearSyncStats(var AStats: TSyncStats);
begin
  AStats.Received := 0;
  AStats.Sent := 0;
  AStats.Deleted := 0;
end;

{ Sync functions }

function SyncWithPeer(var AEngine: TSyncEngine; const APeerIP: RawUtf8;
  APeerPort: Word; const APeerName: RawUtf8): TSyncStats;
var
  RemoteEntries: TFileEntries;
  I: Integer;
  NeedDownload: Boolean;
  LocalEntry: PFileEntry;
  TimeDiff: Integer;
  LocalPath: string;
  LocalHash: RawUtf8;
  RelPath: RawUtf8;
  DestPath: string;
  ShowProgress: Boolean;
  ProgressHelper: TSyncProgressHelper;
  ProgressCb: TTransferProgress;
  Downloaded: Boolean;
  Attempt: Integer;
  Existing: PFileEntry;
begin
  ClearSyncStats(Result);

  RemoteEntries := TransferRequestFileList(APeerIP, APeerPort);
  if Length(RemoteEntries) = 0 then
    Exit;

  for I := 0 to High(RemoteEntries) do
  begin
    NeedDownload := False;

    AEngine.EntriesLock^.Lock;
    try
      LocalEntry := FindEntry(AEngine.Entries^, RemoteEntries[I].RelPath);
      if LocalEntry = nil then
        NeedDownload := True
      else
      begin
        TimeDiff := Round(Abs(RemoteEntries[I].ModifiedUtc - LocalEntry^.ModifiedUtc) * SecsPerDay);
        if TimeDiff > 1 then
        begin
          if RemoteEntries[I].ModifiedUtc > LocalEntry^.ModifiedUtc then
            NeedDownload := True;
        end
        else if (TimeDiff <= 1) and (RemoteEntries[I].Size <> LocalEntry^.Size) then
        begin
          LocalPath := IncludeTrailingPathDelimiter(AEngine.RootDir) +
            StringReplace(string(LocalEntry^.RelPath), '/', '\', [rfReplaceAll]);
          LocalHash := HashFile(LocalPath);
          if (RemoteEntries[I].Sha256 = '') or (LocalHash <> RemoteEntries[I].Sha256) then
            NeedDownload := True;
        end;
      end;
    finally
      AEngine.EntriesLock^.UnLock;
    end;

    if NeedDownload then
    begin
      RelPath := RemoteEntries[I].RelPath;
      DestPath := IncludeTrailingPathDelimiter(AEngine.RootDir) +
        StringReplace(string(RelPath), '/', '\', [rfReplaceAll]);

      // Suppress watcher for this path to prevent feedback loop
      if AEngine.Watcher <> nil then
        AEngine.Watcher.SuppressPath(RelPath);
      try
        ShowProgress := RemoteEntries[I].Size >= PROGRESS_MIN_SIZE;
        ProgressHelper := nil;
        ProgressCb := nil;
        if ShowProgress then
        begin
          ProgressHelper := TSyncProgressHelper.Create(RelPath);
          ProgressCb := ProgressHelper.OnProgress;
        end;
        try
          Downloaded := TransferDownloadFile(APeerIP, APeerPort,
            RelPath, DestPath, ProgressCb);
          Attempt := 1;
          while (not Downloaded) and (Attempt < FILE_RETRY_COUNT) do
          begin
            Inc(Attempt);
            Sleep(FILE_RETRY_DELAY_MS * Attempt);
            Downloaded := TransferDownloadFile(APeerIP, APeerPort,
              RelPath, DestPath, ProgressCb);
          end;
        finally
          ProgressHelper.Free;
        end;

        if ShowProgress then
          ConsoleWriteRaw(#13); // move past progress line

        if Downloaded then
        begin
          // Preserve original modification timestamp to prevent sync loops
          FileSetDateFromUnixUtc(TFileName(DestPath),
            DateTimeToUnixTime(RemoteEntries[I].ModifiedUtc));

          Inc(Result.Received);
          ConsoleWrite(FormatUtf8(SCaptionFileReceived,
            [RelPath, FormatFileSize(RemoteEntries[I].Size)]), ccLightCyan);

          AEngine.EntriesLock^.Lock;
          try
            Existing := FindEntry(AEngine.Entries^, RelPath);
            if Existing <> nil then
            begin
              Existing^.Size := RemoteEntries[I].Size;
              Existing^.ModifiedUtc := RemoteEntries[I].ModifiedUtc;
              Existing^.Sha256 := RemoteEntries[I].Sha256;
            end
            else
            begin
              SetLength(AEngine.Entries^, Length(AEngine.Entries^) + 1);
              AEngine.Entries^[High(AEngine.Entries^)] := RemoteEntries[I];
            end;
          finally
            AEngine.EntriesLock^.UnLock;
          end;
        end;
      finally
        // Delay unsuppress so watcher debounce window fully passes
        Sleep(WATCHER_DEBOUNCE_MS * 3);
        if AEngine.Watcher <> nil then
          AEngine.Watcher.UnsuppressPath(RelPath);
      end;
    end;
  end;
end;

procedure HandleRemoteDelete(var AEngine: TSyncEngine; const ARelPath: RawUtf8);
var
  FullPath: string;
begin
  if Pos('..', string(ARelPath)) > 0 then
    Exit;

  FullPath := IncludeTrailingPathDelimiter(AEngine.RootDir) +
    StringReplace(string(ARelPath), '/', '\', [rfReplaceAll]);

  if FileExists(FullPath) then
  begin
    // Suppress watcher to prevent echoing the delete back
    if AEngine.Watcher <> nil then
      AEngine.Watcher.SuppressPath(ARelPath);
    try
      DeleteFile(FullPath);
      ConsoleWrite(FormatUtf8(SCaptionFileRemoteDeleted, [ARelPath]), ccLightRed);

      AEngine.EntriesLock^.Lock;
      try
        RemoveEntry(AEngine.Entries^, ARelPath);
      finally
        AEngine.EntriesLock^.UnLock;
      end;
    finally
      Sleep(WATCHER_DEBOUNCE_MS + 50);
      if AEngine.Watcher <> nil then
        AEngine.Watcher.UnsuppressPath(ARelPath);
    end;
  end;
end;

procedure NotifyPeersOfChange(const APeers: TPeerInfoDynArray);
var
  I: Integer;
begin
  for I := 0 to High(APeers) do
    TransferSendChangesNotify(APeers[I].IP, APeers[I].TcpPort);
end;

procedure NotifyPeersOfDelete(const ARelPath: RawUtf8;
  const APeers: TPeerInfoDynArray);
var
  I: Integer;
begin
  for I := 0 to High(APeers) do
    TransferSendDeleteNotify(APeers[I].IP, APeers[I].TcpPort, ARelPath);
end;

end.
